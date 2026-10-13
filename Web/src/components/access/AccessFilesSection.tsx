// Rune Weaver Dashboard — File write-posture section of the owner configuration surface.
//
// Purpose: Owns `[files] write_mode` plus the ordered `[files]
// write_path_rules` table as one settings surface.
// `WritePathPolicy.classify(path:filesConfig:)` stays the single evaluator of
// every posture resolved from what is saved here, so no precedence, glob, or
// path-canonicalization logic lives in this file — it records owner intent only.
// Scope: Loading the [files] write snapshot, inline fail-closed editing with
// the rule-count and path-length bounds enforced before the wire, and
// persisting one changed-only patch through PUT /settings. Allow roots, deny
// patterns, and approval-on-deny stay with the Files & Access editor; tool
// enablement stays with the tool toggle.
// Architectural role: settings-adjacent surface rendered outside the shared
// config form, mirroring the bash and policy panel precedents. Write posture
// applies live through the engine with no restart and no filesystem watcher, so
// the saved banner never promises a restart.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  getSettings,
  updateSettings,
  type SettingsResponse,
  type UpdateSettingsInput,
} from "../../api";
import { AlertTriangleIcon, PlusIcon, TrashIcon } from "../icons";

// Closed write-mode vocabulary for files.write ([files] write_mode). The engine
// stays the validator of record: it rejects anything outside this set, so the
// editor only ever surfaces these three postures and a drifted loaded value
// normalizes back to the model posture.
type FilesWriteMode = "model" | "staged" | "live";

const FILES_WRITE_MODES: readonly FilesWriteMode[] = ["model", "staged", "live"];
const DEFAULT_FILES_WRITE_MODE: FilesWriteMode = "model";

// Closed per-path posture vocabulary ([files] write_path_rules.posture). Ask
// parks an approval request, stage and live execute with no request filed, and
// deny refuses outright.
type FilesWritePosture = "live" | "stage" | "ask" | "deny";

const FILES_WRITE_POSTURES: readonly FilesWritePosture[] = [
  "live",
  "stage",
  "ask",
  "deny",
];

// Largest rule list the write-path table may carry, mirroring
// `FilesWritePathRule.maxRuleCount`.
const FILES_WRITE_PATH_RULE_MAX_COUNT = 50;
// Longest path one rule may carry, mirroring `FilesWritePathRule.maxPathLength`.
const FILES_WRITE_PATH_RULE_MAX_PATH_CHARS = 1024;

interface FilesWriteModeOption {
  value: FilesWriteMode;
  label: string;
  description: string;
}

// Option copy explains the enforcement each posture applies, pinned to the
// engine contract: `model` keeps per-call mode selection with an omitted mode
// defaulting to staged review, `staged` forces every write through Staged
// Changes, and `live` writes immediately leaving a `.rune_backup_` rollback copy.
const FILES_WRITE_MODE_OPTIONS: readonly FilesWriteModeOption[] = [
  {
    value: "model",
    label: "Let the model decide",
    description:
      "The agent picks staged or live per call; omitted mode defaults to staged review.",
  },
  {
    value: "staged",
    label: "Always stage for review",
    description:
      "Every write waits in Staged Changes; live writes are disabled.",
  },
  {
    value: "live",
    label: "Always write live",
    description:
      "Writes apply immediately with a .rune_backup_ rollback copy; review staging is disabled.",
  },
];

interface FilesWritePostureOption {
  value: FilesWritePosture;
  label: string;
  // What the posture does to a matching write, stated as the consequence the
  // owner is choosing rather than as a dictionary definition of the token.
  consequence: string;
}

const FILES_WRITE_POSTURE_OPTIONS: readonly FilesWritePostureOption[] = [
  {
    value: "live",
    label: "Live",
    consequence:
      "Writes apply immediately with a .rune_backup_ rollback copy; no approval request is filed.",
  },
  {
    value: "stage",
    label: "Stage",
    consequence:
      "Writes wait in Staged Changes for your decision; nothing lands without review.",
  },
  {
    value: "ask",
    label: "Ask",
    consequence:
      "Writes park an approval request before anything is written to disk.",
  },
  {
    value: "deny",
    label: "Deny",
    consequence:
      "Writes are refused outright, whatever the rest of the policy would allow.",
  },
];

