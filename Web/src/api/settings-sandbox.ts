// Rune Weaver Dashboard — Sandbox execution and container configuration defaults.
import { containsTOMLBreakingScalar, parseTrimmedLines } from "../policyHostNormalize";
import type { DesktopConfigData } from "./settings-types";

// Unified container runtime policy mirroring the engine `ContainersConfig`
// (Sources/RuneWeaverCore/Config.swift).
export interface ContainersConfigData {
  memoryMb: number;
  maxConcurrent: number;
  ttlMinutes: number;
}

// Partial containers patch for `PUT /settings`, mirroring the engine `ContainersUpdate`. Every
// field is optional so a request carrying one key leaves the rest of the stored `[containers]`
// section untouched.
export interface ContainersSettingsUpdate {
  memoryMb?: number;
  maxConcurrent?: number;
  ttlMinutes?: number;
}

// Manual mirrors of ContainersConfig defaults in Sources/RuneWeaverCore/Config.swift.
export const DEFAULT_CONTAINERS_MEMORY_MB = 512;
export const DEFAULT_CONTAINERS_MAX_CONCURRENT = 5;
export const DEFAULT_CONTAINERS_TTL_MINUTES = 60;

// Container knob bounds mirror ContainersConfig.min*/max* statics
// (memory 256-8192 MB, concurrency 1-32, TTL 5-1440 min); the server owns
// the ranges and this mirror sources the client validator so the two cannot drift.
export const CONTAINERS_MEMORY_MIN_MB = 256;
export const CONTAINERS_MEMORY_MAX_MB = 8192;
export const CONTAINERS_MAX_CONCURRENT_MIN = 1;
export const CONTAINERS_MAX_CONCURRENT_MAX = 32;
export const CONTAINERS_TTL_MIN_MINUTES = 5;
export const CONTAINERS_TTL_MAX_MINUTES = 1440;

// Combined containers default mirroring ContainersConfig. The fresh Security
// form seeds from this so the knob editors match the boundary the engine
// enforces before the first settings fetch.
export const DEFAULT_CONTAINERS_CONFIG: ContainersConfigData = {
  memoryMb: DEFAULT_CONTAINERS_MEMORY_MB,
  maxConcurrent: DEFAULT_CONTAINERS_MAX_CONCURRENT,
  ttlMinutes: DEFAULT_CONTAINERS_TTL_MINUTES,
};

// Sandboxed shell execution policy mirroring the engine `BashConfig`
// (Sources/RuneWeaverCore/Config.swift). Rules stay ordered top-to-bottom last-match-wins; the
// timeout is bounded 1-3600 seconds.
export interface BashRuleData {
  pattern: string;
  action: string;
}

// Full bash snapshot on `GET /settings`, mirroring the engine `BashConfig`.
export interface BashConfigData {
  enabled: boolean;
  defaultAction: string;
  rules: BashRuleData[];
  timeoutSeconds: number;
  cpuSeconds?: number;
  memoryMb?: number;
  allowNetwork: boolean;
  sandboxMode?: string;
  hostAllowPatterns?: string[];
}

// Partial bash patch for `PUT /settings`, mirroring the engine
// `BashSettingsUpdate`. Every field is optional so a request carrying one
// key leaves the rest of the stored `[bash]` section untouched.
export interface BashSettingsUpdate {
  enabled?: boolean;
  defaultAction?: string;
  rules?: BashRuleData[];
  timeoutSeconds?: number;
  cpuSeconds?: number;
  memoryMb?: number;
  allowNetwork?: boolean;
  sandboxMode?: string;
  hostAllowPatterns?: string[];
}

// Bash defaults mirror BashConfig in Sources/RuneWeaverCore/Config.swift (enabled, defaultAction,
// defaultRules, defaultTimeoutSeconds, cpuSeconds, memoryMB, allowNetwork, sandboxMode,
// hostAllowPatterns).
export const DEFAULT_BASH_ENABLED = true;
export const DEFAULT_BASH_DEFAULT_ACTION = "ask";
export const DEFAULT_BASH_TIMEOUT_SECONDS = 30;
export const DEFAULT_BASH_CPU_SECONDS = 120;
export const DEFAULT_BASH_MEMORY_MB = 1024;
export const DEFAULT_BASH_ALLOW_NETWORK = false;
export const DEFAULT_BASH_SANDBOX_MODE = "strictContainer";
export const DEFAULT_BASH_HOST_ALLOW_PATTERNS: string[] = [
  "xcodebuild*",
  "codesign*",
];

// Bash timeout bounds mirror BashConfig.minTimeoutSeconds/maxTimeoutSeconds in
// Sources/RuneWeaverCore/Config+Validation.swift and the PUT merge in
// Sources/RuneWeaverServer/ServerBashDTOs.swift.
export const BASH_TIMEOUT_MIN_SECONDS = 1;
export const BASH_TIMEOUT_MAX_SECONDS = 3600;

