// Rune Weaver Dashboard — Needs Action Queue.
//
// Surfaces all items blocked on human decision:
// 1. Tool and egress approvals (consequential actions: delete, push, spend, email).
// 2. Goals paused in 'needs_input' status waiting on operator direction.
//
// Operators can approve or reject immediately with one click directly from
// the dashboard, or jump into the owning chat session.

import { useCallback, useEffect, useState } from "react";
import {
  decideApproval,
  goalNeedsInput,
  listApprovals,
  listGoals,
  respondToQuestion,
  type Goal,
  type PermissionRequest,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import InlineQuestionCard from "../InlineQuestionCard";
import {
  AlertTriangleIcon,
  CheckIcon,
  CloseIcon,
  MessageSquareIcon,
  TargetIcon,
} from "../icons";

interface NeedsActionQueueProps {
  onOpenSession?: (sessionId: string) => void;
  onOpenGoals?: () => void;
  onActionDecided?: () => void;
}

export default function NeedsActionQueue({
  onOpenSession,
  onOpenGoals,
  onActionDecided,
}: NeedsActionQueueProps) {
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [blockedGoals, setBlockedGoals] = useState<Goal[]>([]);
  const [decidingId, setDecidingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fetchActionItems = useCallback(async () => {
    try {
      setError(null);
      const [approvalsRes, goalsRes] = await Promise.all([
        listApprovals(20).catch(() => ({ approvals: [], count: 0 })),
        listGoals().catch(() => ({ goals: [], count: 0 })),
      ]);

      setApprovals(approvalsRes.approvals || []);
      // Single blocked-goal predicate shared with the greeting cluster so
      // both surfaces agree on which statuses count as needing input.
      const inputNeeded = (goalsRes.goals || []).filter((g) =>
        goalNeedsInput(g.status),
      );
      setBlockedGoals(inputNeeded);
    } catch (err) {
      console.warn("Failed to fetch needs-action items:", err);
    }
  }, []);

  useEffect(() => {
    fetchActionItems();
  }, [fetchActionItems]);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (
        frameType === "approval" ||
        frameType === "approval_decided" ||
        frameType === "goal_updated" ||
        frameType === "run_completed"
      ) {
        fetchActionItems();
      }
    },
    [fetchActionItems],
  );

  const handleSocketOpen = useCallback(() => {
    fetchActionItems();
  }, [fetchActionItems]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchActionItems();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [fetchActionItems]);

  async function handleDecision(req: PermissionRequest, approved: boolean) {
    try {
      setDecidingId(req.id);
      await decideApproval(req.id, approved);
      setApprovals((prev) => prev.filter((a) => a.id !== req.id));
      onActionDecided?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to record decision");
    } finally {
      setDecidingId(null);
    }
  }

  async function handleQuestionResponse(id: string, answer?: string, cancelled?: boolean) {
    try {
      setDecidingId(id);
      await respondToQuestion(id, answer, cancelled);
      setApprovals((prev) => prev.filter((a) => a.id !== id));
      onActionDecided?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to record response");
    } finally {
      setDecidingId(null);
    }
  }

  const totalActionsNeeded = approvals.length + blockedGoals.length;

  return (
    <section className="dashboard-section needs-action-section" aria-label="Items needing your action">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <AlertTriangleIcon
            size={18}
            className={`dashboard-section-icon ${
              totalActionsNeeded > 0 ? "status-amber" : "status-green"
            }`}
          />
          <h2 className="dashboard-section-title">Needs Your Action</h2>
          {totalActionsNeeded > 0 ? (
            <span className="dashboard-count-badge attention">{totalActionsNeeded}</span>
          ) : null}
        </div>
        <span className="dashboard-section-subtitle">
          {totalActionsNeeded > 0
            ? "Consequential actions and questions waiting on your OK"
            : "No pending decisions"}
        </span>
      </div>

      {error && <div className="notice-banner error">{error}</div>}

      {totalActionsNeeded === 0 ? (
        <div className="dashboard-empty-card all-clear-card">
          <span className="all-clear-icon">✨</span>
          <div className="all-clear-text">
            <h3 className="all-clear-title">All Caught Up</h3>
            <p className="all-clear-desc">
              No pending approvals, high-impact tool requests, or blocked goals.
            </p>
          </div>
        </div>
      ) : (
        <div className="needs-action-list">
          {/* Pending Tool Approvals & Questions */}
          {approvals.map((req) => {
            const isBusy = decidingId === req.id;
            if (req.toolName === "question.ask") {
              return (
                <InlineQuestionCard
                  key={req.id}
                  request={req}
                  deciding={isBusy}
                  variant="dashboard"
                  onRespond={(id, answer, cancelled) =>
                    void handleQuestionResponse(id, answer, cancelled)
                  }
                  onOpenSession={onOpenSession}
                />
              );
            }
            const isContinuation = req.toolName === "engine.continue";
            const isDesktopResume = req.toolName === "desktop.resume";
            const severity = req.assessment?.severity || "moderate";
            const argSummary = (isContinuation || isDesktopResume)
              ? null
              : (req.input?.argumentsJSON || req.intent || null);
            const toolBadgeText = isContinuation ? "Continuation" : isDesktopResume ? "Desktop Paused" : req.toolName;
            const severityBadgeText = isContinuation ? "CONTINUATION" : isDesktopResume ? "PAUSED" : severity.toUpperCase();
            const descriptionText =
              req.description ||
              (isContinuation
                ? "The agent has completed its allocated tool rounds and is requesting continuation."
                : isDesktopResume
                ? "Desktop automation paused because you moved the mouse. Resume agent control to capture a fresh screenshot and continue."
                : "Approval requested for tool execution.");

            return (
              <article key={req.id} className={`action-card severity-${severity} ${isContinuation ? "action-card-continuation" : ""} ${isDesktopResume ? "action-card-desktop-resume" : ""}`}>
                <div className="action-card-header">
                  <div className="action-card-title-row">
                    <span className={`badge severity-badge severity-${severity}`}>
                      {severityBadgeText}
                    </span>
                    <span className="tool-name-badge">{toolBadgeText}</span>
                  </div>
                  {req.sessionID ? (
                    <button
                      type="button"
                      className="btn-link open-session-link"
                      onClick={() => onOpenSession?.(req.sessionID!)}
                      title="Open chat thread for this approval"
                    >
                      <MessageSquareIcon size={13} />
                      <span>Open Thread</span>
                    </button>
                  ) : null}
                </div>

                <div className="action-card-body">
                  <p className="action-card-desc">{descriptionText}</p>
                  {argSummary ? (
                    <details className="action-args-details">
                      <summary className="action-args-summary">
                        <span>View arguments</span>
                      </summary>
                      <div className="action-args-preview">
                        <code>{argSummary}</code>
                      </div>
                    </details>
                  ) : null}
                </div>

                <div className="action-card-buttons">
                  <button
                    type="button"
                    className="btn btn-primary approve-action-btn"
                    onClick={() => handleDecision(req, true)}
                    disabled={isBusy}
                    aria-label={isContinuation ? "Continue execution" : isDesktopResume ? "Resume desktop control" : `Approve ${req.toolName}`}
                  >
                    <CheckIcon size={15} />
                    <span>
                      {isBusy
                        ? isContinuation
                          ? "Continuing…"
                          : isDesktopResume
                          ? "Resuming…"
                          : "Approving…"
                        : isContinuation
                        ? "Continue"
                        : isDesktopResume
                        ? "Resume Control"
                        : "Approve"}
                    </span>
                  </button>

                  <button
                    type="button"
                    className="btn reject-action-btn"
                    onClick={() => handleDecision(req, false)}
                    disabled={isBusy}
                    aria-label={isContinuation ? "Stop execution" : isDesktopResume ? "Cancel task" : `Reject ${req.toolName}`}
                  >
                    <CloseIcon size={15} />
                    <span>
                      {isBusy
                        ? isContinuation
                          ? "Stopping…"
                          : isDesktopResume
                          ? "Cancelling…"
                          : "Rejecting…"
                        : isContinuation
                        ? "Stop"
                        : isDesktopResume
                        ? "Cancel Task"
                        : "Reject"}
                    </span>
                  </button>
                </div>
              </article>
            );
          })}

          {/* Blocked Goals Needing Input */}
          {blockedGoals.map((goal) => (
            <article key={goal.id} className="action-card goal-input-card">
              <div className="action-card-header">
                <div className="action-card-title-row">
                  <span className="badge severity-badge severity-moderate">
                    NEEDS INPUT
                  </span>
                  <span className="tool-name-badge">Goal Pursuit</span>
                </div>
                {goal.originSessionId ? (
                  <button
                    type="button"
                    className="btn-link open-session-link"
                    onClick={() => onOpenSession?.(goal.originSessionId!)}
                  >
                    <MessageSquareIcon size={13} />
                    <span>Open Thread</span>
                  </button>
                ) : null}
              </div>

              <div className="action-card-body">
                <h4 className="goal-action-title">{goal.title}</h4>
                <p className="action-card-desc">
                  {goal.statement || "This goal is paused waiting for operator guidance or configuration."}
                </p>
              </div>

              <div className="action-card-buttons">
                <button
                  type="button"
                  className="btn btn-primary open-goal-btn"
                  onClick={() => onOpenGoals?.()}
                >
                  <TargetIcon size={15} />
                  <span>Inspect Goal</span>
                </button>
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}
