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
  listSessions,
  updateSessionTitle,
  type PermissionRequest,
  type SessionSummary,
} from "../api";
import {
  getSavedEnum,
  isSameSession,
  persistEnum,
} from "../approvalsSession";
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
}

interface GroupedSessions {
  today: SessionSummary[];
  yesterday: SessionSummary[];
  lastWeek: SessionSummary[];
  older: SessionSummary[];
}

function groupSessionsByDate(sessions: SessionSummary[] = []): GroupedSessions {
  // Compare calendar days via date components so grouping stays correct
  // across DST transitions, where a day is 23 or 25 hours instead of a
  // fixed millisecond offset. Constructing midnight per calendar day keeps
  // Today/Yesterday/Previous-7-Days boundaries on local midnights.
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

export default function SessionSidebar({
  currentSessionID,
  onSelectSession,
  onNewSession,
  isOpen,
  onToggleOpen,
  refreshTrigger,
  pendingApprovals,
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

  // If currentSessionID is active but not yet persisted on server (fresh new chat),
  // optimistically inject it so it immediately appears in the history sidebar under Today.
  // Identity compares case-insensitively so uppercase engine IDs match the
  // lowercase IDs minted by the dashboard without duplicating the draft.
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
      const isScheduled = session.source === "scheduler";
      if (filter === "chat") return !isScheduled;
      if (filter === "scheduler") return isScheduled;
      return true;
    });
  }, [activeSessions, filter]);

  const grouped = groupSessionsByDate(filteredSessions);

  const renderGroup = (label: string, items: SessionSummary[]) => {
    if (items.length === 0) return null;
    return (
      <div className="session-group" key={label}>
        <div className="session-group-label">{label}</div>
        {items.map((session) => {
          const isActive = isSameSession(session.id, currentSessionID);
          const isEditing = editingId === session.id;
          const isScheduled = session.source === "scheduler";

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
