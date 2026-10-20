// Rune Weaver Dashboard — Files write-posture normalization, validation, and patch helpers.
import {
  parseAllowRootsText,
  type SettingsResponse,
  type UpdateSettingsInput,
} from "../../api";
import {
  DEFAULT_FILES_WRITE_PATH_RULES,
  normalizeFilesWritePosture,
  normalizeWritePathRules,
  writePathRulesDiffer,
  type AdvancedWritePathRule,
  type FilesWritePosture,
} from "../settings/settingsAdvancedCounts";

// Closed write-mode vocabulary for files.write ([files] write_mode).
export type FilesWriteMode = "model" | "staged" | "live";

export const FILES_WRITE_MODES: readonly FilesWriteMode[] = [
  "model",
  "staged",
  "live",
];
export const DEFAULT_FILES_WRITE_MODE: FilesWriteMode = "model";

export { normalizeFilesWritePosture };
export type { FilesWritePosture };

// Closed per-path posture vocabulary ([files] write_path_rules.posture). Ask
// parks an approval request, stage and live execute with no request filed, and
// deny refuses outright.
export const FILES_WRITE_POSTURES: readonly FilesWritePosture[] = [
  "live",
  "stage",
  "ask",
  "deny",
];

// Largest rule list the write-path table may carry, mirroring
// `FilesWritePathRule.maxRuleCount`.
export const FILES_WRITE_PATH_RULE_MAX_COUNT = 50;
// Longest path one rule may carry, mirroring `FilesWritePathRule.maxPathLength`.
export const FILES_WRITE_PATH_RULE_MAX_PATH_CHARS = 1024;

interface FilesWriteModeOption {
  value: FilesWriteMode;
  label: string;
  description: string;
}

// Option copy explains the enforcement each posture applies, pinned to the engine contract: `model`
// keeps per-call mode selection with an omitted mode defaulting to staged review, `staged` forces
// every write through Staged Changes, and `live` writes immediately leaving a `.rune_backup_`.
export const FILES_WRITE_MODE_OPTIONS: readonly FilesWriteModeOption[] = [
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

export const FILES_WRITE_POSTURE_OPTIONS: readonly FilesWritePostureOption[] = [
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

// One row of the write-path table as the owner edits it. The path holds raw
// input (including surrounding whitespace and a blank half-typed row) so a
// cleared field surfaces a validation error instead of silently dropping.
export type WritePathRule = AdvancedWritePathRule;

// Last-loaded [files] snapshot driving the changed-only patch: mode, rules,
// deny patterns, allow roots, and approval on deny.
export interface FilesLoadedSnapshot {
  writeMode: FilesWriteMode;
  writePathRules: WritePathRule[];
  denyPatternsText: string;
  allowRootsText: string;
  requireApprovalOnDeny: boolean;
}

// Normalizes a loaded or raw write-mode value into the closed editor vocabulary.
export function normalizeFilesWriteMode(value: unknown): FilesWriteMode {
  const normalized =
    typeof value === "string" ? value.trim().toLowerCase() : "";
  return (FILES_WRITE_MODES as readonly string[]).includes(normalized)
    ? (normalized as FilesWriteMode)
    : DEFAULT_FILES_WRITE_MODE;
}

// Copies the typed defaults into editable rows.
export function defaultFilesWritePathRules(): WritePathRule[] {
  return DEFAULT_FILES_WRITE_PATH_RULES.map((rule) => ({ ...rule }));
}

// Reads the loaded rule list off one settings response. An absent section keeps
// the guard defaults; an explicitly empty list stays empty.
export function readLoadedWritePathRules(settings: SettingsResponse): WritePathRule[] {
  if (!Array.isArray(settings.filesWritePathRules)) {
    return defaultFilesWritePathRules();
  }
  return normalizeWritePathRules(settings.filesWritePathRules);
}

// Canonicalizes a draft for dirty tracking and for the wire: the path trims
// and the posture stays in the closed set, so an edit that returns to the
// loaded shape reads clean instead of staying dirty on formatting alone.
export function canonicalWritePathRules(
  rules: readonly WritePathRule[]
): WritePathRule[] {
  return rules.map((rule) => ({
    path: rule.path.trim(),
    posture: rule.posture,
  }));
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

function validateFilesWriteMode(writeMode: string): string | null {
  if (!(FILES_WRITE_MODES as readonly string[]).includes(writeMode)) {
    return "Invalid files write mode: must be model, staged, or live.";
  }
  return null;
}

// Validates deny patterns and allowed roots boundaries before save.
export function validateFilesDenyPatterns(denyText: string): string | null {
  const denyLines = denyText.split("\n");
  for (let lineIndex = 0; lineIndex < denyLines.length; lineIndex += 1) {
    const trimmed = denyLines[lineIndex].trim();
    if (!trimmed) continue;
    if (trimmed.includes("..")) {
      return `Line ${lineIndex + 1}: Deny pattern must not contain '..': "${trimmed}".`;
    }
  }
  return null;
}

export function validateFilesAllowRootsText(allowRootsText: string): string | null {
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

// Validates both Simple-owned textarea boundaries.
export function validateFilesBoundaryFields(
  denyText: string,
  allowRootsText: string
): string | null {
  const denyError = validateFilesDenyPatterns(denyText);
  if (denyError) return denyError;
  return validateFilesAllowRootsText(allowRootsText);
}

// Client-side validation mirrors the engine bounds so an over-limit rule count,
// a blank or overlong rule path, a relative rule path, an unknown posture, or an
// unknown mode fails in the form before any network write.
export function validateFilesWriteFields(
  writeMode: string,
  rules: readonly WritePathRule[]
): string | null {
  const modeError = validateFilesWriteMode(writeMode);
  if (modeError) return modeError;
  if (rules.length > FILES_WRITE_PATH_RULE_MAX_COUNT) {
    return `Invalid write path rules: at most ${FILES_WRITE_PATH_RULE_MAX_COUNT} entries (got ${rules.length}).`;
  }
  for (let index = 0; index < rules.length; index += 1) {
    const rule = rules[index];
    if (!rule) continue;
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

// Validates the Advanced-owned Files slice: deny patterns first so a blocked
// path typo surfaces before a rule path, then the write-path rules.
export function validateFilesAdvancedFields(
  rules: readonly WritePathRule[],
  denyText: string
): string | null {
  const denyError = validateFilesDenyPatterns(denyText);
  if (denyError) return denyError;
  return validateFilesWriteFields(DEFAULT_FILES_WRITE_MODE, rules);
}

// Validates the Simple-owned Files slice after the pane-level Advanced hook has
// already checked rules plus deny patterns.
export function validateFilesSimpleFields(
  writeMode: string,
  allowRootsText: string
): string | null {
  const modeError = validateFilesWriteMode(writeMode);
  if (modeError) return modeError;
  return validateFilesAllowRootsText(allowRootsText);
}

// Builds the changed-only [files] patch: a field matching its last-loaded value
// stays omitted so the stored value survives, and the mode plus the rule list
// travel together in one payload when both moved.
export function buildFilesWritePatch(
  writeMode: FilesWriteMode,
  rules: readonly WritePathRule[],
  loaded: FilesLoadedSnapshot
): UpdateSettingsInput {
  const patch: UpdateSettingsInput = {};
  if (writeMode !== loaded.writeMode) {
    patch.filesWriteMode = writeMode;
  }
  const canonical = canonicalWritePathRules(rules);
  if (writePathRulesDiffer(canonical, loaded.writePathRules)) {
    patch.filesWritePathRules = canonical.map((rule) => ({
      path: rule.path,
      posture: rule.posture,
    }));
  }
  return patch;
}
