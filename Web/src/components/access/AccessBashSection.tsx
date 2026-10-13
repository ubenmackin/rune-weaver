// Rune Weaver Dashboard — Bash & Shell section of the owner configuration surface.
//
// Purpose: Owns the sandboxed shell execution policy ([bash]) as its own settings
// surface. Rules stay an ordered `pattern = action` list evaluated
// top-to-bottom last-match-wins, so line order is the policy and the catch-all
// belongs first; the section edits that owner configuration only, and no
// rule-engine behavior lives here.
// Scope: Loading the [bash] snapshot, inline fail-closed editing with field
// errors, and persisting the changed-only bash patch through PUT /settings.
// Tool enablement, Keychain values, and engine rule evaluation stay with their
// owners.
// Architectural role: Settings-adjacent surface rendered outside the shared
// config form, mirroring the indexing and policy panel precedents. Writes apply
// live through the engine with no restart and no filesystem watcher, so the
// saved banner never promises a restart.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  BASH_CPU_MAX_SECONDS,
  BASH_CPU_MIN_SECONDS,
  BASH_HOST_ALLOW_PATTERNS_MAX,
  BASH_MEMORY_MAX_MB,
  BASH_MEMORY_MIN_MB,
  BASH_PERMISSION_ACTIONS,
  BASH_SANDBOX_MODES,
  BASH_SANDBOX_TIERS,
  BASH_TIMEOUT_MAX_SECONDS,
  BASH_TIMEOUT_MIN_SECONDS,
  DEFAULT_BASH_CONFIG,
  DEFAULT_BASH_CPU_SECONDS,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT,
  DEFAULT_BASH_MEMORY_MB,
  DEFAULT_BASH_RULES_TEXT,
  DEFAULT_BASH_SANDBOX_MODE,
  bashSandboxSummary,
  formatBashRulesText,
  formatHostAllowPatternsText,
  getSettings,
  parseBashRulesText,
  parseHostAllowPatternsText,
  parseHostAllowPatternsUncapped,
  updateSettings,
  validateBashSandboxMode,
  validateHostAllowPatterns,
  type BashConfigData,
  type BashRuleData,
  type BashSettingsUpdate,
} from "../../api";
import { AlertTriangleIcon, PlusIcon } from "../icons";

// Last-loaded [bash] snapshot driving the changed-only patch: a field the
// owner never touches stays omitted so the stored value survives, while a
// cleared allowlist sends an explicit empty list. Rules ride the formatted
// textarea text so the comparison sees the same parse the editor does.
interface BashLoadedSnapshot {
  enabled: boolean;
  defaultAction: string;
  rulesText: string;
  timeoutSeconds: number;
  cpuSeconds: number;
  memoryMb: number;
  allowNetwork: boolean;
  sandboxMode: string;
  hostAllowPatterns: string[];
}

// The editor draft as the nine knobs sit in the form. Numeric fields hold raw
// input (including empty) so a cleared field surfaces a range error instead of
// silently keeping a stale value, and the rules textarea holds raw text so
// blank lines survive editing and only collapse on save.
interface BashDraft {
  enabled: boolean;
  defaultAction: string;
  rulesText: string;
  timeoutSeconds: number | string;
  cpuSeconds: number | string;
  memoryMB: number | string;
  allowNetwork: boolean;
  sandboxMode: string;
  hostAllowPatternsText: string;
}

// Fresh-form draft, seeded from the combined bash defaults so the editor
// matches the engine boundary before the first settings fetch.
function freshBashDraft(): BashDraft {
  return {
    enabled: DEFAULT_BASH_CONFIG.enabled,
    defaultAction: DEFAULT_BASH_CONFIG.defaultAction,
    rulesText: DEFAULT_BASH_RULES_TEXT,
    timeoutSeconds: DEFAULT_BASH_CONFIG.timeoutSeconds,
    cpuSeconds: DEFAULT_BASH_CPU_SECONDS,
    memoryMB: DEFAULT_BASH_MEMORY_MB,
    allowNetwork: DEFAULT_BASH_CONFIG.allowNetwork,
    sandboxMode: DEFAULT_BASH_SANDBOX_MODE,
    hostAllowPatternsText: DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT,
  };
}

