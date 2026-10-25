// Rune Weaver Dashboard — Goal drawer for the chat surface.

import { useEffect, useState, type RefObject } from "react";
import {
  formatRunDuration,
  goalAdvanceBlockedTitle,
  goalEventKindLabel,
  goalProgressPercent,
  goalStatusLabel,
  goalStatusTone,
  isActiveRunStatus,
  isGoalAdvanceable,
  parseRunTimestamp,
  type Goal,
} from "../api";
import {
  goalStepNextStatus,
  useGoalDetail,
} from "../hooks/useGoalDetail";
import MarkdownText from "./MarkdownText";
import { CloseIcon, TargetIcon } from "./icons";

// Bounded activity window: the audit trail is append-only and can grow without
// limit, so the drawer shows the newest slice rather than the whole history.
const LAST_EVENT_LIMIT = 10;
// Linked runs stay bounded to a glance; the full history lives in the Runs tab.
const LINKED_RUN_LIMIT = 3;

interface GoalDrawerProps {
  // Goal the drawer renders. A change re-reads detail so one mounted drawer can
  // follow a session switch without remounting.
  goalId: string;
  // Snapshot already resolved by the chat header so the header paints before
  // the detail fetch lands. Optional so a standalone mount still works.
  initialGoal?: Goal | null;
  // Dismissal owned by the parent; Escape and the close control both route here
  // so the parent stays the single owner of the open state.
  onClose: () => void;
  // Switches the shell to the full Goals surface. Optional so standalone
  // renders can omit the affordance.
  onSelectTab?: (tab: "goals") => void;
  // Focus target restored after dismissal, normally the chat header chip, so
  // keyboard users land back on the control that opened the panel.
  returnFocusRef?: RefObject<HTMLElement | null>;
}

