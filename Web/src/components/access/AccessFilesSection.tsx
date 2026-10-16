// Rune Weaver Dashboard — File write-posture section of the owner configuration surface.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS,
  DEFAULT_FILES_DENY_PATTERNS_TEXT,
  formatAllowRootsText,
  formatDenyPatternsText,
  parseAllowRootsText,
  parseDenyPatternsText,
  getSettings,
  updateSettings,
  type SettingsResponse,
  type UpdateSettingsInput,
} from "../../api";
import { AlertTriangleIcon, CloseIcon, PlusIcon, RefreshIcon, TrashIcon } from "../icons";
import Modal from "../Modal";

// Closed write-mode vocabulary for files.write ([files] write_mode).
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

// Option copy explains the enforcement each posture applies, pinned to the engine contract: `model`
// keeps per-call mode selection with an omitted mode defaulting to staged review, `staged` forces
// every write through Staged Changes, and `live` writes immediately leaving a `.rune_backup_`.
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

// Last-loaded [files] snapshot driving the changed-only patch: mode, rules,
// deny patterns, allow roots, and approval on deny.
interface FilesLoadedSnapshot {
  writeMode: FilesWriteMode;
  writePathRules: WritePathRule[];
  denyPatternsText: string;
  allowRootsText: string;
  requireApprovalOnDeny: boolean;
}

// Validates deny patterns and allowed roots boundaries before save.
export function validateFilesBoundaryFields(
  denyText: string,
  allowRootsText: string
): string | null {
  const denyLines = denyText.split("\n");
  for (let lineIndex = 0; lineIndex < denyLines.length; lineIndex += 1) {
    const trimmed = denyLines[lineIndex].trim();
    if (!trimmed) continue;
    if (trimmed.includes("..")) {
      return `Line ${lineIndex + 1}: Deny pattern must not contain '..': "${trimmed}".`;
    }
  }
  const allowLines = allowRootsText.split("\n");
  for (let lineIndex = 0; lineIndex < allowLines.length; lineIndex += 1) {
    const trimmed = allowLines[lineIndex].trim();
    if (!trimmed) continue;
    if (trimmed.includes("..")) {
      return `Line ${lineIndex + 1}: Allowed root must not contain '..': "${trimmed}".`;
    }
  }
  if (parseAllowRootsText(allowRootsText).length === 0) {
    return "Allowed roots cannot be empty.";
  }
  return null;
}



// Normalizes a loaded or raw write-mode value into the closed editor vocabulary.
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

// Copies the loaded rule list into rows, tolerating both wire spellings of the posture and dropping
// entries with no usable path.
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

// Whether a rule path can ever match a write target.
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
  loaded: FilesLoadedSnapshot
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