function freshBashLoaded(): BashLoadedSnapshot {
  return {
    enabled: DEFAULT_BASH_CONFIG.enabled,
    defaultAction: DEFAULT_BASH_CONFIG.defaultAction,
    rulesText: DEFAULT_BASH_RULES_TEXT,
    timeoutSeconds: DEFAULT_BASH_CONFIG.timeoutSeconds,
    cpuSeconds: DEFAULT_BASH_CPU_SECONDS,
    memoryMb: DEFAULT_BASH_MEMORY_MB,
    allowNetwork: DEFAULT_BASH_CONFIG.allowNetwork,
    sandboxMode: DEFAULT_BASH_SANDBOX_MODE,
    hostAllowPatterns: [...DEFAULT_BASH_HOST_ALLOW_PATTERNS],
  };
}

// Canonicalizes a draft for dirty tracking. The rules parse through the shared
// codec so a trailing newline or a reordered blank line reads clean, and the
// numbers coerce the same way the patch builder reads them, so an edit that
// returns to the loaded shape never stays dirty on formatting alone. A
// malformed line has no parsed shape to compare, so the raw text stands in and
// the editor reads dirty until the line is repaired.
function bashDraftSignature(draft: BashDraft): string {
  let rules: unknown;
  try {
    rules = parseBashRulesText(draft.rulesText);
  } catch {
    rules = draft.rulesText;
  }
  return JSON.stringify({
    enabled: draft.enabled,
    defaultAction: draft.defaultAction.trim().toLowerCase(),
    rules,
    timeoutSeconds: Number(draft.timeoutSeconds),
    cpuSeconds: Number(draft.cpuSeconds),
    memoryMb: Number(draft.memoryMB),
    allowNetwork: draft.allowNetwork,
    sandboxMode: draft.sandboxMode.trim(),
    hostAllowPatterns: parseHostAllowPatternsText(draft.hostAllowPatternsText),
  });
}

// Live parsed rule count. A malformed line still counts as a non-blank row so
// the badge stays honest until validation reports the line number.
function countBashRules(text: string): number {
  try {
    return parseBashRulesText(text).length;
  } catch {
    return text
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean).length;
  }
}

// Copies one settings fetch into the bash fields, and tolerates an absent
// [bash] section from older engines by keeping the form defaults. Only
// overwrites keys the engine returns so older engines without bash leave the
// form untouched. Rules arrive as an ordered array and render through the
// shared textarea codec so line order survives the round trip.
function applyBashConfigToDraft(draft: BashDraft, bash: BashConfigData): BashDraft {
  const next: BashDraft = { ...draft };
  if (typeof bash.enabled === "boolean") {
    next.enabled = bash.enabled;
  }
  const defaultAction =
    typeof bash.defaultAction === "string" && bash.defaultAction.trim()
      ? bash.defaultAction.trim().toLowerCase()
      : "";
  if (defaultAction) {
    next.defaultAction = defaultAction;
  }
  if (Array.isArray(bash.rules)) {
    const normalized: BashRuleData[] = bash.rules.map((rule) => ({
      pattern: typeof rule.pattern === "string" ? rule.pattern : "",
      action:
        typeof rule.action === "string" && rule.action.trim()
          ? rule.action.trim().toLowerCase()
          : "ask",
    }));
    next.rulesText = formatBashRulesText(normalized);
  }
  const timeout =
    typeof bash.timeoutSeconds === "number"
      ? bash.timeoutSeconds
      : null;
  if (timeout !== null) {
    next.timeoutSeconds = timeout;
  }
  const cpu =
    typeof bash.cpuSeconds === "number"
      ? bash.cpuSeconds
      : null;
  if (cpu !== null) {
    next.cpuSeconds = cpu;
  }
  const memory =
    typeof bash.memoryMb === "number"
      ? bash.memoryMb
      : null;
  if (memory !== null) {
    next.memoryMB = memory;
  }
  if (typeof bash.allowNetwork === "boolean") {
    next.allowNetwork = bash.allowNetwork;
  }
  const rawMode =
    typeof bash.sandboxMode === "string" && bash.sandboxMode.trim()
      ? bash.sandboxMode.trim()
      : "";
  if (rawMode && (BASH_SANDBOX_MODES as readonly string[]).includes(rawMode)) {
    next.sandboxMode = rawMode;
  }
  const rawPatterns = Array.isArray(bash.hostAllowPatterns)
    ? bash.hostAllowPatterns
    : null;
  if (rawPatterns !== null) {
    const filtered = rawPatterns.filter(
      (entry): entry is string => typeof entry === "string",
    );
    next.hostAllowPatternsText = formatHostAllowPatternsText(
      parseHostAllowPatternsText(formatHostAllowPatternsText(filtered)),
    );
  }
  return next;
}

