// Rune Weaver Dashboard — Collapsible session history sidebar for Chat.
// Lists past sessions, supports instant switching, inline renaming, and session deletion.

import { useCallback, useEffect, useRef, useState, type FormEvent, type MouseEvent } from "react";
import {
  deleteSession,
  listSessions,
  updateSessionTitle,
  type SessionSummary,
} from "../api";
import {
  ChatIcon,
  CheckIcon,
  ClockIcon,
  CloseIcon,
  EditIcon,
  PlusIcon,
  TrashIcon,
} from "./icons";

interface SessionSidebarProps {
  currentSessionID: string;
  onSelectSession: (id: string) => void;
  onNewSession: () => void;
  isOpen: boolean;
  onToggleOpen: () => void;
}

interface GroupedSessions {
  today: SessionSummary[];
  yesterday: SessionSummary[];
  lastWeek: SessionSummary[];
  older: SessionSummary[];
}

function groupSessionsByDate(sessions: SessionSummary[] = []): GroupedSessions {
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const yesterdayStart = todayStart - 86400000;
  const lastWeekStart = todayStart - 7 * 86400000;

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

export default function SessionSidebar({
  currentSessionID,
  onSelectSession,
  onNewSession,
  isOpen,
  onToggleOpen,
}: SessionSidebarProps) {
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [loading, setLoading] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingTitle, setEditingTitle] = useState("");
  // Non-blocking delete confirmation: the pending id renders an inline
  // confirm instead of a blocking native prompt.
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  // Submit blurs the input, so `onSubmit` and `onBlur` fire for one save.
  // The in-flight marker drops the second invocation before it can issue
  // a duplicate PATCH.
  const renameInFlightRef = useRef<string | null>(null);

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
  }, [refreshSessions, currentSessionID]);

  async function handleStartRename(session: SessionSummary, e: MouseEvent) {
    e.stopPropagation();
    setEditingId(session.id);
    setEditingTitle(session.title);
  }

  async function handleSaveRename(id: string, e?: FormEvent) {
    if (e) e.preventDefault();
    // Stale (already saved or cancelled) or duplicate (submit plus blur)
    // invocations are no-ops so one save issues exactly one PATCH.
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
      if (id === currentSessionID) {
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

  const grouped = groupSessionsByDate(sessions);

  const renderGroup = (label: string, items: SessionSummary[]) => {
    if (items.length === 0) return null;
    return (
      <div className="session-group" key={label}>
        <div className="session-group-label">{label}</div>
        {items.map((session) => {
          const isActive = session.id === currentSessionID;
          const isEditing = editingId === session.id;
          const isScheduled = session.source === "scheduler";

          return (
            <div
              key={session.id}
              className={`session-item ${isActive ? "active" : ""}`}
              onClick={() => !isEditing && onSelectSession(session.id)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !isEditing) onSelectSession(session.id);
              }}
            >
              {isScheduled ? (
                <ClockIcon size={14} className="session-item-icon scheduled" title="Scheduled run" />
              ) : (
                <ChatIcon size={14} className="session-item-icon" />
              )}
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
                    autoFocus
                    onBlur={() => void handleSaveRename(session.id)}
                    className="session-rename-input"
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
                      onClick={(e) => void handleStartRename(session, e)}
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

      <div className="sidebar-session-list">
        {loading && sessions.length === 0 ? (
          <p className="sidebar-muted">Loading history…</p>
        ) : null}
        {sessions.length === 0 && !loading ? (
          <p className="sidebar-muted">No prior sessions</p>
        ) : (
          <>
            {renderGroup("Today", grouped.today)}
            {renderGroup("Yesterday", grouped.yesterday)}
            {renderGroup("Previous 7 Days", grouped.lastWeek)}
            {renderGroup("Older", grouped.older)}
          </>
        )}
      </div>
      {pendingDeleteId && (
        <div className="modal-overlay" role="dialog" aria-label="Confirm delete session">
          <div className="modal">
            <h3>Delete this chat session?</h3>
            <p className="sidebar-muted">This cannot be undone.</p>
            <div className="row">
              <button type="button" className="ghost" onClick={cancelDelete} disabled={deletingId === pendingDeleteId}>
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
          </div>
        </div>
      )}
    </aside>
  );
}