// CPU budget bounds mirror BashConfig.minCPUSeconds/maxCPUSeconds: a zero budget would kill every
// command instantly while an unbounded one holds a run past any plausible shell turn, so both fail
// closed.
export const BASH_CPU_MIN_SECONDS = 1;
export const BASH_CPU_MAX_SECONDS = 3600;

// Address-space bounds mirror BashConfig.minMemoryMB/maxMemoryMB: a tiny budget fails every spawn
// while a host-scale one invites OOM swaps, so both fail closed.
export const BASH_MEMORY_MIN_MB = 64;
export const BASH_MEMORY_MAX_MB = 8192;

// Mirror of BashConfig.defaultRules; update by hand alongside the Swift
// default. The contract test pins the catch-all so drift fails loudly.
export const DEFAULT_BASH_RULES: BashRuleData[] = [
  { pattern: "*", action: "ask" },
];

// Combined bash default mirroring BashConfig. The fresh form seeds from this object so the editor
// matches the boundary the engine enforces before the first settings fetch.
export const DEFAULT_BASH_CONFIG: BashConfigData = {
  enabled: DEFAULT_BASH_ENABLED,
  defaultAction: DEFAULT_BASH_DEFAULT_ACTION,
  rules: DEFAULT_BASH_RULES.map((rule) => ({ ...rule })),
  timeoutSeconds: DEFAULT_BASH_TIMEOUT_SECONDS,
  cpuSeconds: DEFAULT_BASH_CPU_SECONDS,
  memoryMb: DEFAULT_BASH_MEMORY_MB,
  allowNetwork: DEFAULT_BASH_ALLOW_NETWORK,
  sandboxMode: DEFAULT_BASH_SANDBOX_MODE,
  hostAllowPatterns: [...DEFAULT_BASH_HOST_ALLOW_PATTERNS],
};

// Closed set of valid bash permission actions, mirroring BashPermissionAction
// on the engine. Single source for the client validator and the Bash section
// option lists so the two cannot drift.
export const BASH_PERMISSION_ACTIONS = ["allow", "ask", "deny"] as const;

// Bash textarea codec: one rule per line as `pattern = action` with `allow`, `ask`, or `deny` on
// the right, mirroring the engine `BashSecurity.evaluate(command:config:)` contract
// (Sources/RuneWeaverTools/BashSecurity.swift).
export function parseBashRulesText(text: string | undefined | null): BashRuleData[] {
  if (typeof text !== "string") return [];
  const rules: BashRuleData[] = [];
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (!trimmed) continue;
    const lineNumber = index + 1;
    const separator = trimmed.lastIndexOf("=");
    if (separator === -1) {
      throw new Error(
        `Line ${lineNumber}: expected "pattern = action" (missing "=").`,
      );
    }
    const pattern = trimmed.slice(0, separator).trim();
    const rawAction = trimmed.slice(separator + 1).trim();
    const action = rawAction.toLowerCase();
    if (!pattern) {
      throw new Error(`Line ${lineNumber}: pattern must not be blank.`);
    }
    if (!(BASH_PERMISSION_ACTIONS as readonly string[]).includes(action)) {
      throw new Error(
        `Line ${lineNumber}: action must be allow, ask, or deny (got '${rawAction}').`,
      );
    }
    rules.push({ pattern, action });
  }
  return rules;
}

// Formats ordered bash rules for the textarea, one `pattern = action` per
// line, preserving top-to-bottom order so the last matching rule decides.
export function formatBashRulesText(
  rules: BashRuleData[] | undefined | null,
): string {
  if (!Array.isArray(rules)) return "";
  return rules.map((rule) => `${rule.pattern} = ${rule.action}`).join("\n");
}

// Textarea mirror of the bash rule defaults so the shell policy editor starts
// from the same guard boundary without joining inline in every caller.
export const DEFAULT_BASH_RULES_TEXT: string =
  formatBashRulesText(DEFAULT_BASH_RULES);

// Closed sandbox tier vocabulary mirroring BashSandboxMode on the engine.
// Single source for the client validator and the Bash section dropdown so the
// two cannot drift from the server 400.
export const BASH_SANDBOX_MODES = [
  "strictContainer",
  "machineScoped",
  "hostSeatbelt",
] as const;

// Host allowlist bounds mirroring BashConfig.maxHostAllowPatterns plus
// maxHostAllowPatternLength. Single source for the codec cap and the client
// validator so the form agrees with the server 400.
export const BASH_HOST_ALLOW_PATTERNS_MAX = 50;
export const BASH_HOST_ALLOW_PATTERN_MAX_LENGTH = 256;

