// Rune Weaver Dashboard — Needs Action Queue.
//
// Surfaces all items blocked on human decision:
// 1. Tool and egress approvals (consequential actions: delete, push, spend, email).
// 2. The behavior brake card the trusted-tool watchdog files into the same inbox.
// 3. Goals paused in 'needs_input' status waiting on operator direction.
// 4. Booked scheduled sends awaiting their fire time (monitoring only: Cancel
//    plus a Manage shortcut, no approval semantics of any kind).
//
// Every quick decision on this surface is duration-only: the Allow chevron
// lists the shared duration tiers for the request and the decision carries
// no scope, so the engine resolves the request's own target. One-shot
// (coerced-tool) requests — continuation, desktop resume — carry no standing
// deny either, because their durable tier coerces to thisTime and mints no
// rule; the decision tags surface "dashboard" for the audit trail. Scope
// editing lives in the Approvals Inbox, which every approval card links to,
// and there is no batch or bulk control anywhere — each card is decided on
// its own. Scheduled sends sit outside the attention count entirely: they
// never move the badge, the subtitle, or the greeting caption, and the
// all-clear card requires approvals, goals, and sends to all be empty.

import { useCallback, useEffect, useState } from "react";
import {
  advanceGoal,
  cancelScheduledSend,
  decideApproval,
  goalNeedsInput,
  isGoalUnplanned,
  listApprovals,
  listGoals,
  listScheduledSends,
  parseRunTimestamp,
  respondToQuestion,
  type Goal,
  type ImpactSeverity,
  type PermissionRequest,
  type ScheduledSend,
  type TrustDuration,
} from "../../api";
import { formatRelativeIn } from "../../relativeTime";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import InlineQuestionCard from "../InlineQuestionCard";
import BashTierLine from "../BashTierLine";
import { resolveSandboxSummary } from "../InlineApprovalBanner";
import {
  deriveRequestTarget,
  durationOptionsFor,
  truncateTarget,
} from "../../approvalsShared";
import { useSplitMenu } from "../../useSplitMenu";
import {
  AlertTriangleIcon,
  ApprovalsIcon,
  CheckIcon,
  ChevronRightIcon,
  CloseIcon,
  MessageSquareIcon,
  TargetIcon,
} from "../icons";

interface NeedsActionQueueProps {
  onOpenSession?: (sessionId: string) => void;
  onOpenGoals?: () => void;
  onOpenSchedules?: () => void;
  onActionDecided?: () => void;
}

// Watchdog brake card. Releasing the parked turns is its complete decision, so
// it renders a dedicated Resume / Keep paused branch with no duration control
// instead of the generic approve or deny pair.
const BRAKE_TOOL_NAME = "behavior.brake";

// One-shot (coerced-tool) requests, mirroring the engine's oneShotToolNames in
// ApprovalQueue: any durable tier on them coerces to thisTime and mints no
// rule, so a standing deny on one is a dead vote. The chat banner gates them
// behind dedicated Continue/Stop and Resume/Cancel branches with no standing
// deny at all; the dashboard card matches by hiding the Deny-always chevron
// for these tools. question.ask and behavior.brake never reach the generic
// card (own branches above) but stay in the set for contract parity.
const ONE_SHOT_TOOL_NAMES: ReadonlySet<string> = new Set([
  "engine.continue",
  "question.ask",
  "desktop.resume",
  "behavior.brake",
]);

// One ordering scale shared by tool approvals, questions, and brake cards, so a
// consequential card never sinks below a quieter one.
function severityRank(severity: ImpactSeverity): number {
  switch (severity) {
    case "dangerous":
      return 3;
    case "moderate":
      return 2;
    default:
      return 1;
  }
}

function requestSeverity(req: PermissionRequest): ImpactSeverity {
  return req.assessment?.severity ?? "moderate";
}

// Severity descending, then filing time descending. The wire carries no filing
// timestamp, so payload position is the only filing signal available: a later
// position in the payload reads as the more recent filing, so equal severities
// break newest-first.
function orderBySeverityThenFiling(approvals: PermissionRequest[]): PermissionRequest[] {
  return approvals
    .map((req, index) => ({ req, index }))
    .sort((a, b) => {
      const severity =
        severityRank(requestSeverity(b.req)) - severityRank(requestSeverity(a.req));
      return severity !== 0 ? severity : b.index - a.index;
    })
    .map((entry) => entry.req);
}

