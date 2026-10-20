// Rune Weaver Dashboard — Bash draft normalization, canonicalization, and validation helpers.
import {
  BASH_HOST_ALLOW_PATTERNS_MAX,
  BASH_MEMORY_MAX_MB,
  BASH_MEMORY_MIN_MB,
  BASH_CPU_MAX_SECONDS,
  BASH_CPU_MIN_SECONDS,
  BASH_SANDBOX_MODES,
  BASH_TIMEOUT_MAX_SECONDS,
  BASH_TIMEOUT_MIN_SECONDS,
  DEFAULT_BASH_CONFIG,
  DEFAULT_BASH_CPU_SECONDS,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT,
  DEFAULT_BASH_MEMORY_MB,
  DEFAULT_BASH_RULES_TEXT,
  DEFAULT_BASH_SANDBOX_MODE,
  formatBashRulesText,
  formatHostAllowPatternsText,
  parseBashRulesText,
  parseHostAllowPatternsText,
  parseHostAllowPatternsUncapped,
  validateBashSandboxMode,
  validateHostAllowPatterns,
  type BashConfigData,
  type BashRuleData,
} from "../../api";

// Advanced tuning bounds alias the engine constants so the UI can never offer
// a value the server rejects.
export const BASH_TUNING_TIMEOUT_MIN_SECONDS = BASH_TIMEOUT_MIN_SECONDS;
export const BASH_TUNING_TIMEOUT_MAX_SECONDS = BASH_TIMEOUT_MAX_SECONDS;
export const BASH_TUNING_CPU_MIN_SECONDS = BASH_CPU_MIN_SECONDS;
export const BASH_TUNING_CPU_MAX_SECONDS = BASH_CPU_MAX_SECONDS;
export const BASH_TUNING_MEMORY_MIN_MB = BASH_MEMORY_MIN_MB;
export const BASH_TUNING_MEMORY_MAX_MB = BASH_MEMORY_MAX_MB;
export const BASH_TUNING_HOST_PATTERNS_MAX = BASH_HOST_ALLOW_PATTERNS_MAX;

// Last-loaded [bash] snapshot driving the changed-only patch: a field the owner never touches stays
// omitted so the stored value survives, while a cleared allowlist sends an explicit empty list.
export interface BashLoadedSnapshot {
  defaultAction: string;
  rulesText: string;
  timeoutSeconds: number;
  cpuSeconds: number;
  memoryMb: number;
  allowNetwork: boolean;
  sandboxMode: string;
  hostAllowPatterns: string[];
}

