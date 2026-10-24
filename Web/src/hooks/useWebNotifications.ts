// Rune Weaver Dashboard — Hook to manage in-app unread attention badges from WebSocket events.
// OS-level desktop notifications are owned exclusively by the native macOS Menu Bar app.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSharedWebSocket } from "./useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
} from "./useSharedWebSocket";
import { normalizeSessionID } from "../approvalsSession";
import {
  DEFAULT_NOTIFICATIONS_CONFIG,
  getSettings,
  isGoalNeedsInputProactive,
  isIdeaProposedProactive,
  notificationsConfig,
  resolveNotificationsConfig,
} from "../api";
import type {
  NotificationsConfigData,
  SettingsResponse,
} from "../api";

// Reads the filing identity from an approval prompt so rebroadcasts for the same filing collapse to
// one badge bump.
function approvalRequestID(request: Record<string, unknown>): string | undefined {
  const raw = request.id;
  if (typeof raw === "string" && raw.trim().length > 0) return raw.trim();
  return undefined;
}

// Reads the resolved identity across the decided wire shapes the engine may emit.
function decidedApprovalID(frame: WSGenericFrame): string | undefined {
  const candidates: unknown[] = [frame.id, frame.approvalID, frame.approvalId];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate.trim();
    }
  }
  const nestedKeys = ["request", "approval"] as const;
  for (const key of nestedKeys) {
    const nested: unknown = frame[key];
    if (nested && typeof nested === "object" && !Array.isArray(nested)) {
      const nestedID: unknown = (nested as Record<string, unknown>).id;
      if (typeof nestedID === "string" && nestedID.trim().length > 0) {
        return nestedID.trim();
      }
    }
  }
  return undefined;
}

// Decided broadcast family that evicts one pending filing. Kept as a set so
// a newly added engine spelling cannot leave the badge pinned while the
// inbox already removed the card.
const DECIDED_FRAME_TYPES: ReadonlySet<string> = new Set([
  "approval_decided",
  "approval_resolved",
  "approval_removed",
  "approval_deleted",
  "approval_completed",
  "approval_cancelled",
]);

// Bound for remembered decided ids. The set exists only to collapse repeat
// broadcasts for the same resolution, so it must not grow with session age;
// evicting oldest-first keeps dedup effective while holding memory flat.
const MAX_DECIDED_IDS = 500;

function trackDecidedID(store: Set<string>, id: string): void {
  store.add(id);
  if (store.size <= MAX_DECIDED_IDS) return;
  const excess = store.size - MAX_DECIDED_IDS;
  const iterator = store.values();
  for (let i = 0; i < excess; i++) {
    const next = iterator.next();
    if (next.done) break;
    store.delete(next.value);
  }
}

export interface UseWebNotificationsOptions {
  settings?: SettingsResponse | null;
  notifications?: Partial<NotificationsConfigData> | null;
}

function overridePrefsFromArg(
  arg: UseWebNotificationsOptions | SettingsResponse | Partial<NotificationsConfigData> | null | undefined,
): NotificationsConfigData | undefined {
  if (!arg || typeof arg !== "object") return undefined;
  const record = arg as Record<string, unknown>;
  if ("settings" in record) {
    const settings = record["settings"] as SettingsResponse | null | undefined;
    if (settings && typeof settings === "object") return notificationsConfig(settings);
    return undefined;
  }
  if ("notifications" in record) {
    const value = record["notifications"] as Partial<NotificationsConfigData> | null | undefined;
    if (value && typeof value === "object") return resolveNotificationsConfig(value);
    if (value == null && "configPath" in record) {
      return notificationsConfig(record as unknown as SettingsResponse);
    }
    return undefined;
  }
  const keys = ["approvalRequested", "schedulerRun", "goalAdvance", "ideaProposed", "indexFailed", "chatFailed"];
  if (keys.some((key) => key in record)) {
    return resolveNotificationsConfig(record as unknown as Partial<NotificationsConfigData>);
  }
  if ("configPath" in record) {
    return notificationsConfig(record as unknown as SettingsResponse);
  }
  return undefined;
}

// Maps a run row kind to its interruption switch. Unknown kinds have no
// dedicated switch, so they surface unless every run switch is muted.
function runKindAllowsBadge(kind: unknown, prefs: NotificationsConfigData): boolean {
  const normalized = typeof kind === "string" ? kind.trim().toLowerCase() : "";
  if (normalized === "scheduler") return prefs.schedulerRun;
  if (normalized === "goal") return prefs.goalAdvance;
  if (normalized === "index") return prefs.indexFailed;
  if (normalized === "chat") return prefs.chatFailed;
  return prefs.schedulerRun || prefs.goalAdvance || prefs.indexFailed || prefs.chatFailed;
}