// Rebuilds the editor draft from the last-loaded snapshot, which is what the
// populate path seeds from: a key the engine omits keeps the previously loaded
// value instead of resetting to a fresh-form default.
function bashDraftFromLoaded(loaded: BashLoadedSnapshot): BashDraft {
  return {
    enabled: loaded.enabled,
    defaultAction: loaded.defaultAction,
    rulesText: loaded.rulesText,
    timeoutSeconds: loaded.timeoutSeconds,
    cpuSeconds: loaded.cpuSeconds,
    memoryMB: loaded.memoryMb,
    allowNetwork: loaded.allowNetwork,
    sandboxMode: loaded.sandboxMode,
    hostAllowPatternsText: formatHostAllowPatternsText(loaded.hostAllowPatterns),
  };
}

// Mirrors the last-loaded snapshot the patch builder compares against, so a
// save that echoes the loaded shape leaves the next patch empty.
function bashLoadedFromDraft(draft: BashDraft): BashLoadedSnapshot {
  return {
    enabled: draft.enabled,
    defaultAction: draft.defaultAction.trim().toLowerCase(),
    rulesText: draft.rulesText,
    timeoutSeconds: Number(draft.timeoutSeconds),
    cpuSeconds: Number(draft.cpuSeconds),
    memoryMb: Number(draft.memoryMB),
    allowNetwork: draft.allowNetwork,
    sandboxMode: draft.sandboxMode.trim(),
    hostAllowPatterns: parseHostAllowPatternsText(draft.hostAllowPatternsText),
  };
}