export default function GoalDrawer({
  goalId,
  initialGoal,
  onClose,
  onSelectTab,
  returnFocusRef,
}: GoalDrawerProps) {
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // Detail, linked runs, and every mutation live in the shared goal controller
  // so the drawer and the Goals panel share one implementation; the controller
  // also reloads only when a `goal_updated` push names this goal.
  const {
    detail,
    runs,
    loadingDetailId,
    advancingGoalId,
    togglingGoalId,
    togglingStepId,
    advance,
    toggleStatus,
    setStepStatus,
  } = useGoalDetail(goalId, {
    runLimit: LINKED_RUN_LIMIT,
    onError: setError,
    onNotice: setNotice,
  });

  // Escape dismisses and returns focus to the chip. Registered on the window so
  // the key works regardless of which control inside the panel holds focus.
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      onClose();
      // Focus after dismissal so a parent that unmounts the panel on close
      // never leaves focus stranded on a removed node.
      returnFocusRef?.current?.focus();
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose, returnFocusRef]);

  const goal = detail?.goal ?? initialGoal ?? null;
  const isTerminal = goal?.status === "abandoned";
  const loading = loadingDetailId === goalId;
  const advancing = advancingGoalId === goalId;
  const togglingStatus = togglingGoalId === goalId;

  const percent = detail ? goalProgressPercent(detail.goal.progress) : 0;
  const events = detail ? detail.events.slice(0, LAST_EVENT_LIMIT) : [];

  return (
    <aside
      className="goal-drawer"
      data-testid="goal-drawer"
      aria-label={goal ? `Goal ${goal.title}` : "Goal details"}
    >
      <div className="goal-drawer-header">
        <div className="goal-drawer-heading">
          <span className="goal-drawer-title-row">
            <TargetIcon size={16} />
            <strong className="goal-drawer-title">
              {goal ? goal.title : "Goal"}
            </strong>
            {goal ? (
              <span className={`status-pill ${goalStatusTone(goal.status)}`}>
                {goalStatusLabel(goal.status).toUpperCase()}
              </span>
            ) : null}
          </span>
          {goal ? (
            <span className="muted text-xs">
              {goal.progress.done}/{goal.progress.total} steps
            </span>
          ) : null}
        </div>
        <button
          type="button"
          className="icon-button"
          onClick={onClose}
          aria-label="Close goal"
        >
          <CloseIcon size={16} />
        </button>
      </div>

      {detail ? (
        <div
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={percent}
          aria-label={`${detail.goal.title} progress`}
          className="progress-track"
        >
          <div
            className="progress-fill"
            style={{ width: `${percent}%` }}
          />
        </div>
      ) : null}

      <div className="goal-drawer-body">
        {error ? <p className="error">{error}</p> : null}
        {notice ? <div className="notice-banner">{notice}</div> : null}

        {loading && !detail ? (
          <p className="muted text-xs">Loading goal…</p>
        ) : null}

        {detail ? (
          <>
            <section aria-label="Goal plan">
              <h4>Plan</h4>
              {detail.steps.length === 0 ? (
                <p className="muted text-xs">
                  No plan drafted yet. The agent lands it shortly after creation.
                </p>
              ) : (
                <ul className="goal-plan-list">
                  {detail.steps.map((step) => (
                    <li key={step.id} className="goal-plan-step">
                      <input
                        type="checkbox"
                        checked={step.status === "done"}
                        disabled={togglingStepId === step.id || isTerminal}
                        onChange={() =>
                          void setStepStatus(step, goalStepNextStatus(step))
                        }
                        aria-label={`Toggle ${step.title}`}
                      />
                      <div className="goal-plan-step-body">
                        <span
                          className={
                            step.status === "done"
                              ? "goal-plan-step-title done"
                              : "goal-plan-step-title"
                          }
                        >
                          {step.title}
                        </span>
                        <span className="muted text-xs">
                          {" "}
                          · {step.status.replace(/_/g, " ")}
                        </span>
                        {step.notes ? (
                          <MarkdownText
                            text={step.notes}
                            className="markdown-content text-xs"
                          />
                        ) : null}
                      </div>
                      <button
                        type="button"
                        className="ghost goal-step-skip"
                        onClick={() => void setStepStatus(step, "skipped")}
                        disabled={
                          togglingStepId === step.id ||
                          isTerminal ||
                          step.status === "skipped"
                        }
                        aria-label={`Skip ${step.title}`}
                      >
                        Skip
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </section>

            <section aria-label="Goal activity">
              <h4>Recent activity</h4>
              {events.length === 0 ? (
                <p className="muted text-xs">No activity recorded yet.</p>
              ) : (
                <div className="embedded-runs-list">
                  {events.map((event) => (
                    <div
                      className="embedded-run-item goal-event-item"
                      key={event.id}
                    >
                      <div className="muted text-xs">
                        {goalEventKindLabel(event.kind)} ·{" "}
                        {parseRunTimestamp(event.createdAt).toLocaleString()}
                      </div>
                      <MarkdownText
                        text={event.message}
                        className="markdown-content"
                      />
                    </div>
                  ))}
                </div>
              )}
            </section>

            <section aria-label="Linked runs">
              <h4>Linked runs</h4>
              {runs.length === 0 ? (
                <p className="muted text-xs">
                  No runs recorded for this goal yet. Use Work on it now to start one.
                </p>
              ) : (
                <div className="embedded-runs-list">
                  {runs.map((run) => {
                    const duration = formatRunDuration(run.durationMs);
                    return (
                      <div className="embedded-run-item" key={run.id}>
                        <div className="embedded-run-meta">
                          <span className={`status-pill small ${run.status}`}>
                            {isActiveRunStatus(run.status)
                              ? "IN PROGRESS"
                              : run.status.toUpperCase()}
                          </span>
                          <span className="text-xs muted">
                            {parseRunTimestamp(run.timestamp).toLocaleString()}
                          </span>
                          {duration ? (
                            <span className="text-xs muted">• {duration}</span>
                          ) : null}
                        </div>
                        <div className="embedded-run-response">
                          {run.response || run.message}
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </section>
          </>
        ) : null}
      </div>

      <div className="goal-drawer-footer">
        <button
          type="button"
          className={`status-toggle-btn ${
            goal?.status === "active" ? "is-pause" : "is-resume"
          }`}
          onClick={() => {
            if (goal) void toggleStatus(goal);
          }}
          disabled={togglingStatus || isTerminal || !goal}
          aria-label={goal?.status === "active" ? "Pause" : "Resume"}
        >
          {togglingStatus
            ? "Updating…"
            : goal?.status === "active"
              ? "Pause"
              : "Resume"}
        </button>
        <button
          type="button"
          className="ghost run-now-btn"
          onClick={() => {
            if (goal) void advance(goal);
          }}
          disabled={
            advancing || isTerminal || !goal || !isGoalAdvanceable(goal.status)
          }
          title={
            goal && isGoalAdvanceable(goal.status)
              ? "Work on it now"
              : goalAdvanceBlockedTitle(goal?.status ?? "")
          }
          aria-label="Work on it now"
        >
          {advancing ? "Working…" : "Work on it now"}
        </button>
        {onSelectTab ? (
          <button
            type="button"
            className="ghost"
            onClick={() => {
              onSelectTab("goals");
              onClose();
            }}
            aria-label="Open in Goals"
          >
            Open in Goals
          </button>
        ) : null}
      </div>
    </aside>
  );
}
