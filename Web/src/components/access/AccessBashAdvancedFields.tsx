// Rune Weaver Dashboard — Advanced-only Bash fields: tuning mirrors and confinement controls.
import {
  BASH_SANDBOX_MODES,
  BASH_SANDBOX_TIERS,
  bashSandboxSummary,
  DEFAULT_BASH_CPU_SECONDS,
  DEFAULT_BASH_MEMORY_MB,
  DEFAULT_BASH_TIMEOUT_SECONDS,
} from "../../api";
import {
  BASH_TUNING_CPU_MAX_SECONDS,
  BASH_TUNING_CPU_MIN_SECONDS,
  BASH_TUNING_HOST_PATTERNS_MAX,
  BASH_TUNING_MEMORY_MAX_MB,
  BASH_TUNING_MEMORY_MIN_MB,
  BASH_TUNING_TIMEOUT_MAX_SECONDS,
  BASH_TUNING_TIMEOUT_MIN_SECONDS,
} from "./accessBashDraft";

interface BashTuningFieldsProps {
  idPrefix: string;
  timeoutSeconds: number | string;
  cpuSeconds: number | string;
  memoryMB: number | string;
  onTimeoutChange: (value: string) => void;
  onCpuChange: (value: string) => void;
  onMemoryChange: (value: string) => void;
}

// The three numeric engine budgets. Each keeps a mirror string so a cleared
// input can be validated with an actionable message instead of snapping to 0.
export function BashTuningFields({
  idPrefix,
  timeoutSeconds,
  cpuSeconds,
  memoryMB,
  onTimeoutChange,
  onCpuChange,
  onMemoryChange,
}: BashTuningFieldsProps) {
  return (
    <div className="field-grid">
      <label className="field">
        <span>Timeout (seconds)</span>
        <input
          id={`${idPrefix}-timeout`}
          type="number"
          min={BASH_TUNING_TIMEOUT_MIN_SECONDS}
          max={BASH_TUNING_TIMEOUT_MAX_SECONDS}
          step={1}
          value={timeoutSeconds}
          placeholder={String(DEFAULT_BASH_TIMEOUT_SECONDS)}
          onChange={(event) => onTimeoutChange(event.target.value)}
        />
        <small className="muted">
          Default execution timeout in seconds ({BASH_TUNING_TIMEOUT_MIN_SECONDS} to{" "}
          {BASH_TUNING_TIMEOUT_MAX_SECONDS}).
        </small>
      </label>
      <label className="field">
        <span>CPU seconds</span>
        <input
          id={`${idPrefix}-cpu-seconds`}
          type="number"
          min={BASH_TUNING_CPU_MIN_SECONDS}
          max={BASH_TUNING_CPU_MAX_SECONDS}
          step={1}
          value={cpuSeconds}
          placeholder={String(DEFAULT_BASH_CPU_SECONDS)}
          onChange={(event) => onCpuChange(event.target.value)}
        />
        <small className="muted">
          CPU time budget in seconds ({BASH_TUNING_CPU_MIN_SECONDS} to{" "}
          {BASH_TUNING_CPU_MAX_SECONDS}); wall-clock may exceed CPU time for sleeping processes; best-effort ulimit bound.
        </small>
      </label>
      <label className="field">
        <span>Memory (MB)</span>
        <input
          id={`${idPrefix}-memory-mb`}
          type="number"
          min={BASH_TUNING_MEMORY_MIN_MB}
          max={BASH_TUNING_MEMORY_MAX_MB}
          step={1}
          value={memoryMB}
          placeholder={String(DEFAULT_BASH_MEMORY_MB)}
          onChange={(event) => onMemoryChange(event.target.value)}
        />
        <small className="muted">
          Maximum resident memory per command ({BASH_TUNING_MEMORY_MIN_MB} to{" "}
          {BASH_TUNING_MEMORY_MAX_MB}); best-effort ulimit bound.
        </small>
      </label>
    </div>
  );
}

interface BashConfinementFieldsProps {
  idPrefix: string;
  sandboxMode: string;
  allowNetwork: boolean;
  hostAllowPatternsText: string;
  onSandboxModeChange: (mode: string) => void;
  onHostAllowPatternsChange: (text: string) => void;
}

// The execution tier plus the host-scoped allowlist. These live only in
// Advanced because they widen the sandbox; the tier summary stays visible so a
// selected posture is never hidden behind the disclosure.
export function BashConfinementFields({
  idPrefix,
  sandboxMode,
  allowNetwork,
  hostAllowPatternsText,
  onSandboxModeChange,
  onHostAllowPatternsChange,
}: BashConfinementFieldsProps) {
  return (
    <div className="field">
      <label htmlFor={`${idPrefix}-sandbox-mode`}>Execution tier</label>
      <select
        id={`${idPrefix}-sandbox-mode`}
        className="input-field"
        aria-label="Execution tier"
        value={sandboxMode}
        onChange={(event) => onSandboxModeChange(event.target.value)}
      >
        {BASH_SANDBOX_TIERS.map((tier) => (
          <option key={tier.value} value={tier.value}>
            {tier.label}
          </option>
        ))}
      </select>
      <small className="muted" data-testid="bash-sandbox-help">
        {bashSandboxSummary(sandboxMode, allowNetwork)}
      </small>
      <small className="muted" data-testid="bash-sandbox-scope">
        {BASH_SANDBOX_TIERS.find((tier) => tier.value === sandboxMode)?.scope ?? ""}
      </small>
      <label htmlFor={`${idPrefix}-host-patterns`}>Host allow patterns</label>
      <textarea
        id={`${idPrefix}-host-patterns`}
        className="input-field"
        aria-label="Host allow patterns"
        value={hostAllowPatternsText}
        onChange={(event) => onHostAllowPatternsChange(event.target.value)}
        placeholder={"xcodebuild*\ncodesign*"}
        rows={4}
      />
      <small className="muted">
        One pattern per line gating{" "}
        {BASH_SANDBOX_TIERS.find((tier) => tier.value === "hostSeatbelt")?.label ??
          "On this Mac"}{" "}
        execution. Empty list blocks host execution entirely. List{" "}
        {countPatternLines(hostAllowPatternsText)} of {BASH_TUNING_HOST_PATTERNS_MAX}.
      </small>
      {sandboxMode !== BASH_SANDBOX_MODES[0] ? (
        <small className="muted">
          Execution stays inside the selected tier even when a command matches an allow rule.
        </small>
      ) : null}
    </div>
  );
}

function countPatternLines(text: string): number {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean).length;
}
