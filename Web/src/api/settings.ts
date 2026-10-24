// Rune Weaver Dashboard — Settings management API and persona defaults.
import { fetchJson } from "./http";
import type {
  ContainersConfigData,
  ContainersSettingsUpdate,
  BashConfigData,
  BashSettingsUpdate,
  FanoutConfigData,
  FanoutSettingsUpdate,
} from "./settings-sandbox";
import { parseLinesToList, formatListToText } from "./settings-sandbox";
import type {
  ProviderConfigData,
  EmailAccountData,
  MediaConfigData,
  IndexConfigData,
  IndexSettingsUpdate,
  GoalsConfigData,
  GoalsSettingsUpdate,
  SchedulerConfigData,
  ProactiveConfigData,
  ProactiveSettingsUpdate,
  IdeasConfigData,
  IdeasSettingsUpdate,
  NotificationsConfigData,
  NotificationsSettingsUpdate,
  WorkspaceConfigData,
  WorkspaceSettingsUpdate,
  DesktopConfigData,
  DesktopSettingsUpdate,
} from "./settings-types";
import {
  clampToolRounds,
  DEFAULT_NOTIFICATIONS_CONFIG,
  DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS,
  DEFAULT_ENGINE_MAX_TOOL_ITERATIONS,
  DEFAULT_GOALS_MAX_TOOL_ITERATIONS,
  resolveNotificationsConfig,
} from "./settings-types";
import type { SchedulerJob } from "./scheduler";


// Owner-facing assistant persona mirrored from the engine `PersonaConfig`
// (Sources/RuneWeaverCore/PersonaConfig.swift).
export interface PersonaData {
  assistantName?: string;
  tone?: string;
  style?: string;
  userName?: string;
  avatar?: string;
}

// Partial persona patch for `PUT /settings`, mirroring the engine `PersonaUpdate`.
export interface PersonaSettingsUpdate {
  assistantName?: string;
  tone?: string;
  style?: string;
  userName?: string;
  avatar?: string;
}

// Closed tone set mirroring `PersonaTone`; single source for the pane select
// and the client validator so the two cannot drift from the engine merge.
export const PERSONA_TONES = ["concise", "warm", "formal", "playful"] as const;

// Select options in engine order, labeled for display only — the values are
// the canonical lowercase raw strings the engine re-validates.
export const PERSONA_TONE_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "concise", label: "Concise" },
  { value: "warm", label: "Warm" },
  { value: "formal", label: "Formal" },
  { value: "playful", label: "Playful" },
];

// Closed avatar accent set mirroring `PersonaAvatar`. The value selects a
// client-side colorway only and never reaches a prompt byte.
export const PERSONA_AVATAR_COLORS = ["violet", "cyan", "emerald", "rose"] as const;

// Manual mirrors of PersonaConfig bounds (maxAssistantNameLength, maxStyleLength,
// maxUserNameLength) and defaults (defaultAssistantName, defaultTone, defaultAvatar); the server
// owns the values and the contract tests pin both ends so a drift fails loudly.
export const MAX_PERSONA_ASSISTANT_NAME_LENGTH = 32;
export const MAX_PERSONA_STYLE_LENGTH = 2000;
export const MAX_PERSONA_USER_NAME_LENGTH = 64;
export const DEFAULT_PERSONA_TONE = "warm";
export const DEFAULT_PERSONA_AVATAR = "violet";

