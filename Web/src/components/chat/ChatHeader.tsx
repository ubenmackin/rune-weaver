// Rune Weaver Dashboard — Chat panel header displaying session metadata, goal chip, persona indicator, and actions.

import type { RefObject } from "react";
import { goalStatusTone, type Goal } from "../../api";
import { SettingsIcon, TargetIcon } from "../icons";

interface ChatHeaderProps {
  sidebarOpen: boolean;
  historyButtonRef: RefObject<HTMLButtonElement>;
  onOpenSidebar: () => void;
  personaDisplayName: string | null;
  sessionID: string;
  sessionGoal: Goal | null;
  goalChipRef: RefObject<HTMLButtonElement>;
  onOpenGoalDrawer: () => void;
  sessionPendingCount: number;
  onOpenSettings: () => void;
  onNewSession: () => void;
}

export default function ChatHeader({
  sidebarOpen,
  historyButtonRef,
  onOpenSidebar,
  personaDisplayName,
  sessionID,
  sessionGoal,
  goalChipRef,
  onOpenGoalDrawer,
  sessionPendingCount,
  onOpenSettings,
  onNewSession,
}: ChatHeaderProps) {
  return (
    <div className="chat-panel-header">
      <div className="chat-panel-title">
        {!sidebarOpen && (
          <button
            type="button"
            ref={historyButtonRef}
            className="open-sidebar-btn"
            onClick={onOpenSidebar}
            title="Open session history"
          >
            History
          </button>
        )}
        <h2>Chat</h2>
        {/* Persona name beside the session title: the title stays primary,
            so the name reads small and muted. An absent persona (or a name
            that normalizes blank) renders exactly today's header — no
            identity row at all. Text identity only: the greeting cluster
            owns the app's sole avatar image, so this row never renders one. */}
        {personaDisplayName ? (
          <span
            className="chat-persona-identity"
            data-testid="chat-persona-identity"
          >
            <span className="chat-persona-name">{personaDisplayName}</span>
          </span>
        ) : null}
        <span className="session-id-tag font-mono" title={sessionID}>
          {sessionID.slice(0, 8)}
        </span>
        {/* Goal chip: compact pursuit pill shown only for a session the
            engine linked to a goal. Clicking opens the drawer; the chip
            stays mounted while the drawer is open so Escape can return
            focus to it. */}
        {sessionGoal ? (
          <button
            type="button"
            ref={goalChipRef}
            className={`goal-chip ${goalStatusTone(sessionGoal.status)}`}
            data-testid="session-goal-chip"
            onClick={onOpenGoalDrawer}
            title={`${sessionGoal.title} — ${sessionGoal.progress.done}/${sessionGoal.progress.total} steps`}
          >
            <TargetIcon size={13} />
            <span className="goal-chip-title">Goal Tracker</span>
            <span className="goal-chip-progress">
              {sessionGoal.progress.done}/{sessionGoal.progress.total}
            </span>
          </button>
        ) : null}
        {sessionPendingCount > 0 ? (
          <span
            className="pending-approval-badge"
            data-testid="session-pending-badge"
            title={`${sessionPendingCount} approval${sessionPendingCount > 1 ? "s" : ""} awaiting decision for this session`}
          >
            Pending approval ({sessionPendingCount})
          </span>
        ) : null}
      </div>

      <div className="chat-panel-actions">
        <button
          type="button"
          className="ghost chat-settings-btn"
          onClick={onOpenSettings}
          aria-label="Chat Settings"
          title="Chat Settings"
        >
          <SettingsIcon size={14} />
          <span>Settings</span>
        </button>
        <button
          type="button"
          className="ghost new-session-btn"
          onClick={onNewSession}
          aria-label="New session"
        >
          New Session
        </button>
      </div>
    </div>
  );
}
