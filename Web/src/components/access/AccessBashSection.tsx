// Rune Weaver Dashboard — Bash & Shell section of the owner configuration surface.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  BASH_PERMISSION_ACTIONS,
  DEFAULT_BASH_CONFIG,
  DEFAULT_BASH_CPU_SECONDS,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT,
  DEFAULT_BASH_MEMORY_MB,
  DEFAULT_BASH_RULES_TEXT,
  DEFAULT_BASH_SANDBOX_MODE,
  BASH_SANDBOX_TIERS,
  bashSandboxSummary,
  formatHostAllowPatternsText,
  parseBashRulesText,
  parseHostAllowPatternsText,
  parseHostAllowPatternsUncapped,
  updateSettings,
  type BashRuleData,
  type BashSettingsUpdate,
  type SettingsResponse,
  type UpdateSettingsInput,
} from "../../api";
import { AlertTriangleIcon, PlusIcon } from "../icons";
import { AdvancedDisclosure } from "../settings/AdvancedDisclosure";
import { SwitchControl } from "../settings/SwitchControl";
import {
  BashConfinementFields,
  BashTuningFields,
} from "./AccessBashAdvancedFields";
import {
  bashDraftSignature,
  countBashRules,
  freshBashDraft,
  freshBashLoaded,
  validateBashBudgets,
  validateBashConfinementFields,
  type BashDraft,
  type BashLoadedSnapshot,
} from "./accessBashDraft";
import {
  fetchSharedAccessSettings,
  resolveBashDraftAndLoaded,
} from "./accessSettingsLoader";
import type { UseBashAdvancedResult } from "./useAccessAdvanced";

// Advanced Bash validation messages the disclosure can focus. Shared by the
// panel prop and the server-error router so one message never prints twice.
const BASH_ADVANCED_ERROR_KEYWORDS = [
  "timeout",
  "cpu",
  "memory",
  "sandbox",
  "tier",
  "host allow",
] as const;

function isBashAdvancedError(message: string): boolean {
  const lowered = message.toLowerCase();
  return BASH_ADVANCED_ERROR_KEYWORDS.some((keyword) =>
    lowered.includes(keyword)
  );
}