// Normalizes a tone spelling the way the engine merge does: trim plus
// lowercase before matching the closed set, so `WARM` saves identically to
// `warm` and the pane select never blanks on a file-configured casing.
export function normalizePersonaTone(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

// Normalizes an avatar accent spelling with the same trim-plus-lowercase
// posture as the tone; callers pair this with `PERSONA_AVATAR_COLORS` to
// decide between a real accent and the violet fallback.
export function normalizePersonaAvatarColor(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

// Reads the assistant display name, normalizing absent or blank payloads
// to null so identity surfaces fall back to the stock label instead of rendering
// an empty string.
export function personaAssistantName(persona: PersonaData | null | undefined): string | null {
  const raw = persona?.assistantName;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

// Reads the stored avatar accent across both spellings, returning the raw
// (unvalidated) token or null. `PersonaAvatar` owns the closed-set fallback
// so accent validation lives in exactly one render path.
export function personaAvatarColor(persona: PersonaData | null | undefined): string | null {
  const raw = persona?.avatar;
  return typeof raw === "string" && raw.trim().length > 0 ? raw.trim() : null;
}

// Reads the owner address name with the same blank normalization the settings populate path applies.
export function personaUserName(persona: PersonaData | null | undefined): string {
  const raw = persona?.userName;
  return typeof raw === "string" ? raw : "";
}

// Reads the free-form style guidance; absent degrades to the empty stored
// default so the textarea never renders undefined.
export function personaStyle(persona: PersonaData | null | undefined): string {
  const raw = persona?.style;
  return typeof raw === "string" ? raw : "";
}

export interface FilesWritePathRuleData {
  path: string;
  posture: string;
}

export interface SettingsResponse {
  engineName: string;
  logLevel: string;
  compactionThresholdPercent?: number;
  maxToolIterations?: number;
  // Flat scheduler section default; optional for back-compat with older engines.
  schedulerMaxToolIterations?: number;
  defaultProvider: string;
  fallbackProvider?: string;
  providers: Record<string, ProviderConfigData>;
  memoryVectorDBPath: string;
  memoryEpisodesDBPath: string;
  memoryEmbeddingModel: string;
  memoryEmbeddingBackend: string;
  voiceSTTProvider: string;
  voiceWhisperModel: string;
  voiceTTSProvider: string;
  // Unified container runtime policy under [containers]; optional for back-compat with older
  // engines that predate the section.
  containers?: ContainersConfigData;
  // File access policy persisted under [files]; optional for back-compat
  // with older engines that predate the deny list.
  filesDenyPatterns?: string[];
  filesAllowRoots?: string[];
  filesRequireApprovalOnDeny?: boolean;
  // Forced files.write posture from [files] write_mode (`model` | `staged` | `live`); optional for
  // back-compat with older engines that predate the key.
  filesWriteMode?: string;
  filesWritePathRules?: FilesWritePathRuleData[];
  // Web search policy persisted under [browser] (searxng_url, timeout, max_results). The engine
  // encodes both the canonical `browser*` keys and the `search*` aliases with identical values so
  // either contract reads without falling back to defaults; older engines may carry only `browser*`.
  browserSearxngURL?: string;
  browserSearchTimeoutSeconds?: number;
  browserMaxResults?: number;
  browserTimeoutSeconds?: number;
  browserFetchTimeoutSeconds?: number;
  searchSearxngURL?: string;
  searchTimeoutSeconds?: number;
  searchMaxResults?: number;
  emailAccounts: EmailAccountData[];
  pluginsDir: string;
  pluginsMarketplaceIndexURL: string;
  pluginsAutoRescan: boolean;
  media?: MediaConfigData;
  // Local background indexer policy under [index]; optional for back-compat
  // with older engines that predate the section.
  index?: IndexConfigData;
  // Native desktop vision and gated control under [desktop]; optional for
  // back-compat with older engines that predate the section.
  desktop?: DesktopConfigData;
  // Sandboxed shell execution policy under [bash]; optional for back-compat
  // with older engines that predate the section.
  bash?: BashConfigData;
  // Steady goal pursuit policy under [goals]; optional for back-compat with
  // older engines that predate the section.
  goals?: GoalsConfigData;
  // Scheduled-run tool budget under [scheduler]; optional for back-compat
  // with older engines that predate the section.
  scheduler?: SchedulerConfigData;
  // Interruption policy under [proactive]; optional for back-compat with
  // older engines that predate the section.
  proactive?: ProactiveConfigData;
  // Per-type interruption preferences under [notifications]; optional for
  // back-compat with older engines that predate the section.
  notifications?: NotificationsConfigData;
  // Proactive Wayfinder suggestion policy under [ideas]; optional for back-compat
  // with older engines that predate the section.
  ideas?: IdeasConfigData;
  // Parallel worker fan-out policy under [fanout]; optional for back-compat
  // with older engines that predate the section.
  fanout?: FanoutConfigData;
  // Agent scratch quotas under [workspace]; optional for back-compat with
  // older engines that predate the section. An absent section keeps the stock
  // quotas so the Tools editors fall back instead of blanking.
  workspace?: WorkspaceConfigData;
  // Owner-facing assistant persona under [persona]; optional for back-compat
  // with older engines that predate the section. An absent persona keeps the
  // stock identity, so identity surfaces fall back instead of blanking.
  persona?: PersonaData;
  // HTTP bind from [server]; optional for back-compat with older engines that
  // predate the bind keys. Absent degrades to the loopback defaults so the
  // Network pane never renders blank.
  serverHostname?: string;
  serverPort?: number;
  serverAllowedHosts?: string[];
  configPath: string;
  // Whether the last PUT needs a restart to take effect. True only when the save carried
  // bind-affecting [server] keys; the route never live-reloads the socket or the middleware set.
  requiresRestart?: boolean;
}

export interface UpdateSettingsInput {
  engineName?: string;
  logLevel?: string;
  compactionThresholdPercent?: number;
  maxToolIterations?: number;
  defaultProvider?: string;
  fallbackProvider?: string;
  // Provider entries carry the prefix-reuse knobs (slot_count/slotCount/cache_prompt/cachePrompt)
  // through ProviderConfigData so a dashboard PUT preserves file-configured values instead of
  // stripping them to unset.
  providers?: Record<string, ProviderConfigData>;
  memoryVectorDBPath?: string;
  memoryEpisodesDBPath?: string;
  memoryEmbeddingModel?: string;
  memoryEmbeddingBackend?: string;
  voiceSTTProvider?: string;
  voiceWhisperModel?: string;
  voiceTTSProvider?: string;
  // Partial containers patch; an omitted patch preserves the stored
  // [containers] section.
  containers?: ContainersSettingsUpdate;
  filesDenyPatterns?: string[];
  filesAllowRoots?: string[];
  filesRequireApprovalOnDeny?: boolean;
  // Owner-forced write posture for files.write; the engine re-validates the
  // closed `model` | `staged` | `live` set and rejects an unknown value instead
  // of silently falling back to the model posture.
  filesWriteMode?: string;
  filesWritePathRules?: FilesWritePathRuleData[];
  // Dual-write both contracts so old and new engines persist the [browser] values tools dial.
  browserSearxngURL?: string;
  browserSearchTimeoutSeconds?: number;
  browserMaxResults?: number;
  browserTimeoutSeconds?: number;
  browserFetchTimeoutSeconds?: number;
  searchSearxngURL?: string;
  searchTimeoutSeconds?: number;
  searchMaxResults?: number;
  emailAccounts?: EmailAccountData[];
  pluginsDir?: string;
  pluginsMarketplaceIndexURL?: string;
  pluginsAutoRescan?: boolean;
  media?: MediaConfigData;
  // Partial index patch; an omitted patch preserves the stored [index] section.
  index?: IndexSettingsUpdate;
  // Partial desktop patch; an omitted patch preserves the stored [desktop] section.
  desktop?: DesktopSettingsUpdate;
  // Partial bash patch; an omitted patch preserves the stored [bash] section.
  bash?: BashSettingsUpdate;
  // Partial goals patch; an omitted patch preserves the stored [goals] section.
  goals?: GoalsSettingsUpdate;
  // Partial proactive patch; an omitted patch preserves the stored [proactive] section.
  proactive?: ProactiveSettingsUpdate;
  // Partial notifications patch; an omitted patch preserves the stored
  // [notifications] section. Carried on the shared save with live apply.
  notifications?: NotificationsSettingsUpdate;
  // Partial ideas patch; an omitted patch preserves the stored [ideas] section.
  ideas?: IdeasSettingsUpdate;
  // Partial fan-out patch; an omitted patch preserves the stored [fanout] section.
  fanout?: FanoutSettingsUpdate;
  // Partial workspace patch; an omitted patch preserves the stored [workspace] section.
  workspace?: WorkspaceSettingsUpdate;
  // Partial persona patch; an omitted patch preserves the stored [persona]
  // section, so a name-only save never wipes the owner's tone, style, address
  // name, or accent.
  persona?: PersonaSettingsUpdate;
  // Bind patch for [server]; an omitted patch preserves the stored section.
  // The engine persists these to the file and returns requiresRestart without
  // live-reloading the bind, so the dashboard shows a restart banner.
  serverHostname?: string;
  serverPort?: number;
  serverAllowedHosts?: string[];
}

// Manual mirrors of ServerEndpointConfig ([server] bind) in
// Sources/RuneWeaverCore/Config.swift so a fresh Network form matches the
// boundary the engine enforces before the first settings fetch.
export const DEFAULT_SERVER_HOSTNAME = "127.0.0.1";
export const DEFAULT_SERVER_PORT = 8082;
export const MAX_SERVER_ALLOWED_HOSTS = 20;
export const MAX_SERVER_ALLOWED_HOST_LENGTH = 253;

// Whether a bind hostname is loopback-only. Non-loopback binds need a resolvable owner token and
// fail closed otherwise, so the Network pane gates its save copy on this check before any network
// write.
export function isLoopbackHostname(hostname: string | undefined | null): boolean {
  const trimmed = (hostname ?? "").trim().toLowerCase();
  return (
    trimmed === "127.0.0.1" ||
    trimmed === "localhost" ||
    trimmed === "::1" ||
    trimmed === "[::1]"
  );
}

// Single web source for the restart compare: trimmed plus lowercased, then a single outer bracket
// pair stripped only when the inner text holds a colon so `::1` and `[::1]` (or `::` and `[::]`)
// compare equal while bracketed non-IPv6 spellings stay distinct.
export function canonicalRestartHost(value: string): string {
  const candidate = value.trim().toLowerCase();
  if (candidate.length >= 2 && candidate.startsWith("[") && candidate.endsWith("]")) {
    const inner = candidate.slice(1, -1);
    if (inner.includes(":")) return inner;
  }
  return candidate;
}

// Normalizes one allowed_hosts entry to the compared Host form: trimmed, lowercased, with a
// trailing empty or numeric :port stripped so Example.COM:8082 stores as example.com.
export function normalizeServerAllowedHost(entry: string): string {
  const trimmed = entry.trim().toLowerCase();
  if (!trimmed) return trimmed;
  if (trimmed.startsWith("[")) {
    const close = trimmed.indexOf("]");
    if (close === -1) return trimmed;
    const after = trimmed.slice(close + 1);
    if (after.length === 0) return trimmed.slice(0, close + 1);
    if (after.startsWith(":")) {
      const portPart = after.slice(1);
      if (portPart.length > 0 && /^[0-9]+$/.test(portPart)) {
        return trimmed.slice(0, close + 1);
      }
    }
    return trimmed;
  }
  const colonCount = (trimmed.match(/:/g) ?? []).length;
  if (colonCount > 1) return trimmed;
  const colon = trimmed.indexOf(":");
  if (colon !== -1) {
    // Preserve the carved fragment for scheme inputs (`http://...` -> `http`)
    // so the pinned parity fixtures stay stable; validation drops these
    // fail-closed before any allowlist stores them.
    if (trimmed.includes("://")) return trimmed.slice(0, colon);
    const portPart = trimmed.slice(colon + 1);
    if (/^[0-9]*$/.test(portPart)) return trimmed.slice(0, colon);
    return trimmed;
  }
  return trimmed;
}

// Single source for IPv6 bracket-shape validation shared by the allowed_hosts and hostname
// validators.
export function validateBracketedHost(trimmed: string, entry: string): string | null {
  // Fail closed on `[` without `]` (and vice versa): an unbalanced bracket
  // would never match exactly yet read as configured.
  if (trimmed.includes("[") !== trimmed.includes("]")) {
    return `must not contain unbalanced brackets (got '${entry}')`;
  }
  // Fail closed on bracketed non-IPv6 and empty brackets: `[example.com]`, `[127.0.0.1]`, or `[]`
  // would never match exactly yet read as configured.
  if (trimmed.includes("[") || trimmed.includes("]")) {
    const openCount = (trimmed.match(/\[/g) ?? []).length;
    const closeCount = (trimmed.match(/\]/g) ?? []).length;
    const close = trimmed.indexOf("]");
    if (
      !trimmed.startsWith("[") ||
      openCount !== 1 ||
      closeCount !== 1 ||
      close === -1
    ) {
      return `must not contain bracketed non-IPv6 (got '${entry}'); brackets are only for IPv6 literals`;
    }
    const inner = trimmed.slice(1, close);
    if (!inner) {
      return `must not contain empty brackets (got '${entry}')`;
    }
    if (!inner.includes(":")) {
      return `must not contain bracketed non-IPv6 (got '${entry}'); list the host without brackets instead`;
    }
    const afterBracket = trimmed.slice(close + 1);
    if (afterBracket) {
      if (!afterBracket.startsWith(":")) {
        return `must not contain bracketed non-IPv6 (got '${entry}'); brackets are only for IPv6 literals`;
      }
      const portPart = afterBracket.slice(1);
      if (!portPart || !/^[0-9]+$/.test(portPart)) {
        return `must not contain bracketed non-IPv6 (got '${entry}'); brackets are only for IPv6 literals`;
      }
    }
  }
  return null;
}

// Validates one allowed_hosts entry against the exact-only Host semantics the gate enforces.
export function validateServerAllowedHost(entry: string): string | null {
  const trimmed = entry.trim();
  if (!trimmed) return "must not contain empty strings";
  if (trimmed.length > MAX_SERVER_ALLOWED_HOST_LENGTH) {
    return `must not exceed ${MAX_SERVER_ALLOWED_HOST_LENGTH} characters (got ${trimmed.length})`;
  }
  const lowered = trimmed.toLowerCase();
  if (lowered.includes("://")) {
    return `must not contain a scheme (got '${entry}'); list the host instead`;
  }
  if (lowered === "*") {
    return `must not contain bare "*" (would allow every host)`;
  }
  if (lowered.includes("*")) {
    return `must not contain wildcards (got '${entry}'); list exact hosts instead`;
  }
  if (lowered.includes("/")) {
    return `must not contain CIDR or paths (got '${entry}'); list exact hosts instead`;
  }
  if (trimmed.includes("@")) {
    return `must not contain userinfo (got '${entry}')`;
  }
  if (trimmed.includes("?") || trimmed.includes("#")) {
    return `must be a host without query or fragment (got '${entry}')`;
  }
  if (trimmed.includes(" ") || trimmed.includes("\t")) {
    return `must not contain whitespace (got '${entry}')`;
  }
  if (/[\u0000-\u001F\u007F]/.test(trimmed)) {
    return `must not contain control characters (got '${entry}')`;
  }
  // Single-sourced bracket shape so a future IPv6 spelling change stays in
  // lockstep with the server 400.
  const bracketProblem = validateBracketedHost(trimmed, entry);
  if (bracketProblem) {
    return bracketProblem;
  }
  // Fail closed on unbracketed `host:suffix` with a non-numeric suffix: normalization strips only
  // an empty or numeric port, so `evil.com:evil` would otherwise persist verbatim garbage.
  if (!trimmed.startsWith("[")) {
    const colonCount = (trimmed.match(/:/g) ?? []).length;
    if (colonCount === 1) {
      const colon = trimmed.indexOf(":");
      const suffix = trimmed.slice(colon + 1);
      if (!/^[0-9]*$/.test(suffix)) {
        return `must be a host with an optional numeric port (got '${entry}'); list exact hosts instead`;
      }
    }
  }
  // Fail closed on a trailing FQDN dot: the gate compares exact normalized
  // hosts, so `example.com.` would never match `example.com` yet read as
  // allowed. Mirrors validateExactHost.
  if (trimmed.endsWith(".")) {
    return `must not end with '.' (got '${entry}'); list the host without the trailing dot instead`;
  }
  const normalized = normalizeServerAllowedHost(trimmed);
  if (!normalized) {
    return "must not contain empty strings";
  }
  return null;
}

// Validates the full allowed_hosts list: bounded count plus per-entry
// exact-only rules so a bad line points at its editor line with its number.
export function validateServerAllowedHosts(hosts: string[]): string | null {
  if (hosts.length > MAX_SERVER_ALLOWED_HOSTS) {
    return `Allowed hosts must contain at most ${MAX_SERVER_ALLOWED_HOSTS} entries (got ${hosts.length}).`;
  }
  for (let i = 0; i < hosts.length; i += 1) {
    const problem = validateServerAllowedHost(hosts[i]);
    if (problem) {
      return `Line ${i + 1}: ${problem}`;
    }
  }
  return null;
}

// Whether a trimmed hostname carries a `:port` suffix.
function isServerHostnameWithPortSuffix(trimmed: string): boolean {
  if (trimmed.startsWith("[")) {
    const close = trimmed.indexOf("]");
    if (close === -1) return false;
    const after = trimmed.slice(close + 1);
    if (!after.startsWith(":")) return false;
    const portPart = after.slice(1);
    return portPart.length > 0 && /^[0-9]+$/.test(portPart);
  }
  const colonCount = (trimmed.match(/:/g) ?? []).length;
  if (colonCount !== 1) return false;
  const colon = trimmed.indexOf(":");
  const suffix = trimmed.slice(colon + 1);
  if (suffix.length === 0) return true;
  return /^[0-9]+$/.test(suffix);
}

// Validates one server.hostname value against the exact-only Host semantics the gate enforces,
// mirroring RuneWeaverConfig.validateServerHostname so a bad bind fails closed in the form before
// any network write.
export function validateServerHostname(entry: string): string | null {
  const trimmed = entry.trim();
  if (!trimmed) return "must not be empty";
  if (trimmed.length > MAX_SERVER_ALLOWED_HOST_LENGTH) {
    return `must not exceed ${MAX_SERVER_ALLOWED_HOST_LENGTH} characters (got ${trimmed.length})`;
  }
  const lowered = trimmed.toLowerCase();
  if (lowered.includes("://")) {
    return `must not contain a scheme (got '${entry}'); list the host instead`;
  }
  if (lowered === "*") {
    return `must not contain bare "*" (would allow every host)`;
  }
  if (lowered.includes("*")) {
    return `must not contain wildcards (got '${entry}'); list the host instead`;
  }
  if (lowered.includes("/")) {
    return `must not contain CIDR or paths (got '${entry}'); list the host instead`;
  }
  if (trimmed.includes("@")) {
    return `must not contain userinfo (got '${entry}')`;
  }
  if (trimmed.includes("?") || trimmed.includes("#")) {
    return `must be a host without query or fragment (got '${entry}')`;
  }
  if (trimmed.includes(" ") || trimmed.includes("\t")) {
    return `must not contain whitespace (got '${entry}')`;
  }
  if ([...trimmed].some((ch) => { const code = ch.charCodeAt(0); return code < 0x20 || code === 0x7f; })) {
    return `must not contain control characters (got '${entry}')`;
  }
  // Single-sourced bracket shape so a future IPv6 spelling change stays in
  // lockstep with the server 400.
  const bracketProblem = validateBracketedHost(trimmed, entry);
  if (bracketProblem) {
    return bracketProblem;
  }
  // Fail closed on unbracketed `host:suffix` with a non-numeric suffix: normalization strips only
  // an empty or numeric port, so `evil.com:evil` would otherwise persist verbatim garbage.
  if (!trimmed.startsWith("[")) {
    const colonCount = (trimmed.match(/:/g) ?? []).length;
    if (colonCount === 1) {
      const colon = trimmed.indexOf(":");
      const suffix = trimmed.slice(colon + 1);
      if (!/^[0-9]*$/.test(suffix)) {
        return `must be a host without a port (got '${entry}'); configure the port via server.port instead`;
      }
    }
  }
  if (trimmed.endsWith(".")) {
    return `must not end with '.' (got '${entry}'); list the host without the trailing dot instead`;
  }
  if (isServerHostnameWithPortSuffix(trimmed)) {
    return `must be a host without a port (got '${entry}'); configure the port via server.port instead`;
  }
  const normalized = normalizeServerAllowedHost(trimmed);
  if (!normalized) {
    return "must not be empty";
  }
  return null;
}

// Textarea mirror of the empty allowed-hosts defaults so the Network editor
// starts from the same empty allowlist without joining inline in every caller.
export const DEFAULT_SERVER_ALLOWED_HOSTS_TEXT = "";

// Parses the allowed-hosts textarea into the wire shape, one exact host per
// line with blank lines ignored, so an emptied editor reads as an explicit
// empty allowlist instead of persisting whitespace-only rows.
export function parseServerAllowedHostsText(
  text: string | undefined | null,
): string[] {
  return parseLinesToList(text, []);
}

// Formats an allowed-hosts array for the multiline editor, falling back to
// the empty allowlist when an older engine omits the [server] section so the
// textarea and array states never diverge on the default boundary.
export function formatServerAllowedHostsText(
  hosts: string[] | undefined | null,
): string {
  return formatListToText(hosts, DEFAULT_SERVER_ALLOWED_HOSTS_TEXT);
}

// Manual mirror of FilesConfig.defaultDenyPatterns in Sources/RuneWeaverCore/Config.swift.
export const DEFAULT_FILES_DENY_PATTERNS: string[] = [
  ".env*",
  ".netrc",
  "secrets.json",
  "config.toml",
  "*.pem",
  "*.key",
  "*keychain*",
  ".ssh/*",
  ".aws/*",
  ".runeweaver/memory/*",
  ".runeweaver/memory/vectors/*",
  ".runeweaver/browser_profiles/*",
  ".runeweaver/policy.toml",
  ".runeweaver/auth_token",
  ".runeweaver/searxng/*",
  ".git-credentials",
  ".gitcookies",
  ".rclone.conf",
  ".npmrc",
  ".pypirc",
  ".Xauthority",
  ".emulator_console_auth_token",
  ".gnupg/*",
  ".kube/*",
  ".docker/*",
  ".config/gcloud/*",
  ".chia_keys/*",
  "*_history",
  ".zsh_sessions/*",
];

// Manual mirror of FilesConfig.defaultAllowRoots (`~` = home); update by
// hand alongside the Swift default.
export const DEFAULT_FILES_ALLOW_ROOTS: string[] = ["~"];

// Textarea mirror of the deny defaults so the blocked-paths editor starts from the same guard
// boundary without joining inline in every caller.
export const DEFAULT_FILES_DENY_PATTERNS_TEXT: string =
  DEFAULT_FILES_DENY_PATTERNS.join("\n");

// Parses the blocked-paths textarea into the wire shape, defaulting to the
// files guard boundary when no text is present.
export function parseDenyPatternsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, DEFAULT_FILES_DENY_PATTERNS);
}

// Formats a deny array for the multiline editor, falling back to the guard
// defaults when an older engine omits the [files] section entirely.
export function formatDenyPatternsText(
  patterns: string[] | undefined | null
): string {
  return formatListToText(patterns, DEFAULT_FILES_DENY_PATTERNS_TEXT);
}

// Textarea mirror of the allow-roots defaults so the allowed-roots editor starts from the same
// guard boundary without joining inline in every caller.
export const DEFAULT_FILES_ALLOW_ROOTS_TEXT: string =
  DEFAULT_FILES_ALLOW_ROOTS.join("\n");

// Parses the allowed-roots textarea into the wire shape, defaulting to the
// files guard boundary when no text is present.
export function parseAllowRootsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, DEFAULT_FILES_ALLOW_ROOTS);
}

