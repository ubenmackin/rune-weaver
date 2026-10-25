// Rune Weaver Dashboard — Goals Momentum Cockpit.

import { useCallback, useEffect, useState } from "react";
import {
  advanceGoal,
  formatGoalNextAdvance,
  goalProgressPercent,
  goalStatusLabel,
  goalStatusTone,
  listGoals,
  type Goal,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import { ChevronRightIcon, PlusIcon, TargetIcon } from "../icons";

interface GoalsCockpitProps {
  onOpenGoals?: () => void;
  onOpenGoalDetail?: (goalId: string) => void;
  onGoalAdvanced?: () => void;
  refreshTrigger?: number;
}

export default function GoalsCockpit({
  onOpenGoals,
  onOpenGoalDetail,
  onGoalAdvanced,
  refreshTrigger,
}: GoalsCockpitProps) {
  const [goals, setGoals] = useState<Goal[]>([]);
  const [advancingId, setAdvancingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fetchActiveGoals = useCallback(async () => {
    try {
      setError(null);
      const res = await listGoals();
      const active = (res.goals || []).filter((g) => g.status === "active");
      setGoals(active.slice(0, 4)); // top active goals
    } catch (err) {
      console.warn("Failed to fetch active goals:", err);
    }
  }, []);

  useEffect(() => {
    fetchActiveGoals();
  }, [fetchActiveGoals, refreshTrigger]);

  // Periodic tick for live goal advancement countdowns
  const [, setCountTick] = useState(0);
  useEffect(() => {
    const timer = setInterval(() => {
      setCountTick((c) => c + 1);
    }, 10000);
    return () => clearInterval(timer);
  }, []);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (
        frameType === "goal_updated" ||
        frameType === "run_completed" ||
        frameType === "run_started"
      ) {
        fetchActiveGoals();
      }
    },
    [fetchActiveGoals],
  );

  const handleSocketOpen = useCallback(() => {
    fetchActiveGoals();
  }, [fetchActiveGoals]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  // Tab visibility resync ensures returning to the tab immediately refreshes goals
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchActiveGoals();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [fetchActiveGoals]);

  // Periodic heartbeat polling keeps goals progress synchronized
  useEffect(() => {
    const interval = setInterval(fetchActiveGoals, 10000);
    return () => clearInterval(interval);
  }, [fetchActiveGoals]);

  async function handleAdvance(goal: Goal) {
    try {
      setAdvancingId(goal.id);
      await advanceGoal(goal.id);
      onGoalAdvanced?.();
      fetchActiveGoals();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to advance goal");
    } finally {
      setAdvancingId(null);
    }
  }

  return (
    <section className="dashboard-section goals-cockpit-section" aria-label="Active goals momentum">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <TargetIcon size={18} className="dashboard-section-icon accent-blue" />
          <h2 className="dashboard-section-title">Goals Momentum</h2>
          {goals.length > 0 ? (
            <span className="dashboard-count-badge">{goals.length}</span>
          ) : null}
        </div>
        <button
          type="button"
          className="btn-link view-all-link"
          onClick={() => onOpenGoals?.()}
        >
          <span>View All</span>
          <ChevronRightIcon size={13} />
        </button>
      </div>

      {error && <div className="notice-banner error">{error}</div>}

      {goals.length === 0 ? (
        <div className="dashboard-empty-card empty-goals-card">
          <div className="empty-goals-content">
            <h3 className="empty-goals-title">No Active Goals</h3>
            <p className="empty-goals-desc">
              Autonomous goals let RuneWeaver work toward multi-step outcomes on a recurring cadence.
            </p>
            <button
              type="button"
              className="btn new-goal-btn"
              onClick={() => onOpenGoals?.()}
            >
              <PlusIcon size={14} />
              <span>Create Goal</span>
            </button>
          </div>
        </div>
      ) : (
        <div className="goals-cockpit-list">
          {goals.map((goal) => {
            const isBusy = advancingId === goal.id;
            const percent = goalProgressPercent(goal.progress);
            const statusTone = goalStatusTone(goal.status);
            const nextAdvance = formatGoalNextAdvance(goal.status, goal.nextDueAt);

            return (
              <article key={goal.id} className="goal-cockpit-card">
                <div className="goal-cockpit-header">
                  <h3
                    className="goal-cockpit-title"
                    onClick={() => onOpenGoalDetail?.(goal.id)}
                    title={goal.title}
                  >
                    {goal.title}
                  </h3>
                  <span className={`status-pill ${goal.isPlanning ? "running" : statusTone}`}>
                    {goal.isPlanning ? "Drafting Plan" : goalStatusLabel(goal.status)}
                  </span>
                </div>

                <div className="goal-progress-wrap">
                  <div className="goal-progress-labels">
                    <span className="step-counts-text">
                      Step {goal.progress.done} of {goal.progress.total}
                    </span>
                    <span className="percent-text">{percent}%</span>
                  </div>
                  <div className="progress-track" role="progressbar" aria-valuenow={percent} aria-valuemin={0} aria-valuemax={100}>
                    <div
                      className="progress-fill"
                      style={{ width: `${percent}%` }}
                    />
                  </div>
                </div>

                <div className="goal-cockpit-footer">
                  <span className="next-cadence-text text-xs muted">
                    {goal.isPlanning
                      ? "Agent is drafting plan…"
                      : nextAdvance
                      ? `Next: ${nextAdvance}`
                      : "Every interval"}
                  </span>

                  <div className="goal-cockpit-actions">
                    <button
                      type="button"
                      className="btn advance-btn"
                      onClick={() => handleAdvance(goal)}
                      disabled={isBusy || Boolean(goal.isPlanning)}
                      aria-label={
                        goal.status === "unplanned"
                          ? `Plan goal: ${goal.title}`
                          : `Advance goal now: ${goal.title}`
                      }
                    >
                      <span>
                        {isBusy
                          ? goal.status === "unplanned"
                            ? "Planning…"
                            : "Advancing…"
                          : goal.isPlanning
                          ? "Planning…"
                          : goal.status === "unplanned"
                          ? "Plan Goal"
                          : "Advance Now"}
                      </span>
                    </button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