// Bash & Shell configuration section for the settings Access surface. Keeps the
// single draft, the changed-only save, and the live-apply banner; the rule
// engine on the engine side stays the sole evaluator of what persists here.
export function AccessBashSection({
  simpleOnly = false,
  advanced,
}: {
  simpleOnly?: boolean;
  advanced?: UseBashAdvancedResult | null;
} = {}) {
  // simpleOnly is retained for compatibility; Advanced ownership follows the
  // hook presence so both entry points share one disclosure.
  void simpleOnly;
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [defaultAction, setDefaultAction] = useState<string>(
    DEFAULT_BASH_CONFIG.defaultAction
  );
  // The rules editor holds raw textarea text (one `pattern = action` per line) so blank lines
  // survive editing and only collapse on save; the parsed count drives the live badge while copy and
  // paste of rule sets works through this text.
  const [rulesText, setRulesText] = useState<string>(DEFAULT_BASH_RULES_TEXT);
  const [timeoutSeconds, setTimeoutSeconds] = useState<number | string>(
    DEFAULT_BASH_CONFIG.timeoutSeconds
  );
  // Resource budgets bound each shell turn beside the wall-clock timeout: CPU seconds cap compute
  // via `ulimit -t` while memory megabytes cap address space via `ulimit -v`.
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
  // Last accepted signature for dirty tracking. Changed compares the live draft
  // against this value so a return to the loaded shape reads clean.
  const loadedSignatureRef = useRef<string>(bashDraftSignature(freshBashDraft()));
  // Local Advanced open for the standalone path. The pane-level hook owns this
  // when present, so this state only drives the disclosure without a hook.
  const [localAdvancedOpen, setLocalAdvancedOpen] = useState(false);
  // Direct handle to the rules editor so Add Rule can return keyboard focus
  // without a document-wide lookup that breaks with multiple instances or
  // strict-mode remounts.
  const rulesTextareaRef = useRef<HTMLTextAreaElement>(null);

  const draft: BashDraft = {
    defaultAction,
    rulesText,
    timeoutSeconds,
    cpuSeconds,
    memoryMB,
    allowNetwork,
    sandboxMode,
    hostAllowPatternsText,
  };
  // When the pane-level Advanced hook is present it owns tuning plus
  // confinement, so Simple dirty tracking mutes those fields to keep one
  // owner for their keys.
  const simpleSignatureDraft: BashDraft = advanced
    ? {
        ...draft,
        timeoutSeconds: bashLoadedRef.current.timeoutSeconds,
        cpuSeconds: bashLoadedRef.current.cpuSeconds,
        memoryMB: bashLoadedRef.current.memoryMb,
        sandboxMode: bashLoadedRef.current.sandboxMode,
        hostAllowPatternsText: formatHostAllowPatternsText(
          bashLoadedRef.current.hostAllowPatterns
        ),
      }
    : draft;
  const changed = bashDraftSignature(simpleSignatureDraft) !== loadedSignatureRef.current;

  // Copies one loaded snapshot into every field at once, then reseeds the loaded ref and the dirty
  // signature from that same snapshot. The shared loader owns the mapping so
  // the section plus the Advanced hook read identical drafts from one payload.
  const applyLoadedConfig = useCallback((settings: SettingsResponse | null | undefined) => {
    const resolved = resolveBashDraftAndLoaded(settings, bashLoadedRef.current);
    if (!resolved) return;
    const next = resolved.draft;
    bashLoadedRef.current = resolved.loaded;
    loadedSignatureRef.current = bashDraftSignature(next);
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
      const data = await fetchSharedAccessSettings();
      applyLoadedConfig(data);
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

  // Builds the changed-only [bash] patch, omitting stored values. When the
  // Advanced hook is present tuning plus confinement stay out so Advanced
  // remains their sole writer.
  function buildBashPatch(): BashSettingsUpdate {
    const patch: BashSettingsUpdate = {};
    const loaded = bashLoadedRef.current;
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
    if (draft.allowNetwork !== loaded.allowNetwork) {
      patch.allowNetwork = draft.allowNetwork;
    }
    if (!advanced) {
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
    }
    return patch;
  }

  // Client-side validation mirrors engine clamps: malformed rules, empty lists, invalid budgets
  // or tiers, and invalid/TOML-breaking host patterns fail in the form with the same field the
  // server 400 names. With the Advanced hook present budgets plus confinement
  // skip so Advanced owns them.
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
    if (!advanced) {
      const tuningError = validateBashBudgets(
        draft.timeoutSeconds,
        draft.cpuSeconds,
        draft.memoryMB
      );
      if (tuningError) return tuningError;
      const confinementError = validateBashConfinementFields(
        draft.sandboxMode,
        draft.hostAllowPatternsText
      );
      if (confinementError) return confinementError;
    }
    return null;
  }

  // Saves the changed-only [bash] patch through PUT /settings. Only edited keys travel so stored
  // values survive; an emptied allowlist sends an explicit empty list. With the
  // Advanced hook present its patch rides the same payload so one save has one
  // truth.
  const handleSave = async (): Promise<void> => {
    if (advanced) {
      const advError = advanced.validate();
      if (advError) {
        advanced.setSaveError(advError);
        return;
      }
    }
    const validationError = validateBashFields();
    if (validationError) {
      setSaveError(validationError);
      return;
    }
    setSaveLoading(true);
    setSaveError(null);
    try {
      const patch: UpdateSettingsInput = { bash: buildBashPatch() };
      if (advanced) {
        const advPatch = advanced.buildPatch();
        if (advPatch.bash) {
          patch.bash = { ...patch.bash, ...advPatch.bash };
        }
      }
      const updated = await updateSettings(patch);
      // Repopulate first so the accepted snapshot re-seeds both the loaded ref
      // and the dirty comparison; the banner then flips on after it, because
      // the repopulate clears the flag for the plain load path.
      applyLoadedConfig(updated);
      advanced?.applySaved(updated);
      setSaved(true);
    } catch (err: unknown) {
      const message =
        err instanceof ApiError ? err.message : "Failed to save bash settings";
      if (advanced && isBashAdvancedError(message)) {
        advanced.setSaveError(message);
      } else {
        setSaveError(message);
      }
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

  // Local Advanced reset for the standalone path. Restores tuning plus
  // confinement to defaults so reset never touches Simple bindings.
  function handleResetLocalAdvanced() {
    const fresh = freshBashDraft();
    setTimeoutSeconds(fresh.timeoutSeconds);
    setCpuSeconds(fresh.cpuSeconds);
    setMemoryMB(fresh.memoryMB);
    setSandboxMode(fresh.sandboxMode);
    setHostAllowPatternsText(fresh.hostAllowPatternsText);
    setSaveError(null);
  }

  const ruleCount = countBashRules(rulesText);
  const effectiveSandboxMode = advanced ? advanced.sandboxMode : sandboxMode;
  const effectiveHostAllowPatternsText = advanced ? advanced.hostAllowPatternsText : hostAllowPatternsText;
  const effectiveHostPatternCount = parseHostAllowPatternsUncapped(effectiveHostAllowPatternsText).length;
  const advancedChanged = advanced?.changed ?? false;
  // Single disclosure source: hook owns open plus reset when
  // present, otherwise local tuning drives the same disclosure.
  const unifiedOpen = advanced ? advanced.open : localAdvancedOpen;
  const unifiedSetOpen = advanced ? advanced.setOpen : setLocalAdvancedOpen;
  const unifiedValidationError = advanced ? advanced.saveError : saveError;
  const unifiedReset = advanced ? advanced.reset : handleResetLocalAdvanced;

  // An Advanced edit clears the section's saved confirmation too, so a stale
  // success never covers a draft the advanced hook now owns.
  useEffect(() => {
    if (advancedChanged) setSaved(false);
  }, [advancedChanged]);

  return (
    <section className="settings-section card" aria-label="Bash & Shell" data-testid="bash-pane">
      <div className="settings-section-title-group">
        <h3>Bash &amp; Shell</h3>
        <p className="settings-section-hint">
          Sandboxed shell execution with per-command approval policy. Changes apply
          immediately with no restart.
        </p>
      </div>

      {/* Deliberately no Enabled checkbox: the Settings → Tools toggle is the one
          enablement gate, so a second one here could only disagree with it. */}

      {loading ? <p className="muted text-sm" data-testid="bash-loading">Loading bash settings…</p> : null}

      {loadError ? (
        <div className="error-banner" data-testid="bash-load-error">
          <AlertTriangleIcon size={16} />
          <span>{loadError}</span>
        </div>
      ) : null}

      {!loading && !loadError ? (
        <>
          {/* Advanced errors print once inside the disclosure, never twice behind the top banner. */}
          {saveError && !isBashAdvancedError(saveError) ? (
            <div className="error-banner" data-testid="bash-error">
              <AlertTriangleIcon size={16} />
              <span>{saveError}</span>
            </div>
          ) : null}

          {saved ? (
            <div data-testid="bash-saved" className="settings-save-success">
              Bash settings saved. Changes apply immediately with no restart.
            </div>
          ) : null}

          <p className="muted text-sm bash-intro-note">
            Rules evaluate top-to-bottom last-match-wins; the default action applies
            when nothing matches. Default working directory is the engine home with an
            optional per-call override inside allowed roots, confined by the execution
            tier below.
          </p>

          <div className="form-group mb-3">
            <label htmlFor="bash-default-action" className="text-sm">Default action</label>
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

          <p className="muted text-sm mb-3" data-testid="bash-confinement-summary">
            Execution tier: {BASH_SANDBOX_TIERS.find((tier) => tier.value === effectiveSandboxMode)?.label ?? effectiveSandboxMode}. {bashSandboxSummary(effectiveSandboxMode, allowNetwork)} Host allow patterns: {effectiveHostPatternCount} configured. Edit both in Advanced Bash settings below.
          </p>

          <div className="settings-subsection-header access-subsection-spaced-md">
            <div className="settings-section-title-group">
              <h4 className="access-subsection-heading">Rules</h4>
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
          <div className="form-group mt-2">
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

          <div className="form-group checkbox-group">
            <SwitchControl
              testId="bash-allow-network"
              checked={allowNetwork}
              onChange={(e) => handleAllowNetworkChange(e.target.checked)}
              label="Allow network access"
              hint="Allow network access"
            />
            <span className="form-group-hint">
              When on, sandboxed commands may reach the network; otherwise they run isolated.
            </span>
          </div>

          <AdvancedDisclosure
            tabName="Bash"
            open={unifiedOpen}
            onOpenChange={unifiedSetOpen}
            testId="advanced-bash"
            validationError={unifiedValidationError}
            errorKeywords={[...BASH_ADVANCED_ERROR_KEYWORDS]}
            onReset={unifiedReset}
          >
            {advanced?.loading ? (
              <p className="muted text-sm" data-testid="advanced-bash-loading">Loading advanced bash settings…</p>
            ) : null}
            {advanced?.loadError ? (
              <div className="error-banner" data-testid="advanced-bash-load-error">
                <AlertTriangleIcon size={16} />
                <span>{advanced.loadError}</span>
              </div>
            ) : null}
            {!advanced || (!advanced.loading && !advanced.loadError) ? (
              <>
                <BashTuningFields
                  timeoutSeconds={advanced ? advanced.timeoutSeconds : timeoutSeconds}
                  cpuSeconds={advanced ? advanced.cpuSeconds : cpuSeconds}
                  memoryMB={advanced ? advanced.memoryMB : memoryMB}
                  onTimeoutChange={advanced ? advanced.handleTimeoutChange : handleTimeoutChange}
                  onCpuChange={advanced ? advanced.handleCpuChange : handleCpuSecondsChange}
                  onMemoryChange={advanced ? advanced.handleMemoryChange : handleMemoryMBChange}
                  idPrefix={advanced ? "adv-bash" : "bash"}
                />
                <BashConfinementFields
                  idPrefix={advanced ? "adv-bash" : "bash"}
                  sandboxMode={advanced ? advanced.sandboxMode : sandboxMode}
                  allowNetwork={allowNetwork}
                  hostAllowPatternsText={advanced ? advanced.hostAllowPatternsText : hostAllowPatternsText}
                  onSandboxModeChange={advanced ? advanced.handleSandboxModeChange : handleSandboxModeChange}
                  onHostAllowPatternsChange={advanced ? advanced.handleHostAllowPatternsChange : handleHostAllowPatternsChange}
                />
              </>
            ) : null}
          </AdvancedDisclosure>

          <div className="settings-footer">
            <span className="muted text-sm" data-testid="bash-save-hint">
              {changed || advancedChanged
                ? "Unsaved changes: only the edited keys travel in the bash patch."
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