// Formats an allow-roots array for the multiline editor, falling back to the
// guard defaults when an older engine omits the [files] section entirely.
export function formatAllowRootsText(
  roots: string[] | undefined | null
): string {
  return formatListToText(roots, DEFAULT_FILES_ALLOW_ROOTS_TEXT);
}

// Manual mirrors of the [browser] defaults (searxng_url, timeout, max_results) pinned to
// BrowserConfig in Sources/RuneWeaverCore/Config.swift (defaultSearxngURL, defaultMaxResults),
// Config/config.toml.example, and CONFIG.md.
export const DEFAULT_SEARCH_SEARXNG_URL = "http://127.0.0.1:8888";
export const DEFAULT_SEARCH_TIMEOUT_SECONDS = 10;
export const DEFAULT_SEARCH_MAX_RESULTS = 10;
export const DEFAULT_BROWSER_TIMEOUT_SECONDS = 30;
export const DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS = 15;
export const DEFAULT_MEDIA_TIMEOUT_SECONDS = 15;
export const DEFAULT_GOALS_MAX_STEPS_PER_GOAL = 12;
export const DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS = 0;
export const DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL = 8;
export const DEFAULT_IDEAS_MAX_PER_CYCLE = 3;
export const DEFAULT_IDEAS_TIMEOUT_SECONDS = 20;