// Mirror of `FilesWritePathRule.defaultRules`: the personal-data directories
// ask while the working directories stage, so the editor opens on the same
// boundary an engine that predates the rule list would apply.
const DEFAULT_FILES_WRITE_PATH_RULES: readonly WritePathRule[] = [
  { path: "~/Library", posture: "ask" },
  { path: "~/Photos", posture: "ask" },
  { path: "~/Documents", posture: "stage" },
  { path: "~/Desktop", posture: "stage" },
  { path: "~/Downloads", posture: "stage" },
];

// One row of the write-path table as the owner edits it. The path holds raw
// input (including surrounding whitespace and a blank half-typed row) so a
// cleared field surfaces a validation error instead of silently dropping.
interface WritePathRule {
  path: string;
  posture: FilesWritePosture;
}

// Last-loaded [files] write snapshot driving the changed-only patch: the mode
// and the rule list the owner never touches stay omitted so the stored values
// survive.
interface FilesWriteLoadedSnapshot {
  writeMode: FilesWriteMode;
  writePathRules: WritePathRule[];
}



// Normalizes a loaded or raw write-mode value into the closed editor
// vocabulary. Older engines omit the key and a hand-edited config can carry
// casing, so the editor falls back to the model posture rather than rendering
// an unknown selection.
function normalizeFilesWriteMode(value: unknown): FilesWriteMode {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  return (FILES_WRITE_MODES as readonly string[]).includes(normalized)
    ? (normalized as FilesWriteMode)
    : DEFAULT_FILES_WRITE_MODE;
}

// Normalizes one loaded posture into the closed set. An unknown or absent
// token fails closed to ask — the posture that parks an approval request —
// instead of silently widening write authority.
function normalizeFilesWritePosture(value: unknown): FilesWritePosture {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  return (FILES_WRITE_POSTURES as readonly string[]).includes(normalized)
    ? (normalized as FilesWritePosture)
    : "ask";
}

// Copies the loaded rule list into rows, tolerating both wire spellings of the
// posture and dropping entries with no usable path. An absent list keeps the
// documented defaults (an older engine, or a section the owner never wrote),
// while an explicit empty list stays empty because an owner who cleared every
// rule opted out of per-path postures.
function normalizeWritePathRules(raw: unknown): WritePathRule[] {
  if (!Array.isArray(raw)) {
    return DEFAULT_FILES_WRITE_PATH_RULES.map((rule) => ({ ...rule }));
  }
  const rules: WritePathRule[] = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as { path?: unknown; posture?: unknown };
    if (typeof record.path !== "string") continue;
    rules.push({
      path: record.path,
      posture: normalizeFilesWritePosture(record.posture),
    });
  }
  return rules;
}

// Reads the loaded rule list off one settings response.
function readLoadedWritePathRules(settings: SettingsResponse): WritePathRule[] {
  return normalizeWritePathRules(settings.filesWritePathRules);
}

// Canonicalizes a draft for dirty tracking and for the wire: the path trims
// and the posture stays in the closed set, so an edit that returns to the
// loaded shape reads clean instead of staying dirty on formatting alone.
function canonicalWritePathRules(rules: readonly WritePathRule[]): WritePathRule[] {
  return rules.map((rule) => ({
    path: rule.path.trim(),
    posture: rule.posture,
  }));
}

function writePathRulesEqual(
  left: readonly WritePathRule[],
  right: readonly WritePathRule[]
): boolean {
  if (left.length !== right.length) return false;
  return left.every(
    (rule, index) =>
      rule.path === right[index]?.path && rule.posture === right[index]?.posture
  );
}

// Consequence copy for one posture: what the owner is choosing happens to every
// matching write, stated once so a row, the select, and the help text agree.
export function writePostureConsequence(posture: string): string {
  const normalized = normalizeFilesWritePosture(posture);
  return (
    FILES_WRITE_POSTURE_OPTIONS.find((option) => option.value === normalized)
      ?.consequence ?? ""
  );
}

// Whether a rule path can ever match a write target. `WritePathPolicy` refuses a
// bare relative rule path because a boundary without a root could only match
// whatever directory the process stood in, so the form fails closed with the
// same shape instead of surfacing a server 400.
function isUsableRulePath(path: string): boolean {
  return path === "~" || path.startsWith("~/") || path.startsWith("/");
}

