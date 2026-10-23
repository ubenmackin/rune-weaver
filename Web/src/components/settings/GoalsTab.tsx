// Rune Weaver Dashboard — Goals & Proactive Suggestions tab pane.

import { useState } from "react";
import type { GoalsConfigData } from "../../api";
import {
  DEFAULT_GOALS_MAX_ACTIVE_GOALS,
  DEFAULT_GOALS_MAX_STEPS_PER_GOAL,
  DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL,
  DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS,
  DEFAULT_GOALS_STEP_INTERVAL_MINUTES,
  DEFAULT_IDEAS_MAX_PER_CYCLE,
  DEFAULT_IDEAS_TIMEOUT_SECONDS,
  GOAL_CADENCE_OPTIONS,
  GOALS_MAX_ACTIVE_MAX,
  GOALS_MAX_ACTIVE_MIN,
  GOALS_STEP_INTERVAL_MAX_MINUTES,
  GOALS_STEP_INTERVAL_MIN_MINUTES,
  goalsMaxToolIterations,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
} from "../../api";
import { AdvancedDisclosure } from "./AdvancedDisclosure";

// Advanced Goals validation messages the disclosure can focus. Shared by the
// panel prop and the shell error router so one message never prints twice.
export const GOALS_ADVANCED_ERROR_KEYWORDS = [
  "goals cap",
  "max active",
  "plan length",
  "max steps",
  "planning timeout",
  "plan timeout",
  "triggers budget",
  "max triggers",
] as const;

export function isGoalsAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return GOALS_ADVANCED_ERROR_KEYWORDS.some((keyword) =>
    lowered.includes(keyword)
  );
}

export interface GoalsTabProps {
  goalsEnabled: boolean;
  setGoalsEnabled: (val: boolean) => void;
  ideasEnabled: boolean;
  setIdeasEnabled: (val: boolean) => void;
  goalsStepIntervalMinutes: number | string;
  setGoalsStepIntervalMinutes: (val: number | string) => void;
  goalsMaxActiveGoals: number | string;
  setGoalsMaxActiveGoals: (val: number | string) => void;
  goalsMaxStepsPerGoal: number | string;
  setGoalsMaxStepsPerGoal: (val: number | string) => void;
  goalsPlanTimeoutSeconds: number | string;
  setGoalsPlanTimeoutSeconds: (val: number | string) => void;
  goalsMaxTriggersPerGoal: number | string;
  setGoalsMaxTriggersPerGoal: (val: number | string) => void;
  ideasMaxPerCycle: number | string;
  setIdeasMaxPerCycle: (val: number | string) => void;
  ideasTimeoutSeconds: number | string;
  setIdeasTimeoutSeconds: (val: number | string) => void;
  goalsConfig?: GoalsConfigData;
  validationError?: string | null;
}

