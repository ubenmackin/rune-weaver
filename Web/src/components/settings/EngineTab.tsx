// Rune Weaver Dashboard — Engine & Logging tab pane.

import { useState } from "react";
import type { SettingsResponse } from "../../api";
import {
  DEFAULT_ENGINE_MAX_TOOL_ITERATIONS,
  DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS,
  engineMaxToolIterations,
  goalsMaxToolIterations,
  normalizeProactiveMode,
  PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS,
  PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS,
  schedulerMaxToolIterations,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
} from "../../api";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import { countEngineAdvancedChanged } from "./settingsAdvancedCounts";

export interface EngineTabProps {
  engineName: string;
  setEngineName: (val: string) => void;
  logLevel: string;
  setLogLevel: (val: string) => void;
  compactionThresholdPercent: number;
  setCompactionThresholdPercent: (val: number) => void;
  maxToolIterations: number | string;
  setMaxToolIterations: (val: number | string) => void;
  proactiveMode: string;
  setProactiveMode: (val: string) => void;
  proactiveJudgeTimeoutSeconds: number | string;
  setProactiveJudgeTimeoutSeconds: (val: number | string) => void;
  settings: SettingsResponse | null;
  validationError?: string | null;
}

export function EngineTab({
  engineName,
  setEngineName,
  logLevel,
  setLogLevel,
  compactionThresholdPercent,
  setCompactionThresholdPercent,
  maxToolIterations,
  setMaxToolIterations,
  proactiveMode,
  setProactiveMode,
  proactiveJudgeTimeoutSeconds,
  setProactiveJudgeTimeoutSeconds,
  settings,
  validationError = null,
}: EngineTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const schedulerRounds = schedulerMaxToolIterations(settings);
  const goalRounds = goalsMaxToolIterations(settings?.goals);
  const advancedChangedCount = countEngineAdvancedChanged(
    compactionThresholdPercent
  );

  // Reset restores the stock compaction threshold.
  const resetEngineAdvanced = () => {
    setCompactionThresholdPercent(80);
  };
  return (
    <>
      <div className="settings-section card">
        <div className="settings-section-title-group">
          <h3>Engine & Logging</h3>
          <p className="settings-section-hint">
            Identity name and logging verbosity for the Rune Weaver daemon.
          </p>
        </div>
        <div className="form-row">
          <div className="form-group flex-1">
            <label htmlFor="engine-name">Engine Name</label>
            <input
              id="engine-name"
              type="text"
              className="input-field"
              value={engineName}
              onChange={(e) => setEngineName(e.target.value)}
              required
            />
          </div>
          <div className="form-group flex-1">
            <label htmlFor="log-level">Log Level</label>
            <select
              id="log-level"
              className="input-field"
              value={logLevel}
              onChange={(e) => setLogLevel(e.target.value)}
            >
              <option value="trace">Trace (Verbose)</option>
              <option value="debug">Debug</option>
              <option value="info">Info</option>
              <option value="notice">Notice</option>
              <option value="warning">Warning</option>
              <option value="error">Error</option>
            </select>
          </div>
        </div>
        <div className="form-row" style={{ marginTop: "1rem" }}>
          <div className="form-group flex-1">
            <label htmlFor="max-tool-iterations">
              Max Tool Rounds per Turn (Chats)
            </label>
            <input
              id="max-tool-iterations"
              type="number"
              className="input-field"
              min={TOOL_ROUNDS_MIN}
              max={TOOL_ROUNDS_MAX}
              step={1}
              value={maxToolIterations}
              onChange={(e) => setMaxToolIterations(e.target.value)}
            />
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Applies to interactive chats only. When a chat reaches this many consecutive tool rounds it parks for your approval to continue. Range: {TOOL_ROUNDS_MIN}–{TOOL_ROUNDS_MAX}. Default is {DEFAULT_ENGINE_MAX_TOOL_ITERATIONS}.
            </p>
          </div>
        </div>
      </div>
      <div className="settings-section card" style={{ marginTop: "16px" }} data-testid="proactive-pane">
        <div className="settings-section-title-group">
          <h3>Proactivity</h3>
        <p className="settings-section-hint">
          Background interruption policy. Applies live with no restart.
        </p>
        </div>
        <div className="form-row" style={{ marginTop: "1rem" }}>
          <div className="form-group flex-1">
            <label htmlFor="proactive-mode">Proactivity Mode</label>
            <select
              id="proactive-mode"
              className="input-field"
              value={normalizeProactiveMode(proactiveMode) || proactiveMode}
              onChange={(e) => setProactiveMode(normalizeProactiveMode(e.target.value) || e.target.value)}
            >
              <option value="all">All — surface every background outcome</option>
              <option value="milestones">Milestones — milestones, errors, and parked turns only</option>
              <option value="guarded">Guarded — milestones plus a judge call for routine successes</option>
              <option value="off">Off — never interrupt</option>
            </select>
            <span className="form-group-hint">
              Off never interrupts; the approvals inbox keeps recording.
            </span>
          </div>
          <div className="form-group flex-1">
            <label htmlFor="proactive-judge-timeout">Judge Timeout (seconds)</label>
            <input
              id="proactive-judge-timeout"
              type="number"
              className="input-field"
              min={PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS}
              max={PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS}
              step={1}
              value={proactiveJudgeTimeoutSeconds}
              onChange={(e) => setProactiveJudgeTimeoutSeconds(e.target.value)}
            />
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Seconds the guarded judge may spend before the gate fails open. Range: {PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS}–{PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS}. Default is {DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS}.
            </p>
          </div>
        </div>
      </div>
      <AdvancedDisclosure
        tabName="Engine"
        changedCount={advancedChangedCount}
        summary={
          advancedChangedCount > 0
            ? `${advancedChangedCount} advanced engine ${advancedChangedCount === 1 ? "setting" : "settings"} changed`
            : undefined
        }
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        testId="advanced-engine"
        validationError={validationError}
        errorKeywords={["compaction", "scheduler", "goal runs"]}
        onReset={resetEngineAdvanced}
      >
        <div className="settings-section card">
          <div className="form-row">
            <div className="form-group flex-1">
              <label htmlFor="compaction-threshold">
                Context Compaction Threshold: {compactionThresholdPercent}%
              </label>
              <div style={{ display: "flex", alignItems: "center", gap: "1rem" }}>
                <input
                  id="compaction-threshold"
                  type="range"
                  min={10}
                  max={100}
                  step={5}
                  value={compactionThresholdPercent}
                  onChange={(e) => setCompactionThresholdPercent(Number(e.target.value))}
                  style={{ flex: 1 }}
                />
                <span style={{ minWidth: "3rem", fontWeight: "bold" }}>
                  {compactionThresholdPercent}%
                </span>
              </div>
              <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                When session token usage reaches this percentage of the model&apos;s context limit, older tool outputs and turns are compacted to prevent overflow. Default is 80%.
              </p>
            </div>
          </div>
          <div className="form-row" style={{ marginTop: "1rem" }}>
            <div className="form-group flex-1">
              <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                Chats use {engineMaxToolIterations(settings)} rounds per turn (parks for approval). Scheduled runs use {schedulerRounds} rounds by default with per-job override (synthesizes plus budget_exceeded, or parks when the job sets on_tool_limit to park). Goal runs use {goalRounds} rounds (always synthesizes plus budget_exceeded).
              </p>
            </div>
          </div>
        </div>
      </AdvancedDisclosure>
    </>
  );
}

export default EngineTab;