// The editor draft as the knobs sit in the form.
export interface BashDraft {
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
export function freshBashDraft(): BashDraft {
  return {
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

export function freshBashLoaded(): BashLoadedSnapshot {
  return {
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

// Canonicalizes a draft for dirty tracking.
export function bashDraftSignature(draft: BashDraft): string {
  let rules: unknown;
  try {
    rules = parseBashRulesText(draft.rulesText);
  } catch {
    rules = draft.rulesText;
  }
  return JSON.stringify({
    defaultAction: draft.defaultAction.trim().toLowerCase(),
    rules,
    timeoutSeconds: Number(draft.timeoutSeconds),
    cpuSeconds: Number(draft.cpuSeconds),
    memoryMb: Number(draft.memoryMB),
    allowNetwork: draft.allowNetwork,
    sandboxMode: draft.sandboxMode.trim(),
    hostAllowPatterns: parseHostAllowPatternsUncapped(draft.hostAllowPatternsText),
  });
}

// Live parsed rule count. A malformed line still counts as a non-blank row so
// the badge stays honest until validation reports the line number.
export function countBashRules(text: string): number {
  try {
    return parseBashRulesText(text).length;
  } catch {
    return text
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean).length;
  }
}

// Normalizes a stored tier into the closed sandbox vocabulary.
export function normalizeBashSandboxMode(value: unknown): string {
  const trimmed = typeof value === "string" ? value.trim() : "";
  return (BASH_SANDBOX_MODES as readonly string[]).includes(trimmed)
    ? trimmed
    : DEFAULT_BASH_SANDBOX_MODE;
}

// Formats a loaded host allowlist through the shared codec so the textarea and
// the wire list agree on trimming, ordering, and the engine bound.
export function normalizeHostAllowPatternsText(value: unknown): string {
  if (!Array.isArray(value)) return DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT;
  const filtered = value.filter(
    (entry): entry is string => typeof entry === "string",
  );
  return formatHostAllowPatternsText(
    parseHostAllowPatternsText(formatHostAllowPatternsText(filtered)),
  );
}

// Copies one settings fetch into the bash fields, and tolerates an absent [bash] section from older
// engines by keeping the form defaults.
export function applyBashConfigToDraft(draft: BashDraft, bash: BashConfigData): BashDraft {
  const next: BashDraft = { ...draft };
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
  if (typeof bash.timeoutSeconds === "number") {
    next.timeoutSeconds = bash.timeoutSeconds;
  }
  if (typeof bash.cpuSeconds === "number") {
    next.cpuSeconds = bash.cpuSeconds;
  }
  if (typeof bash.memoryMb === "number") {
    next.memoryMB = bash.memoryMb;
  }
  if (typeof bash.allowNetwork === "boolean") {
    next.allowNetwork = bash.allowNetwork;
  }
  next.sandboxMode = normalizeBashSandboxMode(bash.sandboxMode);
  next.hostAllowPatternsText = normalizeHostAllowPatternsText(bash.hostAllowPatterns);
  return next;
}

// Rebuilds the editor draft from the last-loaded snapshot, which is what the
// populate path seeds from: a key the engine omits keeps the previously loaded
// value instead of resetting to a fresh-form default.
export function bashDraftFromLoaded(loaded: BashLoadedSnapshot): BashDraft {
  return {
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
export function bashLoadedFromDraft(draft: BashDraft): BashLoadedSnapshot {
  return {
    defaultAction: draft.defaultAction.trim().toLowerCase(),
    rulesText: draft.rulesText,
    timeoutSeconds: Number(draft.timeoutSeconds),
    cpuSeconds: Number(draft.cpuSeconds),
    memoryMb: Number(draft.memoryMB),
    allowNetwork: draft.allowNetwork,
    sandboxMode: draft.sandboxMode.trim(),
    hostAllowPatterns: parseHostAllowPatternsUncapped(draft.hostAllowPatternsText),
  };
}

// Validates the three numeric engine budgets with one shared bound set,
// so Simple plus Advanced saves report the same field message.
export function validateBashBudgets(
  timeoutSeconds: number | string,
  cpuSeconds: number | string,
  memoryMB: number | string
): string | null {
  const timeoutNum = Number(timeoutSeconds);
  if (
    !Number.isInteger(timeoutNum) ||
    timeoutNum < BASH_TUNING_TIMEOUT_MIN_SECONDS ||
    timeoutNum > BASH_TUNING_TIMEOUT_MAX_SECONDS
  ) {
    return `Invalid bash timeout: timeout must be between ${BASH_TUNING_TIMEOUT_MIN_SECONDS} and ${BASH_TUNING_TIMEOUT_MAX_SECONDS} seconds.`;
  }
  const cpuNum = Number(cpuSeconds);
  if (
    !Number.isInteger(cpuNum) ||
    cpuNum < BASH_TUNING_CPU_MIN_SECONDS ||
    cpuNum > BASH_TUNING_CPU_MAX_SECONDS
  ) {
    return `Invalid bash CPU budget: CPU time must be between ${BASH_TUNING_CPU_MIN_SECONDS} and ${BASH_TUNING_CPU_MAX_SECONDS} seconds.`;
  }
  const memoryNum = Number(memoryMB);
  if (
    !Number.isInteger(memoryNum) ||
    memoryNum < BASH_TUNING_MEMORY_MIN_MB ||
    memoryNum > BASH_TUNING_MEMORY_MAX_MB
  ) {
    return `Invalid bash memory budget: memory must be between ${BASH_TUNING_MEMORY_MIN_MB} and ${BASH_TUNING_MEMORY_MAX_MB} MB.`;
  }
  return null;
}

// Validates the Advanced confinement slice: the closed tier set plus the
// engine allowlist bounds, including the uncapped count the textarea codec
// would otherwise silently truncate.
export function validateBashConfinementFields(
  sandboxMode: string,
  hostAllowPatternsText: string
): string | null {
  const tierError = validateBashSandboxMode(sandboxMode);
  if (tierError) return tierError;
  const uncapped = parseHostAllowPatternsUncapped(hostAllowPatternsText);
  if (uncapped.length > BASH_TUNING_HOST_PATTERNS_MAX) {
    return `Invalid bash host allow patterns: must contain at most ${BASH_TUNING_HOST_PATTERNS_MAX} entries (got ${uncapped.length}).`;
  }
  return validateHostAllowPatterns(uncapped);
}