// Host allowlist textarea codec: one pattern per line. Trims lines, drops blanks, preserves
// first-seen order, and caps at the auditable bound so copy and paste of pattern sets works.
export function parseHostAllowPatternsUncapped(
  text: string | undefined | null,
): string[] {
  if (typeof text !== "string") return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const trimmed of parseTrimmedLines(text)) {
    if (seen.has(trimmed)) continue;
    seen.add(trimmed);
    out.push(trimmed);
  }
  return out;
}

export function parseHostAllowPatternsText(
  text: string | undefined | null,
): string[] {
  return parseHostAllowPatternsUncapped(text).slice(
    0,
    BASH_HOST_ALLOW_PATTERNS_MAX,
  );
}

// Preserves stored order so the editor round-trips without reshuffling the
// auditable allowlist; a non-list from an older engine omitting the key shows empty.
export function formatHostAllowPatternsText(
  patterns: string[] | undefined | null,
): string {
  if (!Array.isArray(patterns)) return "";
  return patterns.join("\n");
}

// Textarea mirror of the host allowlist defaults so the confinement editor
// starts from the Xcode toolchain boundary without joining inline.
export const DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT: string =
  formatHostAllowPatternsText(DEFAULT_BASH_HOST_ALLOW_PATTERNS);

// Plain-language tier copy mirroring BashSandboxCopy.approvalSummary.
// Host execution stays user-scoped regardless of the network flag while
// strict describes a temporary container and machine a persistent workspace.
export const BASH_SANDBOX_COPY = {
  strictWithoutNetwork:
    "Runs in a temporary container with no internet access. Nothing is kept after the run.",
  strictWithNetwork:
    "Runs in a temporary container with internet access to approved destinations only. Nothing is kept after the run.",
  machineWithoutNetwork:
    "Runs in a persistent workspace machine with no internet access. Workspace files persist across runs.",
  machineWithNetwork:
    "Runs in a persistent workspace machine with internet access to approved destinations only. Workspace files persist across runs.",
  host: "Runs on your Mac as you with full access to your files.",
} as const;

export function bashSandboxSummary(
  sandboxMode: string,
  allowNetwork: boolean,
): string {
  if (sandboxMode === "hostSeatbelt") {
    return BASH_SANDBOX_COPY.host;
  }
  if (sandboxMode === "machineScoped") {
    return allowNetwork
      ? BASH_SANDBOX_COPY.machineWithNetwork
      : BASH_SANDBOX_COPY.machineWithoutNetwork;
  }
  return allowNetwork
    ? BASH_SANDBOX_COPY.strictWithNetwork
    : BASH_SANDBOX_COPY.strictWithoutNetwork;
}

// Human-readable tier labels plus scope sentences for the Bash & Shell editor.
export const BASH_SANDBOX_TIERS = [
  {
    value: BASH_SANDBOX_MODES[0],
    label: "Temporary container",
    scope: "Scope: fresh workspace scratch, deleted at turn end.",
  },
  {
    value: BASH_SANDBOX_MODES[1],
    label: "Workspace machine",
    scope: "Scope: full workspace, kept across runs.",
  },
  {
    value: BASH_SANDBOX_MODES[2],
    label: "On this Mac",
    scope: "Scope: your entire Mac, running as you.",
  },
] as const;

// Closed-tier check mirroring the engine raw-value decode with surrounding
// whitespace tolerated but casing exact.
export function validateBashSandboxMode(
  mode: string | undefined | null,
): string | null {
  const trimmed = (mode ?? "").trim();
  if (!(BASH_SANDBOX_MODES as readonly string[]).includes(trimmed)) {
    return `Invalid bash sandbox mode: must be one of ${(BASH_SANDBOX_MODES as readonly string[]).join(", ")}.`;
  }
  return null;
}

// Allowlist check mirroring BashConfig.validateHostAllowPatterns: at most 50
// entries, each 1 to 256 chars, rejecting newline, null, C0 controls, DEL,
// and TOML-breaking scalars.
export function validateHostAllowPatterns(
  patterns: string[] | undefined | null,
): string | null {
  if (!Array.isArray(patterns)) {
    return "Invalid bash host allow patterns: expected a list.";
  }
  if (patterns.length > BASH_HOST_ALLOW_PATTERNS_MAX) {
    return `Invalid bash host allow patterns: must contain at most ${BASH_HOST_ALLOW_PATTERNS_MAX} entries (got ${patterns.length}).`;
  }
  for (let index = 0; index < patterns.length; index += 1) {
    const pattern = patterns[index];
    if (typeof pattern !== "string") {
      return `Invalid bash host allow patterns: entry ${index + 1} must be a string.`;
    }
    const trimmed = pattern.trim();
    if (!trimmed) {
      return `Invalid bash host allow patterns: entry ${index + 1} must not be blank.`;
    }
    // Trimmed UTF-16 length stands in for Swift String.count; allowlist
    // entries are fnmatch text where the two agree and the server stays
    // authoritative for exotic graphemes.
    if (trimmed.length > BASH_HOST_ALLOW_PATTERN_MAX_LENGTH) {
      return `Invalid bash host allow patterns: entry ${index + 1} must be between 1 and ${BASH_HOST_ALLOW_PATTERN_MAX_LENGTH} characters.`;
    }
    if (
      pattern.includes("\n") ||
      pattern.includes("\r") ||
      pattern.includes("\0")
    ) {
      return `Invalid bash host allow patterns: entry ${index + 1} must not contain newline or null characters.`;
    }
    if (/[\u0000-\u001F\u007F]/.test(pattern)) {
      return `Invalid bash host allow patterns: entry ${index + 1} must not contain control characters.`;
    }
    if (containsTOMLBreakingScalar(pattern)) {
      return `Invalid bash host allow patterns: entry ${index + 1} carries TOML-breaking characters.`;
    }
  }
  return null;
}