export function useWebNotifications(
  options?: UseWebNotificationsOptions | SettingsResponse | Partial<NotificationsConfigData> | null,
) {
  const overridePrefs = useMemo(() => overridePrefsFromArg(options), [options]);
  const hasOverride = overridePrefs !== undefined;
  const [livePrefs, setLivePrefs] = useState<NotificationsConfigData>(() => ({
    ...DEFAULT_NOTIFICATIONS_CONFIG,
  }));
  useEffect(() => {
    if (hasOverride) return;
    let cancelled = false;
    const refresh = () => {
      getSettings()
        .then((settings) => {
          if (cancelled) return;
          setLivePrefs(notificationsConfig(settings));
        })
        .catch(() => {
          // Unreadable settings keep the all-enabled fallback so badges still surface.
        });
    };
    refresh();
    const handleFocus = () => {
      refresh();
    };
    if (typeof window !== "undefined") {
      window.addEventListener("focus", handleFocus);
    }
    return () => {
      cancelled = true;
      if (typeof window !== "undefined") {
        window.removeEventListener("focus", handleFocus);
      }
    };
  }, [hasOverride]);
  const effectivePrefs = overridePrefs ?? livePrefs;
  const prefsRef = useRef<NotificationsConfigData>(effectivePrefs);
  useEffect(() => {
    prefsRef.current = effectivePrefs;
  }, [effectivePrefs]);

  // Unread count for runs that ended in an error or failure requiring operator
  // attention. Routine successful runs ("ok") do not badge the navbar.
  const [runsBadge, setRunsBadge] = useState(0);
  const [approvalsBadge, setApprovalsBadge] = useState(0);
  // Owner-attention count for goals parked awaiting input or proposed ideas.
  const [goalsAttention, setGoalsAttention] = useState(0);
  // Degraded-tool notices keep their own counter instead of inflating runs
  // or approvals; the bell surfaces the count as an amber badge cleared when
  // the chat view is shown or acknowledged.
  const [warningsBadge, setWarningsBadge] = useState(0);
  // Dedup seen warning lines so live plus terminal repeats never inflate the bell.
  const seenWarningsRef = useRef<Set<string>>(new Set());
  // Pending approval ids that already bumped the badge and still await a
  // decision. Enrichment rebroadcasts reuse the identical id, so the set is
  // what keeps a second arrival for the same filing from counting twice.
  const seenApprovalIDsRef = useRef<Set<string>>(new Set());
  // Decided ids already applied to the badge.
  const consumedDecidedIDsRef = useRef<Set<string>>(new Set());

  const handleMessage = useCallback((data: WSIncomingFrame) => {
    if (!data || typeof data !== "object") return;
    // Narrow the typed union through the generic frame so run and request
    // nests stay explicit without widening the handler to `any`.
    const frame = data as WSGenericFrame;
    const frameType = typeof frame.type === "string" ? frame.type : undefined;
    if (frameType === "run_completed" && frame.run && typeof frame.run === "object") {
      const run = frame.run as Record<string, unknown>;
      const status = typeof run.status === "string" ? run.status.toLowerCase() : undefined;
      // Only runs that failed, errored, or exceeded tool budget require operator attention.
      // Routine successful runs ("ok") do not badge the navbar.
      if (status === "error" || status === "failed" || status === "budget_exceeded") {
        if (!runKindAllowsBadge(run.kind, prefsRef.current)) return;
        setRunsBadge((prev) => prev + 1);
      }
    } else if (frameType === "approval" && frame.request && typeof frame.request === "object") {
      const request = frame.request as Record<string, unknown>;
      // Muted approval types suppress the badge bump while run logs and inbox
      // rows still record; the filing is marked consumed so its later decision
      // cannot drop a different filing's count.
      if (!prefsRef.current.approvalRequested) {
        const mutedID = approvalRequestID(request);
        if (mutedID !== undefined) trackDecidedID(consumedDecidedIDsRef.current, mutedID);
        return;
      }
      // One bump per filing: enrichment rebroadcasts share the identical id,
      // so an already-counted id never bumps again while a filing without a
      // usable id still surfaces rather than dropping silently.
      const filingID = approvalRequestID(request);
      if (filingID !== undefined) {
        if (
          !seenApprovalIDsRef.current.has(filingID) &&
          !consumedDecidedIDsRef.current.has(filingID)
        ) {
          seenApprovalIDsRef.current.add(filingID);
          setApprovalsBadge((prev) => prev + 1);
        }
      } else {
        setApprovalsBadge((prev) => prev + 1);
      }
    } else if (frameType !== undefined && DECIDED_FRAME_TYPES.has(frameType)) {
      // One drop per resolution across every decide surface: a seen filing leaves the pending set,
      // while a filing from before mount (or another tab, or the menu bar) still clears one stale
      // count.
      const resolvedID = decidedApprovalID(frame);
      if (resolvedID !== undefined) {
        if (consumedDecidedIDsRef.current.has(resolvedID)) return;
        if (seenApprovalIDsRef.current.has(resolvedID)) {
          seenApprovalIDsRef.current.delete(resolvedID);
        }
        trackDecidedID(consumedDecidedIDsRef.current, resolvedID);
        setApprovalsBadge((prev) => Math.max(0, prev - 1));
      } else {
        setApprovalsBadge((prev) => Math.max(0, prev - 1));
      }
    } else if (frameType === "warning") {
      // Degraded-tool skips are informational, never fatal. Session-filter like the chat
      // banner so one session's skips never alarm another, dedup by line so repeats never
      // inflate, and skip while chat is visible since the banner already informs.
      const rawSession: unknown = frame.sessionID;
      const frameSession = typeof rawSession === "string" ? rawSession : undefined;
      // Untagged warnings carry no owner and never touch the banner, so they never touch the bell.
      if (!frameSession) return;
      try {
        const active = normalizeSessionID(
          typeof window !== "undefined" ? window.localStorage.getItem("rw_active_session_id") : null,
        );
        if (active && normalizeSessionID(frameSession) !== active) return;
      } catch {
        // Storage is best-effort; without an active session fall through to visible check.
      }
      if (typeof window !== "undefined") {
        try {
          const hash = window.location.hash
            .replace("#", "")
            .toLowerCase()
            .split("/")[0]
            .split("?")[0];
          const path = window.location.pathname
            .replace(/^\//, "")
            .toLowerCase()
            .split("/")[0];
          const chatVisible = hash.length > 0 ? hash === "chat" : path === "chat";
          // Chat stays mounted across tabs, so staying on chat shows the banner already;
          // counting again would ever-grow the bell beside an already-visible notice.
          if (chatVisible && !document.hidden) return;
        } catch {
          // Ignore visibility probe failures and count honestly.
        }
      }
      const rawMessage: unknown = frame.message;
      const message =
        typeof rawMessage === "string" && rawMessage.trim().length > 0
          ? rawMessage
          : "A tool was skipped for this turn";
      if (seenWarningsRef.current.has(message)) return;
      seenWarningsRef.current.add(message);
      setWarningsBadge((prev) => prev + 1);
    } else if (isGoalNeedsInputProactive(frame)) {
      if (!prefsRef.current.goalAdvance) return;
      setGoalsAttention((prev) => prev + 1);
    } else if (isIdeaProposedProactive(frame)) {
      if (!prefsRef.current.ideaProposed) return;
      setGoalsAttention((prev) => prev + 1);
    }
  }, []);

  useSharedWebSocket(handleMessage);

  // Deprecated no-op shim preserved so existing callers remain type-compatible while
  // desktop notifications live exclusively in the macOS Menu Bar app.
  const requestPermission = useCallback(async (): Promise<
    NotificationPermission | "unsupported"
  > => "unsupported", []);

  const clearRunsBadge = useCallback(() => {
    setRunsBadge(0);
  }, []);

  const clearApprovalsBadge = useCallback(() => {
    // Navigation acknowledgment resets the advisory count without touching server pending lists.
    seenApprovalIDsRef.current.clear();
    consumedDecidedIDsRef.current.clear();
    setApprovalsBadge(0);
  }, []);

  const clearWarningsBadge = useCallback(() => {
    seenWarningsRef.current.clear();
    setWarningsBadge(0);
  }, []);

  const clearGoalsAttention = useCallback(() => {
    // Acknowledgment only: the goals list remains the source of truth, so
    // clearing the advisory count never fabricates a server-side resolution.
    setGoalsAttention(0);
  }, []);

  return {
    notificationsEnabled: false,
    permission: "default" as NotificationPermission,
    isNotificationSupported: false,
    requestPermission,
    runsBadge,
    clearRunsBadge,
    approvalsBadge,
    clearApprovalsBadge,
    warningsBadge,
    clearWarningsBadge,
    goalsAttention,
    clearGoalsAttention,
  };
}