export function GoalsTab({
  goalsEnabled,
  setGoalsEnabled,
  ideasEnabled,
  setIdeasEnabled,
  goalsStepIntervalMinutes,
  setGoalsStepIntervalMinutes,
  goalsMaxActiveGoals,
  setGoalsMaxActiveGoals,
  goalsMaxStepsPerGoal,
  setGoalsMaxStepsPerGoal,
  goalsPlanTimeoutSeconds,
  setGoalsPlanTimeoutSeconds,
  goalsMaxTriggersPerGoal,
  setGoalsMaxTriggersPerGoal,
  ideasMaxPerCycle,
  setIdeasMaxPerCycle,
  ideasTimeoutSeconds,
  setIdeasTimeoutSeconds,
  goalsConfig,
  validationError = null,
}: GoalsTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);

  // Reset restores stock goals caps and budgets.
  const resetGoalsAdvanced = () => {
    setGoalsMaxActiveGoals(DEFAULT_GOALS_MAX_ACTIVE_GOALS);
    setGoalsMaxStepsPerGoal(DEFAULT_GOALS_MAX_STEPS_PER_GOAL);
    setGoalsPlanTimeoutSeconds(DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS);
    setGoalsMaxTriggersPerGoal(DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL);
  };

  return (
    <div className="settings-section card" data-testid="goals-pane">
      <div className="settings-section-title-group">
        <h3>Goals</h3>
      <p className="settings-section-hint">
        Steady long-horizon pursuit and proactive suggestions. Applies live with no restart.
      </p>
      </div>
      <div className="form-group checkbox-group">
        <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
          <input
            id="goals-enabled"
            type="checkbox"
            checked={goalsEnabled}
            onChange={(e) => setGoalsEnabled(e.target.checked)}
          />
          <span>Enable goal pursuit</span>
        </label>
        <span className="form-group-hint">
          Off by default so a fresh install never spends planning calls until you opt in. Goals advance on cadence via the service worker and the CLI foreground loop.
        </span>
      </div>
      <div className="form-group checkbox-group">
        <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
          <input
            id="ideas-enabled"
            type="checkbox"
            checked={ideasEnabled}
            onChange={(e) => setIdeasEnabled(e.target.checked)}
          />
          <span>Enable proactive ideas</span>
        </label>
        <span className="form-group-hint">
          Off by default. When enabled, the agent proposes next moves it thinks you would value; each suggestion waits for Accept or Dismiss before anything changes.
        </span>
      </div>
      <div className="form-row" style={{ marginTop: "1rem" }}>
        <div className="form-group flex-1">
          <label htmlFor="goals-step-interval">Default Cadence (minutes)</label>
          <input
            id="goals-step-interval"
            type="number"
            className="input-field"
            min={GOALS_STEP_INTERVAL_MIN_MINUTES}
            max={GOALS_STEP_INTERVAL_MAX_MINUTES}
            step={1}
            value={goalsStepIntervalMinutes}
            onChange={(e) => setGoalsStepIntervalMinutes(e.target.value)}
          />
          <div
            role="group"
            aria-label="Cadence presets"
            style={{ display: "flex", flexWrap: "wrap", gap: "8px", marginTop: "8px" }}
          >
            {GOAL_CADENCE_OPTIONS.map((option) => (
              <button
                key={option.value}
                type="button"
                className={`tools-category-pill${Number(goalsStepIntervalMinutes) === option.value ? " active" : ""}`}
                aria-pressed={Number(goalsStepIntervalMinutes) === option.value}
                onClick={() => setGoalsStepIntervalMinutes(option.value)}
              >
                {option.label}
              </button>
            ))}
          </div>
          <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
            Cadence hint stored on each new goal. Range: {GOALS_STEP_INTERVAL_MIN_MINUTES}–{GOALS_STEP_INTERVAL_MAX_MINUTES}. Default is {DEFAULT_GOALS_STEP_INTERVAL_MINUTES} (daily).
          </p>
        </div>
      </div>
      <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
        Goal runs use {goalsMaxToolIterations(goalsConfig)} consecutive tool rounds per turn (range {TOOL_ROUNDS_MIN}–{TOOL_ROUNDS_MAX}, set via [goals] max_tool_iterations in config.toml). When a goal run reaches its budget it synthesizes a summary and records budget_exceeded instead of parking for approval.
      </p>
      <div className="form-row" style={{ marginTop: "1rem" }}>
        <div className="form-group flex-1">
          <label htmlFor="ideas-max-per-cycle">Max Ideas Per Cycle</label>
          <input
            id="ideas-max-per-cycle"
            type="number"
            className="input-field"
            min={1}
            max={10}
            step={1}
            value={ideasMaxPerCycle}
            onChange={(e) => setIdeasMaxPerCycle(e.target.value)}
          />
          <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
            Maximum proactive suggestions generated per cycle. Range: 1–10. Default is {DEFAULT_IDEAS_MAX_PER_CYCLE}.
          </p>
        </div>
        <div className="form-group flex-1">
          <label htmlFor="ideas-timeout-seconds">Idea Review Timeout (seconds)</label>
          <input
            id="ideas-timeout-seconds"
            type="number"
            className="input-field"
            min={1}
            max={120}
            step={1}
            value={ideasTimeoutSeconds}
            onChange={(e) => setIdeasTimeoutSeconds(e.target.value)}
          />
          <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
            Timeout in seconds for proactive ideas generation review. Range: 1–120. Default is {DEFAULT_IDEAS_TIMEOUT_SECONDS}s.
          </p>
        </div>
      </div>
      <AdvancedDisclosure
        tabName="Goals"
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        testId="advanced-goals"
        validationError={validationError}
        errorKeywords={[...GOALS_ADVANCED_ERROR_KEYWORDS]}
        onReset={resetGoalsAdvanced}
      >
        <div className="form-row">
          <div className="form-group flex-1">
            <label htmlFor="goals-max-active">Max Active Goals</label>
            <input
              id="goals-max-active"
              type="number"
              className="input-field"
              min={GOALS_MAX_ACTIVE_MIN}
              max={GOALS_MAX_ACTIVE_MAX}
              step={1}
              value={goalsMaxActiveGoals}
              onChange={(e) => setGoalsMaxActiveGoals(e.target.value)}
            />
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Maximum goals in the active state at once. Range: {GOALS_MAX_ACTIVE_MIN}–{GOALS_MAX_ACTIVE_MAX}. Default is {DEFAULT_GOALS_MAX_ACTIVE_GOALS}.
            </p>
          </div>
        </div>
        <div className="form-row" style={{ marginTop: "1rem" }}>
          <div className="form-group flex-1">
            <label htmlFor="goals-max-steps">Max Steps Per Goal</label>
            <input
              id="goals-max-steps"
              type="number"
              className="input-field"
              min={1}
              max={24}
              step={1}
              value={goalsMaxStepsPerGoal}
              onChange={(e) => setGoalsMaxStepsPerGoal(e.target.value)}
            />
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Maximum plan steps generated per goal. Range: 1–24. Default is {DEFAULT_GOALS_MAX_STEPS_PER_GOAL}.
            </p>
          </div>
          <div className="form-group flex-1">
            <label htmlFor="goals-plan-timeout">Planning Timeout (seconds)</label>
            <input
              id="goals-plan-timeout"
              type="number"
              className="input-field"
              min={0}
              max={86400}
              step={1}
              value={goalsPlanTimeoutSeconds}
              onChange={(e) => setGoalsPlanTimeoutSeconds(e.target.value)}
            />
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Timeout in seconds for model goal decomposition planning (0 for unlimited). Default is 0 (unlimited).
            </p>
          </div>
          <div className="form-group flex-1">
            <label htmlFor="goals-max-triggers">Max Triggers Per Goal</label>
            <input
              id="goals-max-triggers"
              type="number"
              className="input-field"
              min={0}
              max={32}
              step={1}
              value={goalsMaxTriggersPerGoal}
              onChange={(e) => setGoalsMaxTriggersPerGoal(e.target.value)}
            />
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Event wake-up triggers allowed per goal. Range: 0–32. Default is {DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL}.
            </p>
          </div>
        </div>
      </AdvancedDisclosure>
    </div>
  );
}

export default GoalsTab;
