// Rune Weaver Dashboard — Hook to manage browser Notification API permissions and WebSocket events.

import { useCallback, useRef, useState } from "react";
import { useSharedWebSocket } from "./useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
} from "./useSharedWebSocket";
import { normalizeSessionID } from "../approvalsSession";
import { isGoalNeedsInputProactive, isIdeaProposedProactive } from "../api";

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

export function useWebNotifications() {
  const [permission, setPermission] = useState<NotificationPermission>(() => {
    if (typeof window !== "undefined" && "Notification" in window) {
      return Notification.permission;
    }
    return "default";
  });

  // Unread count for runs that ended in an error or failure requiring operator
  // attention. Routine successful runs ("ok") do not badge the navbar.
  const [runsBadge, setRunsBadge] = useState(0);
  const [approvalsBadge, setApprovalsBadge] = useState(0);
  // Owner-attention count for goals parked awaiting input.
  const [goalsAttention, setGoalsAttention] = useState(0);
  // Degraded-tool notices keep their own counter instead of inflating runs
  // or approvals; the bell surfaces the count as an amber badge gated behind
  // the same permission toggle, cleared when the chat view is shown.
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
        setRunsBadge((prev) => prev + 1);
      }

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const kind = typeof run.kind === "string" ? run.kind : undefined;
        const response = typeof run.response === "string" ? run.response : undefined;
        const message = typeof run.message === "string" ? run.message : undefined;
        let label = "Chat Finished";
        if (status === "budget_exceeded") {
          label = "Tool Budget Exceeded";
        } else if (kind === "scheduler") {
          label = "Job Run Finished";
        } else if (kind === "index") {
          label = "Index Run Finished";
        } else if (kind === "goal") {
          label = "Goal Advancement Finished";
        }
        const title = `Rune Weaver: ${label}`;
        const body = response ? response.slice(0, 150) : message;
        new Notification(title, { body });
      }
    } else if (frameType === "approval" && frame.request && typeof frame.request === "object") {
      const request = frame.request as Record<string, unknown>;
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

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const toolName = typeof request.toolName === "string" ? request.toolName : "unknown tool";
        const detail =
          typeof request.description === "string"
            ? request.description
            : typeof request.toolName === "string"
              ? request.toolName
              : "A tool needs approval";
        new Notification("Rune Weaver: Approval Needed", {
          body: `Tool ${toolName}: ${detail}`,
        });
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
          const hash = window.location.hash.replace("#", "").toLowerCase();
          const path = window.location.pathname.replace(/^\//, "").toLowerCase();
          const chatVisible =
            hash === "" || hash === "chat" || path === "" || path === "chat" || path === "/";
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

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        new Notification("Rune Weaver: Tool Warning", {
          body: message.slice(0, 150),
        });
      }
    } else if (isGoalNeedsInputProactive(frame)) {
      // A goal parked on owner input is the one proactive nudge the goals surface badges.
      setGoalsAttention((prev) => prev + 1);
      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const title = typeof frame.title === "string" ? frame.title.trim() : "";
        const headline =
          typeof frame.headline === "string" ? frame.headline.trim() : "";
        new Notification(
          title ? `Rune Weaver: ${title}` : "Rune Weaver: Goal needs input",
          { body: headline || undefined },
        );
      }
    } else if (isIdeaProposedProactive(frame)) {
      // A freshly proposed idea is the other proactive nudge the goals surface badges: it rides the
      // same proactive frame as a parked goal, so the counter rises on the same signal the panel
      // reads.
      setGoalsAttention((prev) => prev + 1);
      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const title = typeof frame.title === "string" ? frame.title.trim() : "";
        const headline =
          typeof frame.headline === "string" ? frame.headline.trim() : "";
        new Notification(
          title ? `Rune Weaver: ${title}` : "Rune Weaver: New idea",
          { body: headline || undefined },
        );
      }
    }
  }, []);

  useSharedWebSocket(handleMessage);

  // Support probe kept beside permission so callers never have to sniff the
  // global directly; an absent API is a capability gap, not a denied choice,
  // and must surface its own guidance instead of a permission prompt.
  const isNotificationSupported =
    typeof window !== "undefined" && "Notification" in window;

  // Permission request owned here so every bell tap shares one fail-closed path.
  const requestPermission = useCallback(async (): Promise<
    NotificationPermission | "unsupported"
  > => {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return "unsupported";
    }
    // Fail-closed: a blocked choice stays blocked until the operator changes
    // site settings; re-requesting would resolve without UI and look silent.
    if (Notification.permission === "denied") {
      setPermission("denied");
      return "denied";
    }
    try {
      const outcome = await Notification.requestPermission();
      setPermission(outcome);
      return outcome;
    } catch {
      // A throwing prompt leaves no new grant behind; report the live state
      // so the bell falls back to guidance instead of claiming success.
      return Notification.permission;
    }
  }, []);

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
    notificationsEnabled: permission === "granted",
    permission,
    isNotificationSupported,
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