// File access and write-posture configuration for the settings Access surface. Keeps the
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
  const [filesDenyText, setFilesDenyText] = useState<string>(
    DEFAULT_FILES_DENY_PATTERNS_TEXT
  );
  const [filesAllowRootsText, setFilesAllowRootsText] = useState<string>(
    formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS)
  );
  const [filesRequireApprovalOnDeny, setFilesRequireApprovalOnDeny] =
    useState<boolean>(true);
  const [pendingResetDeny, setPendingResetDeny] = useState<boolean>(false);
  const [pendingResetRoots, setPendingResetRoots] = useState<boolean>(false);

  const [saved, setSaved] = useState(false);
  const [saveLoading, setSaveLoading] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const loadedRef = useRef<FilesLoadedSnapshot>({
    writeMode: DEFAULT_FILES_WRITE_MODE,
    writePathRules: DEFAULT_FILES_WRITE_PATH_RULES.map((rule) => ({ ...rule })),
    denyPatternsText: DEFAULT_FILES_DENY_PATTERNS_TEXT,
    allowRootsText: formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS),
    requireApprovalOnDeny: true,
  });

  const denyPatternCount = parseDenyPatternsText(filesDenyText).length;
  const allowRootsCount = parseAllowRootsText(filesAllowRootsText).length;

  const canonicalRules = canonicalWritePathRules(rules);
  const changed =
    writeMode !== loadedRef.current.writeMode ||
    !writePathRulesEqual(canonicalRules, loadedRef.current.writePathRules) ||
    filesDenyText !== loadedRef.current.denyPatternsText ||
    filesAllowRootsText !== loadedRef.current.allowRootsText ||
    filesRequireApprovalOnDeny !== loadedRef.current.requireApprovalOnDeny;

  // Copies one loaded snapshot into both editors at once, then reseeds the loaded ref and the dirty
  // comparison from that same snapshot.
  const applyLoadedConfig = useCallback((settings: SettingsResponse | null | undefined) => {
    if (!settings) return;
    const nextMode = normalizeFilesWriteMode(settings.filesWriteMode);
    const nextRules = readLoadedWritePathRules(settings);
    const nextDenyText = Array.isArray(settings.filesDenyPatterns)
      ? formatDenyPatternsText(settings.filesDenyPatterns)
      : DEFAULT_FILES_DENY_PATTERNS_TEXT;
    const nextAllowRootsText = Array.isArray(settings.filesAllowRoots)
      ? formatAllowRootsText(settings.filesAllowRoots)
      : formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS);
    const nextApprovalOnDeny = settings.filesRequireApprovalOnDeny ?? true;

    loadedRef.current = {
      writeMode: nextMode,
      writePathRules: nextRules,
      denyPatternsText: nextDenyText,
      allowRootsText: nextAllowRootsText,
      requireApprovalOnDeny: nextApprovalOnDeny,
    };
    setWriteMode(nextMode);
    setRules(nextRules.map((rule) => ({ ...rule })));
    setFilesDenyText(nextDenyText);
    setFilesAllowRootsText(nextAllowRootsText);
    setFilesRequireApprovalOnDeny(nextApprovalOnDeny);
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
          : "Failed to load file settings."
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

  // Saves the changed-only [files] patch through PUT /settings. Only the edited keys travel, and
  // the mode plus the rule list ride one payload.
  const handleSave = async (): Promise<void> => {
    const boundaryError = validateFilesBoundaryFields(filesDenyText, filesAllowRootsText);
    if (boundaryError) {
      setSaveError(boundaryError);
      return;
    }
    const validationError = validateFilesWriteFields(writeMode, rules);
    if (validationError) {
      setSaveError(validationError);
      return;
    }
    setSaveLoading(true);
    setSaveError(null);
    try {
      const patch = buildFilesWritePatch(writeMode, rules, loadedRef.current);
      if (filesDenyText !== loadedRef.current.denyPatternsText) {
        patch.filesDenyPatterns = parseDenyPatternsText(filesDenyText);
      }
      if (filesAllowRootsText !== loadedRef.current.allowRootsText) {
        patch.filesAllowRoots = parseAllowRootsText(filesAllowRootsText);
      }
      if (filesRequireApprovalOnDeny !== loadedRef.current.requireApprovalOnDeny) {
        patch.filesRequireApprovalOnDeny = filesRequireApprovalOnDeny;
      }
      const updated = await updateSettings(patch);
      // Repopulate first so the accepted snapshot re-seeds both the loaded ref
      // and the dirty comparison; the banner then flips on after it, because
      // the repopulate clears the flag for the plain load path.
      applyLoadedConfig(updated);
      setSaved(true);
    } catch (err: unknown) {
      setSaveError(
        err instanceof ApiError
          ? err.message
          : "Failed to save file settings"
      );
    } finally {
      setSaveLoading(false);
    }
  };

  const atRuleBound = rules.length >= FILES_WRITE_PATH_RULE_MAX_COUNT;

  return (
    <div className="access-files-pane" data-testid="files-pane">
      {/* SECTION 1: Files & Access */}
      <section
        className="settings-section card"
        aria-label="Files & Access"
        data-testid="files-access-pane"
        style={{ marginBottom: "20px" }}
      >
        <div className="settings-section-title-group">
          <h3>Files & Access</h3>
          <p className="settings-section-hint">
            Allow roots bound file tools, email attachment saves, bash working directories, and staged-file review: those surfaces can only reach paths inside the allowed roots. Denied paths are skipped everywhere including the document index, while allow roots do not affect index coverage.
          </p>
          <p className="settings-section-hint">
            This is the system-boundary allowed-roots and blocked-paths surface in
            Access → Files. Fine-grained write-path posture (Stage, Ask,
            Live, Deny per path) lives in Access → Files below.
          </p>
        </div>

        <div className="settings-subsection-header">
          <div className="settings-section-title-group">
            <h4 style={{ margin: "0 0 4px 0" }}>Blocked Paths</h4>
            <p className="settings-section-hint">
              One glob per line. Denied paths escalate or fail per the toggle below.
            </p>
          </div>
          <div className="row">
            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={() => setPendingResetDeny(true)}
            >
              <RefreshIcon size={14} />
              <span>Reset to Defaults</span>
            </button>
          </div>
        </div>

        <div className="form-group" style={{ marginTop: "8px" }}>
          <label htmlFor="deny-patterns-textarea">
            Deny patterns{" "}
            <span className="muted text-sm">
              ({denyPatternCount} {denyPatternCount === 1 ? "pattern" : "patterns"})
            </span>
          </label>
          <textarea
            id="deny-patterns-textarea"
            className="input-field deny-patterns-textarea"
            aria-label="Deny patterns, one per line"
            value={filesDenyText}
            onChange={(e) => {
              setFilesDenyText(e.target.value);
              markEdited();
            }}
            placeholder="e.g. .env*, *.pem, .ssh/*"
            rows={8}
          />
          <span className="form-group-hint">
            Glob-like patterns: `*` matches within a name, directory prefixes like
            `.ssh/*` guard a whole subtree. `..` escapes are rejected with line
            numbers; blank lines are ignored.
          </span>
          {denyPatternCount === 0 && (
            <span className="form-group-hint">
              No deny patterns configured. File tools will allow all in-scope paths.
            </span>
          )}
        </div>

        <div className="settings-subsection-header" style={{ marginTop: "20px" }}>
          <div className="settings-section-title-group">
            <h4 style={{ margin: "0 0 4px 0" }}>Allowed Roots</h4>
            <p className="settings-section-hint">
              Home containment boundary (`~` expands to the home directory). Paths outside
              these roots escalate to approval.
            </p>
          </div>
          <div className="row">
            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={() => setPendingResetRoots(true)}
            >
              <RefreshIcon size={14} />
              <span>Reset Roots</span>
            </button>
          </div>
        </div>

        <div className="form-group" style={{ marginTop: "8px" }}>
          <label htmlFor="allow-roots-textarea">
            Allowed roots, one per line{" "}
            <span className="muted text-sm">
              ({allowRootsCount} {allowRootsCount === 1 ? "root" : "roots"})
            </span>
          </label>
          <textarea
            id="allow-roots-textarea"
            className="input-field allow-roots-textarea"
            aria-label="Allowed roots, one per line"
            value={filesAllowRootsText}
            onChange={(e) => {
              setFilesAllowRootsText(e.target.value);
              markEdited();
            }}
            placeholder="e.g. ~"
            rows={6}
          />
          <span className="form-group-hint">
            One root per line. `~` expands to the home directory for home containment.
            Blank lines are ignored. Order is display-only and never changes the access decision.
          </span>
        </div>

        <div className="form-group checkbox-group" style={{ marginTop: "16px" }}>
          <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
            <input
              id="files-require-approval"
              type="checkbox"
              checked={filesRequireApprovalOnDeny}
              onChange={(e) => {
                setFilesRequireApprovalOnDeny(e.target.checked);
                markEdited();
              }}
            />
            <span>Require approval on deny</span>
          </label>
          <span className="form-group-hint">
            When on, denied paths escalate to the approvals inbox instead of failing silently.
          </span>
        </div>
      </section>

      {/* SECTION 2: File Write Posture */}
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
          <p className="settings-section-hint">
            This is the fine-grained write-path posture surface in Access → Files.
            System-boundary allowed roots and blocked paths live
            in Access → Files above.
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

          <div className="files-explainer-card" data-testid="files-write-explainer">
            <h5>About Write Path Rules</h5>
            <p>
              Write path rules define folder-specific write postures, overriding the global write mode above for matching directories. The longest matching path wins:
            </p>
            <ul>
              <li><strong>Stage</strong>: Writes wait in Staged Changes for your review; no prompt needed.</li>
              <li><strong>Ask</strong>: Parks an approval request in your Inbox before anything is written.</li>
              <li><strong>Live</strong>: Writes directly to disk with an automatic rollback backup.</li>
              <li><strong>Deny</strong>: Refuses writes outright. Deny rules are locked for safety.</li>
            </ul>
            <p className="muted text-sm" style={{ marginBottom: 0 }}>
              Deny outranks every other posture and persists until the rule is removed.
            </p>
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

          {rules.length > 0 ? (
            <div
              className="files-write-table-wrapper"
              data-testid="files-write-table-scroll"
              style={{ maxHeight: "320px", overflowY: "auto" }}
            >
              <table className="files-write-table" data-testid="files-write-rules-table">
                <thead style={{ position: "sticky", top: 0, zIndex: 1 }}>
                  <tr>
                    <th style={{ width: "35%", position: "sticky", top: 0 }}>Path</th>
                    <th style={{ width: "160px", position: "sticky", top: 0 }}>Posture</th>
                    <th style={{ position: "sticky", top: 0 }}>Consequence</th>
                    <th style={{ width: "50px", textAlign: "center", position: "sticky", top: 0 }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {rules.map((rule, index) => {
                    const ruleNumber = index + 1;
                    const pathId = `files-write-rule-path-${index}`;
                    const postureId = `files-write-rule-posture-${index}`;
                    const locked = rule.posture === "deny";
                    return (
                      <tr
                        key={`files-write-rule-${index}`}
                        data-testid={`files-write-rule-${index}`}
                      >
                        <td>
                          <input
                            id={pathId}
                            aria-label={`Rule ${ruleNumber} path`}
                            className="input-field"
                            value={rule.path}
                            onChange={(e) => handleRulePathChange(index, e.target.value)}
                            placeholder="~/Documents/Secrets"
                            style={{ margin: 0, width: "100%" }}
                          />
                        </td>
                        <td>
                          <select
                            id={postureId}
                            aria-label={`Rule ${ruleNumber} posture`}
                            className="input-field"
                            value={rule.posture}
                            onChange={(e) =>
                              handleRulePostureChange(index, e.target.value)
                            }
                            disabled={locked}
                            title={locked ? "A deny rule cannot be softened here" : undefined}
                            style={{ margin: 0, width: "100%" }}
                          >
                            {FILES_WRITE_POSTURE_OPTIONS.map((option) => (
                              <option key={option.value} value={option.value}>
                                {option.label}
                              </option>
                            ))}
                          </select>
                        </td>
                        <td>
                          <span
                            className="form-group-hint"
                            data-testid={`files-write-rule-${index}-consequence`}
                            style={{ margin: 0, display: "inline-block" }}
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
                        </td>
                        <td style={{ textAlign: "center" }}>
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
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : null}

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

      {pendingResetDeny ? (
        <Modal
          label="Confirm reset deny patterns"
          onClose={() => setPendingResetDeny(false)}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Reset deny patterns?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setPendingResetDeny(false)}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will replace {denyPatternCount}{" "}
              {denyPatternCount === 1 ? "custom pattern" : "custom patterns"} with{" "}
              {DEFAULT_FILES_DENY_PATTERNS.length} defaults. This only updates the
              form — nothing is saved until you choose Save.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setPendingResetDeny(false)}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => {
                setFilesDenyText(DEFAULT_FILES_DENY_PATTERNS_TEXT);
                setPendingResetDeny(false);
                markEdited();
              }}
              aria-label="Confirm reset deny patterns"
            >
              Reset to Defaults
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingResetRoots ? (
        <Modal
          label="Confirm reset allowed roots"
          onClose={() => setPendingResetRoots(false)}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Reset allowed roots?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setPendingResetRoots(false)}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will replace {allowRootsCount}{" "}
              {allowRootsCount === 1 ? "custom root" : "custom roots"} with{" "}
              {DEFAULT_FILES_ALLOW_ROOTS.length}{" "}
              {DEFAULT_FILES_ALLOW_ROOTS.length === 1 ? "default" : "defaults"} (
              {DEFAULT_FILES_ALLOW_ROOTS.join(", ")}). This only updates the form —
              nothing is saved until you choose Save.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setPendingResetRoots(false)}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => {
                setFilesAllowRootsText(formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS));
                setPendingResetRoots(false);
                markEdited();
              }}
              aria-label="Confirm reset allowed roots"
            >
              Reset Roots
            </button>
          </div>
        </Modal>
      ) : null}
    </div>
  );
}

export default AccessFilesSection;