// Fire-time ascending so the most imminent send leads the monitoring group.
function orderSendsByFireTime(sends: ScheduledSend[]): ScheduledSend[] {
  return [...sends].sort(
    (a, b) => parseRunTimestamp(a.fireAt).getTime() - parseRunTimestamp(b.fireAt).getTime(),
  );
}

// Full duration and scope options live in the Approvals Inbox, so every
// approval card routes there. The hash anchor resolves through the shell's
// existing hashchange router, which keeps the link working without threading a
// navigation callback through every card variant.
function OpenInboxLink({ req }: { req: PermissionRequest }) {
  return (
    <a
      href="#approvals"
      className="btn-link open-inbox-link"
      title={`Open ${req.toolName} in the Approvals Inbox for duration and scope options`}
    >
      <ApprovalsIcon size={13} />
      <span>Open in Inbox</span>
    </a>
  );
}

interface DashboardApprovalCardProps {
  req: PermissionRequest;
  severity: ImpactSeverity;
  severityBadgeText: string;
  toolBadgeText: string;
  descriptionText: string;
  argSummary: string | null;
  cardClassName?: string;
  isBusy: boolean;
  onOpenSession?: (sessionId: string) => void;
  onDecide: (req: PermissionRequest, approved: boolean, duration: TrustDuration) => void;
}