// Client-side validation mirrors the engine bounds so an over-limit rule count,
// a blank or overlong rule path, a relative rule path, an unknown posture, or an
// unknown mode fails in the form before any network write.
export function validateFilesWriteFields(
  writeMode: string,
  rules: readonly WritePathRule[]
): string | null {
  if (!(FILES_WRITE_MODES as readonly string[]).includes(writeMode)) {
    return "Invalid files write mode: must be model, staged, or live.";
  }
  if (rules.length > FILES_WRITE_PATH_RULE_MAX_COUNT) {
    return `Invalid write path rules: at most ${FILES_WRITE_PATH_RULE_MAX_COUNT} entries (got ${rules.length}).`;
  }
  for (let index = 0; index < rules.length; index += 1) {
    const rule = rules[index];
    const label = `Rule ${index + 1}`;
    const path = rule.path.trim();
    if (!path) {
      return `Invalid write path rule: ${label} path must not be blank.`;
    }
    if (path.length > FILES_WRITE_PATH_RULE_MAX_PATH_CHARS) {
      return `Invalid write path rule: ${label} path must be at most ${FILES_WRITE_PATH_RULE_MAX_PATH_CHARS} characters (got ${path.length}).`;
    }
    if (!isUsableRulePath(path)) {
      return `Invalid write path rule: ${label} path must be ~, start with ~/, or be an absolute path.`;
    }
    if (!(FILES_WRITE_POSTURES as readonly string[]).includes(rule.posture)) {
      return `Invalid write path rule: ${label} posture must be live, stage, ask, or deny.`;
    }
  }
  return null;
}

// Builds the changed-only [files] patch: a field matching its last-loaded value
// stays omitted so the stored value survives, and the mode plus the rule list
// travel together in one payload when both moved.
function buildFilesWritePatch(
  writeMode: FilesWriteMode,
  rules: readonly WritePathRule[],
  loaded: FilesWriteLoadedSnapshot
): UpdateSettingsInput {
  const patch: UpdateSettingsInput = {};
  if (writeMode !== loaded.writeMode) {
    patch.filesWriteMode = writeMode;
  }
  const canonical = canonicalWritePathRules(rules);
  if (!writePathRulesEqual(canonical, loaded.writePathRules)) {
    patch.filesWritePathRules = canonical.map((rule) => ({
      path: rule.path,
      posture: rule.posture,
    }));
  }
  return patch;
}