// Manual mirrors of DesktopConfig defaults in Sources/RuneWeaverCore/Config.swift.
export const DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION = 1280;
export const DEFAULT_DESKTOP_JPEG_QUALITY = 0.75;

// Manual mirror of DesktopConfig.defaultBlockedApps; update by hand alongside
// the Swift default.
export const DEFAULT_DESKTOP_BLOCKED_APPS: string[] = [
  "Terminal",
  "iTerm2",
  "Keychain Access",
  "System Settings",
  "System Preferences",
  "1Password",
  "Bitwarden",
];

// Textarea mirror of the blocked-apps defaults so the desktop editor starts
// from the same guard boundary without joining inline in every caller.
export const DEFAULT_DESKTOP_BLOCKED_APPS_TEXT: string =
  DEFAULT_DESKTOP_BLOCKED_APPS.join("\n");

// Shared line-list codec for multiline editors: one entry per line, trimmed, with blank lines
// dropped so an emptied editor reads as an explicit empty list instead of persisting whitespace-only
// rows.
export function parseLinesToList(
  text: string | undefined | null,
  fallback: string[],
): string[] {
  if (text == null) return [...fallback];
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

// Shared formatter for multiline editors: joins a list for display, falling
// back to the caller-supplied text when an older engine omits the section so
// textarea and array states never diverge on the default boundary.
export function formatListToText(
  list: string[] | undefined | null,
  fallback: string,
): string {
  if (!Array.isArray(list)) return fallback;
  return list.join("\n");
}

// Parses the blocked-apps textarea into the wire shape, defaulting to the
// desktop guard boundary when no text is present.
export function parseBlockedAppsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, DEFAULT_DESKTOP_BLOCKED_APPS);
}

// Formats a blocked-apps array for the multiline editor, falling back to the
// guard defaults when an older engine omits the [desktop] section entirely.
export function formatBlockedAppsText(apps: string[] | undefined | null): string {
  return formatListToText(apps, DEFAULT_DESKTOP_BLOCKED_APPS_TEXT);
}

// Default desktop policy mirroring DesktopConfig so a fresh form matches the
// boundary the engine enforces before the first settings fetch.
export const DEFAULT_DESKTOP_CONFIG: DesktopConfigData = {
  maxImageDimension: DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION,
  jpegQuality: DEFAULT_DESKTOP_JPEG_QUALITY,
  blockedApps: [...DEFAULT_DESKTOP_BLOCKED_APPS],
};

// Parallel worker fan-out policy mirroring the engine `FanOutConfig`
// (Sources/RuneWeaverCore/Config.swift).
export interface FanoutConfigData {
  maxWorkers: number;
  workerTimeoutSeconds: number;
  fullTools: boolean;
}

// Partial fan-out patch for `PUT /settings`, mirroring the engine fan-out
// update shape. Every field is optional so a request carrying one key leaves
// the rest of the stored `[fanout]` section untouched; the JSON keys are camelCase.
export interface FanoutSettingsUpdate {
  maxWorkers?: number;
  workerTimeoutSeconds?: number;
  fullTools?: boolean;
}

// Modal empty-field fallbacks for the fan-out knobs: a cleared Max workers input saves the
// small-swarm default and a cleared timeout saves unlimited (0) so local models are never held to a
// stale budget by accident.
export const DEFAULT_FANOUT_MAX_WORKERS = 2;
export const DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS = 0;
export const DEFAULT_FANOUT_FULL_TOOLS = false;

// Combined fan-out default seeding the fresh form before the first fetch so
// the editor matches the modal empty-field boundary.
export const DEFAULT_FANOUT_CONFIG: FanoutConfigData = {
  maxWorkers: DEFAULT_FANOUT_MAX_WORKERS,
  workerTimeoutSeconds: DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
  fullTools: DEFAULT_FANOUT_FULL_TOOLS,
};
