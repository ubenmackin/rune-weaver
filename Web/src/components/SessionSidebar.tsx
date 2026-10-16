// Rune Weaver Dashboard — Collapsible session history sidebar for Chat.

import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type MouseEvent,
  type ReactElement,
  type RefObject,
} from "react";
import {
  deleteSession,
  isActiveRunStatus,
  listSessions,
  updateSessionTitle,
  type PermissionRequest,
  type SessionSummary,
} from "../api";
import {
  getSavedEnum,
  isSameSession,
  normalizeSessionID,
  persistEnum,
  runSessionID,
} from "../approvalsSession";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { useIsMobile } from "../hooks/useIsMobile";
import { useRunningRuns } from "../hooks/useRunningRuns";
import type { WSGenericFrame } from "../hooks/useSharedWebSocket";
import {
  AlertTriangleIcon,
  ChatIcon,
  CheckIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  ClockIcon,
  CloseIcon,
  EditIcon,
  FanOutIcon,
  PlusIcon,
  TargetIcon,
  TrashIcon,
} from "./icons";
import Modal from "./Modal";

// Run-lifecycle frames arrive in bursts (a swarm emits parent plus child
// start/settle updates), so they coalesce into one `listSessions()` refetch
// instead of one request per frame.
const SESSION_REFRESH_COALESCE_MS = 750;

export type SessionFilter = "all" | "chat" | "scheduler";

interface SessionSidebarProps {
  currentSessionID: string;
  onSelectSession: (id: string) => void;
  onNewSession: () => void;
  isOpen: boolean;
  onToggleOpen: () => void;
  refreshTrigger?: number;
  // Shell activation flag for the Chat tab.
  isActive?: boolean;
  pendingApprovals?: PermissionRequest[];
  // Live interactive turns parked in the chat view while the user browses
  // other sessions. The sidebar merges these with polled run rows so a
  // background turn stays badged even before its run record persists.
  runningSessionIDs?: Set<string> | string[] | null;
  // Live handheld flag from the owner.
  isMobile?: boolean;
  // Close-only dismissal for the mobile drawer. Falls back to the toggle
  // when omitted so existing callers keep working; unlike the toggle it can
  // never reopen a closed drawer from backdrop or Escape paths.
  onClose?: () => void;
  // History trigger owned by the chat view. The drawer returns focus here
  // after every mobile dismissal so keyboard users land back on the control
  // that opened the drawer instead of losing focus to the document body.
  historyButtonRef?: RefObject<HTMLButtonElement | null>;
}

interface GroupedSessions {
  today: SessionSummary[];
  yesterday: SessionSummary[];
  lastWeek: SessionSummary[];
  older: SessionSummary[];
}

function groupSessionsByDate(sessions: SessionSummary[] = []): GroupedSessions {
  // Compare calendar days via date components so grouping stays correct across DST transitions,
  // where a day is 23 or 25 hours instead of a fixed millisecond offset. Constructing midnight per
  // calendar day keeps Today/Yesterday/Previous-7-Days boundaries on local midnights.
  const now = new Date();
  const todayStart = new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate(),
  ).getTime();
  const yesterdayStart = new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate() - 1,
  ).getTime();
  const lastWeekStart = new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate() - 7,
  ).getTime();

  const grouped: GroupedSessions = {
    today: [],
    yesterday: [],
    lastWeek: [],
    older: [],
  };

  if (!Array.isArray(sessions)) return grouped;

  for (const session of sessions) {
    const time = new Date(session.updatedAt).getTime();
    if (time >= todayStart) {
      grouped.today.push(session);
    } else if (time >= yesterdayStart) {
      grouped.yesterday.push(session);
    } else if (time >= lastWeekStart) {
      grouped.lastWeek.push(session);
    } else {
      grouped.older.push(session);
    }
  }

  return grouped;
}

function getSavedSessionFilter(): SessionFilter {
  return getSavedEnum<SessionFilter>(
    "rw_session_filter",
    ["all", "chat", "scheduler"],
    "chat",
  );
}

// Classifies one session for the Chats/Scheduled tabs. Normalizes the stored
// source so drifted casing or surrounding whitespace never strands a scheduled
// run under Chats; unattributed rows stay chats to match the history default.
function isScheduledSession(session: SessionSummary | null | undefined): boolean {
  const raw = session?.source;
  return typeof raw === "string" && raw.trim().toLowerCase() === "scheduler";
}