export function getSettings(): Promise<SettingsResponse> {
  return fetchJson<SettingsResponse>("/settings");
}

export function updateSettings(
  input: UpdateSettingsInput,
): Promise<SettingsResponse> {
  return fetchJson<SettingsResponse>("/settings", {
    method: "PUT",
    body: JSON.stringify(input),
  });
}

// Reads the live scheduler section default from GET /settings, falling back
// to the engine default when the section predates the key.
export function schedulerMaxToolIterations(
  settings: SettingsResponse | undefined | null,
): number {
  const raw =
    settings?.schedulerMaxToolIterations ??
    settings?.scheduler?.maxToolIterations;
  return clampToolRounds(raw, DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS);
}

// Resolves the live per-job effective budget: a finite per-job override wins,
// otherwise the live section default applies.
export function schedulerJobEffectiveMaxToolIterations(
  job: SchedulerJob | undefined | null,
  sectionDefault: number | null | undefined,
): number {
  return clampToolRounds(
    job?.maxToolIterations,
    clampToolRounds(sectionDefault, DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS),
  );
}

// Reads the live interactive-chat tool budget from GET /settings, falling back
// to the engine default when the flat key is absent or drifted so the summary
// never renders an unsaved draft value.
export function engineMaxToolIterations(
  settings: SettingsResponse | undefined | null,
): number {
  const raw = settings?.maxToolIterations;
  return clampToolRounds(raw, DEFAULT_ENGINE_MAX_TOOL_ITERATIONS);
}

// Interruption policy for background scheduler and goal turns, mirroring the engine
// `ProactiveConfig` (Sources/RuneWeaverCore/Config.swift).

// Reads the live goal tool budget from GET /settings, preferring camelCase
// and falling back to the engine default on absent or drifted shapes.
export function goalsMaxToolIterations(
  goals: GoalsConfigData | undefined | null,
): number {
  const raw =
    goals?.maxToolIterations ??
    DEFAULT_GOALS_MAX_TOOL_ITERATIONS;
  return clampToolRounds(raw, DEFAULT_GOALS_MAX_TOOL_ITERATIONS);
}

// Reads the live per-type interruption preferences from GET /settings,
// degrading an absent section to all-enabled so older engines still surface
// every type. Unknown keys never reach the form; filtering only quiets
// interruptions while history and inbox rows keep recording.
export function notificationsConfig(
  settings: SettingsResponse | undefined | null,
): NotificationsConfigData {
  if (!settings?.notifications) return { ...DEFAULT_NOTIFICATIONS_CONFIG };
  return resolveNotificationsConfig(settings.notifications);
}