// File write-posture configuration for the settings Access surface. Keeps the
// single draft, the changed-only save, and the live-apply banner; the engine
// stays the sole evaluator of the posture a write actually takes.
export function AccessFilesSection() {
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [writeMode, setWriteMode] = useState<FilesWriteMode>(
    DEFAULT_FILES_WRITE_MODE
  );
  const [rules, setRules] = useState<WritePathRule[]>(
    DEFAULT_FILES_WRITE_PATH_RULES.map((rule) => ({ ...rule }))
  );
  const [saved, setSaved] = useState(false);
  const [saveLoading, setSaveLoading] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const loadedRef = useRef<FilesWriteLoadedSnapshot>({
    writeMode: DEFAULT_FILES_WRITE_MODE,
    writePathRules: DEFAULT_FILES_WRITE_PATH_RULES.map((rule) => ({ ...rule })),
  });

  const canonicalRules = canonicalWritePathRules(rules);
  const changed =
    writeMode !== loadedRef.current.writeMode ||
    !writePathRulesEqual(canonicalRules, loadedRef.current.writePathRules);

  // Copies one loaded snapshot into both editors at once, then reseeds the
  // loaded ref and the dirty comparison from that same snapshot. Deriving both
  // from one freshly built draft keeps the next changed-only patch honest
  // instead of comparing against state that has not re-rendered yet.
  const applyLoadedConfig = useCallback((settings: SettingsResponse | null | undefined) => {
    if (!settings) return;
    const nextMode = normalizeFilesWriteMode(settings.filesWriteMode);
    const nextRules = readLoadedWritePathRules(settings);
    loadedRef.current = { writeMode: nextMode, writePathRules: nextRules };
    setWriteMode(nextMode);
    setRules(nextRules.map((rule) => ({ ...rule })));
    setSaved(false);
  }, []);

  const loadFilesWriteSettings = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      applyLoadedConfig(await getSettings());
    } catch (err: unknown) {
      setLoadError(
        err instanceof ApiError
          ? err.message
          : "Failed to load file write settings."
      );
    } finally {
      setLoading(false);
    }
  }, [applyLoadedConfig]);

  useEffect(() => {
    void loadFilesWriteSettings();
  }, [loadFilesWriteSettings]);

  // Any edit clears the saved confirmation so a stale success never reads as
  // covering the current draft.
  function markEdited() {
    setSaved(false);
  }

  function handleWriteModeChange(next: string) {
    setWriteMode(normalizeFilesWriteMode(next));
    markEdited();
  }

  function handleRulePathChange(index: number, raw: string) {
    setRules((prev) =>
      prev.map((rule, position) =>
        position === index ? { ...rule, path: raw } : rule
      )
    );
    markEdited();
  }

  // A deny row never softens from here: the select locks so the only posture a
  // loaded deny rule offers is deny. Removing the row stays an explicit, visible
  // edit rather than a one-way door that would strand a mistyped path forever.
  function handleRulePostureChange(index: number, next: string) {
    setRules((prev) =>
      prev.map((rule, position) =>
        position === index
          ? { ...rule, posture: normalizeFilesWritePosture(next) }
          : rule
      )
    );
    markEdited();
  }

  function handleRemoveRule(index: number) {
    setRules((prev) => prev.filter((_, position) => position !== index));
    markEdited();
  }

  // A fresh row starts at the approval posture so a half-typed path never
  // widens write authority while the owner is still entering it.
  function handleAddRule() {
    setRules((prev) => [...prev, { path: "", posture: "ask" }]);
    markEdited();
  }

  // Saves the changed-only [files] patch through PUT /settings. Only the edited
  // keys travel, and the mode plus the rule list ride one payload. Client
  // validation reports inline without closing while a server 400 lands in the
  // error path without discarding the draft. Posture applies live, so success
  // shows the saved banner with no restart banner.
  const handleSave = async (): Promise<void> => {
    const validationError = validateFilesWriteFields(writeMode, rules);
    if (validationError) {
      setSaveError(validationError);
      return;
    }
    setSaveLoading(true);
    setSaveError(null);
    try {
      const updated = await updateSettings(
        buildFilesWritePatch(writeMode, rules, loadedRef.current)
      );
      // Repopulate first so the accepted snapshot re-seeds both the loaded ref
      // and the dirty comparison; the banner then flips on after it, because
      // the repopulate clears the flag for the plain load path.
      applyLoadedConfig(updated);
      setSaved(true);
    } catch (err: unknown) {
      setSaveError(
        err instanceof ApiError
          ? err.message
          : "Failed to save file write settings"
      );
    } finally {
      setSaveLoading(false);
    }
  };

  const atRuleBound = rules.length >= FILES_WRITE_PATH_RULE_MAX_COUNT;

  return (
    <section
      className="settings-section card"
      aria-label="File Write Posture"
      data-testid="files-write-pane"
    >
      <div className="settings-section-title-group">
        <h3>File Write Posture</h3>
        <p className="settings-section-hint">
          Choose how every <code>files.write</code> lands and which paths take
          which posture. Changes apply immediately with no restart.
        </p>
      </div>

      {loading ? (
        <p className="muted text-sm" data-testid="files-write-loading">
          Loading file write settings…
        </p>
      ) : null}

      {loadError ? (
        <div
          className="error-banner"
          data-testid="files-write-load-error"
          style={{ marginBottom: "12px" }}
        >
          <AlertTriangleIcon size={16} />
          <span>{loadError}</span>
        </div>
      ) : null}

      {!loading && !loadError ? (
        <>
          {saveError ? (
            <div
              className="error-banner"
              data-testid="files-write-error"
              style={{ marginBottom: "12px" }}
            >
              <AlertTriangleIcon size={16} />
              <span>{saveError}</span>
            </div>
          ) : null}

          {saved ? (
            <div
              data-testid="files-write-saved"
              style={{
                padding: "8px 12px",
                borderRadius: "6px",
                backgroundColor: "rgba(16, 185, 129, 0.15)",
                color: "#10b981",
                fontSize: "0.85rem",
                marginBottom: "12px",
              }}
            >
              File write settings saved. Changes apply immediately with no
              restart.
            </div>
          ) : null}

          <p className="muted text-sm" style={{ marginBottom: "16px" }} data-testid="files-write-precedence">
            Deny patterns refuse first. The longest matching write-path rule
            below decides next — a rule covers its path and everything inside it,
            so a deeper rule outranks a broader one. Otherwise the write mode
            above applies inside the allowed roots, and a path outside every
            allowed root asks.
          </p>

          {/* The radio group surfaces only the closed model|staged|live set;
              the engine re-validates the same vocabulary on save. */}
          <div
            className="form-group"
            role="radiogroup"
            aria-label="Files write mode"
            style={{ marginBottom: "12px" }}
          >
            {FILES_WRITE_MODE_OPTIONS.map((option) => (
              <label
                key={option.value}
                className="toggle-label"
                style={{
                  display: "flex",
                  alignItems: "flex-start",
                  gap: "8px",
                  marginBottom: "10px",
                  cursor: "pointer",
                }}
              >
                <input
                  type="radio"
                  name="filesWriteMode"
                  value={option.value}
                  checked={writeMode === option.value}
                  onChange={() => handleWriteModeChange(option.value)}
                />
                <span style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
                  <span>{option.label}</span>
                  <span className="muted text-sm">{option.description}</span>
                </span>
              </label>
            ))}
          </div>

          <div className="settings-subsection-header" style={{ marginTop: "16px" }}>
            <div className="settings-section-title-group">
              <h4 style={{ margin: "0 0 4px 0" }}>Write Path Rules</h4>
              <p className="settings-section-hint">
                One path per row. The longest matching rule wins; a path outside
                every allow root asks.
              </p>
            </div>
            <div className="row">
              <button
                type="button"
                className="ghost icon-text-btn"
                onClick={handleAddRule}
                disabled={atRuleBound}
              >
                <PlusIcon size={14} />
                <span>Add Rule</span>
              </button>
            </div>
          </div>

          <span className="form-group-hint" data-testid="files-write-rules-bounds">
            Up to {FILES_WRITE_PATH_RULE_MAX_COUNT} rules, each path up to{" "}
            {FILES_WRITE_PATH_RULE_MAX_PATH_CHARS} characters.{" "}
            <span className="muted text-sm">
              ({rules.length} {rules.length === 1 ? "rule" : "rules"})
            </span>
          </span>

          {rules.length === 0 ? (
            <p className="muted text-sm" style={{ marginTop: "12px" }}>
              No write-path rules. Every write falls through to the mode above,
              and anything outside the allowed roots asks.
            </p>
          ) : null}

          {rules.map((rule, index) => {
            const ruleNumber = index + 1;
            const pathId = `files-write-rule-path-${index}`;
            const postureId = `files-write-rule-posture-${index}`;
            const locked = rule.posture === "deny";
            return (
              <div
                key={`files-write-rule-${index}`}
                data-testid={`files-write-rule-${index}`}
                style={{
                  display: "flex",
                  gap: "8px",
                  alignItems: "flex-start",
                  marginTop: "12px",
                }}
              >
                <div style={{ flex: 1, minWidth: 0 }}>
                  <label htmlFor={pathId} style={{ fontSize: "0.82rem" }}>
                    Rule {ruleNumber} path
                  </label>
                  <input
                    id={pathId}
                    className="input-field"
                    value={rule.path}
                    onChange={(e) => handleRulePathChange(index, e.target.value)}
                    placeholder="~/Documents/Secrets"
                  />
                </div>
                <div style={{ width: "140px", flexShrink: 0 }}>
                  <label htmlFor={postureId} style={{ fontSize: "0.82rem" }}>
                    Rule {ruleNumber} posture
                  </label>
                  <select
                    id={postureId}
                    className="input-field"
                    value={rule.posture}
                    onChange={(e) =>
                      handleRulePostureChange(index, e.target.value)
                    }
                    disabled={locked}
                    title={locked ? "A deny rule cannot be softened here" : undefined}
                  >
                    {FILES_WRITE_POSTURE_OPTIONS.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                </div>
                <button
                  type="button"
                  className="icon-button"
                  aria-label={`Remove rule ${ruleNumber}`}
                  data-testid={`files-write-rule-${index}-remove`}
                  onClick={() => handleRemoveRule(index)}
                  title={`Remove rule ${ruleNumber}`}
                >
                  <TrashIcon size={14} />
                </button>
                <span
                  className="form-group-hint"
                  data-testid={`files-write-rule-${index}-consequence`}
                  style={{ flexBasis: "100%" }}
                >
                  {writePostureConsequence(rule.posture)}
                  {locked ? (
                    <span data-testid={`files-write-rule-${index}-lock`}>
                      {" "}
                      Deny is locked: this refusal can be widened only by
                      removing the rule.
                    </span>
                  ) : null}
                </span>
              </div>
            );
          })}

          <div className="settings-footer">
            <span className="muted text-sm" data-testid="files-write-save-hint">
              {changed
                ? "Unsaved changes — only the edited keys travel in the files patch."
                : "Only the edited keys travel; every untouched value survives."}
            </span>
            <button
              type="button"
              className="primary-button save-button"
              data-testid="files-write-save"
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

export default AccessFilesSection;
