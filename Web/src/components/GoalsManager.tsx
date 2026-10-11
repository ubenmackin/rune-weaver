// Rune Weaver Dashboard — Long-horizon goal manager.
//
// Purpose: drives steady goal pursuit from the dashboard: listing goals with
// their progress, creating a goal and its cadence, advancing, pausing,
// abandoning, or purging, and inspecting one goal's plan checklist, audit
// events, and linked runs. The agent can also create goals from chat, so this
// surface mirrors rather than owns the pursuit lifecycle.
// Scope: rendering plus the create, tombstone, and purge calls this panel
// owns; detail reads, advance, status flips, and step moves route through the
// shared goal controller. Cadence bounds, status and event vocabularies, and
// the wire shapes live with the client API module; durable pursuit stays with
// the engine, so this component never invents state the server cannot
// round-trip.
// Architectural role: one of the dashboard panels multiplexed over the shared
// WebSocket, refreshing its list on `goal_updated` pushes. The needs-input
// attention count is owned by the shell's notification hook and passed in, so
// the panel never counts the same proactive frames a second time. Model-
// authored event and step notes render exclusively through the sanitized
// MarkdownText path — this file holds no raw HTML injection.

import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  acceptIdea,
  ApiError,
  createGoal,
  deleteGoal,
  dismissIdea,
  formatGoalNextAdvance,
  getSettings,
  goalCadenceLabel,
  goalEventKindLabel,
  goalProgressPercent,
  goalStatusLabel,
  goalStatusTone,
  ideaKindLabel,
  isActiveRunStatus,
  isIdeaProposedProactive,
  listGoals,
  listIdeas,
  parseGoalUpdatedFrame,
  parseIdea,
  parseRunTimestamp,
  GOAL_CADENCE_OPTIONS,
  DEFAULT_GOALS_STEP_INTERVAL_MINUTES,
  type Goal,
  type GoalStep,
  type Idea,
} from "../api";
import {
  useSharedWebSocket,
  type WSIncomingFrame,
} from "../hooks/useSharedWebSocket";
import {
  goalStepNextStatus,
  useGoalDetail,
} from "../hooks/useGoalDetail";
import MarkdownText from "./MarkdownText";
import Modal from "./Modal";
import {
  CloseIcon,
  PlusIcon,
  RefreshIcon,
  TargetIcon,
  TrashIcon,
} from "./icons";

// Default filter: hide abandoned goals so a long pursuit history never crowds
// the active work, while an explicit "All" lets the owner audit dropped goals.
type GoalFilter = "current" | "all";

// Bounded linked-runs window for an expanded goal row; the full history stays
// on the Runs surface.
const EXPANDED_RUN_LIMIT = 20;

// First-run examples shown when the owner has no goals yet. Each card prefills
// the create form so a new pursuit starts from a concrete shape instead of a
// blank statement; cadences reuse the same option values the form offers.
const GOAL_EXAMPLES: Array<{ title: string; statement: string; cadence: number }> = [
  {
    title: "Publish the field guide",
    statement: "The guide is written, reviewed, and shared with the team.",
    cadence: 10080,
  },
  {
    title: "Dig into 5 papers on a topic",
    statement:
      "Five papers read, each summarized in a running annotated bibliography.",
    cadence: 1440,
  },
  {
    title: "Get ready for the conference talk",
    statement: "A finished outline, slides, and a rehearsed Q&A.",
    cadence: 720,
  },
];

// Normalizes an idea list payload, dropping rows a drifted or older engine
// cannot validate so a malformed entry never reaches the render path.
function parseIdeaList(raw: unknown): Idea[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .map(parseIdea)
    .filter((idea): idea is Idea => idea !== null);
}

interface GoalsManagerProps {
  // Needs-input count owned by the shell's notification hook. The panel only
  // renders it, so the Work trigger badge and this header share one source.
  attentionCount?: number;
  // The shell owns tab navigation; the panel only asks to open Settings.
  onOpenSettings?: () => void;
}