// Classifies a session spawned as a fan-out worker. Workers normally nest via
// `parentSessionID`, but the source stays the classifier so an orphaned worker
// (parent deleted) still reads as a swarm branch instead of a plain chat.
function isFanOutWorkerSession(session: SessionSummary | null | undefined): boolean {
  const raw = session?.source;
  return typeof raw === "string" && raw.trim().toLowerCase() === "fanout_worker";
}

// Classifies a session executing or linked to a goal. Goals carry an explicit
// source ("goal") or a non-empty goalId, distinguishing autonomous goal runs
// from interactive chats, scheduled jobs, and fan-out workers.
function isGoalSession(session: SessionSummary | null | undefined): boolean {
  const raw = session?.source;
  const isGoalSource = typeof raw === "string" && raw.trim().toLowerCase() === "goal";
  const hasGoalId = typeof session?.goalId === "string" && session.goalId.trim().length > 0;
  return isGoalSource || hasGoalId;
}

// Resolved props for the presentational view.
type SessionSidebarViewProps = Omit<
  SessionSidebarProps,
  "isMobile" | "isActive"
> & {
  isMobile: boolean;
  isActive: boolean;
};

function SessionSidebarView({
  currentSessionID,
  onSelectSession,
  onNewSession,
  isOpen,
  onToggleOpen,
  refreshTrigger,
  pendingApprovals,
  runningSessionIDs,
  isMobile,
  // Aliased because the group renderer below already uses `isActive` for the
  // per-row highlight, which is a different concept from tab activation.
  isActive: active,
  onClose,
  historyButtonRef,
}: SessionSidebarViewProps) {
  // Drawer container for initial focus when the mobile drawer opens.
  const sidebarRef = useRef<HTMLElement | null>(null);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [loading, setLoading] = useState(false);
  const [filter, setFilter] = useState<SessionFilter>(getSavedSessionFilter);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingTitle, setEditingTitle] = useState("");
  // Non-blocking delete confirmation: the pending id renders a true modal.
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  // Fan-out parents whose worker children are revealed. Expansion is ephemeral
  // view state by design: it defaults to collapsed, is never persisted, and
  // deleting a row never cascades it, so a swarm opens only when asked.
  const [expandedParentKeys, setExpandedParentKeys] = useState<Set<string>>(
    () => new Set<string>(),
  );
  // Submit blurs the input, so `onSubmit` and `onBlur` fire for one save.
  // The in-flight marker drops the second invocation before it can issue
  // a duplicate PATCH.
  const renameInFlightRef = useRef<string | null>(null);
  // Focus the rename input via ref callback instead of `autoFocus` so focus
  // stays managed without stealing it on unrelated renders; the input only
  // mounts while editing, so focusing on mount mirrors the prior behavior.
  const focusRenameInput = useCallback((node: HTMLInputElement | null) => {
    if (node) node.focus();
  }, []);

  // Pending focus-restore timer for mobile dismissal. Stored in a ref so an
  // unmount before the tick can clear it instead of focusing a detached node.
  const focusTimeoutRef = useRef<ReturnType<typeof window.setTimeout> | null>(
    null,
  );

  // Returns focus to the History trigger after a mobile dismissal.
  const returnFocusToTrigger = useCallback(() => {
    if (focusTimeoutRef.current !== null) {
      window.clearTimeout(focusTimeoutRef.current);
    }
    focusTimeoutRef.current = window.setTimeout(() => {
      focusTimeoutRef.current = null;
      historyButtonRef?.current?.focus();
    }, 0);
  }, [historyButtonRef]);

  useEffect(() => {
    return () => {
      if (focusTimeoutRef.current !== null) {
        window.clearTimeout(focusTimeoutRef.current);
        focusTimeoutRef.current = null;
      }
    };
  }, []);

  // Close-only dismissal shared by every mobile exit path.
  const requestDrawerClose = useCallback(() => {
    if (onClose) {
      onClose();
      return;
    }
    if (isOpen) {
      onToggleOpen();
    }
  }, [onClose, isOpen, onToggleOpen]);

  // Backdrop dismissal for the mobile drawer. Desktop never renders a
  // backdrop so this handler only fires on handheld widths; it closes the
  // drawer and returns focus to the History trigger.
  const handleBackdropClick = useCallback(() => {
    requestDrawerClose();
    returnFocusToTrigger();
  }, [requestDrawerClose, returnFocusToTrigger]);

  // Escape dismissal for the mobile drawer. Registered on window only while
  // the handheld drawer is open so desktop Escape handling elsewhere never
  // double-fires; closes the drawer and returns focus to the History trigger.
  const handleEscape = useCallback(
    (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      requestDrawerClose();
      returnFocusToTrigger();
    },
    [requestDrawerClose, returnFocusToTrigger],
  );

  useEffect(() => {
    if (!isOpen || !isMobile) return;
    window.addEventListener("keydown", handleEscape);
    return () => window.removeEventListener("keydown", handleEscape);
  }, [isOpen, isMobile, handleEscape]);

  // Modal drawer contract for the handheld drawer: trap Tab inside the drawer while it is open so
  // keyboard focus cannot reach the dimmed background behind the backdrop, and lock background
  // scroll until dismissal.
  useEffect(() => {
    if (!isOpen || !isMobile) return;
    const container = sidebarRef.current;
    if (!container) return;
    function handleTabTrap(event: KeyboardEvent) {
      if (event.key !== "Tab") return;
      if (!container) return;
      const focusable = Array.from(
        container.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ),
      );
      if (focusable.length === 0) {
        event.preventDefault();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement as HTMLElement | null;
      if (event.shiftKey) {
        if (active === first || !container.contains(active)) {
          event.preventDefault();
          last.focus();
        }
      } else if (active === last || !container.contains(active)) {
        event.preventDefault();
        first.focus();
      }
    }
    window.addEventListener("keydown", handleTabTrap);
    return () => window.removeEventListener("keydown", handleTabTrap);
  }, [isOpen, isMobile]);

  // Locks background scroll while the handheld drawer is open and restores
  // the prior value on close or unmount so the page behind the dim backdrop
  // cannot scroll under the drawer.
  useEffect(() => {
    if (!isOpen || !isMobile) return;
    if (typeof document === "undefined") return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previous;
    };
  }, [isOpen, isMobile]);

  // Moves focus into the drawer when it opens on mobile so keyboard and screen-reader users land
  // inside the history list; desktop keeps its existing focus because the sidebar is always inline
  // there.
  useEffect(() => {
    if (!isOpen || !isMobile) return;
    sidebarRef.current?.focus();
  }, [isOpen, isMobile]);

  // Session select that also dismisses the mobile drawer. Desktop keeps the inline sidebar open
  // across switches; mobile closes it and returns focus to the History trigger.
  const handleSelectAndMaybeClose = useCallback(
    (id: unknown) => {
      if (typeof id !== "string" || id.trim().length === 0) return;
      onSelectSession(id);
      if (isMobile) {
        requestDrawerClose();
        returnFocusToTrigger();
      }
    },
    [onSelectSession, isMobile, requestDrawerClose, returnFocusToTrigger],
  );

  // Sessions with a turn still running on the engine while the user browses elsewhere.
  const [liveRunningIDs, setLiveRunningIDs] = useState<Set<string>>(
    () => new Set<string>(),
  );
  const { runningIDs: sharedRunningIDs, refresh: refreshSharedRuns } =
    useRunningRuns();
  // Shared poller already returns normalized lowercase owners through the
  // single active contract, so wrap directly as the polled set for the badge
  // union below without a second derivation.
  const polledRunningIDs = useMemo(
    () => new Set<string>(sharedRunningIDs),
    [sharedRunningIDs],
  );

  // Pending trailing-coalesce timer for session-list revalidation. Held in a
  // ref so a frame arriving inside the window is absorbed rather than queuing a
  // second refetch, and so unmount can drop a tick bound for a detached view.
  const refreshTimerRef = useRef<ReturnType<typeof window.setTimeout> | null>(
    null,
  );

  const refreshSessions = useCallback(async () => {
    setLoading(true);
    try {
      const response = await listSessions();
      if (response && Array.isArray(response.sessions)) {
        setSessions(response.sessions);
      } else {
        setSessions([]);
      }
    } catch {
      // Keep existing list on transient failure
    } finally {
      setLoading(false);
    }
  }, []);

  // Trailing coalesce: the first frame schedules, frames inside the window are
  // absorbed, and a later frame schedules again.
  const scheduleSessionsRefresh = useCallback(() => {
    if (refreshTimerRef.current !== null) return;
    refreshTimerRef.current = window.setTimeout(() => {
      refreshTimerRef.current = null;
      void refreshSessions();
    }, SESSION_REFRESH_COALESCE_MS);
  }, [refreshSessions]);

  // A detached sidebar must never refetch, so the pending tick is cleared on
  // unmount instead of firing against a view that no longer exists.
  useEffect(() => {
    return () => {
      if (refreshTimerRef.current !== null) {
        window.clearTimeout(refreshTimerRef.current);
        refreshTimerRef.current = null;
      }
    };
  }, []);

  const handleRunBroadcast = useCallback(
    (data: unknown) => {
      const frame = data as WSGenericFrame | null;
      if (!frame || typeof frame !== "object") return;
      const frameType = typeof frame.type === "string" ? frame.type : undefined;
      if (frameType !== "run_started" && frameType !== "run_completed") return;
      // The lifecycle frame itself is the refresh signal: a start or settle can
      // add, retitle, or reprioritize a row, so the coalesced refetch must not
      // depend on the nested run parsing.
      scheduleSessionsRefresh();
      const nested = (frame as Record<string, unknown>).run;
      if (!nested || typeof nested !== "object") return;
      const owner = runSessionID(
        nested as Parameters<typeof runSessionID>[0],
      );
      const normalized = normalizeSessionID(owner);
      if (!normalized) return;
      // Single active contract with the polled run log: only a live running status keeps the badge
      // lit.
      const nestedStatus =
        typeof (nested as Record<string, unknown>).status === "string"
          ? ((nested as Record<string, unknown>).status as string)
          : undefined;
      if (frameType === "run_started" && isActiveRunStatus(nestedStatus)) {
        setLiveRunningIDs((previous) => {
          if (previous.has(normalized)) return previous;
          const next = new Set(previous);
          next.add(normalized);
          return next;
        });
      } else {
        setLiveRunningIDs((previous) => {
          if (!previous.has(normalized)) return previous;
          const next = new Set(previous);
          next.delete(normalized);
          return next;
        });
      }
    },
    [scheduleSessionsRefresh],
  );

  // A reconnect may have missed lifecycle frames while the socket was down, so
  // the open event revalidates a possibly-stale history through the same
  // coalescing window instead of trusting cached rows.
  const handleSocketOpen = useCallback(() => {
    scheduleSessionsRefresh();
  }, [scheduleSessionsRefresh]);

  useSharedWebSocket(handleRunBroadcast, undefined, handleSocketOpen);

  // Browsers throttle or suspend hidden tabs, and a backgrounded dashboard may miss both frames and
  // socket events, so returning to the foreground revalidates the list; the shared coalescer folds a
  // near-simultaneous reconnect into the same refetch.
  useEffect(() => {
    function handleVisibilityChange() {
      if (document.visibilityState === "visible") {
        scheduleSessionsRefresh();
      }
    }
    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [scheduleSessionsRefresh]);

  // Revalidate the shared poller when the viewed session changes so a switch badges without waiting
  // for the next tick; the interval itself stays owned by the shared hook.
  useEffect(() => {
    refreshSharedRuns();
  }, [refreshSharedRuns, currentSessionID, refreshTrigger]);

  const handleFilterChange = (nextFilter: SessionFilter) => {
    setFilter(nextFilter);
    persistEnum("rw_session_filter", nextFilter);
  };

  // Optimistic draft timestamp minted once per unseen session in an effect
  // so render stays pure; the memo below only reads the stable value.
  const [draftStamp, setDraftStamp] = useState<{
    id: string;
    at: string;
  } | null>(null);

  useEffect(() => {
    void refreshSessions();
  }, [refreshSessions, currentSessionID, refreshTrigger]);

  // The shell keeps ChatView mounted behind `display: none`, so a tab return never remounts this
  // sidebar: without an edge-triggered refetch, sessions created while another tab was showing would
  // stay invisible until the next socket frame or socket reopen.
  const wasActiveRef = useRef(active);

  useEffect(() => {
    const wasActive = wasActiveRef.current;
    wasActiveRef.current = active;
    if (!wasActive && active) {
      void refreshSessions();
    }
  }, [active, refreshSessions]);

  function handleStartRename(session: SessionSummary, e: MouseEvent) {
    e.stopPropagation();
    setEditingId(session.id);
    setEditingTitle(session.title);
  }

  async function handleSaveRename(id: string, e?: FormEvent) {
    if (e) e.preventDefault();
    if (editingId !== id || renameInFlightRef.current === id) return;
    renameInFlightRef.current = id;
    const trimmed = editingTitle.trim();
    if (!trimmed) {
      renameInFlightRef.current = null;
      setEditingId(null);
      return;
    }
    try {
      await updateSessionTitle(id, trimmed);
      setSessions((prev) =>
        prev.map((s) => (s.id === id ? { ...s, title: trimmed } : s)),
      );
    } catch {
      // Keep prior title on error
    } finally {
      renameInFlightRef.current = null;
      setEditingId(null);
    }
  }

  async function confirmDelete() {
    if (!pendingDeleteId) return;
    const id = pendingDeleteId;
    setDeletingId(id);
    try {
      await deleteSession(id);
      setSessions((prev) => prev.filter((s) => s.id !== id));
      if (isSameSession(id, currentSessionID)) {
        onNewSession();
      }
      setPendingDeleteId(null);
    } catch {
      // Handle error
    } finally {
      setDeletingId(null);
    }
  }

  function cancelDelete() {
    setPendingDeleteId(null);
  }

  // If currentSessionID is active but not yet persisted on server (fresh new chat), optimistically
  // inject it so it immediately appears in the history sidebar under Today.
  const hasCurrentSession = sessions.some((s) => isSameSession(s.id, currentSessionID));
  // Mint the optimistic timestamp in an effect so render stays pure and the
  // draft keeps one stable instant per unseen session across re-renders.
  useEffect(() => {
    if (!currentSessionID || hasCurrentSession) return;
    if (draftStamp && isSameSession(draftStamp.id, currentSessionID)) return;
    setDraftStamp({ id: currentSessionID, at: new Date().toISOString() });
  }, [currentSessionID, hasCurrentSession, draftStamp]);
  const activeSessions = useMemo(() => {
    if (!currentSessionID || hasCurrentSession) return sessions;
    if (!draftStamp || !isSameSession(draftStamp.id, currentSessionID)) return sessions;
    const draft: SessionSummary = {
      id: currentSessionID,
      title: "New Chat",
      messageCount: 0,
      summary: null,
      createdAt: draftStamp.at,
      updatedAt: draftStamp.at,
      source: "chat",
    };
    return [draft, ...sessions];
  }, [sessions, currentSessionID, hasCurrentSession, draftStamp]);

  // Fan-out tree derivation over the filtered candidates.
  const {
    candidateSessions,
    childrenByParent,
    parentKeyByChildKey,
    topLevelSessions,
  } = useMemo(() => {
    const candidates = activeSessions.filter((session) => {
      const isScheduled = isScheduledSession(session);
      if (filter === "chat") return !isScheduled;
      if (filter === "scheduler") return isScheduled;
      return true;
    });
    const candidateKeys = new Set(
      candidates.map((session) => normalizeSessionID(session.id)),
    );
    const children = new Map<string, SessionSummary[]>();
    const parents = new Map<string, string>();
    for (const session of candidates) {
      const sessionKey = normalizeSessionID(session.id);
      const parentKey = normalizeSessionID(session.parentSessionID);
      // An empty or self-referential parent is not nesting; treating it as one
      // would detach the row from every group.
      if (!parentKey || parentKey === sessionKey) continue;
      if (!candidateKeys.has(parentKey)) continue;
      const siblings = children.get(parentKey);
      if (siblings) {
        siblings.push(session);
      } else {
        children.set(parentKey, [session]);
      }
      parents.set(sessionKey, parentKey);
    }
    // Ascending creation order keeps siblings in the order the swarm spawned
    // them, independent of when each worker last updated.
    for (const siblings of children.values()) {
      siblings.sort(
        (a, b) =>
          new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime(),
      );
    }
    return {
      candidateSessions: candidates,
      childrenByParent: children,
      parentKeyByChildKey: parents,
      topLevelSessions: candidates.filter(
        (session) => !parents.has(normalizeSessionID(session.id)),
      ),
    };
  }, [activeSessions, filter]);

  // The active session's entire ancestor chain stays open while its descendant is being viewed, so
  // switching to a worker (or reloading on one) never hides the row the owner is reading, however
  // deep the swarm nests.
  const activeAncestorKeys = useMemo(() => {
    const ancestors = new Set<string>();
    const visited = new Set<string>();
    let key = normalizeSessionID(currentSessionID);
    while (key.length > 0 && !visited.has(key)) {
      visited.add(key);
      const parentKey = parentKeyByChildKey.get(key);
      if (!parentKey) break;
      ancestors.add(parentKey);
      key = parentKey;
    }
    return ancestors;
  }, [parentKeyByChildKey, currentSessionID]);

  const expandedParentSet = useMemo(() => {
    if (activeAncestorKeys.size === 0) return expandedParentKeys;
    const effective = new Set(expandedParentKeys);
    for (const key of activeAncestorKeys) {
      effective.add(key);
    }
    return effective;
  }, [expandedParentKeys, activeAncestorKeys]);

  // Union of every running signal so one missed transport never hides a background turn: live
  // broadcasts for immediacy, polled runs for reloads, and the chat view's parked flights for turns
  // whose run row has not persisted yet.
  const backgroundRunning = useMemo(() => {
    const merged = new Set<string>();
    for (const id of liveRunningIDs) merged.add(id);
    for (const id of polledRunningIDs) merged.add(id);
    if (runningSessionIDs) {
      const incoming: Iterable<string> = Array.isArray(runningSessionIDs)
        ? runningSessionIDs
        : runningSessionIDs instanceof Set
          ? runningSessionIDs
          : [];
      for (const id of incoming) {
        const normalized = normalizeSessionID(id);
        if (normalized) merged.add(normalized);
      }
    }
    return merged;
  }, [liveRunningIDs, polledRunningIDs, runningSessionIDs]);

  const grouped = groupSessionsByDate(topLevelSessions);

  // One row renderer shared by both tree levels.
  const renderSessionRow = (
    session: SessionSummary,
    { isChild }: { isChild: boolean },
  ): ReactElement => {
    const isActive = isSameSession(session.id, currentSessionID);
    const isEditing = editingId === session.id;
    const isScheduled = isScheduledSession(session);
    const sessionKey = normalizeSessionID(session.id);
    const childSessions = childrenByParent.get(sessionKey) ?? [];
    const hasChildren = childSessions.length > 0;
    const isExpanded = hasChildren && expandedParentSet.has(sessionKey);
    // Background turns keep their badge even while viewed elsewhere so the user can spot a
    // still-running session without opening Runs.
    const isBackgroundRunning = backgroundRunning.has(sessionKey);

    return (
      <Fragment key={session.id}>
        <div
          className={`session-item ${isActive ? "active" : ""} ${isChild ? "session-item-child" : ""}`}
          onClick={() => !isEditing && handleSelectAndMaybeClose(session.id)}
          role="button"
          tabIndex={0}
          aria-label={`Open session ${session.title}`}
          onKeyDown={(e) => {
            // Nested controls (disclosure, rename, delete) act on their own
            // Enter/Space; only a key event targeting the row itself may select,
            // so bubbling activations never open the session behind them.
            if (e.target !== e.currentTarget) return;
            if (isEditing) return;
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              handleSelectAndMaybeClose(session.id);
            }
          }}
        >
          {hasChildren ? (
            <button
              type="button"
              className="session-disclosure-btn"
              data-testid="session-fanout-disclosure"
              aria-expanded={isExpanded}
              aria-label={`${isExpanded ? "Collapse" : "Expand"} ${childSessions.length} fan-out agent session${childSessions.length === 1 ? "" : "s"} for ${session.title}`}
              onClick={(e) => {
                e.stopPropagation();
                setExpandedParentKeys((previous) => {
                  const next = new Set(previous);
                  if (next.has(sessionKey)) {
                    next.delete(sessionKey);
                  } else {
                    next.add(sessionKey);
                  }
                  return next;
                });
              }}
            >
              {isExpanded ? (
                <ChevronDownIcon size={12} />
              ) : (
                <ChevronRightIcon size={12} />
              )}
            </button>
          ) : null}
          {(() => {
            const hasPendingApproval = pendingApprovals?.some((req) =>
              isSameSession(req.sessionID, session.id),
            );
            if (hasPendingApproval) {
              return (
                <AlertTriangleIcon
                  size={14}
                  className="session-item-icon pending-approval"
                  title="Approval pending"
                  data-testid="session-approval-pending-icon"
                />
              );
            }
            if (isGoalSession(session)) {
              return (
                <TargetIcon
                  size={14}
                  className="session-item-icon goal"
                  title="Goal run"
                  data-testid="session-goal-icon"
                />
              );
            }
            if (isScheduled) {
              return (
                <ClockIcon
                  size={14}
                  className="session-item-icon scheduled"
                  title="Scheduled run"
                />
              );
            }
            // A nested row or a spawned worker is always a swarm branch, even
            // when its parent is gone and it has to stand on its own.
            if (isChild || isFanOutWorkerSession(session)) {
              return (
                <FanOutIcon
                  size={14}
                  className="session-item-icon fanout"
                  title="Fan-out agent session"
                  data-testid="session-fanout-child-icon"
                />
              );
            }
            return <ChatIcon size={14} className="session-item-icon" />;
          })()}
          {isEditing ? (
            <form
              className="session-rename-form"
              onSubmit={(e) => void handleSaveRename(session.id, e)}
              onClick={(e) => e.stopPropagation()}
            >
              <input
                type="text"
                value={editingTitle}
                onChange={(e) => setEditingTitle(e.target.value)}
                ref={focusRenameInput}
                onBlur={() => void handleSaveRename(session.id)}
                className="session-rename-input"
                aria-label={`Rename session ${session.title}`}
              />
              <button
                type="submit"
                className="session-icon-btn"
                title="Save title"
              >
                <CheckIcon size={12} />
              </button>
              <button
                type="button"
                className="session-icon-btn"
                onClick={() => setEditingId(null)}
                title="Cancel"
              >
                <CloseIcon size={12} />
              </button>
            </form>
          ) : (
            <>
              <span className="session-title" title={session.title}>
                {session.title}
              </span>
              {hasChildren ? (
                <span
                  className="session-fanout-count"
                  data-testid="session-fanout-count"
                >
                  {childSessions.length} agent{childSessions.length === 1 ? "" : "s"}
                </span>
              ) : null}
              {isBackgroundRunning ? (
                <span
                  className="session-running-badge"
                  data-testid="session-running-badge"
                  title="Turn running in background"
                  aria-label={`Turn running in background for ${session.title}`}
                >
                  Running
                </span>
              ) : null}
              <div className="session-item-actions">
                <button
                  type="button"
                  className="session-icon-btn"
                  title="Rename session"
                  onClick={(e) => handleStartRename(session, e)}
                >
                  <EditIcon size={12} />
                </button>
                <button
                  type="button"
                  className="session-icon-btn delete"
                  title="Delete session"
                  onClick={(e) => {
                    e.stopPropagation();
                    setPendingDeleteId(session.id);
                  }}
                >
                  <TrashIcon size={12} />
                </button>
              </div>
            </>
          )}
        </div>
        {/* Children render inside the parent's own fragment so a worker that
            itself spawned workers nests one level deeper instead of dropping
            out of the tree. */}
        {isExpanded
          ? childSessions.map((child) =>
              renderSessionRow(child, { isChild: true }),
            )
          : null}
      </Fragment>
    );
  };

  const renderGroup = (label: string, items: SessionSummary[]) => {
    if (items.length === 0) return null;
    return (
      <div className="session-group" key={label}>
        <div className="session-group-label">{label}</div>
        {items.map((session) => renderSessionRow(session, { isChild: false }))}
      </div>
    );
  };

  return (
    <>
      {/* Dim backdrop for the handheld drawer. Mount follows the open state
          alone while the stylesheet owns visibility: the handheld query
          reveals it and the wide query keeps it hidden, so desktop never
          shows a dim layer. A real button keeps the dismiss affordance
          keyboard-operable (Enter/Space) alongside the Escape path instead of
          hiding a clickable layer from assistive technology. */}
      {isOpen ? (
        <button
          type="button"
          className="sidebar-backdrop"
          data-testid="sidebar-backdrop"
          aria-label="Close history"
          onClick={handleBackdropClick}
        />
      ) : null}
      <aside
        ref={sidebarRef}
        tabIndex={-1}
        aria-label="Session history"
        role={isMobile && isOpen ? "dialog" : undefined}
        aria-modal={isMobile && isOpen ? true : undefined}
        className={`session-sidebar ${isOpen ? "open" : "collapsed"}`}
      >
        <div className="sidebar-header">
          <button
            type="button"
            className="new-chat-btn"
            onClick={onNewSession}
            title="Start a new chat session"
          >
            <PlusIcon size={16} />
            <span>New Chat</span>
          </button>
          <button
            type="button"
            className="toggle-sidebar-btn"
            onClick={onToggleOpen}
            title={isOpen ? "Collapse sidebar" : "Expand sidebar"}
            aria-label={isOpen ? "Collapse sidebar" : "Expand sidebar"}
          >
            <CloseIcon size={14} />
          </button>
        </div>

        {/* Sidebar Filter Tabs (Chats vs Scheduled vs All) */}
        <div className="sidebar-filter-tabs">
          <button
            type="button"
            className={`sidebar-filter-tab ${filter === "chat" ? "active" : ""}`}
            onClick={() => handleFilterChange("chat")}
            title="Show interactive chat sessions"
          >
            Chats
          </button>
          <button
            type="button"
            className={`sidebar-filter-tab ${filter === "scheduler" ? "active" : ""}`}
            onClick={() => handleFilterChange("scheduler")}
            title="Show scheduled background runs"
          >
            Scheduled
          </button>
          <button
            type="button"
            className={`sidebar-filter-tab ${filter === "all" ? "active" : ""}`}
            onClick={() => handleFilterChange("all")}
            title="Show all sessions"
          >
            All
          </button>
        </div>

        <div className="sidebar-session-list">
          {loading && sessions.length === 0 ? (
            <p className="sidebar-muted">Loading history…</p>
          ) : null}
          {candidateSessions.length === 0 && !loading ? (
            <p className="sidebar-muted">
              {filter === "scheduler"
                ? "No scheduled runs"
                : filter === "chat"
                  ? "No chat sessions"
                  : "No prior sessions"}
            </p>
          ) : (
            <>
              {renderGroup("Today", grouped.today)}
              {renderGroup("Yesterday", grouped.yesterday)}
              {renderGroup("Previous 7 Days", grouped.lastWeek)}
              {renderGroup("Older", grouped.older)}
            </>
          )}
        </div>
      </aside>

      {/* Centered Modal for Session Delete Confirmation */}
      {pendingDeleteId ? (
        <Modal
          label="Confirm delete session"
          onClose={cancelDelete}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete chat session?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDelete}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete this conversation and its message history. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDelete}
              disabled={deletingId === pendingDeleteId}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDelete()}
              disabled={deletingId === pendingDeleteId}
              aria-label="Confirm delete session"
            >
              {deletingId === pendingDeleteId ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      ) : null}
    </>
  );
}

// Hook-backed entry for standalone renders without an owner flag.
function SessionSidebarHooked(
  props: Omit<SessionSidebarProps, "isMobile" | "isActive"> & {
    isMobile?: undefined;
    isActive: boolean;
  },
) {
  const hookIsMobile = useIsMobile();
  return <SessionSidebarView {...props} isMobile={hookIsMobile} />;
}

export default function SessionSidebar({
  isMobile: isMobileProp,
  isActive: isActiveProp,
  ...rest
}: SessionSidebarProps) {
  // Single-owner handheld truth: ChatView always passes its live `isMobile` flag, so render
  // directly with no second subscription here.
  const active = isActiveProp ?? true;
  if (isMobileProp !== undefined) {
    return <SessionSidebarView {...rest} isMobile={isMobileProp} isActive={active} />;
  }
  return <SessionSidebarHooked {...rest} isActive={active} />;
}