// Generic approval card with duration-only Allow / Deny split buttons sharing
// the chat banner's split-allow class structure, so menu styling stays shared.
// The Allow chevron lists exactly the shared tiers for the request and sends
// no scope. The Deny chevron offers only the standing deny, and only for
// ordinary tools: a one-shot (coerced-tool) request resolves a single parked
// batch, so its standing-deny control is hidden exactly like the chat
// banner's dedicated one-shot branches. Open, dismissal, focus, and keyboard
// semantics come from the shared useSplitMenu machine both decision surfaces
// consume.
function DashboardApprovalCard({
  req,
  severity,
  severityBadgeText,
  toolBadgeText,
  descriptionText,
  argSummary,
  cardClassName,
  isBusy,
  onOpenSession,
  onDecide,
}: DashboardApprovalCardProps) {
  // A one-shot request can only deny once: its durable tier coerces to
  // thisTime inside the shared decision contract and mints no rule, so the
  // standing-deny control stays off the card entirely, matching the chat
  // banner's dedicated one-shot branches.
  const isOneShot = ONE_SHOT_TOOL_NAMES.has(req.toolName);
  const allowOptions = durationOptionsFor(req);
  const derivedTarget = deriveRequestTarget(req);
  // Shared split-menu machine: open state, outside-pointer-down dismissal,
  // focus-on-open, and the allow/deny keyboard flow come from the same hook
  // the chat banner consumes, so both quick surfaces stay one vocabulary.
  const {
    allowOpen,
    denyOpen,
    allowGroupRef,
    denyGroupRef,
    allowChevronRef,
    denyChevronRef,
    allowItemRefs,
    denyItemRef,
    toggleAllow,
    toggleDeny,
    closeAllowMenu,
    closeDenyMenu,
    handleAllowMenuKeyDown,
    handleDenyMenuKeyDown,
    setFocusedIndex,
  } = useSplitMenu(allowOptions.length);

  function handlePickAllow(value: TrustDuration) {
    closeAllowMenu(false);
    onDecide(req, true, value);
  }

  function handlePickDenyAlways() {
    closeDenyMenu(false);
    onDecide(req, false, "forever");
  }

  return (
    <article className={`action-card severity-${severity}${cardClassName ? ` ${cardClassName}` : ""}`}>
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
        <OpenInboxLink req={req} />
      </div>

      <div className="action-card-body">
        <p className="action-card-desc">{descriptionText}</p>
        <BashTierLine summary={resolveSandboxSummary(req)} />
        {derivedTarget ? (
          <p className="action-target-line">
            <span className="action-target-label">Target:</span>{" "}
            <code className="action-target-value" title={derivedTarget}>
              {truncateTarget(derivedTarget)}
            </code>
          </p>
        ) : null}
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
        <div
          className="split-allow-group"
          ref={allowGroupRef}
          onKeyDown={handleAllowMenuKeyDown}
        >
          <button
            type="button"
            className="btn btn-primary approve-action-btn split-allow-main"
            onClick={() => onDecide(req, true, "thisTime")}
            disabled={isBusy}
            aria-label={`Approve once for ${req.toolName}`}
          >
            <CheckIcon size={15} />
            <span>{isBusy ? "Approving…" : "Approve once"}</span>
          </button>
          <button
            ref={allowChevronRef}
            type="button"
            className="btn btn-primary split-allow-chevron"
            disabled={isBusy}
            aria-haspopup="menu"
            aria-expanded={allowOpen}
            aria-label={`Allow options for ${req.toolName}`}
            onClick={toggleAllow}
          >
            <span aria-hidden="true">▾</span>
          </button>
          {allowOpen && !isBusy ? (
            <ul className="split-allow-menu" role="menu">
              {allowOptions.map((option, index) => (
                <li key={option.value} role="none">
                  <button
                    ref={(node) => {
                      allowItemRefs.current[index] = node;
                    }}
                    type="button"
                    role="menuitem"
                    className="split-allow-menu-item"
                    onClick={() => handlePickAllow(option.value)}
                    onFocus={() => setFocusedIndex(index)}
                  >
                    {option.label}
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
        </div>

        <div
          className="split-deny-group"
          ref={denyGroupRef}
          onKeyDown={handleDenyMenuKeyDown}
        >
          <button
            type="button"
            className="btn reject-action-btn split-deny-main"
            onClick={() => onDecide(req, false, "thisTime")}
            disabled={isBusy}
            aria-label={`Deny ${req.toolName}`}
          >
            <CloseIcon size={15} />
            <span>{isBusy ? "Denying…" : "Deny"}</span>
          </button>
          {!isOneShot ? (
            <button
              ref={denyChevronRef}
              type="button"
              className="btn reject-action-btn split-deny-chevron"
              disabled={isBusy}
              aria-haspopup="menu"
              aria-expanded={denyOpen}
              aria-label={`Deny options for ${req.toolName}`}
              onClick={toggleDeny}
            >
              <span aria-hidden="true">▾</span>
            </button>
          ) : null}
          {denyOpen && !isBusy && !isOneShot ? (
            <ul className="split-allow-menu" role="menu">
              <li role="none">
                <button
                  ref={denyItemRef}
                  type="button"
                  role="menuitem"
                  className="split-allow-menu-item split-allow-menu-item-danger"
                  onClick={handlePickDenyAlways}
                >
                  Deny always
                </button>
              </li>
            </ul>
          ) : null}
        </div>
      </div>

      <p className="action-card-once-note">
        Duration applies to this target only. Scope editing lives in the Inbox.
      </p>
    </article>
  );
}

export default function NeedsActionQueue({
  onOpenSession,
  onOpenGoals,
  onOpenSchedules,
  onActionDecided,
}: NeedsActionQueueProps) {
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [blockedGoals, setBlockedGoals] = useState<Goal[]>([]);
  const [pendingSends, setPendingSends] = useState<ScheduledSend[]>([]);
  const [decidingId, setDecidingId] = useState<string | null>(null);
  const [planningGoalId, setPlanningGoalId] = useState<string | null>(null);
  const [cancellingSendId, setCancellingSendId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fetchActionItems = useCallback(async () => {
    try {
      setError(null);
      const [approvalsRes, goalsRes, sendsRes] = await Promise.all([
        listApprovals(20).catch(() => ({ approvals: [], count: 0 })),
        listGoals().catch(() => ({ goals: [], count: 0 })),
        listScheduledSends().catch(() => ({ sends: [], count: 0 })),
      ]);

      setApprovals(approvalsRes.approvals || []);
      // Single blocked-goal predicate shared with the greeting cluster:
      // goals parked awaiting owner input OR unplanned goals not yet planning.
      const actionGoals = (goalsRes.goals || []).filter(
        (g) => goalNeedsInput(g.status) || (isGoalUnplanned(g.status) && !g.isPlanning),
      );
      setBlockedGoals(actionGoals);
      // Settled rows (sent, cancelled, failed) already have their Runs history
      // entry, so only queued or in-flight sends need monitoring here.
      const pending = (sendsRes.sends || []).filter(
        (s) => s.status === "queued" || s.status === "sending",
      );
      setPendingSends(pending);
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
        frameType === "run_started" ||
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

  async function handleDecision(req: PermissionRequest, approved: boolean, duration: TrustDuration = "thisTime") {
    try {
      setDecidingId(req.id);
      // Duration-only quick surface: the decision carries the picked tier with
      // surface "dashboard" and no scope, so the engine resolves the request's
      // own target. Scope editing stays in the Approvals Inbox.
      await decideApproval(req.id, approved, duration, undefined, "dashboard");
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

  async function handlePlanGoal(goalId: string) {
    try {
      setPlanningGoalId(goalId);
      await advanceGoal(goalId);
      await fetchActionItems();
      onActionDecided?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to plan goal");
    } finally {
      setPlanningGoalId(null);
    }
  }

  async function handleCancelSend(send: ScheduledSend) {
    try {
      setCancellingSendId(send.id);
      await cancelScheduledSend(send.id);
      await fetchActionItems();
      onActionDecided?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to cancel scheduled send");
    } finally {
      setCancellingSendId(null);
    }
  }

  const orderedApprovals = orderBySeverityThenFiling(approvals);
  const orderedSends = orderSendsByFireTime(pendingSends);
  const totalActionsNeeded = orderedApprovals.length + blockedGoals.length;
  const hasVisibleItems = totalActionsNeeded > 0 || orderedSends.length > 0;

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

      {hasVisibleItems ? (
        <div className="needs-action-list">
          {/* Pending Tool Approvals & Questions */}
          {orderedApprovals.map((req) => {
            const isBusy = decidingId === req.id;
            const severity = requestSeverity(req);
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
                  headerLink={<OpenInboxLink req={req} />}
                />
              );
            }
            // The brake card owns its decision completely: releasing the parked
            // turns is the whole action, so it carries no duration or scope
            // control of any kind.
            if (req.toolName === BRAKE_TOOL_NAME) {
              return (
                <article
                  key={req.id}
                  className={`action-card action-card-brake severity-${severity}`}
                >
                  <div className="action-card-header">
                    <div className="action-card-title-row">
                      <span className={`badge severity-badge severity-${severity}`}>PAUSED</span>
                      <span className="tool-name-badge">{BRAKE_TOOL_NAME}</span>
                    </div>
                    <OpenInboxLink req={req} />
                  </div>

                  <div className="action-card-body">
                    <p className="action-card-desc">
                      {req.description ||
                        "The behavior brake parked the running turns after an anomaly in trusted-tool outcomes."}
                    </p>
                    <p className="action-card-once-note">
                      Releasing the parked turns is the whole decision — neither choice grants a permission.
                    </p>
                  </div>

                  <div className="action-card-buttons">
                    <button
                      type="button"
                      className="btn btn-primary approve-action-btn"
                      onClick={() => handleDecision(req, true)}
                      disabled={isBusy}
                      aria-label="Resume"
                      title="Releases the parked turns and resets the brake counters"
                    >
                      <CheckIcon size={15} />
                      <span>{isBusy ? "Resuming…" : "Resume"}</span>
                    </button>

                    <button
                      type="button"
                      className="btn reject-action-btn"
                      onClick={() => handleDecision(req, false)}
                      disabled={isBusy}
                      aria-label="Keep paused"
                      title="Leaves every parked turn exactly as it is"
                    >
                      <CloseIcon size={15} />
                      <span>{isBusy ? "Keeping paused…" : "Keep paused"}</span>
                    </button>
                  </div>
                </article>
              );
            }
            const isContinuation = req.toolName === "engine.continue";
            const isDesktopResume = req.toolName === "desktop.resume";
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
              <DashboardApprovalCard
                key={req.id}
                req={req}
                severity={severity}
                severityBadgeText={severityBadgeText}
                toolBadgeText={toolBadgeText}
                descriptionText={descriptionText}
                argSummary={argSummary}
                cardClassName={`${isContinuation ? "action-card-continuation" : ""} ${isDesktopResume ? "action-card-desktop-resume" : ""}`.trim()}
                isBusy={isBusy}
                onOpenSession={onOpenSession}
                onDecide={(target, approved, duration) => void handleDecision(target, approved, duration)}
              />
            );
          })}

          {/* Blocked Goals Needing Input or Unplanned */}
          {blockedGoals.map((goal) => {
            const isUnplanned = isGoalUnplanned(goal.status);
            const isPlanningThis = planningGoalId === goal.id;
            return (
              <article
                key={goal.id}
                className={`action-card goal-input-card ${isUnplanned ? "goal-unplanned-card" : ""}`}
              >
                <div className="action-card-header">
                  <div className="action-card-title-row">
                    <span className="badge severity-badge severity-moderate">
                      {isUnplanned ? "UNPLANNED" : "NEEDS INPUT"}
                    </span>
                    <span className="tool-name-badge">
                      {isUnplanned ? "Goal Planning" : "Goal Pursuit"}
                    </span>
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
                    {goal.statement ||
                      (isUnplanned
                        ? "This goal has no plan yet. Let the agent break it down into actionable steps."
                        : "This goal is paused waiting for operator guidance or configuration.")}
                  </p>
                </div>

                <div className="action-card-buttons">
                  {isUnplanned ? (
                    <button
                      type="button"
                      className="btn btn-primary plan-goal-btn"
                      onClick={() => handlePlanGoal(goal.id)}
                      disabled={isPlanningThis || Boolean(goal.isPlanning)}
                      aria-label={`Plan ${goal.title}`}
                    >
                      <TargetIcon size={15} />
                      <span>{isPlanningThis || goal.isPlanning ? "Planning…" : "Plan Goal"}</span>
                    </button>
                  ) : null}
                  <button
                    type="button"
                    className={`btn ${isUnplanned ? "btn-secondary" : "btn-primary"} open-goal-btn`}
                    onClick={() => onOpenGoals?.()}
                  >
                    <TargetIcon size={15} />
                    <span>Inspect Goal</span>
                  </button>
                </div>
              </article>
            );
          })}

          {/* Booked scheduled sends awaiting their fire time. Monitoring only:
              each card carries its own Cancel and nothing else — no approve or
              deny pair, no duration or scope control, no bulk action, no
              collapse, no edit. */}
          {orderedSends.length > 0 ? (
            <section className="scheduled-sends-group" aria-label="Scheduled sends">
              <div className="scheduled-sends-header">
                <h3 className="scheduled-sends-title">Scheduled sends</h3>
                <button
                  type="button"
                  className="btn-link view-all-link"
                  onClick={() => onOpenSchedules?.()}
                >
                  <span>Manage</span>
                  <ChevronRightIcon size={13} />
                </button>
              </div>
              <div className="scheduled-sends-list">
                {orderedSends.map((send) => {
                  const isCancelling = cancellingSendId === send.id;
                  const fireDate = parseRunTimestamp(send.fireAt);
                  const hasFireTime = fireDate.getTime() > 0;
                  const fireLocal = hasFireTime ? fireDate.toLocaleString() : "Unknown time";
                  const fireRelative = hasFireTime
                    ? formatRelativeIn(fireDate.getTime() - Date.now())
                    : null;
                  return (
                    <article key={send.id} className="action-card scheduled-send-card">
                      <div className="action-card-header">
                        <div className="action-card-title-row">
                          <span className={`badge channel-badge channel-${send.channel}`}>
                            {send.channel === "email" ? "EMAIL" : "MESSAGES"}
                          </span>
                          <span className="tool-name-badge">{send.recipient}</span>
                        </div>
                      </div>

                      <div className="action-card-body">
                        {send.subject ? (
                          <h4 className="goal-action-title">{send.subject}</h4>
                        ) : null}
                        <p className="action-card-desc">
                          <span className="send-fire-time">{fireLocal}</span>
                          {fireRelative ? (
                            <span className="send-fire-relative"> ({fireRelative})</span>
                          ) : null}
                        </p>
                      </div>

                      <div className="action-card-buttons">
                        <button
                          type="button"
                          className="btn reject-action-btn cancel-send-btn"
                          onClick={() => void handleCancelSend(send)}
                          disabled={isCancelling}
                          aria-label={`Cancel scheduled send to ${send.recipient}`}
                        >
                          <CloseIcon size={15} />
                          <span>{isCancelling ? "Cancelling…" : "Cancel"}</span>
                        </button>
                      </div>
                    </article>
                  );
                })}
              </div>
            </section>
          ) : null}
        </div>
      ) : (
        <div className="dashboard-empty-card all-clear-card">
          <span className="all-clear-icon">✨</span>
          <div className="all-clear-text">
            <h3 className="all-clear-title">All Caught Up</h3>
            <p className="all-clear-desc">
              No pending approvals, high-impact tool requests, or blocked goals.
            </p>
          </div>
        </div>
      )}
    </section>
  );
}
