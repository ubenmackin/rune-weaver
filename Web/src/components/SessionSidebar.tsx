// Rune Weaver Dashboard — Collapsible session history sidebar for Chat.
// Lists past sessions, supports instant switching, inline renaming, and session deletion.

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type MouseEvent,
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
import { useRunningRuns } from "../hooks/useRunningRuns";
import type { WSGenericFrame } from "../hooks/useSharedWebSocket";
import {
  AlertTriangleIcon,
  ChatIcon,
  CheckIcon,
  ClockIcon,
  CloseIcon,
  EditIcon,
  PlusIcon,
  TrashIcon,
} from "./icons";
import Modal from "./Modal";

export type SessionFilter = "all" | "chat" | "scheduler";

interface SessionSidebarProps {
  currentSessionID: string;
  onSelectSession: (id: string) => void;
  onNewSession: () => void;
  isOpen: boolean;
  onToggleOpen: () => void;
  refreshTrigger?: number;
  pendingApprovals?: PermissionRequest[];
  // Live interactive turns parked in the chat view while the user browses
  // other sessions. The sidebar merges these with polled run rows so a
  // background turn stays badged even before its run record persists.
  runningSessionIDs?: Set<string> | string[] | null;
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

export default function SessionSidebar({
  currentSessionID,
  onSelectSession,
  onNewSession,
  isOpen,
  onToggleOpen,
  refreshTrigger,
  pendingApprovals,
  runningSessionIDs,
}: SessionSidebarProps) {
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [loading, setLoading] = useState(false);
  const [filter, setFilter] = useState<SessionFilter>(getSavedSessionFilter);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingTitle, setEditingTitle] = useState("");
  // Non-blocking delete confirmation: the pending id renders a true modal.
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
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

  // Sessions with a turn still running on the engine while the user browses
  // elsewhere. Live broadcasts mark the start immediately while the shared
  // run-log poller covers reloads and missed sockets, so the badge never
  // depends on one transport alone. Entries are normalized lowercase for
  // comparison since the engine formats UUIDs uppercase and the dashboard
  // mints lowercase. Polling lives single-source in `useRunningRuns` alongside
  // the chat view so two mounted views share one interval instead of doubling
  // QPS; this view keeps only the live set plus the shared polled set.
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

  const handleRunBroadcast = useCallback((data: unknown) => {
    const frame = data as WSGenericFrame | null;
    if (!frame || typeof frame !== "object") return;
    const frameType = typeof frame.type === "string" ? frame.type : undefined;
    if (frameType !== "run_started" && frameType !== "run_completed") return;
    const nested = (frame as Record<string, unknown>).run;
    if (!nested || typeof nested !== "object") return;
    const owner = runSessionID(
      nested as Parameters<typeof runSessionID>[0],
    );
    const normalized = normalizeSessionID(owner);
    if (!normalized) return;
    // Single active contract with the polled run log: only a live running
    // status keeps the badge lit. A parked awaiting_approval turn arrives as
    // completed and surfaces through the approvals icon instead, so live and
    // polled views agree after reload without double-badging.
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
  }, []);

  useSharedWebSocket(handleRunBroadcast);

  // Revalidate the shared poller when the viewed session changes so a switch
  // badges without waiting for the next tick; the interval itself stays owned
  // by the shared hook. Terminal eviction needs no local timer because the
  // shared tick plus live `run_completed` broadcasts clear both sets.
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

  useEffect(() => {
    void refreshSessions();
  }, [refreshSessions, currentSessionID, refreshTrigger]);

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

  const filteredSessions = useMemo(() => {
    return activeSessions.filter((session) => {
      const isScheduled = isScheduledSession(session);
      if (filter === "chat") return !isScheduled;
      if (filter === "scheduler") return isScheduled;
      return true;
    });
  }, [activeSessions, filter]);

  // Union of every running signal so one missed transport never hides a
  // background turn: live broadcasts for immediacy, polled runs for reloads,
  // and the chat view's parked flights for turns whose run row has not
  // persisted yet. All entries stay normalized for case-insensitive matches.
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

  const grouped = groupSessionsByDate(filteredSessions);

  const renderGroup = (label: string, items: SessionSummary[]) => {
    if (items.length === 0) return null;
    return (
      <div className="session-group" key={label}>
        <div className="session-group-label">{label}</div>
        {items.map((session) => {
          const isActive = isSameSession(session.id, currentSessionID);
          const isEditing = editingId === session.id;
          const isScheduled = isScheduledSession(session);
          // Background turns keep their badge even while viewed elsewhere so
          // the user can spot a still-running session without opening Runs.
          // The active session keeps its typing indicator in chat; the row
          // badge stays as the cross-session signal.
          const isBackgroundRunning = backgroundRunning.has(
            normalizeSessionID(session.id),
          );

          return (
            <div
              key={session.id}
              className={`session-item ${isActive ? "active" : ""}`}
              onClick={() => !isEditing && onSelectSession(session.id)}
              role="button"
              tabIndex={0}
              aria-label={`Open session ${session.title}`}
              onKeyDown={(e) => {
                if (isEditing) return;
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  onSelectSession(session.id);
                }
              }}
            >
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
                if (isScheduled) {
                  return (
                    <ClockIcon
                      size={14}
                      className="session-item-icon scheduled"
                      title="Scheduled run"
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
          );
        })}
      </div>
    );
  };

  return (
    <>
      <aside className={`session-sidebar ${isOpen ? "open" : "collapsed"}`}>
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
          {filteredSessions.length === 0 && !loading ? (
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