// Bash & Shell configuration section for the settings Access surface. Keeps the
// single draft, the changed-only save, and the live-apply banner; the rule
// engine on the engine side stays the sole evaluator of what persists here.
export function AccessBashSection() {
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [enabled, setEnabled] = useState<boolean>(DEFAULT_BASH_CONFIG.enabled);
  const [defaultAction, setDefaultAction] = useState<string>(
    DEFAULT_BASH_CONFIG.defaultAction
  );
  // The rules editor holds raw textarea text (one `pattern = action` per line)
  // so blank lines survive editing and only collapse on save; the parsed count
  // drives the live badge while copy and paste of rule sets works through this
  // text.
  const [rulesText, setRulesText] = useState<string>(DEFAULT_BASH_RULES_TEXT);
  const [timeoutSeconds, setTimeoutSeconds] = useState<number | string>(
    DEFAULT_BASH_CONFIG.timeoutSeconds
  );
  // Resource budgets bound each shell turn beside the wall-clock timeout: CPU
  // seconds cap compute via `ulimit -t` while memory megabytes cap address
  // space via `ulimit -v`. Numeric inputs hold raw text (including empty) so a
  // cleared field surfaces a range error instead of silently keeping stale.
  const [cpuSeconds, setCpuSeconds] = useState<number | string>(
    DEFAULT_BASH_CPU_SECONDS
  );
  const [memoryMB, setMemoryMB] = useState<number | string>(DEFAULT_BASH_MEMORY_MB);
  const [allowNetwork, setAllowNetwork] = useState<boolean>(
    DEFAULT_BASH_CONFIG.allowNetwork
  );
  const [sandboxMode, setSandboxMode] = useState<string>(DEFAULT_BASH_SANDBOX_MODE);
  const [hostAllowPatternsText, setHostAllowPatternsText] = useState<string>(
    DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT
  );
  const [saved, setSaved] = useState(false);
  const [saveLoading, setSaveLoading] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const bashLoadedRef = useRef<BashLoadedSnapshot>(freshBashLoaded());
  // Last accepted signature for dirty tracking. Changed is a canonical compare
  // of the live draft against this value, so an edit that returns to the loaded
  // shape reads clean instead of staying dirty on formatting alone.
  const loadedSignatureRef = useRef<string>(bashDraftSignature(freshBashDraft()));
  // Direct handle to the rules editor so Add Rule can return keyboard focus
  // without a document-wide lookup that breaks with multiple instances or
  // strict-mode remounts.
  const rulesTextareaRef = useRef<HTMLTextAreaElement>(null);

  const draft: BashDraft = {
    enabled,
    defaultAction,
    rulesText,
    timeoutSeconds,
    cpuSeconds,
    memoryMB,
    allowNetwork,
    sandboxMode,
    hostAllowPatternsText,
  };
  const changed = bashDraftSignature(draft) !== loadedSignatureRef.current;

  // Copies one loaded snapshot into every field at once, then reseeds the
  // loaded ref and the dirty signature from that same snapshot. Deriving both
  // from one freshly built draft keeps the next changed-only patch honest
  // instead of comparing against state that has not re-rendered yet.
  const applyLoadedConfig = useCallback((bash: BashConfigData | undefined | null) => {
    if (!bash) return;
    const next = applyBashConfigToDraft(
      bashDraftFromLoaded(bashLoadedRef.current),
      bash,
    );
    bashLoadedRef.current = bashLoadedFromDraft(next);
    loadedSignatureRef.current = bashDraftSignature(next);
    setEnabled(next.enabled);
    setDefaultAction(next.defaultAction);
    setRulesText(next.rulesText);
    setTimeoutSeconds(next.timeoutSeconds);
    setCpuSeconds(next.cpuSeconds);
    setMemoryMB(next.memoryMB);
    setAllowNetwork(next.allowNetwork);
    setSandboxMode(next.sandboxMode);
    setHostAllowPatternsText(next.hostAllowPatternsText);
    setSaved(false);
  }, []);

  const loadBashSettings = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const data = await getSettings();
      applyLoadedConfig(data.bash);
    } catch (err: unknown) {
      setLoadError(
        err instanceof ApiError ? err.message : "Failed to load bash settings.",
      );
    } finally {
      setLoading(false);
    }
  }, [applyLoadedConfig]);

  useEffect(() => {
    void loadBashSettings();
  }, [loadBashSettings]);

  // Any edit clears the saved confirmation so a stale success never reads as
  // covering the current draft.
  function markEdited() {
    setSaved(false);
  }

  function handleEnabledChange(next: boolean) {
    setEnabled(next);
    markEdited();
  }

  function handleDefaultActionChange(next: string) {
    setDefaultAction(next);
    markEdited();
  }

  function handleSandboxModeChange(next: string) {
    setSandboxMode(next);
    markEdited();
  }

  function handleHostAllowPatternsChange(raw: string) {
    setHostAllowPatternsText(raw);
    markEdited();
  }

  function handleRulesTextChange(raw: string) {
    setRulesText(raw);
    markEdited();
  }

  function handleTimeoutChange(raw: string) {
    setTimeoutSeconds(raw === "" ? "" : Number(raw));
    markEdited();
  }

  function handleCpuSecondsChange(raw: string) {
    setCpuSeconds(raw === "" ? "" : Number(raw));
    markEdited();
  }

  function handleMemoryMBChange(raw: string) {
    setMemoryMB(raw === "" ? "" : Number(raw));
    markEdited();
  }

  function handleAllowNetworkChange(next: boolean) {
    setAllowNetwork(next);
    markEdited();
  }

  // Builds the changed-only [bash] patch: a field matching its last-loaded
  // value stays omitted so the stored value survives, while an emptied
  // allowlist sends an explicit empty list.
  function buildBashPatch(): BashSettingsUpdate {
    const patch: BashSettingsUpdate = {};
    const loaded = bashLoadedRef.current;
    if (draft.enabled !== loaded.enabled) {
      patch.enabled = draft.enabled;
    }
    const nextAction = draft.defaultAction.trim().toLowerCase();
    if (nextAction !== loaded.defaultAction) {
      patch.defaultAction = nextAction;
    }
    try {
      const currentRules = parseBashRulesText(draft.rulesText);
      const loadedRules = parseBashRulesText(loaded.rulesText);
      const rulesChanged =
        currentRules.length !== loadedRules.length ||
        currentRules.some(
          (rule, index) =>
            rule.pattern !== loadedRules[index]?.pattern ||
            rule.action !== loadedRules[index]?.action,
        );
      if (rulesChanged) {
        patch.rules = currentRules;
      }
    } catch {
      // Malformed rules never reach the patch: validation reports the line
      // number before any network write.
    }
    const timeoutNum = Number(draft.timeoutSeconds);
    if (timeoutNum !== loaded.timeoutSeconds) {
      patch.timeoutSeconds = timeoutNum;
    }
    const cpuNum = Number(draft.cpuSeconds);
    if (cpuNum !== loaded.cpuSeconds) {
      patch.cpuSeconds = cpuNum;
    }
    const memoryNum = Number(draft.memoryMB);
    if (memoryNum !== loaded.memoryMb) {
      patch.memoryMb = memoryNum;
    }
    if (draft.allowNetwork !== loaded.allowNetwork) {
      patch.allowNetwork = draft.allowNetwork;
    }
    const nextMode = draft.sandboxMode.trim();
    if (nextMode !== loaded.sandboxMode) {
      patch.sandboxMode = nextMode;
    }
    const currentPatterns = parseHostAllowPatternsText(draft.hostAllowPatternsText);
    if (
      currentPatterns.length !== loaded.hostAllowPatterns.length ||
      currentPatterns.some(
        (entry, index) => entry !== loaded.hostAllowPatterns[index],
      )
    ) {
      patch.hostAllowPatterns = [...currentPatterns];
    }
    return patch;
  }

  // Client-side validation mirrors the engine clamps so a bad default action, a
  // malformed rule line, an empty rule list, an out-of-range budget, an unknown
  // tier, or an over-limit, blank, overlong, control-char, or TOML-breaking
  // host pattern fails in the form with the same field the server 400 names.
  function validateBashFields(): string | null {
    const normalizedAction = draft.defaultAction.trim().toLowerCase();
    if (!(BASH_PERMISSION_ACTIONS as readonly string[]).includes(normalizedAction)) {
      return 'Invalid bash default action: must be allow, ask, or deny.';
    }
    let parsed: BashRuleData[];
    try {
      parsed = parseBashRulesText(draft.rulesText);
    } catch (err) {
      return err instanceof Error ? err.message : "Invalid bash rules.";
    }
    if (parsed.length === 0) {
      return "Invalid bash rules: at least one rule is required.";
    }
    const timeoutNum = Number(draft.timeoutSeconds);
    if (!Number.isInteger(timeoutNum) || timeoutNum < BASH_TIMEOUT_MIN_SECONDS || timeoutNum > BASH_TIMEOUT_MAX_SECONDS) {
      return `Invalid bash timeout: timeout must be between ${BASH_TIMEOUT_MIN_SECONDS} and ${BASH_TIMEOUT_MAX_SECONDS} seconds.`;
    }
    const cpuNum = Number(draft.cpuSeconds);
    if (!Number.isInteger(cpuNum) || cpuNum < BASH_CPU_MIN_SECONDS || cpuNum > BASH_CPU_MAX_SECONDS) {
      return `Invalid bash CPU budget: CPU time must be between ${BASH_CPU_MIN_SECONDS} and ${BASH_CPU_MAX_SECONDS} seconds.`;
    }
    const memoryNum = Number(draft.memoryMB);
    if (!Number.isInteger(memoryNum) || memoryNum < BASH_MEMORY_MIN_MB || memoryNum > BASH_MEMORY_MAX_MB) {
      return `Invalid bash memory budget: memory must be between ${BASH_MEMORY_MIN_MB} and ${BASH_MEMORY_MAX_MB} MB.`;
    }
    const tierError = validateBashSandboxMode(draft.sandboxMode);
    if (tierError) {
      return tierError;
    }
    const uncapped = parseHostAllowPatternsUncapped(draft.hostAllowPatternsText);
    if (uncapped.length > BASH_HOST_ALLOW_PATTERNS_MAX) {
      return `Invalid bash host allow patterns: must contain at most ${BASH_HOST_ALLOW_PATTERNS_MAX} entries (got ${uncapped.length}).`;
    }
    const patternsError = validateHostAllowPatterns(uncapped);
    if (patternsError) {
      return patternsError;
    }
    return null;
  }

  // Saves the changed-only [bash] patch through PUT /settings. Only edited keys
  // travel so stored values survive; an emptied allowlist sends an
  // explicit empty list. Client validation reports inline without closing while
  // a server 400 lands in the error path without discarding the draft.
  // Confinement applies live, so success shows the saved banner with no
  // restart banner.
  const handleSave = async (): Promise<void> => {
    const validationError = validateBashFields();
    if (validationError) {
      setSaveError(validationError);
      return;
    }
    setSaveLoading(true);
    setSaveError(null);
    try {
      const updated = await updateSettings({ bash: buildBashPatch() });
      // Repopulate first so the accepted snapshot re-seeds both the loaded ref
      // and the dirty comparison; the banner then flips on after it, because
      // the repopulate clears the flag for the plain load path.
      applyLoadedConfig(updated.bash);
      setSaved(true);
    } catch (err: unknown) {
      setSaveError(
        err instanceof ApiError ? err.message : "Failed to save bash settings",
      );
    } finally {
      setSaveLoading(false);
    }
  };

  // Rule editing is a single textarea (small-screen friendly for long rule
  // sets, and copy and paste of rule sets works through this text); Add Rule
  // focuses the editor for keyboard flow.
  const handleAddRule = () => {
    // No row model exists for the textarea, so Add focuses the editor for
    // keyboard flow; ensure a trailing newline exists so typed rules start
    // on a fresh line without altering the parsed count by itself.
    setRulesText((prev) => {
      if (!prev) return prev;
      return prev.endsWith("\n") ? prev : `${prev}\n`;
    });
    markEdited();
    rulesTextareaRef.current?.focus();
  };

  const ruleCount = countBashRules(rulesText);

  return (
    <section className="settings-section card" aria-label="Bash & Shell" data-testid="bash-pane">
      <div className="settings-section-title-group">
        <h3>Bash &amp; Shell</h3>
        <p className="settings-section-hint">
          Sandboxed shell execution with per-command approval policy. Changes apply
          immediately with no restart.
        </p>
      </div>

      {loading ? <p className="muted text-sm" data-testid="bash-loading">Loading bash settings…</p> : null}

      {loadError ? (
        <div className="error-banner" data-testid="bash-load-error" style={{ marginBottom: "12px" }}>
          <AlertTriangleIcon size={16} />
          <span>{loadError}</span>
        </div>
      ) : null}

      {!loading && !loadError ? (
        <>
          {saveError ? (
            <div className="error-banner" data-testid="bash-error" style={{ marginBottom: "12px" }}>
              <AlertTriangleIcon size={16} />
              <span>{saveError}</span>
            </div>
          ) : null}

          {saved ? (
            <div
              data-testid="bash-saved"
              style={{
                padding: "8px 12px",
                borderRadius: "6px",
                backgroundColor: "rgba(16, 185, 129, 0.15)",
                color: "#10b981",
                fontSize: "0.85rem",
                marginBottom: "12px",
              }}
            >
              Bash settings saved. Changes apply immediately with no restart.
            </div>
          ) : null}

          <p className="muted text-sm" style={{ marginBottom: "16px" }}>
            Rules evaluate top-to-bottom last-match-wins; the default action applies
            when no rule matches.
          </p>

          <p className="muted text-sm" style={{ marginBottom: "16px" }}>
            Default working directory is the engine home with an optional per-call override inside allowed roots, confined by the execution tier below.
          </p>

          <div className="form-group checkbox-group" style={{ marginBottom: "12px" }}>
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                id="bash-enabled"
                type="checkbox"
                checked={enabled}
                onChange={(e) => handleEnabledChange(e.target.checked)}
              />
              <span>Enabled</span>
            </label>
            <span className="form-group-hint">
              When off, the shell tool refuses every command without dialing.
            </span>
          </div>

          <div className="form-group" style={{ marginBottom: "12px" }}>
            <label htmlFor="bash-default-action" style={{ fontSize: "0.82rem" }}>Default action</label>
            <select
              id="bash-default-action"
              className="input-field"
              value={defaultAction}
              onChange={(e) => handleDefaultActionChange(e.target.value)}
            >
              {BASH_PERMISSION_ACTIONS.map((action) => (
                <option key={action} value={action}>
                  {action.charAt(0).toUpperCase() + action.slice(1)}
                </option>
              ))}
            </select>
            <span className="form-group-hint">
              Action when no rule matches, top-to-bottom last-match-wins otherwise.
            </span>
          </div>

          <div className="form-group" style={{ marginBottom: "12px" }}>
            <label htmlFor="bash-sandbox-mode" style={{ fontSize: "0.82rem" }}>Execution tier</label>
            <select
              id="bash-sandbox-mode"
              className="input-field"
              aria-label="Execution tier"
              value={sandboxMode}
              onChange={(e) => handleSandboxModeChange(e.target.value)}
            >
              {BASH_SANDBOX_TIERS.map((tier) => (
                <option key={tier.value} value={tier.value}>
                  {tier.label}
                </option>
              ))}
            </select>
            <span className="form-group-hint" data-testid="bash-sandbox-help">
              {bashSandboxSummary(sandboxMode, allowNetwork)}
            </span>
            <span className="form-group-hint" data-testid="bash-sandbox-scope">
              {BASH_SANDBOX_TIERS.find((tier) => tier.value === sandboxMode)?.scope ?? ""}
            </span>
          </div>

          <div className="form-group" style={{ marginBottom: "12px" }}>
            <label htmlFor="bash-host-allow-patterns" style={{ fontSize: "0.82rem" }}>Host allow patterns</label>
            <textarea
              id="bash-host-allow-patterns"
              className="input-field"
              aria-label="Host allow patterns"
              value={hostAllowPatternsText}
              onChange={(e) => handleHostAllowPatternsChange(e.target.value)}
              placeholder={"xcodebuild*\ncodesign*"}
              rows={4}
            />
            <span className="form-group-hint">
              One pattern per line gating {BASH_SANDBOX_TIERS.find((tier) => tier.value === "hostSeatbelt")?.label ?? "On this Mac"} execution. Empty list blocks host execution entirely.
            </span>
          </div>

          <div className="settings-subsection-header" style={{ marginTop: "16px" }}>
            <div className="settings-section-title-group">
              <h4 style={{ margin: "0 0 4px 0" }}>Rules</h4>
              <p className="settings-section-hint">
                Ordered top-to-bottom, last match wins. Patterns match the command line.
              </p>
            </div>
            <div className="row">
              <button
                type="button"
                className="ghost icon-text-btn"
                onClick={handleAddRule}
              >
                <PlusIcon size={14} />
                <span>Add Rule</span>
              </button>
            </div>
          </div>
          <div className="form-group" style={{ marginTop: "8px" }}>
            <label htmlFor="bash-rules-textarea">
              Rules, one per line{" "}
              <span className="muted text-sm">
                ({ruleCount} {ruleCount === 1 ? "rule" : "rules"})
              </span>
            </label>
            <textarea
              id="bash-rules-textarea"
              ref={rulesTextareaRef}
              className="input-field bash-rules-textarea"
              aria-label="Rules, one per line"
              value={rulesText}
              onChange={(e) => handleRulesTextChange(e.target.value)}
              placeholder={"* = deny\ngit status = allow\nnpm test = allow"}
              rows={8}
            />
            <span className="form-group-hint">
              One rule per line as `pattern = action` (allow, ask, or deny). Blank lines are
              ignored. Rules evaluate top-to-bottom; the last matching rule wins
              (last-match-wins). Put the catch-all first and specifics after.
            </span>
          </div>

          <details data-testid="bash-advanced-details" style={{ marginTop: "16px", marginBottom: "12px" }}>
            <summary style={{ cursor: "pointer", fontSize: "0.82rem" }}>Advanced</summary>
            <div className="form-group" style={{ marginTop: "12px", marginBottom: "12px" }}>
              <label htmlFor="bash-timeout" style={{ fontSize: "0.82rem" }}>Timeout (seconds)</label>
              <input
                id="bash-timeout"
                type="number"
                min={BASH_TIMEOUT_MIN_SECONDS}
                max={BASH_TIMEOUT_MAX_SECONDS}
                step={1}
                className="input-field"
                value={timeoutSeconds}
                onChange={(e) => handleTimeoutChange(e.target.value)}
                placeholder="30"
              />
              <span className="form-group-hint">
                Default execution timeout in seconds (1 to 3600).
              </span>
            </div>

            <div className="form-group" style={{ marginBottom: "12px" }}>
              <label htmlFor="bash-cpu-seconds" style={{ fontSize: "0.82rem" }}>CPU seconds</label>
              <input
                id="bash-cpu-seconds"
                type="number"
                min={BASH_CPU_MIN_SECONDS}
                max={BASH_CPU_MAX_SECONDS}
                step={1}
                className="input-field"
                value={cpuSeconds}
                onChange={(e) => handleCpuSecondsChange(e.target.value)}
                placeholder="120"
              />
              <span className="form-group-hint">
                CPU time budget in seconds; wall-clock may exceed CPU time for sleeping processes.
              </span>
            </div>

            <div className="form-group" style={{ marginBottom: "12px" }}>
              <label htmlFor="bash-memory-mb" style={{ fontSize: "0.82rem" }}>Memory (MB)</label>
              <input
                id="bash-memory-mb"
                type="number"
                min={BASH_MEMORY_MIN_MB}
                max={BASH_MEMORY_MAX_MB}
                step={1}
                className="input-field"
                value={memoryMB}
                onChange={(e) => handleMemoryMBChange(e.target.value)}
                placeholder="1024"
              />
              <span className="form-group-hint">
                Address-space budget in MB as a best-effort ulimit bound.
              </span>
            </div>
          </details>

          <div className="form-group checkbox-group">
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                id="bash-allow-network"
                type="checkbox"
                checked={allowNetwork}
                onChange={(e) => handleAllowNetworkChange(e.target.checked)}
              />
              <span>Allow network access</span>
            </label>
            <span className="form-group-hint">
              When on, sandboxed commands may reach the network; otherwise they run isolated.
            </span>
          </div>

          <div className="settings-footer">
            <span className="muted text-sm" data-testid="bash-save-hint">
              {changed
                ? "Unsaved changes — only the edited keys travel in the bash patch."
                : "Only the edited keys travel; every untouched value survives."}
            </span>
            <button
              type="button"
              className="primary-button save-button"
              data-testid="bash-save"
              onClick={() => void handleSave()}
              disabled={saveLoading}
            >
              {saveLoading ? "Saving…" : "Save"}
            </button>
          </div>
        </>
      ) : null}
    </section>
  );
}

export default AccessBashSection;