export default function GoalsManager({
  attentionCount = 0,
  onOpenSettings,
}: GoalsManagerProps) {
  const [goals, setGoals] = useState<Goal[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [filter, setFilter] = useState<GoalFilter>("current");

  // Creation stays available unless settings explicitly turn goals off. Older
  // engines without the section and transient read failures keep the enabled
  // UI; the engine still fails closed on submit.
  const [goalsEnabled, setGoalsEnabled] = useState(true);

  // Proactive suggestions shown above the goal list. Dismissed ideas hide
  // under the default filter exactly as abandoned goals do, so an audit of
  // past "no"s only appears on the All view.
  const [ideas, setIdeas] = useState<Idea[]>([]);
  const [ideasLoading, setIdeasLoading] = useState(false);
  const [actingIdeaId, setActingIdeaId] = useState<string | null>(null);

  // Creation form state; the modal stays open on failure so the owner's input
  // survives a rejected submit instead of being silently discarded.
  const [createOpen, setCreateOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [statement, setStatement] = useState("");
  const [cadence, setCadence] = useState<number>(
    DEFAULT_GOALS_STEP_INTERVAL_MINUTES,
  );
  const [creating, setCreating] = useState(false);

  // Tombstone and purge are the destructive actions this panel still owns;
  // advance, status, and step locks live with the shared goal controller.
  const [abandoningGoalId, setAbandoningGoalId] = useState<string | null>(null);
  const [purgingGoalId, setPurgingGoalId] = useState<string | null>(null);

  // Purge is destructive and irreversible, so it is the one action routed
  // through the shared confirmation Modal; the tombstone Abandon path stays
  // immediate because it preserves history.
  const [purgeTarget, setPurgeTarget] = useState<Goal | null>(null);

  // Only one row expands at a time, so the shared controller owns that goal's
  // plan, audit events, and linked runs together and clears them on collapse.
  const [expandedGoalId, setExpandedGoalId] = useState<string | null>(null);
  const {
    detail: expandedDetail,
    runs: expandedRuns,
    loadingDetailId,
    advancingGoalId,
    togglingGoalId,
    togglingStepId,
    advance,
    toggleStatus,
    setStepStatus,
  } = useGoalDetail(expandedGoalId, {
    runLimit: EXPANDED_RUN_LIMIT,
    onError: setError,
    onNotice: setNotice,
  });

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listGoals();
      setGoals(response.goals);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Goals failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    listGoals()
      .then((response) => {
        if (!cancelled) setGoals(response.goals);
      })
      .catch((failure) => {
        if (!cancelled) {
          setError(failure instanceof ApiError ? failure.message : "Goals failed");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const refreshIdeas = useCallback(async () => {
    setIdeasLoading(true);
    try {
      const response = await listIdeas();
      setIdeas(parseIdeaList(response.ideas));
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Ideas failed");
    } finally {
      setIdeasLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    setIdeasLoading(true);
    listIdeas()
      .then((response) => {
        if (!cancelled) setIdeas(parseIdeaList(response.ideas));
      })
      .catch((failure) => {
        if (!cancelled) {
          setError(failure instanceof ApiError ? failure.message : "Ideas failed");
        }
      })
      .finally(() => {
        if (!cancelled) setIdeasLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    // Only an explicit false disables creation, so older engines and transient
    // failures keep the enabled UI; the engine still fails closed on submit.
    getSettings()
      .then((settings) => {
        if (!cancelled && settings.goals?.enabled === false) {
          setGoalsEnabled(false);
        }
      })
      .catch(() => {
        // Keep creation available when settings cannot be read.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const handleSocketFrame = useCallback(
    (frame: WSIncomingFrame) => {
      // The shared hub passes unknown frame types through as generic records, so
      // this handler reads the discriminator from a widened view instead of
      // narrowing the closed union the client mirrors for chat frames.
      const raw = frame as unknown as Record<string, unknown>;
      if (raw.type === "goal_updated") {
        // The push is the refresh: the engine only emits it for a real change,
        // so a valid snapshot re-reads the list to pick up derived tallies. The
        // shell-owned attention count comes from its own hook, not this handler.
        if (parseGoalUpdatedFrame(raw)) {
          void refresh();
        }
        return;
      }
      // A freshly proposed idea rides the shared proactive frame. Re-read the
      // ideas list so a newly announced suggestion appears in the panel without
      // a manual refresh or remount; the shell's notification hook still owns
      // the attention badge, so this handler never counts the frame itself.
      if (isIdeaProposedProactive(raw)) {
        void refreshIdeas();
      }
    },
    [refresh, refreshIdeas],
  );
  useSharedWebSocket(handleSocketFrame);

  const visibleGoals =
    filter === "all"
      ? goals
      : goals.filter((goal) => goal.status !== "abandoned");

  const visibleIdeas =
    filter === "all"
      ? ideas
      : ideas.filter((idea) => idea.status !== "dismissed");

  // Accepting applies the suggestion server-side (a re-plan or a new goal) and
  // then flips its status, so the goal list refreshes alongside the idea card.
  async function handleAcceptIdea(idea: Idea) {
    setActingIdeaId(idea.id);
    setError(null);
    try {
      const updated = await acceptIdea(idea.id);
      setIdeas((prev) =>
        prev.map((row) => (row.id === updated.id ? updated : row)),
      );
      void refresh();
      setNotice(`Accepted "${idea.title}".`);
    } catch (failure) {
      // The engine answers the same honest 400/409 it would for the equivalent
      // goal action, so surface that message verbatim instead of a generic one.
      setError(failure instanceof ApiError ? failure.message : "Accept failed");
    } finally {
      setActingIdeaId(null);
    }
  }

  async function handleDismissIdea(idea: Idea) {
    setActingIdeaId(idea.id);
    setError(null);
    try {
      const updated = await dismissIdea(idea.id);
      setIdeas((prev) =>
        prev.map((row) => (row.id === updated.id ? updated : row)),
      );
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Dismiss failed");
    } finally {
      setActingIdeaId(null);
    }
  }

  function resetForm() {
    setTitle("");
    setStatement("");
    setCadence(DEFAULT_GOALS_STEP_INTERVAL_MINUTES);
  }

  // Prefills the create form from an example card without submitting. It sets
  // each field directly instead of resetting first so the example survives.
  function openCreateWithExample(example: {
    title: string;
    statement: string;
    cadence: number;
  }) {
    setTitle(example.title);
    setStatement(example.statement);
    setCadence(example.cadence);
    setCreateOpen(true);
  }

  function closeCreate() {
    if (creating) return;
    setCreateOpen(false);
    resetForm();
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmedTitle = title.trim();
    // The submit control stays disabled while the title or statement is blank,
    // so this guard is the invariant rather than the user-facing validation.
    if (!trimmedTitle) return;
    const trimmedStatement = statement.trim();
    if (!trimmedStatement) {
      setError("Describe what done looks like before creating a goal.");
      return;
    }
    setCreating(true);
    setError(null);
    try {
      const detail = await createGoal({
        title: trimmedTitle,
        statement: trimmedStatement,
        stepIntervalMinutes: cadence,
      });
      setGoals((prev) => [
        detail.goal,
        ...prev.filter((goal) => goal.id !== detail.goal.id),
      ]);
      setCreateOpen(false);
      resetForm();
      setNotice(
        `Created "${detail.goal.title}". The agent is drafting its plan.`,
      );
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Goal creation failed");
    } finally {
      setCreating(false);
    }
  }

  // Advance, status flip, and step move all route through the shared goal
  // controller, which owns the 409 contention copy and the post-mutation
  // re-read so the panel and the chat drawer cannot drift.
  async function handleToggleStatus(goal: Goal) {
    const updated = await toggleStatus(goal);
    if (updated) {
      setGoals((prev) =>
        prev.map((row) => (row.id === goal.id ? updated.goal : row)),
      );
    }
  }

  async function handleAbandon(goal: Goal) {
    setAbandoningGoalId(goal.id);
    setError(null);
    try {
      // A tombstone keeps the row joinable for run history, so the local status
      // flips instead of the row disappearing; the default filter then hides it.
      await deleteGoal(goal.id);
      setGoals((prev) =>
        prev.map((row) =>
          row.id === goal.id ? { ...row, status: "abandoned" } : row,
        ),
      );
      if (expandedGoalId === goal.id) {
        setExpandedGoalId(null);
      }
      setNotice(`Abandoned "${goal.title}". Run history is preserved.`);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Abandon failed");
    } finally {
      setAbandoningGoalId(null);
    }
  }

  async function confirmPurge() {
    if (!purgeTarget) return;
    const goal = purgeTarget;
    setPurgingGoalId(goal.id);
    setError(null);
    try {
      await deleteGoal(goal.id, true);
      setGoals((prev) => prev.filter((row) => row.id !== goal.id));
      if (expandedGoalId === goal.id) {
        setExpandedGoalId(null);
      }
      setPurgeTarget(null);
      setNotice(`Purged "${goal.title}" and its plan.`);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Purge failed");
    } finally {
      setPurgingGoalId(null);
    }
  }

  // Expansion drives the shared controller: setting the id triggers the detail
  // read, and collapsing clears it so no stale row state lingers.
  function toggleDetail(goalId: string) {
    setExpandedGoalId((current) => (current === goalId ? null : goalId));
  }

  async function handleToggleStep(step: GoalStep) {
    const moved = await setStepStatus(step, goalStepNextStatus(step));
    // Progress tallies live on the list row, so the card refreshes too.
    if (moved) void refresh();
  }

  return (
    <section className="panel" aria-label="Goals manager">
      <div className="panel-header-row">
        <div>
          <h2>Goals</h2>
          <p className="muted text-sm">
            Long-horizon pursuits the agent works on a little at a time, step by step.
          </p>
        </div>

        <div className="row">
          {attentionCount > 0 ? (
            <span
              className="pending-approval-badge"
              data-testid="goals-attention-badge"
              role="status"
            >
              {attentionCount === 1
                ? "1 goal needs input"
                : `${attentionCount} goals need input`}
            </span>
          ) : null}
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => {
              void refresh();
              void refreshIdeas();
            }}
            disabled={loading}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
          <span className="muted text-sm">{visibleGoals.length} goals</span>

          <button
            type="button"
            className="primary icon-text-btn"
            onClick={() => {
              resetForm();
              setCreateOpen(true);
            }}
            disabled={!goalsEnabled}
            title={!goalsEnabled ? "Goals are turned off" : undefined}
          >
            <PlusIcon size={14} />
            <span>New Goal</span>
          </button>
          {/* Disabled buttons suppress hover and focus tooltip delivery in
              several browsers, so the disable reason is visible header text
              too; the title stays only as a hover supplement where tooltips
              do reach the user. */}
          {!goalsEnabled ? (
            <span className="muted text-sm">
              Goals are turned off in Settings
            </span>
          ) : null}
        </div>
      </div>

      {error ? <p className="error">{error}</p> : null}
      {notice ? <div className="notice-banner">{notice}</div> : null}

      <div className="filter-chip-row" style={{ marginTop: 12 }}>
        <button
          type="button"
          className={`filter-chip ${filter === "current" ? "active" : ""}`}
          onClick={() => setFilter("current")}
          aria-pressed={filter === "current"}
        >
          Current
        </button>
        <button
          type="button"
          className={`filter-chip ${filter === "all" ? "active" : ""}`}
          onClick={() => setFilter("all")}
          aria-pressed={filter === "all"}
        >
          All
        </button>
      </div>

      {/* Ideas panel: proactive suggestions above the goal list. Each card
          carries a kind pill plus the title and body; the body renders through
          the sanitized MarkdownText path only, never raw HTML. */}
      <div className="ideas-panel" data-testid="ideas-panel" style={{ marginTop: 12 }}>
        <div className="panel-header-row">
          <h3 style={{ margin: 0 }}>Ideas</h3>
          <span className="muted text-sm">
            {ideasLoading && ideas.length === 0
              ? "Loading…"
              : `${visibleIdeas.length} ideas`}
          </span>
        </div>
        {visibleIdeas.length === 0 && !ideasLoading ? (
          <p className="muted text-xs" style={{ marginTop: 6 }}>
            No suggestions right now. The agent proposes ideas as goals and
            activity accumulate.
          </p>
        ) : null}
        <div className="job-cards-list">
          {visibleIdeas.map((idea) => (
            <div
              key={idea.id}
              className="schedule-card active"
              data-testid={`idea-card-${idea.id}`}
            >
              <div className="schedule-card-top">
                <div className="schedule-card-identity">
                  <div className="schedule-card-title-row">
                    <strong className="schedule-card-name">{idea.title}</strong>
                    <span className="status-pill small">
                      {ideaKindLabel(idea.kind).toUpperCase()}
                    </span>
                  </div>
                </div>
                <div className="schedule-card-actions">
                  <button
                    type="button"
                    className="ghost"
                    onClick={() => void handleDismissIdea(idea)}
                    disabled={
                      actingIdeaId === idea.id || idea.status !== "proposed"
                    }
                    aria-label={`Dismiss ${idea.title}`}
                  >
                    Dismiss
                  </button>
                  <button
                    type="button"
                    className="primary"
                    onClick={() => void handleAcceptIdea(idea)}
                    disabled={
                      actingIdeaId === idea.id || idea.status !== "proposed"
                    }
                    aria-label={`Accept ${idea.title}`}
                  >
                    {actingIdeaId === idea.id ? "Applying…" : "Accept"}
                  </button>
                </div>
              </div>
              {idea.body ? (
                <MarkdownText
                  text={idea.body}
                  className="markdown-content text-xs"
                />
              ) : null}
            </div>
          ))}
        </div>
      </div>

      {goals.length === 0 && !loading ? (
        !goalsEnabled ? (
          <div className="empty-state-box">
            <TargetIcon size={22} />
            <h3>Goals are turned off</h3>
            <p className="muted">
              Goals are turned off in Settings. Turn on Enable goal pursuit
              under Goals & Proactivity to have the agent plan and work on
              longer projects.
            </p>
            {onOpenSettings ? (
              <button
                type="button"
                className="primary mt-3"
                onClick={onOpenSettings}
              >
                Open Settings
              </button>
            ) : null}
          </div>
        ) : (
          <div className="empty-state-box">
            <TargetIcon size={22} />
            <h3>No goals yet</h3>
            <p className="muted">
              A goal is something you want to get done that takes more than one
              sitting. Tell the agent what you&apos;re aiming for, and it will
              make a plan and work on it a step at a time — checking in with
              you along the way.
            </p>
            <div className="goal-explainer-steps">
              <span>You describe what done looks like</span>
              <span aria-hidden="true">→</span>
              <span>The agent writes a step-by-step plan</span>
              <span aria-hidden="true">→</span>
              <span>It works on one step each session, and asks when it&apos;s stuck</span>
            </div>
            <h4>Not sure where to start? Try one of these:</h4>
            <div className="preset-grid goal-example-grid">
              {GOAL_EXAMPLES.map((example) => (
                <button
                  key={example.title}
                  type="button"
                  className="preset-card goal-example-card"
                  onClick={() => openCreateWithExample(example)}
                >
                  <span className="preset-card-title">{example.title}</span>
                  <span className="preset-card-desc">{example.statement}</span>
                  <span className="goal-example-cadence">
                    {goalCadenceLabel(example.cadence)}
                  </span>
                </button>
              ))}
            </div>
            <button
              type="button"
              className="primary mt-3"
              onClick={() => {
                resetForm();
                setCreateOpen(true);
              }}
            >
              Create Your First Goal
            </button>
            <p className="muted text-xs" style={{ margin: 0 }}>
              Need the same task repeated on a schedule instead? Use Schedules.
            </p>
          </div>
        )
      ) : null}

      {goals.length > 0 && visibleGoals.length === 0 && !loading ? (
        <div className="empty-state-box">
          <h3>No current goals</h3>
          <p className="muted">
            Every goal is abandoned. Switch to All to review the ones you dropped.
          </p>
        </div>
      ) : null}

      <div className="job-cards-list">
        {visibleGoals.map((goal) => {
          const isExpanded = expandedGoalId === goal.id;
          const detail = isExpanded ? expandedDetail : undefined;
          const runsForGoal = isExpanded ? expandedRuns : [];
          const percent = goalProgressPercent(goal.progress);
          const isTerminal = goal.status === "abandoned";

          return (
            <div
              key={goal.id}
              className={`schedule-card ${isTerminal ? "disabled" : "active"}`}
            >
              <div className="schedule-card-top">
                <div className="schedule-card-identity">
                  <div className="schedule-card-title-row">
                    <strong className="schedule-card-name">{goal.title}</strong>
                    <span
                      className={`status-pill ${
                        goal.isPlanning
                          ? "running"
                          : goalStatusTone(goal.status)
                      }`}
                    >
                      {goal.isPlanning
                        ? "DRAFTING PLAN"
                        : goalStatusLabel(goal.status).toUpperCase()}
                    </span>
                  </div>
                  <div className="schedule-card-details muted text-xs">
                    {goal.isPlanning ? (
                      <span>Agent is drafting plan…</span>
                    ) : (
                      <>
                        <span>
                          next work session {formatGoalNextAdvance(goal.status, goal.nextDueAt)}
                        </span>
                        <span> · {goalCadenceLabel(goal.stepIntervalMinutes)}</span>
                        <span>
                          {" "}
                          · {goal.progress.done}/{goal.progress.total} steps
                        </span>
                      </>
                    )}
                  </div>
                </div>

                <div className="schedule-card-actions">
                  <button
                    type="button"
                    className={`${goal.status === "unplanned" ? "primary" : "ghost"} run-now-btn`}
                    onClick={() => void advance(goal)}
                    disabled={
                      advancingGoalId === goal.id ||
                      isTerminal ||
                      Boolean(goal.isPlanning)
                    }
                    title={
                      goal.isPlanning
                        ? "Planning in progress"
                        : goal.status === "unplanned"
                        ? "Plan goal with agent"
                        : "Work on it now"
                    }
                    aria-label={
                      goal.isPlanning
                        ? "Planning"
                        : goal.status === "unplanned"
                        ? "Plan Goal"
                        : "Work on it now"
                    }
                  >
                    {advancingGoalId === goal.id || goal.isPlanning
                      ? "Planning…"
                      : goal.status === "unplanned"
                      ? "Plan Goal"
                      : "Work on it now"}
                  </button>

                  <button
                    type="button"
                    className={`status-toggle-btn ${
                      goal.status === "active" ? "enabled" : "disabled"
                    }`}
                    onClick={() => void handleToggleStatus(goal)}
                    disabled={
                      togglingGoalId === goal.id ||
                      isTerminal ||
                      goal.status === "unplanned" ||
                      Boolean(goal.isPlanning)
                    }
                    aria-label={goal.status === "active" ? "Pause" : "Resume"}
                  >
                    {togglingGoalId === goal.id
                      ? "Updating…"
                      : goal.status === "active"
                        ? "Pause"
                        : "Resume"}
                  </button>

                  <button
                    type="button"
                    className="ghost"
                    onClick={() => void handleAbandon(goal)}
                    disabled={abandoningGoalId === goal.id || isTerminal}
                    aria-label="Abandon"
                  >
                    {abandoningGoalId === goal.id ? "Abandoning…" : "Abandon"}
                  </button>

                  <button
                    type="button"
                    className="icon-button danger"
                    onClick={() => setPurgeTarget(goal)}
                    disabled={isTerminal}
                    title="Purge goal and plan"
                    aria-label="Purge"
                  >
                    <TrashIcon size={15} />
                  </button>
                </div>
              </div>

              {/* Progress bar: the plan-wide completion at a glance. An empty
                  plan renders an empty track rather than a misleading full bar. */}
              <div style={{ marginTop: 10 }}>
                <div
                  role="progressbar"
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={percent}
                  aria-label={`${goal.title} progress`}
                  style={{
                    height: 6,
                    borderRadius: 999,
                    background: "rgba(255, 255, 255, 0.08)",
                    overflow: "hidden",
                  }}
                >
                  <div
                    style={{
                      height: "100%",
                      width: `${percent}%`,
                      borderRadius: 999,
                      background: "var(--accent-purple, #8b5cf6)",
                    }}
                  />
                </div>
              </div>

              <div className="schedule-card-prompt">
                <span className="prompt-label">Done looks like:</span>
                <span className="prompt-text">{goal.statement}</span>
              </div>

              <div className="schedule-card-footer">
                <button
                  type="button"
                  className="view-history-btn"
                  onClick={() => toggleDetail(goal.id)}
                >
                  {isExpanded ? "Hide Plan & Activity" : "Show Plan & Activity"}
                </button>
              </div>

              {isExpanded ? (
                <div className="embedded-history-drawer">
                  <h4>Plan &amp; Activity for &quot;{goal.title}&quot;</h4>

                  {loadingDetailId === goal.id && !detail ? (
                    <p className="muted text-xs">Loading plan…</p>
                  ) : null}

                  {detail ? (
                    <>
                      <ol
                        className="goal-plan-list"
                        style={{
                          listStyle: "none",
                          margin: 0,
                          padding: 0,
                          display: "flex",
                          flexDirection: "column",
                          gap: 6,
                        }}
                      >
                        {goal.isPlanning ? (
                          <li
                            className="muted text-xs"
                            style={{
                              padding: "10px 12px",
                              borderRadius: "6px",
                              background: "rgba(59, 130, 246, 0.1)",
                              border: "1px solid rgba(59, 130, 246, 0.2)",
                              color: "var(--accent-blue, #60a5fa)",
                            }}
                          >
                            Drafting plan… The agent is breaking down this goal into actionable steps.
                          </li>
                        ) : detail.steps.length === 0 ? (
                          <li
                            className="muted text-xs"
                            style={{
                              padding: "10px 12px",
                              borderRadius: "6px",
                              background: "rgba(255, 255, 255, 0.04)",
                              border: "1px dashed rgba(255, 255, 255, 0.15)",
                            }}
                          >
                            No plan drafted yet. Click &quot;Plan Goal&quot; above to have the agent generate actionable steps.
                          </li>
                        ) : (
                          detail.steps.map((step) => (
                            <li
                              key={step.id}
                              style={{
                                display: "flex",
                                alignItems: "flex-start",
                                gap: 8,
                              }}
                            >
                              <input
                                type="checkbox"
                                checked={step.status === "done"}
                                disabled={
                                  togglingStepId === step.id || isTerminal
                                }
                                onChange={() =>
                                  void handleToggleStep(step)
                                }
                                aria-label={`Toggle ${step.title}`}
                              />
                              <div>
                                <span
                                  className="text-xs"
                                  style={{
                                    textDecoration:
                                      step.status === "done"
                                        ? "line-through"
                                        : "none",
                                  }}
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
                            </li>
                          ))
                        )}
                      </ol>

                      <h4 style={{ marginTop: 12 }}>Recent activity</h4>
                      {detail.events.length === 0 ? (
                        <p className="muted text-xs">No activity recorded yet.</p>
                      ) : (
                        <div className="embedded-runs-list">
                          {detail.events.map((event) => (
                            <div
                              className="embedded-run-item"
                              key={event.id}
                              style={{ display: "block" }}
                            >
                              <div className="muted text-xs">
                                {goalEventKindLabel(event.kind)} ·{" "}
                                {parseRunTimestamp(
                                  event.createdAt,
                                ).toLocaleString()}
                              </div>
                              <MarkdownText
                                text={event.message}
                                className="markdown-content"
                              />
                            </div>
                          ))}
                        </div>
                      )}

                      <h4 style={{ marginTop: 12 }}>Linked runs</h4>
                      {runsForGoal.length === 0 ? (
                        <p className="muted text-xs">
                          No runs recorded for this goal yet. Use Work on it now to
                          start one.
                        </p>
                      ) : (
                        <div className="embedded-runs-list">
                          {runsForGoal.map((run) => (
                            <div className="embedded-run-item" key={run.id}>
                              <div className="embedded-run-meta">
                                <span
                                  className={`status-pill small ${run.status}`}
                                >
                                  {isActiveRunStatus(run.status)
                                    ? "IN PROGRESS"
                                    : run.status.toUpperCase()}
                                </span>
                                <span className="text-xs muted">
                                  {parseRunTimestamp(
                                    run.timestamp,
                                  ).toLocaleString()}
                                </span>
                              </div>
                              <div className="embedded-run-response">
                                {run.response || run.message}
                              </div>
                            </div>
                          ))}
                        </div>
                      )}
                    </>
                  ) : null}
                </div>
              ) : null}
            </div>
          );
        })}
      </div>

      {createOpen ? (
        <Modal
          label="Create goal"
          onClose={closeCreate}
          containerClassName="modal-container"
        >
          <form onSubmit={(event) => void handleCreate(event)}>
            <div className="modal-header">
              <h3>New Goal</h3>
              <button
                type="button"
                className="icon-button"
                onClick={closeCreate}
                disabled={creating}
                aria-label="Close"
              >
                <CloseIcon size={16} />
              </button>
            </div>
            <div className="modal-body">
              <p className="muted text-sm" style={{ marginTop: 0 }}>
                Tell the agent what you want to get done. It will make a plan
                and work on it a step at a time.
              </p>
              <div className="form-group">
                <label htmlFor="goal-title">What do you want to get done?</label>
                <input
                  id="goal-title"
                  type="text"
                  value={title}
                  onChange={(event) => setTitle(event.target.value)}
                  placeholder="e.g. Publish the field guide"
                  autoComplete="off"
                  aria-required="true"
                />
              </div>
              <div className="form-group mt-4">
                <label htmlFor="goal-statement">What does done look like?</label>
                <textarea
                  id="goal-statement"
                  value={statement}
                  onChange={(event) => setStatement(event.target.value)}
                  placeholder="e.g. The guide is written, reviewed, and shared with the team."
                  rows={4}
                  aria-required="true"
                />
                <span className="form-group-hint">
                  Describe what will be true when this is finished — and why it
                  matters to you. Required.
                </span>
              </div>
              <div className="form-group mt-4">
                <label htmlFor="goal-cadence">How often should I work on it?</label>
                <select
                  id="goal-cadence"
                  value={cadence}
                  onChange={(event) => setCadence(Number(event.target.value))}
                >
                  {GOAL_CADENCE_OPTIONS.map((option) => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div className="modal-footer">
              <button
                type="button"
                className="ghost"
                onClick={closeCreate}
                disabled={creating}
              >
                Cancel
              </button>
              <button
                type="submit"
                className="primary"
                disabled={
                  creating ||
                  title.trim().length === 0 ||
                  statement.trim().length === 0
                }
                aria-label="Create goal"
              >
                {creating ? "Creating…" : "Create Goal"}
              </button>
            </div>
          </form>
        </Modal>
      ) : null}

      {/* Purge confirmation routes through the shared Modal so the destructive
          path gets the same Escape support and stacking-context escape as the
          scheduler delete dialog. */}
      {purgeTarget ? (
        <Modal
          label="Confirm purge goal"
          onClose={() => {
            if (purgingGoalId === purgeTarget.id) return;
            setPurgeTarget(null);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Purge goal?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setPurgeTarget(null)}
              disabled={purgingGoalId === purgeTarget.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              Permanently delete &quot;{purgeTarget.title}&quot; and its plan.
              This cannot be undone. Abandon instead to keep the history.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setPurgeTarget(null)}
              disabled={purgingGoalId === purgeTarget.id}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmPurge()}
              disabled={purgingGoalId === purgeTarget.id}
              aria-label="Confirm purge"
            >
              {purgingGoalId === purgeTarget.id ? "Purging…" : "Purge"}
            </button>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}
