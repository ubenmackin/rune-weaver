// Rune Weaver Dashboard — Settings manager for config.toml configuration.
// Allows managing LLM providers, engine identity, container policy, memory, voice, web search, email accounts, and the owner-facing assistant persona.
// The persona pane persists [persona] through the shared settings PUT with a
// changed-only patch and publishes every loaded and saved snapshot to the
// shared persona store, so identity surfaces mirror the owner's edits live.

import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_CONTAINERS_CONFIG,
  CONTAINERS_MAX_CONCURRENT_MAX,
  CONTAINERS_MAX_CONCURRENT_MIN,
  CONTAINERS_MEMORY_MAX_MB,
  CONTAINERS_MEMORY_MIN_MB,
  CONTAINERS_TTL_MAX_MINUTES,
  CONTAINERS_TTL_MIN_MINUTES,
  DEFAULT_SEARCH_MAX_RESULTS,
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
  DEFAULT_SERVER_HOSTNAME,
  DEFAULT_SERVER_PORT,
  MAX_SERVER_ALLOWED_HOSTS,
  MAX_SERVER_ALLOWED_HOST_LENGTH,
  formatServerAllowedHostsText,
  isLoopbackHostname,
  canonicalRestartHost,
  normalizeServerAllowedHost,
  parseServerAllowedHostsText,
  validateServerAllowedHosts,
  validateServerHostname,
  ensureSearch,
  getSearchHealth,
  hasActiveRuns,
  listRuns,
  removeSearch,
  resolveSearchDiagnostics,
  resolveSearchMessage,
  RUN_LOG_POLL_LIMIT,
  searchStageCopy,
  startElapsedSeconds,
  getSettings,
  updateSettings,
  rotateToken,
  clearAuthToken,
  authHeaders,
  isSessionAuthenticated,
  getPlugins,
  rescanPlugins,
  stopSearch,
  updatePluginState,
  uninstallPlugin,
  getTools,
  updateToolState,
  DEFAULT_DESKTOP_BLOCKED_APPS_TEXT,
  DEFAULT_DESKTOP_JPEG_QUALITY,
  DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION,
  DEFAULT_GOALS_ENABLED,
  DEFAULT_GOALS_MAX_ACTIVE_GOALS,
  DEFAULT_GOALS_STEP_INTERVAL_MINUTES,
  DEFAULT_GOALS_MAX_STEPS_PER_GOAL,
  DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS,
  DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL,
  DEFAULT_ENGINE_MAX_TOOL_ITERATIONS,
  TOOL_ROUNDS_MIN,
  TOOL_ROUNDS_MAX,
  engineMaxToolIterations,
  schedulerMaxToolIterations,
  goalsMaxToolIterations,
  DEFAULT_IDEAS_ENABLED,
  DEFAULT_IDEAS_MAX_PER_CYCLE,
  DEFAULT_IDEAS_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
  DEFAULT_MEDIA_TIMEOUT_SECONDS,
  DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS,
  DEFAULT_PROACTIVE_MODE,
  GOALS_MAX_ACTIVE_MAX,
  GOALS_MAX_ACTIVE_MIN,
  GOALS_STEP_INTERVAL_MAX_MINUTES,
  GOALS_STEP_INTERVAL_MIN_MINUTES,
  PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS,
  PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS,
  PROACTIVE_MODES,
  normalizeProactiveMode,
  isValidProactiveMode,
  DEFAULT_PERSONA_AVATAR,
  DEFAULT_PERSONA_TONE,
  MAX_PERSONA_ASSISTANT_NAME_LENGTH,
  MAX_PERSONA_STYLE_LENGTH,
  MAX_PERSONA_USER_NAME_LENGTH,
  PERSONA_AVATAR_COLORS,
  PERSONA_TONE_OPTIONS,
  PERSONA_TONES,
  normalizePersonaAvatarColor,
  normalizePersonaTone,
  personaAssistantName,
  personaStyle,
  personaUserName,
  type PersonaData,
  type PersonaSettingsUpdate,
  formatBlockedAppsText,
  parseBlockedAppsText,
  DEFAULT_FANOUT_FULL_TOOLS,
  DEFAULT_FANOUT_MAX_WORKERS,
  DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
  DEFAULT_WORKSPACE_CONFIG,
  WORKSPACE_QUOTA_FILES_MAX,
  WORKSPACE_QUOTA_FILES_MIN,
  WORKSPACE_QUOTA_MB_MAX,
  WORKSPACE_QUOTA_MB_MIN,
  WORKSPACE_TMP_TTL_MAX_DAYS,
  WORKSPACE_TMP_TTL_MIN_DAYS,
  type ContainersConfigData,
  type ContainersSettingsUpdate,
  type DesktopConfigData,
  type DesktopSettingsUpdate,
  type EmailAccountData,
  type FanoutConfigData,
  type FanoutSettingsUpdate,
  type GoalsConfigData,
  type GoalsSettingsUpdate,
  type IdeasConfigData,
  type IdeasSettingsUpdate,
  type ProactiveConfigData,
  type ProactiveSettingsUpdate,
  type MediaConfigData,
  type ProviderConfigData,
  type SettingsResponse,
  type PluginSummary,
  type ToolInfo,
  type WorkspaceConfigData,
  type WorkspaceSettingsUpdate,
  checkSecretStatus,
  formatWorkspaceBytes,
  getWorkspaceMachine,
  getWorkspaceUsage,
  isPromotableScriptPath,
  listAgentTools,
  promoteAgentTool,
  pruneWorkspaceTmp,
  recycleWorkspaceMachine,
  runAgentTool,
  setAgentToolStatus,
  shortAgentToolHash,
  stopWorkspaceMachine,
  validateAgentToolPromote,
  workspaceQuotaPercent,
  WORKSPACE_TOOLS_PREFIX,
  type AgentTool,
  type WorkspaceMachineResponse,
  type WorkspaceUsageResponse,
} from "../api";
import {
  AlertTriangleIcon,
  ApprovalsIcon,
  CalendarIcon,
  ChatIcon,
  CheckIcon,
  CloseIcon,
  FolderIcon,
  GlobeIcon,
  KeyIcon,
  MailIcon,
  MemoryIcon,
  MenuIcon,
  MessageSquareIcon,
  MicIcon,
  MonitorIcon,
  PlusIcon,
  RefreshIcon,
  SearchIcon,
  SettingsIcon,
  StopIcon,
  TargetIcon,
  TerminalIcon,
  TrashIcon,
  UserIcon,
  WrenchIcon,
} from "./icons";
import Modal from "./Modal";
import { StoreSecretModal } from "./StoreSecretModal";
import RuneMarketplaceModal from "./RuneMarketplaceModal";
import { IndexPolicyPanel } from "./IndexingPanel";
import AccessPane from "./AccessPane";
import {
  PersonaAvatar,
  publishPersonaFromSettings,
} from "./PersonaAvatar";
import { ToastStack } from "./Toast";
import {
  ACCESS_RULES_SECTION_TOKEN,
  readAccessDeepLink,
  readAccessParamValue,
} from "./access/accessNav";
import { useRunningRuns } from "../hooks/useRunningRuns";
import { useToastStack } from "../hooks/useToastStack";
import { useSearchStartProgress } from "../hooks/useSearchStartProgress";
import { useIsMobile } from "../hooks/useIsMobile";

// Vertical navigation keeps every category visible without horizontal scrolling; Access leads
// because it is the owner "what the agent may do" home — standing rules, Bash & Shell, Network,
// Credentials, and Files write posture all live on its section rail, and the policy.toml editor
// is reached through its Network sub-tabs, so no separate Policy tab remains. Security keeps
// container governance plus the Files & Access guard (allow roots, deny patterns, approval on
// deny) plus token rotation. The `search` id stays verbatim while the pane displays as Web: the
// search* API aliases and the /search/* health routes are keyed to that id, so only the label
// moves. The `network` pane owns the [server] bind (hostname, port, allowed_hosts) plus the
// restart banner.
// Persona and goals sit beside providers because the owner reaches for identity
// and durable pursuit as often as model routing; engine keeps only its own
// knobs plus the background interruption policy so each surface stays scannable.
type SettingsTab =
  | "access"
  | "providers"
  | "persona"
  | "goals"
  | "engine"
  | "tools"
  | "security"
  | "memory"
  | "voice"
  | "search"
  | "email"
  | "network"
  | "indexing";

// Closed tab vocabulary for fail-closed selection: an unknown id keeps the
// current tab instead of blanking the content pane, so drifted callers can
// never strand the form without a visible section.
const SETTINGS_TABS: readonly SettingsTab[] = [
  "access",
  "providers",
  "persona",
  "voice",
  "memory",
  "goals",
  "tools",
  "indexing",
  "search",
  "email",
  "security",
  "network",
  "engine",
];

// Section-finder index behind the sidenav search: each tab matches its own
// label plus the capability words owners reach for, so one query discovers the
// pane wherever its knob actually lives. Access carries the section names the
// approvals inbox and owner vocabulary use (rules, bash, network, credentials,
// files) because those editors live behind the pane, not on the tab itself.
const SETTINGS_TAB_KEYWORDS: Record<SettingsTab, string> = {
  access:
    "access rules permissions allow deny standing bash shell commands network domains egress credentials keys files write posture policy sandbox review",
  providers: "llm providers models api keys routing fallback",
  persona: "persona identity tone style avatar assistant name",
  goals: "goals pursuit cadence plan steps triggers",
  engine: "engine logs name compaction tool rounds proactive ideas interruption",
  tools: "tools runes plugins builtin agents workspace promoted scripts marketplace",
  security: "security containers sandbox files allow roots deny approval blocked paths token rotation",
  memory: "memory storage vectors episodes embeddings recall",
  voice: "voice whisper speech stt tts",
  search: "web search searxng browser timeouts fetch",
  email: "email accounts imap smtp mailboxes",
  network: "network server hostname port bind allowed hosts restart",
  indexing: "indexing index documents status",
};

// Matches one tab against the trimmed lowercase section-finder query.
function matchesSettingsTab(tab: SettingsTab, query: string): boolean {
  if (!query) return true;
  return SETTINGS_TAB_KEYWORDS[tab].includes(query);
}

// Narrows an unknown tab id to the known vocabulary without throwing, so
// selection stays fail-closed on drifted or persisted values.
export function isSettingsTab(value: unknown): value is SettingsTab {
  return (
    typeof value === "string" &&
    (SETTINGS_TABS as readonly string[]).includes(value)
  );
}

// An access deep link lands on Access whether it names the section or a
// single rule. The shared readers resolve raw values and rule ids across hash
// and query-string forms; the bare section token returns null from the rule
// reader by design, so it is matched explicitly here while everything else
// delegates — this file never re-runs the URLSearchParams loop itself.
function hasAccessSectionLink(): boolean {
  if (typeof window === "undefined") return false;
  if (readAccessDeepLink() !== null) return true;
  return readAccessParamValue() === ACCESS_RULES_SECTION_TOKEN;
}

// Converges a loaded tone/accent spelling to the closed set the engine merge
// accepts, falling back to the stock default for an unknown or absent value.
// The populate path and the delta baseline must start from identical converged
// values: if one kept a drifted stored spelling while the other normalized,
// the pane would open dirty on a value the owner never typed.
function canonicalPersonaTone(value: unknown): string {
  const normalized = normalizePersonaTone(value);
  return (PERSONA_TONES as readonly string[]).includes(normalized)
    ? normalized
    : DEFAULT_PERSONA_TONE;
}

function canonicalPersonaAvatarColor(value: unknown): string {
  const normalized = normalizePersonaAvatarColor(value);
  return (PERSONA_AVATAR_COLORS as readonly string[]).includes(normalized)
    ? normalized
    : DEFAULT_PERSONA_AVATAR;
}

interface ToolCategoryMeta {
  id: string;
  name: string;
  description: string;
  icon: (props: { size?: number; className?: string }) => React.JSX.Element;
}

// Browser and web tools share one section because they dial the same [browser]
// timeout surface (SearXNG plus request timeouts) and one Configure editor;
// splitting them stranded web.fetch away from the timeout UI its calls need.
// The browser-web id is the sole grouping for both prefixes, so pills, search
// filtering, and bulk toggles stay in lockstep and any future browser.* or
// web.* tool lands here without a second pill or section. Bash, files, and
// calendar-reminders each keep a dedicated section carrying only the
// enablement toggle; their policy editors live on the Access surface, so no
// category-level Configure is offered here.
const TOOL_CATEGORIES: readonly ToolCategoryMeta[] = [
  { id: "desktop", name: "Desktop & Automation", description: "Screen capture, OCR, and approval-gated mouse/keyboard control", icon: MonitorIcon },
  { id: "messages", name: "Messages & SMS", description: "Search, read, and send macOS iMessages and text messages", icon: MessageSquareIcon },
  { id: "email", name: "Email & Mailboxes", description: "IMAP search, message read, attachment inspection, and drafts", icon: MailIcon },
  { id: "calendar-reminders", name: "Calendar & Reminders", description: "macOS Calendar events and Reminders management", icon: CalendarIcon },
  { id: "browser-web", name: "Browser, Web & API", description: "Web search, page fetch, browser automation, and API requests", icon: GlobeIcon },
  { id: "bash", name: "Bash & Shell", description: "Terminal execution and sandboxed system commands", icon: TerminalIcon },
  { id: "files", name: "Files & Workspace", description: "Filesystem reads, staged changes, and workspace writes", icon: FolderIcon },
  { id: "memories", name: "Long-Term Memory", description: "Episodic and profile memory store and recall", icon: MemoryIcon },
  { id: "goal", name: "Autonomous Goals", description: "Multi-turn goal planning, tracking, and execution", icon: TargetIcon },
  { id: "fanout", name: "Fan-Out Workers", description: "Concurrent worker turns for parallel subtasks", icon: WrenchIcon },
  { id: "media", name: "Media & Streaming", description: "Media search and client control", icon: WrenchIcon },
  { id: "other", name: "Other Tools", description: "General utility tools and external plugins", icon: WrenchIcon },
];

// Prefix routing keeps the category vocabulary closed: every builtin lands in
// exactly one section, with browser.*, web.*, and api.* intentionally collapsed
// into browser-web so the single Browser, Web & API editor owns all three.
// External plugin tools stay in Other regardless of name prefix, so a
// colliding bash.evil or files.evil never joins a builtin section; only builtin
// names route by prefix.
const KNOWN_BUILTIN_TOOL_CATEGORIES: Record<string, string> = {
  "desktop.screenshot": "desktop",
  "desktop.action": "desktop",
  "messages.search": "messages",
  "messages.read": "messages",
  "messages.send": "messages",
  "email.search": "email",
  "email.read": "email",
  "email.attachment": "email",
  "email.send": "email",
  "email.listMailboxes": "email",
  "email.move": "email",
  "calendar.search": "calendar-reminders",
  "calendar.create": "calendar-reminders",
  "calendar.update": "calendar-reminders",
  "calendar.delete": "calendar-reminders",
  "calendar.list": "calendar-reminders",
  "reminders.search": "calendar-reminders",
  "reminders.create": "calendar-reminders",
  "reminders.update": "calendar-reminders",
  "reminders.delete": "calendar-reminders",
  "reminders.list": "calendar-reminders",
  "browser.navigate": "browser-web",
  "browser.act": "browser-web",
  "web.search": "browser-web",
  "web.fetch": "browser-web",
  "bash.exec": "bash",
  "files.read": "files",
  "files.grep": "files",
  "files.glob": "files",
  "files.write": "files",
  "files.list": "files",
  "memories.store": "memories",
  "memories.recall": "memories",
  "goal.create": "goal",
  "goal.status": "goal",
  "goal.progress": "goal",
  "fanout.run": "fanout",
  "media.arr": "media",
  "media.arr.read": "media",
  "api.request": "browser-web",
};

// Routes a builtin tool name by prefix. Callers must gate on provenance
// first; this helper alone cannot tell bash.exec apart from bash.evil.
function resolveBuiltinCategoryByName(toolName: string): string {
  if (toolName.startsWith("desktop.")) return "desktop";
  if (toolName.startsWith("messages.")) return "messages";
  if (toolName.startsWith("email.")) return "email";
  if (toolName.startsWith("calendar.") || toolName.startsWith("reminders.")) return "calendar-reminders";
  if (toolName.startsWith("browser.") || toolName.startsWith("web.") || toolName.startsWith("api.")) return "browser-web";
  if (toolName.startsWith("bash.")) return "bash";
  if (toolName.startsWith("files.")) return "files";
  if (toolName.startsWith("memories.")) return "memories";
  if (toolName.startsWith("goal.")) return "goal";
  if (toolName.startsWith("fanout.")) return "fanout";
  if (toolName.startsWith("media.")) return "media";
  return "other";
}

// Groups tools by name prefix into builtin sections, with provenance gating
// so external names never join a builtin section. The string form has no
// provenance, so it resolves only exact known builtin names and falls through
// to other otherwise; object callers carry isBuiltIn and route by prefix once
// the external gate passes.
export function getToolCategory(tool: ToolInfo): string;
export function getToolCategory(toolName: string): string;
export function getToolCategory(tool: ToolInfo | string): string {
  if (typeof tool === "string") {
    return KNOWN_BUILTIN_TOOL_CATEGORIES[tool] ?? "other";
  }
  if (tool.isBuiltIn === false) return "other";
  return resolveBuiltinCategoryByName(tool.name);
}

// One Configure entry per integration surface keeps a single modal per editor:
// desktop, media, fanout, and browser-web each own one existing modal, so the
// header button opens that editor whenever any rendered tool in the category
// reports hasConfig. Bash, files, and calendar-reminders have no entry: their
// editors live on the Access surface and each keeps a dedicated section with
// only the enablement toggle, so no category header can dangle a Configure
// for a moved editor. Security stays the single config-form editor
// for allow roots, deny patterns, and approval on deny. The server hasConfig
// flag is the sole authority — a null key or no flagged tool hides the button,
// which keeps unconfigurable categories clean and avoids stale per-tool
// buttons when new tools gain editors later.
// Edge case: a filtered view with zero flagged tools in a configurable
// category still hides Configure, so search never offers a dead editor.
function getCategoryConfigKey(categoryId: string): string | null {
  if (categoryId === "desktop") return "desktop";
  if (categoryId === "media") return "media.arr";
  if (categoryId === "fanout") return "fanout.run";
  if (categoryId === "browser-web") return "browser.navigate";
  return null;
}

interface ProviderEntry {
  id: string;
  name: string;
  config: ProviderConfigData;
}

interface EmailEntry {
  id: string;
  account: EmailAccountData;
}

function getEmailPasswordEnv(name: string): string {
  // Unicode-aware to match Swift `EmailAccount.passwordEnvVar`, which keeps
  // Unicode letters/numbers and maps everything else to `_`.
  const safeName = name.toUpperCase().replace(/[^\p{L}\p{N}]/gu, "_");
  return `EMAIL_${safeName}_PASSWORD`;
}

// Shared desktop capture bounds check for the full-save and Configure
// modal-save paths so both reject a bad dimension or quality before any
// network write with one message. Mirrors Config+Validation bounds
// (256-3840, 0.1-1.0).
function validateDesktopCaptureBounds(
  maxImageDimension: number | string,
  jpegQuality: number | string
): string | null {
  const dimNum = Number(maxImageDimension);
  if (!Number.isInteger(dimNum) || dimNum < 256 || dimNum > 3840) {
    return "Invalid desktop image dimension: max image dimension must be between 256 and 3840.";
  }
  const qualityNum = Number(jpegQuality);
  if (!Number.isFinite(qualityNum) || qualityNum < 0.1 || qualityNum > 1.0) {
    return "Invalid desktop JPEG quality: jpeg quality must be between 0.1 and 1.0.";
  }
  return null;
}

// Shared browser automation timeout bounds check for the full-save and the
// browser modal-save paths so an out-of-range value fails on the client
// instead of returning a server 400 from load validation. Mirrors the
// Config+Validation browser.timeout_seconds bound (5-300).
function validateBrowserTimeoutSeconds(value: number | string): string | null {
  const timeoutNum = Number(value);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 5 || timeoutNum > 300) {
    return "Invalid browser timeout: automation timeout must be between 5 and 300 seconds.";
  }
  return null;
}

// Shared direct HTTP request timeout bounds check for the full-save and the
// browser modal-save paths so an out-of-range value fails on the client
// instead of returning a server 400 from load validation. Mirrors the
// Config+Validation browser.fetch_timeout_seconds bound (1-120).
function validateBrowserFetchTimeoutSeconds(value: number | string): string | null {
  const timeoutNum = Number(value);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 1 || timeoutNum > 120) {
    return "Invalid HTTP request timeout: request timeout must be between 1 and 120 seconds.";
  }
  return null;
}

// Shared media request timeout bounds check for the full-save and the media
// modal-save paths so an out-of-range value fails on the client instead of
// returning a server 400 from load validation. Mirrors the
// Config+Validation media.timeout_seconds bound (5-120).
function validateMediaTimeoutSeconds(value: number | string): string | null {
  const timeoutNum = Number(value);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 5 || timeoutNum > 120) {
    return "Invalid media timeout: request timeout must be between 5 and 120 seconds.";
  }
  return null;
}

// Managed browser Python (Playwright) staged progress, mirroring the search
// health shape so the Settings Web pane stays in lockstep instead of
// duplicating timer logic. Homebrew system pythons refuse `pip install`
// outside a venv while `pipx` and the Homebrew `playwright-cli` formula never
// satisfy `import playwright`, so the engine provisions `~/.runeweaver/python`
// once (venv, `pip install playwright`, `playwright install chromium`) and
// publishes one of these steps plus the Start time while the flight runs.
export const BROWSER_PYTHON_VENV_DISPLAY = "~/.runeweaver/python";
export const BROWSER_START_POLL_INTERVAL_MS = 1000;
export const BROWSER_START_CAP_MS = 600_000;
// Pinned Playwright pip requirement the managed provision installs, mirrored
// from PlaywrightPythonEnsurer so an operator's manual recovery converges on
// the same exact release instead of floating across breaking helper APIs.
export const BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT = "playwright==1.49.1";
// User copy per managed-browser provision stage. Mirrors the engine provision
// stage copy so the Preparing line names the same step on both sides; the
// contract test pins this table to the engine wording so drift fails loudly
// instead of silently relabeling the flight.
export const BROWSER_PYTHON_STAGE_COPY: Record<string, string> = {
  resolving: "Finding system Python",
  creating: "Creating managed browser environment",
  installing: "Installing Playwright package",
  browsers: "Installing Chromium browser",
};

// Preset bind targets for the single Network bind control: loopback-only
// serves without a token, while the all-interfaces value needs a resolvable
// owner token and fails closed otherwise. Any other value (localhost, ::1, a
// literal LAN IP) stays on the custom option with its address held directly in
// serverHostname. An explicit custom pick preserves the preset value in the
// revealed input instead of clearing to empty, tracked by the custom flag so
// the selector can stay on custom while holding a preset spelling.
export const SERVER_BIND_PRESETS = ["127.0.0.1", "0.0.0.0"];

// Compares a bind hostname against the preset list case-insensitively via the
// shared restart canonicalization (trim plus lowercase plus IPv6-bracket
// handling) so casing or bracket-only spellings the gate treats identically
// never force a spurious custom pick.
function isServerBindPreset(hostname: string): boolean {
  const candidate = canonicalRestartHost(hostname);
  return SERVER_BIND_PRESETS.some(
    (preset) => canonicalRestartHost(preset) === candidate,
  );
}

// Re-anchor cadence for the live bind while the Network pane is open: polls
// /health so an external restart moves live to the new boot and the banner
// clears without a manual Refresh. Five seconds keeps the banner honest
// without adding steady-state QPS once file converges with boot.
export const SERVER_BOOT_POLL_INTERVAL_MS = 5000;

// Compares allowed_hosts as an order-insensitive IPv6-bracket-canonicalized
// set so a reorder-only, case-only, or IPv6 bracket-only edit never trips a
// spurious restart; each entry runs through the stored Host normalization
// plus the restart bracket canonicalization, matching the server compare of
// normalizedAllowedHost wrapped in canonicalRestartHost. Only bracketed
// spellings whose inner text holds a colon (IPv6) canonicalize, so bracketed
// non-IPv6 spellings stay distinct.
function areServerAllowedHostsEqual(a: string[], b: string[]): boolean {
  const sortedA = [...new Set(a.map((h) => canonicalRestartHost(normalizeServerAllowedHost(h))))].sort();
  const sortedB = [...new Set(b.map((h) => canonicalRestartHost(normalizeServerAllowedHost(h))))].sort();
  if (sortedA.length !== sortedB.length) return false;
  return sortedA.every((h, i) => h === sortedB[i]);
}

interface BrowserPythonHealthPayload {
  ready?: boolean | null;
  pythonPath?: string | null;
  venvPath?: string | null;
  stage?: string | null;
  startedAt?: number | null;
  message?: string | null;
  diagnostics?: string | null;
  started?: boolean | null;
}

// Extracts the live provision stage, normalizing blank or non-string payloads
// to null so the Preparing line only renders for a real in-flight step.
export function resolveBrowserStage(
  response: BrowserPythonHealthPayload | null | undefined,
): string | null {
  if (!response) return null;
  const raw =
    typeof response.stage === "string" && response.stage.trim()
      ? response.stage.trim()
      : "";
  return raw || null;
}

// Extracts the in-flight provision Start time (Unix seconds), normalizing
// missing or non-positive payloads to null so elapsed math falls back to the
// client-side Start instant instead of a garbage epoch.
export function resolveBrowserStartedAt(
  response: BrowserPythonHealthPayload | null | undefined,
): number | null {
  if (!response) return null;
  const raw = response.startedAt;
  return typeof raw === "number" && Number.isFinite(raw) && raw > 0
    ? raw
    : null;
}

// Maps a provision stage to its user copy, degrading unknown stages to a bare
// Preparing label so engine drift never blanks the in-flight line.
export function browserStageCopy(stage: string | null | undefined): string {
  if (stage && BROWSER_PYTHON_STAGE_COPY[stage])
    return BROWSER_PYTHON_STAGE_COPY[stage];
  return "Preparing";
}

// Reports whether the live stage is a minutes-budget download, during which
// the client cap suspends so a first-run pip or Chromium fetch never trips the
// hung-provision path early. Single-sourced so the poll and the cap agree.
export function isBrowserLongStage(stage: string | null | undefined): boolean {
  return stage === "installing" || stage === "browsers";
}

// Shared elapsed helper lives in the API client so browser provision and
// search Start progress agree on one clamp; aliased here so existing call
// sites keep a descriptive name without duplicating the clamp logic.
export const browserElapsedSeconds = startElapsedSeconds;

// Trims an engine banner or diagnostics string, normalizing blank payloads to
// null so callers never render whitespace as detail.
function trimBrowserText(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

// Badge-probe chunk size pinned to the server status cap (`maxSecretStatusKeys`
// in `Sources/RuneWeaverServer/ServerSettingsRoutes.swift`). The server owns
// the bound; this mirror must stay equal at 500 distinct keys so the email
// plus provider plus media union merges chunks instead of tripping a 400 when
// the list grows. Both sides pin 500 (see `SettingsRouteTests` plus the
// dashboard contract test); update both together.
export const SECRET_STATUS_CHUNK_SIZE = 500;

export interface SettingsManagerProps {
  onSettingsSaved?: () => void;
}

export default function SettingsManager({ onSettingsSaved }: SettingsManagerProps = {}) {
  const [settings, setSettings] = useState<SettingsResponse | null>(null);
  const [activeTab, setActiveTab] = useState<SettingsTab>(() => {
    if (typeof window !== "undefined") {
      if (hasAccessSectionLink()) return "access";
      const match = window.location.hash.match(/#settings\/([a-z-]+)/);
      if (match && isSettingsTab(match[1])) return match[1];
    }
    return "providers";
  });

  useEffect(() => {
    function syncTabFromHash() {
      if (typeof window === "undefined") return;
      if (hasAccessSectionLink()) {
        setActiveTab("access");
      } else {
        const match = window.location.hash.match(/#settings\/([a-z-]+)/);
        if (match && isSettingsTab(match[1])) {
          setActiveTab(match[1]);
        }
      }
    }
    window.addEventListener("hashchange", syncTabFromHash);
    return () => window.removeEventListener("hashchange", syncTabFromHash);
  }, []);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Transient toast queue for action feedback (tool toggles, plugin ops, saves).
  // Distinct notices stack with independent timers; an identical copy replaces
  // its sibling so repeat saves refresh one notice instead of duplicating.
  // Contextual health/state errors stay as persistent inline banners.
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast, clearToasts } =
    useToastStack();
  // Active-run guard: staged when a save is requested while in-flight work
  // exists. Cancel aborts the PUT; Continue saves and hot-reloads.
  const [showActiveGuard, setShowActiveGuard] = useState(false);
  // Shared run-log snapshot feeding the guard fallback when the fresh probe
  // fails; parked approvals never count because only running lights the guard.
  const { runs: sharedRuns } = useRunningRuns();
  // Handheld drawer visibility for the settings sidenav. Closed by default so
  // the form keeps the screen on first paint; desktop renders the same sidenav
  // inline via stylesheet alone, so this flag only moves the handheld drawer.
  const [settingsMenuOpen, setSettingsMenuOpen] = useState(false);
  // Section-finder query for the sidenav. Blank shows every tab; a non-blank
  // query keeps only tabs whose label or keyword index matches, so one word
  // ("bash", "rules", "credentials") surfaces the Access pane whose editors
  // live behind the pane rather than on the tab label itself.
  const [settingsNavQuery, setSettingsNavQuery] = useState("");
  // Trigger that opens the settings drawer. Dismissals return focus here so
  // keyboard users land back on the control that opened the drawer instead of
  // losing focus to the document body.
  const menuButtonRef = useRef<HTMLButtonElement | null>(null);
  // Live handheld flag from the shared breakpoint so tab selection can close
  // the drawer on mobile while leaving the desktop inline sidenav untouched.
  const isMobile = useIsMobile();

  // Returns focus to the hamburger after a drawer dismissal. The trigger stays
  // mounted in both drawer states (stylesheet hides it on desktop), so focus
  // can move synchronously without waiting for a post-close mount.
  const returnFocusToMenuButton = useCallback(() => {
    menuButtonRef.current?.focus();
  }, []);

  // Close-only dismissal shared by backdrop, Escape, and tab-select paths so
  // those callers can never reopen a closed drawer by reusing a toggle.
  const closeSettingsMenu = useCallback(() => {
    setSettingsMenuOpen(false);
  }, []);

  // Backdrop dismissal for the handheld drawer. Desktop never renders a
  // backdrop, so this handler only fires on handheld widths.
  const handleSettingsBackdropClick = useCallback(() => {
    closeSettingsMenu();
    returnFocusToMenuButton();
  }, [closeSettingsMenu, returnFocusToMenuButton]);

  // Selects a settings tab while clearing any transient toasts so they
  // never follow navigation. Contextual errors stay as persistent banners.
  // Fail-closed on unknown ids: an invalid tab keeps the current tab instead
  // of blanking the pane. On handheld widths a valid select also dismisses
  // the drawer and returns focus to the hamburger; desktop keeps the inline
  // sidenav open across switches.
  const selectSettingsTab = useCallback(
    (tab: SettingsTab) => {
      if (!isSettingsTab(tab)) return;
      clearToasts();
      setActiveTab(tab);
      if (isMobile && settingsMenuOpen) {
        closeSettingsMenu();
        returnFocusToMenuButton();
      }
    },
    [clearToasts, isMobile, settingsMenuOpen, closeSettingsMenu, returnFocusToMenuButton]
  );

  // Escape dismissal for the handheld drawer. Registered only while the drawer
  // is open so unrelated Escape handling elsewhere never double-fires.
  useEffect(() => {
    if (!settingsMenuOpen) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      closeSettingsMenu();
      returnFocusToMenuButton();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [settingsMenuOpen, closeSettingsMenu, returnFocusToMenuButton]);

  // Clears toasts whenever the tab changes through any path so a save
  // notice never lingers across navigation.
  useEffect(() => {
    clearToasts();
  }, [activeTab, clearToasts]);

  // Form state
  const [engineName, setEngineName] = useState("");
  const [logLevel, setLogLevel] = useState("info");
  const [compactionThresholdPercent, setCompactionThresholdPercent] = useState(80);
  const [maxToolIterations, setMaxToolIterations] = useState<number | string>(DEFAULT_ENGINE_MAX_TOOL_ITERATIONS);
  const [defaultProvider, setDefaultProvider] = useState("");
  const [fallbackProvider, setFallbackProvider] = useState("");
  const [providersList, setProvidersList] = useState<ProviderEntry[]>([]);
  // Unified container runtime policy ([containers]): one table governs the
  // three knobs across bash tiers plus detonation, so the editors share one
  // Security section. Numeric inputs hold raw text (including empty) so a
  // cleared field surfaces a range error instead of silently keeping the
  // stored value; the images are pinned in code and never editable here.
  const [containersMemoryMB, setContainersMemoryMB] = useState<number | string>(
    DEFAULT_CONTAINERS_CONFIG.memoryMb
  );
  const [containersMaxConcurrent, setContainersMaxConcurrent] = useState<number | string>(
    DEFAULT_CONTAINERS_CONFIG.maxConcurrent
  );
  const [containersTTLMinutes, setContainersTTLMinutes] = useState<number | string>(
    DEFAULT_CONTAINERS_CONFIG.ttlMinutes
  );

  const [memoryVectorDBPath, setMemoryVectorDBPath] = useState("");
  const [memoryEpisodesDBPath, setMemoryEpisodesDBPath] = useState("");
  const [memoryEmbeddingModel, setMemoryEmbeddingModel] = useState("");
  const [memoryEmbeddingBackend, setMemoryEmbeddingBackend] = useState("apple");
  const [voiceSTTProvider, setVoiceSTTProvider] = useState("");
  const [voiceWhisperModel, setVoiceWhisperModel] = useState("");
  const [voiceTTSProvider, setVoiceTTSProvider] = useState("");
  // Web search policy under [browser]: SearXNG base URL plus per-request
  // timeout and result cap. Defaults mirror the engine so a fresh form shows
  // the same boundary the service enforces before the first settings fetch.
  const [searchSearxngURL, setSearchSearxngURL] = useState(
    DEFAULT_SEARCH_SEARXNG_URL
  );
  const [searchTimeoutSeconds, setSearchTimeoutSeconds] = useState(
    DEFAULT_SEARCH_TIMEOUT_SECONDS
  );
  const [searchMaxResults, setSearchMaxResults] = useState(
    DEFAULT_SEARCH_MAX_RESULTS
  );
  // Live container health for the Web pane: probed on tab open and updated
  // directly from Start/Stop action responses so the health line stays honest
  // without a page reload or an extra probe round-trip.
  const [searchReachable, setSearchReachable] = useState<boolean | null>(null);
  const [searchHealthLoading, setSearchHealthLoading] = useState(false);
  // Tracks which lifecycle action is in flight so Starting… names the start,
  // Stopping… names the stop, and Removing… names the remove instead of sharing
  // one misleading label.
  const [searchAction, setSearchAction] = useState<
    "start" | "stop" | "remove" | null
  >(null);
  const searchActionBusy = searchAction !== null;
  // Single source for the toggle direction: running offers Stop while stopped
  // and unknown both offer Start, so the header never shows two buttons.
  const searchRunning = searchReachable === true;
  // Guarded remove enablement: only a known stopped entry or an
  // unknown-never-started host may delete, never a running entry and never
  // while any lifecycle action is busy. A running entry must stop first so the
  // server never half-deletes a live container.
  const searchRemoveEnabled = !searchActionBusy && !searchRunning;
  // Non-blocking remove confirmation: the pending flag renders the shared modal
  // so the container entry is never deleted by an accidental click.
  const [pendingRemoveSearch, setPendingRemoveSearch] = useState(false);
  // Shared staged Start progress (1s poll, minutes-budget cap, elapsed, cleanup) feeding the
  // amber Starting line; busy ownership stays here so the cap path keeps the toggle locked.
  const {
    searchStage,
    searchStartElapsed,
    beginSearchStartProgress,
    endSearchStartProgress,
  } = useSearchStartProgress();
  const [searchHealthError, setSearchHealthError] = useState<string | null>(
    null
  );
  // Chained per-stage detail for the optional collapsed diagnostics element.
  // The inline banner stays trimmed to terminal cause plus one remediation;
  // this holds the full stage chain for operators without nesting it in the banner.
  const [searchDiagnostics, setSearchDiagnostics] = useState<string | null>(
    null
  );
  // Managed browser Python health for the Web pane: probed on tab open and
  // updated directly from the Ensure response so the state stays honest
  // without a reload. Tri-state (Ready/Missing/Unknown) plus a Preparing
  // state with stage copy and elapsed while a provision flight runs. The
  // venv path, resolved interpreter, and manual fallback live behind Advanced
  // so the common case shows one action rather than setup internals.
  const [browserReady, setBrowserReady] = useState<boolean | null>(null);
  const [browserPythonPath, setBrowserPythonPath] = useState<string>("");
  const [browserVenvPath, setBrowserVenvPath] = useState<string>(
    BROWSER_PYTHON_VENV_DISPLAY
  );
  const [browserHealthLoading, setBrowserHealthLoading] = useState(false);
  const [browserAction, setBrowserAction] = useState<"ensure" | null>(null);
  // Synchronous guard for the ensure flight: state commits asynchronously, so
  // a double-click before re-render would otherwise start two provisions. The
  // ref flips immediately and the state mirrors it for rendering.
  const browserActionRef = useRef<"ensure" | null>(null);
  const browserActionBusy = browserAction !== null;
  const [browserStage, setBrowserStage] = useState<string | null>(null);
  const [browserElapsed, setBrowserElapsed] = useState(0);
  const browserTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const browserStageRef = useRef<string | null>(null);
  const browserStartMsRef = useRef(0);
  // Handle to the Advanced disclosure so a provision error can force it open
  // while normal toggling stays user-owned; a controlled `open` prop would
  // instead pin it shut whenever no error is present.
  const browserAdvancedRef = useRef<HTMLDetailsElement | null>(null);
  const [browserError, setBrowserError] = useState<string | null>(null);
  const [browserDiagnostics, setBrowserDiagnostics] = useState<string | null>(
    null
  );
  const [emailAccountsList, setEmailAccountsList] = useState<EmailEntry[]>([]);
  const [pluginsDir, setPluginsDir] = useState("~/.runeweaver/plugins");
  const [pluginsMarketplaceIndexURL, setPluginsMarketplaceIndexURL] = useState(
    "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"
  );
  const [pluginsAutoRescan, setPluginsAutoRescan] = useState(true);

  // Plugins & Tools state
  const [pluginsList, setPluginsList] = useState<PluginSummary[]>([]);
  const [allTools, setAllTools] = useState<ToolInfo[]>([]);
  const [rescanLoading, setRescanLoading] = useState(false);
  const [marketplaceOpen, setMarketplaceOpen] = useState(false);
  const [updatingPluginId, setUpdatingPluginId] = useState<string | null>(null);
  // Non-blocking uninstall confirmation: the pending rune renders a true
  // modal so an installed plugin is never removed by an accidental click.
  const [pendingUninstallPlugin, setPendingUninstallPlugin] = useState<{
    id: string;
    name: string;
  } | null>(null);

  // Keychain secret status and store/update modal
  const [secretStatus, setSecretStatus] = useState<Record<string, boolean>>({});
  const [secretModal, setSecretModal] = useState<{
    isOpen: boolean;
    secretKey: string;
    title: string;
    isUpdate: boolean;
  } | null>(null);

  const handleOpenStoreSecretModal = (
    secretKey: string,
    label: string,
    isUpdate: boolean
  ) => {
    setSecretModal({
      isOpen: true,
      secretKey,
      title: isUpdate ? `Update ${label} in Keychain` : `Store ${label} to Keychain`,
      isUpdate,
    });
  };

  const handleSecretSaved = (key: string) => {
    setSecretStatus((prev) => ({ ...prev, [key]: true }));
    pushSuccessToast(`Stored secret for ${key} into macOS Keychain.`);
  };

  // Media configuration state (Sonarr & Radarr)
  const [sonarrEnabled, setSonarrEnabled] = useState(true);
  const [sonarrUrl, setSonarrUrl] = useState("");
  const [sonarrApiKeyEnv, setSonarrApiKeyEnv] = useState("SONARR_API_KEY");
  const [sonarrDefaultQuality, setSonarrDefaultQuality] = useState("");
  const [sonarrDefaultRoot, setSonarrDefaultRoot] = useState("");

  const [radarrEnabled, setRadarrEnabled] = useState(true);
  const [radarrUrl, setRadarrUrl] = useState("");
  const [radarrApiKeyEnv, setRadarrApiKeyEnv] = useState("RADARR_API_KEY");
  const [radarrDefaultQuality, setRadarrDefaultQuality] = useState("");
  const [radarrDefaultRoot, setRadarrDefaultRoot] = useState("");
  const [mediaTimeoutSeconds, setMediaTimeoutSeconds] = useState<number | string>(
    DEFAULT_MEDIA_TIMEOUT_SECONDS
  );

  // Single probe list for every Keychain-backed name so the status map drives
  // all badges: email password envs, provider apiKeyEnvs, and the Sonarr /
  // Radarr apiKeyEnv names. Media names come from the live form plus the last
  // loaded settings so a custom name stays probed before and after populate.
  const relevantSecretKeys = React.useMemo(() => {
    const keys = new Set<string>();
    for (const item of emailAccountsList) {
      const name = item.account.name?.trim();
      if (name) {
        keys.add(getEmailPasswordEnv(name));
      }
    }
    for (const item of providersList) {
      const keyEnv = (item.config.apiKeyEnv || item.config.apiKeyEnv || "").trim();
      if (keyEnv) {
        keys.add(keyEnv);
      }
    }
    const sonarrEnv = sonarrApiKeyEnv.trim();
    if (sonarrEnv) {
      keys.add(sonarrEnv);
    }
    const radarrEnv = radarrApiKeyEnv.trim();
    if (radarrEnv) {
      keys.add(radarrEnv);
    }
    const storedSonarrEnv = (
      settings?.media?.sonarr?.apiKeyEnv ||
      settings?.media?.sonarr?.apiKeyEnv ||
      ""
    ).trim();
    if (storedSonarrEnv) {
      keys.add(storedSonarrEnv);
    }
    const storedRadarrEnv = (
      settings?.media?.radarr?.apiKeyEnv ||
      settings?.media?.radarr?.apiKeyEnv ||
      ""
    ).trim();
    if (storedRadarrEnv) {
      keys.add(storedRadarrEnv);
    }
    return Array.from(keys);
  }, [emailAccountsList, providersList, sonarrApiKeyEnv, radarrApiKeyEnv, settings]);

  // Probes Keychain presence in server-sized chunks so the badge map stays
  // complete even when the email plus provider plus media union outgrows one
  // status request; chunks merge into one map before state lands.
  const refreshSecretStatus = useCallback(async (keysToQuery?: string[]) => {
    const keys = keysToQuery ?? relevantSecretKeys;
    if (keys.length === 0) return;
    try {
      const merged: Record<string, boolean> = {};
      for (let i = 0; i < keys.length; i += SECRET_STATUS_CHUNK_SIZE) {
        const chunk = keys.slice(i, i + SECRET_STATUS_CHUNK_SIZE);
        const res = await checkSecretStatus(chunk);
        if (res) {
          Object.assign(merged, res);
        }
      }
      setSecretStatus((prev) => ({ ...prev, ...merged }));
    } catch {
      // Ignore network errors on secret check
    }
  }, [relevantSecretKeys]);

  useEffect(() => {
    if (relevantSecretKeys.length > 0) {
      void refreshSecretStatus();
    }
  }, [relevantSecretKeys, refreshSecretStatus]);

  const [configuringToolName, setConfiguringToolName] = useState<string | null>(null);
  const [toolSearchQuery, setToolSearchQuery] = useState("");
  const [selectedToolCategory, setSelectedToolCategory] = useState("all");
  const [togglingCategory, setTogglingCategory] = useState<string | null>(null);
  const [mediaSaveLoading, setMediaSaveLoading] = useState(false);
  const [mediaModalError, setMediaModalError] = useState<string | null>(null);
  // Short-lived success-then-close timer for the media modal: held in a ref
  // (not bare setTimeout) so unmount or a second save clears the pending tick
  // instead of firing setState on an unmounted pane or closing a fresh edit.
  const mediaSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [browserTimeoutSeconds, setBrowserTimeoutSeconds] = useState<number | string>(
    DEFAULT_BROWSER_TIMEOUT_SECONDS
  );
  const [browserFetchTimeoutSeconds, setBrowserFetchTimeoutSeconds] = useState<number | string>(
    DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS
  );
  const [browserSaveLoading, setBrowserSaveLoading] = useState(false);
  const [browserModalError, setBrowserModalError] = useState<string | null>(null);
  const browserSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Native desktop vision and gated control ([desktop]): capture knobs for
  // desktop.screenshot plus the blocked-apps list for desktop.action. Each
  // tool configures from its own modal, so this form holds only the knobs —
  // tool enablement lives in the tool-state toggles above. The blocked-apps
  // editor holds raw textarea text (one app per line) so blank lines survive
  // editing and only collapse on save.
  const [desktopMaxImageDimension, setDesktopMaxImageDimension] = useState<
    number | string
  >(DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION);
  const [desktopJpegQuality, setDesktopJpegQuality] = useState<number | string>(
    DEFAULT_DESKTOP_JPEG_QUALITY
  );
  const [desktopBlockedAppsText, setDesktopBlockedAppsText] = useState<string>(
    DEFAULT_DESKTOP_BLOCKED_APPS_TEXT
  );
  const [desktopSaveLoading, setDesktopSaveLoading] = useState(false);
  const [desktopModalError, setDesktopModalError] = useState<string | null>(null);
  // Short-lived success-then-close timer for the desktop modal: held in a ref
  // (not bare setTimeout) so unmount or a second save clears the pending tick
  // instead of firing setState on an unmounted pane or closing a fresh edit.
  const desktopSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Parallel worker fan-out ([fanout]): swarm knobs for fanout.run. Number
  // inputs hold raw text (including empty) so clearing a field saves the
  // modal default instead of preserving the stale value; the toggle stays a
  // plain boolean. Enablement lives in the tool-state switch, so no enabled
  // key travels here. The fresh form seeds from the modal defaults before the
  // first settings fetch.
  const [fanoutMaxWorkers, setFanoutMaxWorkers] = useState<number | string>(
    DEFAULT_FANOUT_MAX_WORKERS
  );
  const [fanoutWorkerTimeoutSeconds, setFanoutWorkerTimeoutSeconds] = useState<
    number | string
  >(DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS);
  const [fanoutFullTools, setFanoutFullTools] = useState<boolean>(
    DEFAULT_FANOUT_FULL_TOOLS
  );
  // Last-loaded fan-out snapshot driving the changed-only patch: a field the
  // operator never touches stays omitted so the stored value survives, while a
  // cleared numeric field sends the modal default as an explicit change.
  const fanoutLoadedRef = useRef<FanoutConfigData>({
    maxWorkers: DEFAULT_FANOUT_MAX_WORKERS,
    workerTimeoutSeconds: DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
    fullTools: DEFAULT_FANOUT_FULL_TOOLS,
  });
  const [fanoutSaveLoading, setFanoutSaveLoading] = useState(false);
  const [fanoutModalError, setFanoutModalError] = useState<string | null>(null);
  // Short-lived success-then-close timer for the fan-out modal: held in a ref
  // (not bare setTimeout) so unmount or a second save clears the pending tick
  // instead of firing setState on an unmounted pane or closing a fresh edit.
  const fanoutSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Steady long-horizon pursuit ([goals]): enablement plus the cadence hint
  // stored on each new goal and the active-goal cap bounding scheduler
  // fan-out. Planning bounds stay file-owned. The fresh form seeds from the
  // engine defaults so the editor matches the boundary before the first
  // settings fetch.
  const [goalsEnabled, setGoalsEnabled] = useState<boolean>(DEFAULT_GOALS_ENABLED);
  const [goalsStepIntervalMinutes, setGoalsStepIntervalMinutes] = useState<number | string>(
    DEFAULT_GOALS_STEP_INTERVAL_MINUTES
  );
  const [goalsMaxActiveGoals, setGoalsMaxActiveGoals] = useState<number | string>(
    DEFAULT_GOALS_MAX_ACTIVE_GOALS
  );
  const [goalsMaxStepsPerGoal, setGoalsMaxStepsPerGoal] = useState<number | string>(
    DEFAULT_GOALS_MAX_STEPS_PER_GOAL
  );
  const [goalsPlanTimeoutSeconds, setGoalsPlanTimeoutSeconds] = useState<number | string>(
    DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS
  );
  const [goalsMaxTriggersPerGoal, setGoalsMaxTriggersPerGoal] = useState<number | string>(
    DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL
  );
  // Proactive Wayfinder suggestions ([ideas]): opt-in enable toggle and generation bounds.
  const [ideasEnabled, setIdeasEnabled] = useState<boolean>(DEFAULT_IDEAS_ENABLED);
  const [ideasMaxPerCycle, setIdeasMaxPerCycle] = useState<number | string>(
    DEFAULT_IDEAS_MAX_PER_CYCLE
  );
  const [ideasTimeoutSeconds, setIdeasTimeoutSeconds] = useState<number | string>(
    DEFAULT_IDEAS_TIMEOUT_SECONDS
  );
  // Background interruption policy ([proactive]): surfacing mode plus the
  // guarded judge budget. Off never interrupts while the approvals inbox and
  // run history keep recording in every mode.
  const [proactiveMode, setProactiveMode] = useState<string>(DEFAULT_PROACTIVE_MODE);
  const [proactiveJudgeTimeoutSeconds, setProactiveJudgeTimeoutSeconds] = useState<number | string>(
    DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS
  );
  // Owner-facing assistant persona ([persona]): assistant name, tone preset,
  // free-form style guidance, the owner's preferred address name, and the
  // client-side avatar accent. Drafts hold raw text so a cleared field saves
  // the documented fallback rather than a coerced default, while tone and
  // accent drafts stay closed-set (populate normalizes, the picker only ever
  // writes known spellings). `personaLoadedRef` keeps the last-loaded snapshot
  // for the changed-only delta: a field the owner never touches stays omitted
  // so the stored value survives exactly like the goals and proactive patches.
  const [personaAssistantNameDraft, setPersonaAssistantNameDraft] = useState("");
  const [personaToneDraft, setPersonaToneDraft] = useState<string>(DEFAULT_PERSONA_TONE);
  const [personaStyleDraft, setPersonaStyleDraft] = useState("");
  const [personaUserNameDraft, setPersonaUserNameDraft] = useState("");
  const [personaAvatarDraft, setPersonaAvatarDraft] = useState<string>(DEFAULT_PERSONA_AVATAR);
  const personaLoadedRef = useRef<PersonaData>({});
  // Files & Access lives in the Security pane as the single files editor:
  // the page Save owns persistence through executeSave with
  // validateFilesFields and buildFilesPayload, so guard shapes never fork.
  // Network bind ([server] hostname, port, allowed_hosts): the socket and the
  // Host gate are fixed at boot, so saves persist to the file and return
  // requiresRestart instead of live-reloading. The allowed-hosts editor holds
  // raw textarea text (one exact host per line) so blank lines survive editing
  // and only collapse on save; the restart flag from the last PUT plus the
  // file-vs-boot comparison below drives the pending-vs-live banner.
  const [serverHostname, setServerHostname] = useState<string>(DEFAULT_SERVER_HOSTNAME);
  // Tracks an explicit Custom pick so entering custom mode preserves the
  // preset value in the revealed input instead of clearing to empty; the
  // selector stays on custom while the input holds the preset until edited,
  // and picking a preset clears the flag.
  const [serverHostnameCustom, setServerHostnameCustom] = useState(false);
  const [serverPort, setServerPort] = useState<number | string>(DEFAULT_SERVER_PORT);
  const [serverAllowedHostsText, setServerAllowedHostsText] = useState<string>("");
  const [serverRestartRequired, setServerRestartRequired] = useState(false);
  // Live boot bind snapshot: the socket and Host gate values fixed at process
  // start. File values from GET/PUT drift ahead after a network save, so the
  // restart banner compares the pending file against this boot snapshot
  // instead of file against file (which would render identical after
  // populateForm syncs the form to the PUT response). Seeded from the first
  // settings fetch and corrected from /health when the engine advertises its
  // boot bind; preserved across PUTs so a second save without a restart keeps
  // the original boot instead of sliding to an intermediate file.
  const [liveServerBind, setLiveServerBind] = useState<{
    hostname: string;
    port: number;
    allowedHosts: string[];
  } | null>(null);
  // Access-management flow: rotating the single owner token signs out every
  // other device the moment the engine swaps it, so the dashboard asks twice
  // before calling the route, then reveals the new token once. The API client
  // adopts the token as soon as rotation returns because the old one is already
  // invalid; the reveal stays until the owner acknowledges storing it, since a
  // false "saved" is the one unrecoverable mistake in this flow.
  const [rotateConfirmStep, setRotateConfirmStep] = useState<0 | 1 | 2>(0);
  const [rotating, setRotating] = useState(false);
  const [rotateError, setRotateError] = useState<string | null>(null);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [tokenSavedAck, setTokenSavedAck] = useState(false);
  const [tokenCopyState, setTokenCopyState] = useState<"idle" | "copied" | "failed">("idle");
  // Tracks the single builtin tool row with an in-flight toggle so sibling
  // rows stay interactive while one request is pending.
  const [togglingToolName, setTogglingToolName] = useState<string | null>(null);
  // Agent scratch workspace usage plus the hash-pinned script registry live on
  // the Tools tab beside the builtin switches. Usage bars read the live tree
  // from GET /workspace/usage while the quota editors below seed from
  // GET /settings [workspace] and persist through the tab save, so the bars
  // stay honest about the tree even while an edit is in flight. The registry
  // stays separate from plugin runes so a promoted shell script never shares
  // fate with an external package.
  const [workspaceUsage, setWorkspaceUsage] = useState<WorkspaceUsageResponse | null>(null);
  const [workspaceLoading, setWorkspaceLoading] = useState(false);
  const [workspaceError, setWorkspaceError] = useState<string | null>(null);
  // Editable scratch quotas bounding the workspace tree. Numeric inputs hold
  // raw text (including empty) so a cleared field surfaces a range error
  // instead of silently keeping the stored quota. The fresh form seeds from
  // the combined workspace default so the editors match the engine boundary
  // before the first settings fetch.
  const [workspaceQuotaMB, setWorkspaceQuotaMB] = useState<number | string>(
    DEFAULT_WORKSPACE_CONFIG.quotaMB
  );
  const [workspaceQuotaFiles, setWorkspaceQuotaFiles] = useState<number | string>(
    DEFAULT_WORKSPACE_CONFIG.quotaFiles
  );
  const [workspaceTmpTTLDays, setWorkspaceTmpTTLDays] = useState<number | string>(
    DEFAULT_WORKSPACE_CONFIG.tmpTTLDays
  );
  const [pruningWorkspace, setPruningWorkspace] = useState(false);
  const [pendingPruneWorkspace, setPendingPruneWorkspace] = useState(false);
  const [workspaceMachine, setWorkspaceMachine] = useState<WorkspaceMachineResponse | null>(null);
  const [workspaceMachineLoading, setWorkspaceMachineLoading] = useState(false);
  const [workspaceMachineError, setWorkspaceMachineError] = useState<string | null>(null);
  const [workspaceMachineAction, setWorkspaceMachineAction] = useState<"stop" | "recycle" | null>(null);
  const [agentTools, setAgentTools] = useState<AgentTool[]>([]);
  const [agentToolsLoading, setAgentToolsLoading] = useState(false);
  const [agentToolsError, setAgentToolsError] = useState<string | null>(null);
  const [togglingAgentToolId, setTogglingAgentToolId] = useState<string | null>(null);
  const [runningAgentToolId, setRunningAgentToolId] = useState<string | null>(null);
  const [agentRunOutput, setAgentRunOutput] = useState<Record<string, string>>({});
  const [promoteName, setPromoteName] = useState("");
  const [promoteScriptPath, setPromoteScriptPath] = useState("");
  const [promoteError, setPromoteError] = useState<string | null>(null);
  const [promotingTool, setPromotingTool] = useState(false);

  const loadPluginsData = useCallback(async () => {
    try {
      const [pluginsRes, toolsRes] = await Promise.all([
        getPlugins(),
        getTools(),
      ]);
      setPluginsList(Array.isArray(pluginsRes?.plugins) ? pluginsRes.plugins : []);
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
    } catch {
      setPluginsList([]);
      setAllTools([]);
    }
  }, []);

  // Refreshes the Web pane health line without touching the settings form: Start/Stop change
  // container state, not config values, so health stays separate from Save.
  // Honest tri-state: only a boolean reachable flag may move the dot, matching TopNav; empty or
  // shape-drifted payloads keep unknown gray (null) instead of coercing missing to false red Stopped.
  const refreshSearchHealth = useCallback(async () => {
    setSearchHealthLoading(true);
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    try {
      const response = await getSearchHealth();
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        // Health carries no diagnostics today; clear the collapsed slot so a
        // prior ensure failure never lingers beside fresh health.
        setSearchDiagnostics(resolveSearchDiagnostics(response));
      } else {
        setSearchReachable(null);
        setSearchHealthError(
          "Search health returned an unexpected response; status unknown."
        );
      }
    } catch (err) {
      setSearchReachable(null);
      setSearchDiagnostics(null);
      setSearchHealthError(
        err instanceof Error ? err.message : "Search health check failed."
      );
    } finally {
      setSearchHealthLoading(false);
    }
  }, []);

  // Stops the browser provision poll without touching terminal state; safe to
  // call twice so the cap path and the settle path can share it.
  const clearBrowserPoll = useCallback(() => {
    if (browserTimerRef.current !== null) {
      clearInterval(browserTimerRef.current);
      browserTimerRef.current = null;
    }
  }, []);

  // Refreshes the browser Python health line without touching the form:
  // provisioning changes the managed venv, not config values. Honest
  // tri-state like search: only a boolean ready flag may move the pill, while
  // a 404 from an older engine without `/browser/health` keeps Unknown with
  // the static venv hint instead of an error banner.
  const refreshBrowserHealth = useCallback(async () => {
    setBrowserHealthLoading(true);
    try {
      const res = await fetch("/browser/health", {
        headers: authHeaders(),
        credentials: "same-origin",
      });
      if (!res.ok) {
        // Older engines predate the browser lifecycle; keep the pill Unknown
        // so the static venv path plus manual fallback still guides setup.
        setBrowserReady(null);
        return;
      }
      const payload = (await res.json()) as BrowserPythonHealthPayload;
      if (typeof payload?.ready === "boolean") {
        setBrowserReady(payload.ready);
        if (typeof payload.pythonPath === "string" && payload.pythonPath.trim()) {
          setBrowserPythonPath(payload.pythonPath.trim());
        }
        if (typeof payload.venvPath === "string" && payload.venvPath.trim()) {
          setBrowserVenvPath(payload.venvPath.trim());
        }
      } else {
        setBrowserReady(null);
      }
    } catch {
      setBrowserReady(null);
    } finally {
      setBrowserHealthLoading(false);
    }
  }, []);

  // Arms a fresh provision poll: resets the stage line, records the
  // client-side Start instant, and polls health about 1s for the live step
  // plus elapsed. The cap fires only past the minutes budget while not in a
  // long download; it clears the stage line and re-probes the dot while
  // keeping the button locked until the terminal ensure result lands.
  const beginBrowserProgress = useCallback(() => {
    setBrowserStage(null);
    browserStageRef.current = null;
    setBrowserElapsed(0);
    const clientStartMs = Date.now();
    browserStartMsRef.current = clientStartMs;
    if (browserTimerRef.current !== null) {
      clearInterval(browserTimerRef.current);
      browserTimerRef.current = null;
    }
    browserTimerRef.current = setInterval(() => {
      if (
        Date.now() - clientStartMs > BROWSER_START_CAP_MS &&
        !isBrowserLongStage(browserStageRef.current)
      ) {
        if (browserTimerRef.current !== null) {
          clearInterval(browserTimerRef.current);
          browserTimerRef.current = null;
        }
        browserStageRef.current = null;
        setBrowserStage(null);
        void refreshBrowserHealth();
        return;
      }
      fetch("/browser/health", {
        headers: authHeaders(),
        credentials: "same-origin",
      })
        .then((res) => (res.ok ? res.json() : null))
        .then((payload) => {
          if (!payload || typeof payload !== "object") return;
          const typed = payload as BrowserPythonHealthPayload;
          const stage = resolveBrowserStage(typed);
          browserStageRef.current = stage;
          setBrowserStage(stage);
          setBrowserElapsed(
            startElapsedSeconds(
              resolveBrowserStartedAt(typed),
              browserStartMsRef.current
            )
          );
        })
        .catch(() => {
          // Poll failures only skip one tick; the next poll retries while the
          // pill stays put.
        });
    }, BROWSER_START_POLL_INTERVAL_MS);
  }, [refreshBrowserHealth]);

  // Terminal settle stops the Preparing line on every path so no settle leaves
  // the poll behind. Busy ownership stays with the caller.
  const endBrowserProgress = useCallback(() => {
    clearBrowserPoll();
    browserStageRef.current = null;
    setBrowserStage(null);
  }, [clearBrowserPoll]);

  // Provisions the managed venv through the dedicated ensure path: the server
  // collapses concurrent callers onto one flight, reuses an existing entry
  // instead of clobbering it, and fails closed offline with the venv path plus
  // manual fallback. The pill moves solely on the terminal result below, so
  // mid-flight flaps never flip it early.
  const handleEnsureBrowser = async () => {
    // Guard on the ref, not the state, so a second click before the re-render
    // still sees the in-flight flight and drops instead of racing it.
    if (browserActionRef.current !== null) return;
    browserActionRef.current = "ensure";
    setBrowserAction("ensure");
    setBrowserError(null);
    setBrowserDiagnostics(null);
    beginBrowserProgress();
    try {
      const res = await fetch("/browser/ensure", {
        method: "POST",
        headers: authHeaders({ "Content-Type": "application/json" }),
        credentials: "same-origin",
        body: JSON.stringify({}),
      });
      if (!res.ok) {
        let detail = `Request failed: /browser/ensure (${res.status})`;
        try {
          const text = await res.text();
          if (text) {
            try {
              const parsed: unknown = JSON.parse(text);
              const record =
                typeof parsed === "object" && parsed !== null
                  ? (parsed as Record<string, unknown>)
                  : null;
              const reason =
                record != null
                  ? (record.reason ?? record.message ?? record.error)
                  : undefined;
              detail =
                typeof reason === "string" && reason.trim()
                  ? reason.trim().slice(0, 500)
                  : text.slice(0, 500);
            } catch {
              detail = text.slice(0, 500);
            }
          }
        } catch {
          // Keep the status fallback when the body is unreadable.
        }
        setBrowserReady(null);
        setBrowserError(detail);
        return;
      }
      const payload = (await res.json()) as BrowserPythonHealthPayload;
      if (typeof payload?.ready === "boolean") {
        setBrowserReady(payload.ready);
        if (typeof payload.pythonPath === "string" && payload.pythonPath.trim()) {
          setBrowserPythonPath(payload.pythonPath.trim());
        }
        if (typeof payload.venvPath === "string" && payload.venvPath.trim()) {
          setBrowserVenvPath(payload.venvPath.trim());
        }
        setBrowserDiagnostics(trimBrowserText(payload.diagnostics));
        if (!payload.ready) {
          const detail = trimBrowserText(payload.message);
          setBrowserError(
            detail ?? "Browser Python is not ready; status unchanged."
          );
        }
      } else {
        setBrowserError(
          "Browser ensure returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setBrowserError(
        err instanceof Error ? err.message : "Failed to ensure browser Python."
      );
    } finally {
      endBrowserProgress();
      browserActionRef.current = null;
      setBrowserAction(null);
    }
  };

  // Single lifecycle toggle mirroring the TopNav shape: unknown and stopped
  // both start, running stops. The direction is captured up front so the busy
  // label and the error slot can tell a failed start apart from a failed stop.
  const handleToggleSearch = async () => {
    if (searchAction !== null) return;
    const wasStarting = !searchRunning;
    setSearchAction(wasStarting ? "start" : "stop");
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    // A Start fans out to a minutes-budget cascade (notably the first-run image pull), so poll
    // health about 1s for the live step while it runs. Polls feed the Starting line only; the pill
    // moves solely on the terminal result below, so mid-flight flaps never flip it early.
    // The cap clears only the stage line plus a dot re-probe; busy stays locked until the
    // terminal result below lands so the toggle cannot race the hung pull.
    if (wasStarting) {
      beginSearchStartProgress(() => {
        void refreshSearchHealth();
      });
    }
    try {
      const response = wasStarting ? await ensureSearch() : await stopSearch();
      // Honest tri-state: only a boolean reachable flag may move the pill; shape-drifted payloads
      // preserve the previous state and surface an inline error instead of optimistically flipping.
      // A failed start (reachable false) renders the trimmed banner in the existing error slot
      // with chained detail in the collapsed diagnostics below, instead of flipping silently to red.
      // A failed stop (still reachable) surfaces its message; a clean stop clears the slot.
      // Stop carries no chained diagnostics today, but the slot clears symmetrically with ensure.
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchDiagnostics(resolveSearchDiagnostics(response));
        if (wasStarting && !response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(detail ?? "Search start failed; status unchanged.");
        } else if (!wasStarting && response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(detail ?? "Search stop failed; still reachable.");
        }
      } else if (wasStarting) {
        setSearchHealthError(
          "Search start returned an unexpected response; status unchanged."
        );
      } else {
        setSearchHealthError(
          "Search stop returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setSearchHealthError(
        err instanceof Error
          ? err.message
          : wasStarting
            ? "Failed to start search."
            : "Failed to stop search."
      );
    } finally {
      // Terminal result stops the Starting line on every path (success, failure, cancellation),
      // so no settle leaves the poll or the pill behind.
      endSearchStartProgress();
      setSearchAction(null);
    }
  };

  // Guarded remove through the dedicated remove path: the server stops a
  // running entry first rather than half-deleting, the image cache survives so
  // the next Start recreates the entry, and the pill moves solely on the
  // honest reachable re-probe below. The button stays disabled while running
  // or busy, so this path normally runs from stopped or unknown only; a
  // still-reachable result refuses with guidance instead of claiming deleted.
  const handleConfirmRemoveSearch = async () => {
    if (searchAction !== null) return;
    setPendingRemoveSearch(false);
    setSearchAction("remove");
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    try {
      const response = await removeSearch();
      // Honest tri-state like the toggle: only a boolean reachable flag may
      // move the pill; shape-drifted payloads preserve state with an error.
      // A refused remove (still reachable, or stopped-but-still-listed via
      // removed false) surfaces its guidance; a clean delete clears to
      // Stopped so the next Start recreates the entry.
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchDiagnostics(resolveSearchDiagnostics(response));
        if (response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(
            detail ??
              "Search remove failed; still reachable. Stop the container first, then retry remove."
          );
        } else if (response.removed === false) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(
            detail ?? "Search remove failed; status unchanged."
          );
        }
      } else {
        setSearchHealthError(
          "Search remove returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setSearchHealthError(
        err instanceof Error ? err.message : "Failed to remove search container."
      );
    } finally {
      setSearchAction(null);
    }
  };

  const handleRescanPlugins = async () => {
    setRescanLoading(true);
    try {
      const res = await rescanPlugins();
      setPluginsList(Array.isArray(res?.plugins) ? res.plugins : []);
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      pushSuccessToast(`Discovered ${res.plugins?.length ?? 0} external runes.`);
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to rescan plugins.");
    } finally {
      setRescanLoading(false);
    }
  };

  const handleToggleEnable = async (plugin: PluginSummary) => {
    setUpdatingPluginId(plugin.id);
    try {
      const action = plugin.isEnabled ? "disable" : "enable";
      const updated = await updatePluginState(plugin.id, { action });
      setPluginsList((prev) => prev.map((p) => (p.id === updated.id ? updated : p)));
      const toolsRes = await getTools();
      setAllTools(toolsRes.tools);
      pushSuccessToast(
        updated.isEnabled
          ? `Enabled rune '${updated.name}' (integrity hash verified).`
          : `Disabled rune '${updated.name}'.`
      );
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to update plugin state.");
    } finally {
      setUpdatingPluginId(null);
    }
  };

  const handlePermissionChange = async (
    pluginId: string,
    toolName: string,
    value: string
  ) => {
    setUpdatingPluginId(pluginId);
    try {
      let updated: PluginSummary;
      if (value === "default") {
        updated = await updatePluginState(pluginId, { action: "clear_override", toolName });
      } else {
        updated = await updatePluginState(pluginId, {
          action: "override_permission",
          toolName,
          permissionLevel: value as "readOnly" | "requiresApproval",
        });
      }
      setPluginsList((prev) => prev.map((p) => (p.id === updated.id ? updated : p)));
      const toolsRes = await getTools();
      setAllTools(toolsRes.tools);
      pushSuccessToast(`Updated permission for '${toolName}' to ${value}.`);
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to override permission.");
    } finally {
      setUpdatingPluginId(null);
    }
  };

  async function confirmUninstallPlugin() {
    if (!pendingUninstallPlugin) return;
    const { id: pluginId, name } = pendingUninstallPlugin;
    setUpdatingPluginId(pluginId);
    try {
      await uninstallPlugin(pluginId);
      setPluginsList((prev) => prev.filter((p) => p.id !== pluginId));
      const toolsRes = await getTools();
      setAllTools(toolsRes.tools);
      pushSuccessToast(`Uninstalled '${name}'.`);
      setPendingUninstallPlugin(null);
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to uninstall plugin.");
    } finally {
      setUpdatingPluginId(null);
    }
  }

  function cancelUninstallPlugin() {
    setPendingUninstallPlugin(null);
  }

  // Final rotate step: the engine persists the replacement before it goes live
  // and returns it once. rotateToken adopts it immediately so background polls
  // and the shared socket keep working on the new credential; only the one-time
  // display value stays in component state.
  const handleConfirmRotate = async () => {
    if (rotating) return;
    setRotateConfirmStep(0);
    setRotating(true);
    setRotateError(null);
    setTokenCopyState("idle");
    try {
      const token = await rotateToken();
      setNewToken(token);
      setTokenSavedAck(false);
    } catch (err) {
      // A refused rotation leaves the current token valid server-side, so the
      // session stays usable and the error renders inline.
      setRotateError(
        err instanceof ApiError ? err.message : "Failed to rotate access token."
      );
    } finally {
      setRotating(false);
    }
  };

  const handleCopyNewToken = async () => {
    if (!newToken) return;
    try {
      // Clipboard access can be denied or absent; report the failure instead of
      // claiming a copy that never happened.
      await navigator.clipboard.writeText(newToken);
      setTokenCopyState("copied");
    } catch {
      setTokenCopyState("failed");
    }
  };

  const handleDismissNewToken = () => {
    setNewToken(null);
    setTokenSavedAck(false);
    setTokenCopyState("idle");
  };

  const handleLogout = () => {
    // Clearing memory and the session mirror together returns the tab to the
    // login gate; the shared socket closes through the same auth transition.
    clearAuthToken();
  };

  // Whether this tab holds an owner credential at all. The loopback no-auth
  // posture never mints one, so offering "Log Out" there would present a
  // session-less control whose only effect is a login gate that accepts any
  // value; the button is omitted until a real token-backed session exists.
  const hasOwnerSession = isSessionAuthenticated();

  // Flips one builtin engine tool without a protected list: every builtin toggles independently so
  // closely related tools (email.read vs email.attachment) never change together.
  const handleToggleTool = async (tool: ToolInfo) => {
    const nextEnabled = !tool.isEnabled;
    setTogglingToolName(tool.name);
    try {
      await updateToolState(tool.name, nextEnabled);
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      pushSuccessToast(
        nextEnabled ? `Enabled tool '${tool.name}'.` : `Disabled tool '${tool.name}'.`
      );
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : `Failed to update tool '${tool.name}'.`);
    } finally {
      setTogglingToolName(null);
    }
  };

  // Bulk-toggles all builtin tools in a given category.
  const handleToggleCategory = async (categoryId: string, enable: boolean) => {
    const categoryTools = (Array.isArray(allTools) ? allTools : []).filter(
      (t) => t.isBuiltIn && getToolCategory(t) === categoryId
    );
    const targets = categoryTools.filter((t) => t.isEnabled !== enable);
    if (targets.length === 0) return;
    setTogglingCategory(categoryId);
    try {
      for (const tool of targets) {
        await updateToolState(tool.name, enable);
      }
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      pushSuccessToast(
        `${enable ? "Enabled" : "Disabled"} all tools in '${categoryId}'.`
      );
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : `Failed to update ${categoryId} tools.`);
    } finally {
      setTogglingCategory(null);
    }
  };

  // Loads bounded scratch usage for the Tools-tab quota bars. A malformed
  // payload degrades to an honest error instead of rendering a partial bar,
  // so a drifted engine never shows a quota without its numerator.
  const refreshWorkspaceUsage = useCallback(async () => {
    setWorkspaceLoading(true);
    setWorkspaceError(null);
    try {
      const usage = await getWorkspaceUsage();
      if (
        typeof usage?.bytes !== "number" ||
        typeof usage?.files !== "number" ||
        typeof usage?.quotaMB !== "number" ||
        typeof usage?.quotaFiles !== "number"
      ) {
        setWorkspaceUsage(null);
        setWorkspaceError("Workspace usage returned an unexpected response; quotas unknown.");
        return;
      }
      setWorkspaceUsage(usage);
    } catch (err) {
      setWorkspaceUsage(null);
      setWorkspaceError(err instanceof Error ? err.message : "Failed to load workspace usage.");
    } finally {
      setWorkspaceLoading(false);
    }
  }, []);

  // Loads the pinned-script registry for the Tools-tab section. Unknown rows
  // stay listed so a tampered script remains visible behind its disabled pill
  // instead of vanishing from review.
  const refreshAgentTools = useCallback(async () => {
    setAgentToolsLoading(true);
    setAgentToolsError(null);
    try {
      const res = await listAgentTools();
      setAgentTools(Array.isArray(res?.tools) ? res.tools : []);
    } catch (err) {
      setAgentTools([]);
      setAgentToolsError(err instanceof Error ? err.message : "Failed to load promoted tools.");
    } finally {
      setAgentToolsLoading(false);
    }
  }, []);

  const refreshWorkspaceMachine = useCallback(async () => {
    setWorkspaceMachineLoading(true);
    setWorkspaceMachineError(null);
    try {
      const status = await getWorkspaceMachine();
      if (
        typeof status?.exists !== "boolean" ||
        typeof status?.running !== "boolean" ||
        typeof status?.image !== "string"
      ) {
        setWorkspaceMachine(null);
        setWorkspaceMachineError("Workspace machine returned an unexpected response; status unknown.");
        return;
      }
      setWorkspaceMachine(status);
    } catch (err) {
      setWorkspaceMachine(null);
      setWorkspaceMachineError(err instanceof Error ? err.message : "Failed to load workspace machine.");
    } finally {
      setWorkspaceMachineLoading(false);
    }
  }, []);

  const handleStopWorkspaceMachine = async () => {
    if (workspaceMachineAction !== null) return;
    setWorkspaceMachineAction("stop");
    try {
      await stopWorkspaceMachine();
      pushSuccessToast("Stopped workspace machine.");
      await refreshWorkspaceMachine();
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to stop workspace machine.");
    } finally {
      setWorkspaceMachineAction(null);
    }
  };

  const handleRecycleWorkspaceMachine = async () => {
    if (workspaceMachineAction !== null) return;
    setWorkspaceMachineAction("recycle");
    try {
      await recycleWorkspaceMachine();
      pushSuccessToast("Recycled workspace machine.");
      await refreshWorkspaceMachine();
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to recycle workspace machine.");
    } finally {
      setWorkspaceMachineAction(null);
    }
  };

  // Prunes expired tmp/ entries after the confirm modal. The receipt counts
  // top-level entries removed, so the toast names the count and the bars
  // refresh instead of optimistically zeroing.
  const handleConfirmPruneWorkspace = async () => {
    if (pruningWorkspace) return;
    setPendingPruneWorkspace(false);
    setPruningWorkspace(true);
    try {
      const receipt = await pruneWorkspaceTmp();
      const removed = typeof receipt?.removed === "number" ? receipt.removed : 0;
      pushSuccessToast(
        removed === 1 ? "Pruned 1 tmp entry." : `Pruned ${removed} tmp entries.`
      );
      await refreshWorkspaceUsage();
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : "Failed to prune workspace tmp.");
    } finally {
      setPruningWorkspace(false);
    }
  };

  // Flips one promoted script without touching siblings. The PATCH body
  // carries the canonical status spelling; the updated row replaces one entry
  // instead of refetching the list so a concurrent promotion never vanishes.
  const handleToggleAgentTool = async (tool: AgentTool) => {
    const nextEnabled = tool.status !== "enabled";
    setTogglingAgentToolId(tool.id);
    try {
      const updated = await setAgentToolStatus(tool.id, nextEnabled);
      setAgentTools((prev) => prev.map((t) => (t.id === updated.id ? updated : t)));
      pushSuccessToast(
        nextEnabled ? `Enabled agent tool '${tool.name}'.` : `Disabled agent tool '${tool.name}'.`
      );
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : `Failed to update agent tool '${tool.name}'.`);
    } finally {
      setTogglingAgentToolId(null);
    }
  };

  // Runs one pinned script with no extra argv. Verification re-hashes before
  // dispatch, so a tampered row answers 400 and lands disabled; the output
  // stores per tool id so concurrent runs never overwrite each other.
  const handleRunAgentTool = async (tool: AgentTool) => {
    if (runningAgentToolId !== null) return;
    setRunningAgentToolId(tool.id);
    try {
      const result = await runAgentTool(tool.id, []);
      const content = typeof result?.content === "string" ? result.content : "";
      setAgentRunOutput((prev) => ({ ...prev, [tool.id]: content || "(no output)" }));
      if (result?.isError) {
        pushErrorToast(content || `Agent tool '${tool.name}' reported an error.`);
      } else {
        pushSuccessToast(`Ran agent tool '${tool.name}'.`);
      }
    } catch (err) {
      pushErrorToast(err instanceof Error ? err.message : `Failed to run agent tool '${tool.name}'.`);
    } finally {
      setRunningAgentToolId(null);
    }
  };

  // Promotes a workspace/tools/ script after the client-side prefix check.
  // The form validates before any network write so an outside path fails
  // with the same words the store would refuse, without a round trip.
  const handlePromoteAgentTool = async () => {
    const problem = validateAgentToolPromote(promoteName, promoteScriptPath);
    if (problem) {
      setPromoteError(problem);
      return;
    }
    if (promotingTool) return;
    setPromotingTool(true);
    setPromoteError(null);
    try {
      const created = await promoteAgentTool(promoteName.trim(), promoteScriptPath.trim());
      setAgentTools((prev) => {
        const next = prev.filter((t) => t.id !== created.id && t.name !== created.name);
        return [...next, created].sort((a, b) => a.name.localeCompare(b.name));
      });
      setPromoteName("");
      setPromoteScriptPath("");
      pushSuccessToast(`Promoted agent tool '${created.name}'.`);
      await refreshWorkspaceUsage();
    } catch (err) {
      setPromoteError(err instanceof Error ? err.message : "Failed to promote agent tool.");
    } finally {
      setPromotingTool(false);
    }
  };

  // Copies one settings fetch into the Sonarr/Radarr fields, tolerating both
  // snake_case and camelCase DTO aliases and falling back to the conventional
  // key names. Only overwrites sections the engine returns so older engines
  // without [media] leave the form defaults untouched.
  const populateMediaSettings = useCallback(
    (media: MediaConfigData | undefined | null) => {
      if (media?.timeoutSeconds !== undefined) {
        setMediaTimeoutSeconds(
          media.timeoutSeconds ?? DEFAULT_MEDIA_TIMEOUT_SECONDS
        );
      }
      if (media?.sonarr) {
        setSonarrEnabled(media.sonarr.enabled ?? true);
        setSonarrUrl(media.sonarr.url ?? "");
        setSonarrApiKeyEnv(
          media.sonarr.apiKeyEnv || "SONARR_API_KEY"
        );
        setSonarrDefaultQuality(
          media.sonarr.defaultQualityProfile ||
            ""
        );
        setSonarrDefaultRoot(
          media.sonarr.defaultRootFolder || ""
        );
      }
      if (media?.radarr) {
        setRadarrEnabled(media.radarr.enabled ?? true);
        setRadarrUrl(media.radarr.url ?? "");
        setRadarrApiKeyEnv(
          media.radarr.apiKeyEnv || "RADARR_API_KEY"
        );
        setRadarrDefaultQuality(
          media.radarr.defaultQualityProfile ||
            ""
        );
        setRadarrDefaultRoot(
          media.radarr.defaultRootFolder || ""
        );
      }
    },
    []
  );

  // Builds the [media] delta from the Sonarr/Radarr form fields so the
  // full-settings save and the modal-only save share one shape. Emptied URL,
  // quality, and root-folder fields send as "" so the engine clears back to
  // auto-detect/unconfigured instead of preserving the stale value; the engine
  // reads blank and missing identically, so "" is the explicit clear signal.
  // An emptied credential env-var name keeps the last loaded stored value
  // instead of resetting to the conventional name, so clearing the input never
  // overwrites a custom name with the default.
  const buildMediaPayload = useCallback(
    (): MediaConfigData => {
      const storedSonarrEnv =
        settings?.media?.sonarr?.apiKeyEnv?.trim() ||
        "";
      const storedRadarrEnv =
        settings?.media?.radarr?.apiKeyEnv?.trim() ||
        "";
      const timeoutSec = typeof mediaTimeoutSeconds === "string" ? parseInt(mediaTimeoutSeconds, 10) : mediaTimeoutSeconds;
      return {
        timeoutSeconds: isNaN(timeoutSec) || timeoutSec <= 0 ? DEFAULT_MEDIA_TIMEOUT_SECONDS : timeoutSec,
        sonarr: {
          enabled: sonarrEnabled,
          url: sonarrUrl.trim(),
          apiKeyEnv:
            sonarrApiKeyEnv.trim() || storedSonarrEnv || "SONARR_API_KEY",
          defaultQualityProfile: sonarrDefaultQuality.trim(),
          defaultRootFolder: sonarrDefaultRoot.trim(),
        },
        radarr: {
          enabled: radarrEnabled,
          url: radarrUrl.trim(),
          apiKeyEnv:
            radarrApiKeyEnv.trim() || storedRadarrEnv || "RADARR_API_KEY",
          defaultQualityProfile: radarrDefaultQuality.trim(),
          defaultRootFolder: radarrDefaultRoot.trim(),
        },
      };
    },
    [
      mediaTimeoutSeconds,
      sonarrEnabled,
      sonarrUrl,
      sonarrApiKeyEnv,
      sonarrDefaultQuality,
      sonarrDefaultRoot,
      radarrEnabled,
      radarrUrl,
      radarrApiKeyEnv,
      radarrDefaultQuality,
      radarrDefaultRoot,
      settings,
    ]
  );

  // Copies one settings fetch into the desktop knob fields, tolerating an
  // absent [desktop] section from older engines by keeping the form defaults.
  // Only overwrites sections the engine returns so older engines without
  // desktop leave the form defaults untouched.
  const populateDesktopSettings = useCallback(
    (desktop: DesktopConfigData | undefined | null) => {
      if (!desktop) return;
      if (typeof desktop.maxImageDimension === "number") {
        setDesktopMaxImageDimension(desktop.maxImageDimension);
      }
      if (typeof desktop.jpegQuality === "number") {
        setDesktopJpegQuality(desktop.jpegQuality);
      }
      if (Array.isArray(desktop.blockedApps)) {
        setDesktopBlockedAppsText(formatBlockedAppsText(desktop.blockedApps));
      }
    },
    []
  );

  // Builds the unified [desktop] delta for the single Configure Desktop
  // Integration modal so the full-settings save and the modal-only save share
  // one shape. Both call sites always send every knob (capture bounds plus the
  // application blocklist). Enable keys never travel here — tool enablement
  // lives in the tool-state toggles.
  // Numeric fields preserve the raw input (including empty/invalid) so the
  // modal validation surfaces range errors instead of silently coercing back
  // to defaults.
  const buildDesktopPayload = useCallback(
    (): DesktopSettingsUpdate => {
      return {
        maxImageDimension: Number(desktopMaxImageDimension),
        jpegQuality: Number(desktopJpegQuality),
        blockedApps: parseBlockedAppsText(desktopBlockedAppsText),
      };
    },
    [
      desktopMaxImageDimension,
      desktopJpegQuality,
      desktopBlockedAppsText,
    ]
  );

  // Copies one settings fetch into the fan-out knob fields, tolerating an
  // absent [fanout] section from older engines by keeping the modal defaults.
  // Only overwrites keys the engine returns so a stored value always wins over
  // the empty-field fallback, and records the snapshot the changed-only patch
  // compares against so untouched knobs stay omitted on save.
  const populateFanoutSettings = useCallback(
    (fanout: FanoutConfigData | undefined | null) => {
      const next: FanoutConfigData = { ...fanoutLoadedRef.current };
      if (typeof fanout?.maxWorkers === "number") {
        setFanoutMaxWorkers(fanout.maxWorkers);
        next.maxWorkers = fanout.maxWorkers;
      }
      if (typeof fanout?.workerTimeoutSeconds === "number") {
        setFanoutWorkerTimeoutSeconds(fanout.workerTimeoutSeconds);
        next.workerTimeoutSeconds = fanout.workerTimeoutSeconds;
      }
      if (typeof fanout?.fullTools === "boolean") {
        setFanoutFullTools(fanout.fullTools);
        next.fullTools = fanout.fullTools;
      }
      fanoutLoadedRef.current = next;
    },
    []
  );

  // Builds the changed-only [fanout] delta for the Configure modal: a knob
  // matching its last-loaded value stays omitted so the stored value survives,
  // while a cleared numeric input sends the modal default as an explicit
  // change. Only snake_case keys travel; no enabled key, which lives in the
  // tool-state toggles.
  const buildFanoutPayload = useCallback(
    (): FanoutSettingsUpdate => {
      const patch: FanoutSettingsUpdate = {};
      const loaded = fanoutLoadedRef.current;
      const maxRaw = typeof fanoutMaxWorkers === "string" ? fanoutMaxWorkers.trim() : fanoutMaxWorkers;
      if (maxRaw === "") {
        if (loaded.maxWorkers !== DEFAULT_FANOUT_MAX_WORKERS) {
          patch.maxWorkers = DEFAULT_FANOUT_MAX_WORKERS;
        }
      } else {
        const maxNum = Number(maxRaw);
        if (maxNum !== loaded.maxWorkers) {
          patch.maxWorkers = maxNum;
        }
      }
      const timeoutRaw =
        typeof fanoutWorkerTimeoutSeconds === "string"
          ? fanoutWorkerTimeoutSeconds.trim()
          : fanoutWorkerTimeoutSeconds;
      if (timeoutRaw === "") {
        if (loaded.workerTimeoutSeconds !== DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS) {
          patch.workerTimeoutSeconds = DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS;
        }
      } else {
        const timeoutNum = Number(timeoutRaw);
        if (timeoutNum !== loaded.workerTimeoutSeconds) {
          patch.workerTimeoutSeconds = timeoutNum;
        }
      }
      if (fanoutFullTools !== loaded.fullTools) {
        patch.fullTools = fanoutFullTools;
      }
      return patch;
    },
    [fanoutMaxWorkers, fanoutWorkerTimeoutSeconds, fanoutFullTools]
  );

  // Copies one settings fetch into the goals fields, tolerating both
  // snake_case and camelCase DTO aliases and an absent [goals] section from
  // older engines by keeping the form defaults. Only overwrites sections the
  // engine returns so older engines without goals leave the form untouched.
  const populateGoalsSettings = useCallback(
    (goals: GoalsConfigData | undefined | null) => {
      if (!goals) return;
      if (typeof goals.enabled === "boolean") {
        setGoalsEnabled(goals.enabled);
      }
      const stepInterval = goals.stepIntervalMinutes;
      if (typeof stepInterval === "number") {
        setGoalsStepIntervalMinutes(stepInterval);
      }
      const maxActive = goals.maxActiveGoals;
      if (typeof maxActive === "number") {
        setGoalsMaxActiveGoals(maxActive);
      }
      const maxSteps = goals.maxStepsPerGoal;
      if (typeof maxSteps === "number") {
        setGoalsMaxStepsPerGoal(maxSteps);
      }
      const planTimeout = goals.planTimeoutSeconds;
      if (typeof planTimeout === "number") {
        setGoalsPlanTimeoutSeconds(planTimeout);
      }
      const maxTriggers = goals.maxTriggersPerGoal;
      if (typeof maxTriggers === "number") {
        setGoalsMaxTriggersPerGoal(maxTriggers);
      }
    },
    []
  );

  // Copies one settings fetch into the idea fields, tolerating an absent
  // [ideas] section from older engines so the form keeps its default instead of
  // blanking the pane.
  const populateIdeasSettings = useCallback(
    (ideas: IdeasConfigData | undefined | null) => {
      if (!ideas) return;
      if (typeof ideas.enabled === "boolean") {
        setIdeasEnabled(ideas.enabled);
      }
      const maxCycle = ideas.maxPerCycle;
      if (typeof maxCycle === "number") {
        setIdeasMaxPerCycle(maxCycle);
      }
      const timeout = ideas.timeoutSeconds;
      if (typeof timeout === "number") {
        setIdeasTimeoutSeconds(timeout);
      }
    },
    []
  );

  // Builds the [ideas] delta from the enable toggle and bounds.
  const buildIdeasPayload = useCallback((): IdeasSettingsUpdate => {
    return {
      enabled: ideasEnabled,
      maxPerCycle: Number(ideasMaxPerCycle),
      timeoutSeconds: Number(ideasTimeoutSeconds),
    };
  }, [ideasEnabled, ideasMaxPerCycle, ideasTimeoutSeconds]);

  // Builds the [goals] delta from the pursuit form fields so the
  // full-settings save shares one shape with future modal saves.
  // Numeric fields preserve the raw input (including empty/invalid) so the
  // page validation surfaces range errors instead of silently coercing back
  // to defaults.
  const buildGoalsPayload = useCallback(
    (): GoalsSettingsUpdate => {
      return {
        enabled: goalsEnabled,
        stepIntervalMinutes: Number(goalsStepIntervalMinutes),
        maxActiveGoals: Number(goalsMaxActiveGoals),
        maxStepsPerGoal: Number(goalsMaxStepsPerGoal),
        planTimeoutSeconds: Number(goalsPlanTimeoutSeconds),
        maxTriggersPerGoal: Number(goalsMaxTriggersPerGoal),
      };
    },
    [
      goalsEnabled,
      goalsStepIntervalMinutes,
      goalsMaxActiveGoals,
      goalsMaxStepsPerGoal,
      goalsPlanTimeoutSeconds,
      goalsMaxTriggersPerGoal,
    ]
  );

  // Shared goals validation for the full-save path so it rejects an
  // out-of-range cadence or cap before any network write with one message.
  // Mirrors GoalsConfig bounds.
  const validateGoalsFields = useCallback((): string | null => {
    const intervalNum = Number(goalsStepIntervalMinutes);
    if (!Number.isInteger(intervalNum) || intervalNum < GOALS_STEP_INTERVAL_MIN_MINUTES || intervalNum > GOALS_STEP_INTERVAL_MAX_MINUTES) {
      return `Invalid goals cadence: step interval must be between ${GOALS_STEP_INTERVAL_MIN_MINUTES} and ${GOALS_STEP_INTERVAL_MAX_MINUTES} minutes.`;
    }
    const capNum = Number(goalsMaxActiveGoals);
    if (!Number.isInteger(capNum) || capNum < GOALS_MAX_ACTIVE_MIN || capNum > GOALS_MAX_ACTIVE_MAX) {
      return `Invalid goals cap: max active goals must be between ${GOALS_MAX_ACTIVE_MIN} and ${GOALS_MAX_ACTIVE_MAX}.`;
    }
    const stepsNum = Number(goalsMaxStepsPerGoal);
    if (!Number.isInteger(stepsNum) || stepsNum < 1 || stepsNum > 24) {
      return "Invalid goals plan length: max steps per goal must be between 1 and 24.";
    }
    const planTimeoutNum = Number(goalsPlanTimeoutSeconds);
    if (!Number.isInteger(planTimeoutNum) || planTimeoutNum < 0 || planTimeoutNum > 86400) {
      return "Invalid goals planning timeout: plan timeout must be between 0 (unlimited) and 86400 seconds.";
    }
    const triggersNum = Number(goalsMaxTriggersPerGoal);
    if (!Number.isInteger(triggersNum) || triggersNum < 0 || triggersNum > 32) {
      return "Invalid goals triggers budget: max triggers per goal must be between 0 and 32.";
    }
    return null;
  }, [
    goalsStepIntervalMinutes,
    goalsMaxActiveGoals,
    goalsMaxStepsPerGoal,
    goalsPlanTimeoutSeconds,
    goalsMaxTriggersPerGoal,
  ]);

  // Shared ideas validation for the full-save path.
  // Mirrors IdeasConfig bounds (1-10 per cycle, 1-120 seconds).
  const validateIdeasFields = useCallback((): string | null => {
    const maxCycleNum = Number(ideasMaxPerCycle);
    if (!Number.isInteger(maxCycleNum) || maxCycleNum < 1 || maxCycleNum > 10) {
      return "Invalid ideas per cycle: must be between 1 and 10.";
    }
    const timeoutNum = Number(ideasTimeoutSeconds);
    if (!Number.isInteger(timeoutNum) || timeoutNum < 1 || timeoutNum > 120) {
      return "Invalid ideas timeout: review timeout must be between 1 and 120 seconds.";
    }
    return null;
  }, [ideasMaxPerCycle, ideasTimeoutSeconds]);

  // Copies one settings fetch into the proactivity fields, tolerating an
  // absent [proactive] section from older engines by keeping the form
  // defaults. Only overwrites sections the engine returns. The mode converges
  // to its canonical lowercase spelling so a file-configured `ALL` or padded
  // value lands on the matching select option instead of blanking it.
  const populateProactiveSettings = useCallback(
    (proactive: ProactiveConfigData | undefined | null) => {
      if (!proactive) return;
      if (typeof proactive.mode === "string" && proactive.mode.trim()) {
        const canonical = normalizeProactiveMode(proactive.mode);
        if (canonical) {
          setProactiveMode(canonical);
        }
      }
      if (typeof proactive.judgeTimeoutSeconds === "number") {
        setProactiveJudgeTimeoutSeconds(proactive.judgeTimeoutSeconds);
      }
    },
    []
  );

  // Builds the [proactive] delta from the interruption form fields so the
  // full-settings save shares one shape with future modal saves. Sends the
  // snake_case keys the engine persists. The mode travels as its canonical
  // lowercase spelling so a differently-cased edit sends what the file
  // loader and the closed-set 400 both recognize.
  const buildProactivePayload = useCallback(
    (): ProactiveSettingsUpdate => {
      return {
        mode: normalizeProactiveMode(proactiveMode),
        judgeTimeoutSeconds: Number(proactiveJudgeTimeoutSeconds),
      };
    },
    [proactiveMode, proactiveJudgeTimeoutSeconds]
  );

  // Shared proactivity validation for the full-save path so it rejects an
  // unknown mode or an out-of-range judge budget before any network write.
  // Mirrors ProactiveMode plus the 1-120 judge bound. Matching is
  // case-insensitive (trim plus lowercase) so the dashboard accepts the same
  // spellings the file loader does.
  const validateProactiveFields = useCallback((): string | null => {
    const normalizedMode = normalizeProactiveMode(proactiveMode);
    if (!isValidProactiveMode(normalizedMode)) {
      return `Invalid proactive mode: must be one of ${(PROACTIVE_MODES as readonly string[]).join(", ")}.`;
    }
    const timeoutNum = Number(proactiveJudgeTimeoutSeconds);
    if (!Number.isInteger(timeoutNum) || timeoutNum < PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS || timeoutNum > PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS) {
      return `Invalid proactive judge timeout: timeout must be between ${PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS} and ${PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS} seconds.`;
    }
    return null;
  }, [proactiveMode, proactiveJudgeTimeoutSeconds]);

  // Copies one settings fetch into the persona fields, tolerating an absent
  // [persona] section from older engines by keeping the stock defaults, and
  // records the loaded snapshot that drives the changed-only delta. Tone and
  // accent converge to their canonical lowercase spellings the way the engine
  // normalizers do, so a file-configured `WARM` or a drifted accent never
  // blanks the select or leaves the picker with no ring.
  const populatePersonaSettings = useCallback(
    (persona: PersonaData | undefined | null) => {
      const loaded = persona ?? {};
      personaLoadedRef.current = loaded;
      setPersonaAssistantNameDraft(personaAssistantName(loaded) ?? "");
      setPersonaToneDraft(canonicalPersonaTone(loaded.tone));
      setPersonaStyleDraft(personaStyle(loaded));
      setPersonaUserNameDraft(personaUserName(loaded));
      setPersonaAvatarDraft(canonicalPersonaAvatarColor(loaded.avatar));
    },
    [],
  );

  // Builds the [persona] delta from the identity drafts: only fields that
  // moved since the last load travel on the wire, so one save is a partial
  // patch that preserves every stored key the owner never touched — including
  // the rest of the persona itself. An emptied assistant name still sends the
  // blank string, which the engine documents as the fall back to the stock
  // identity, rather than silently omitting a deliberate clear.
  const buildPersonaDelta = useCallback((): PersonaSettingsUpdate => {
    const loaded = personaLoadedRef.current;
    const delta: PersonaSettingsUpdate = {};
    const loadedName = personaAssistantName(loaded) ?? "";
    const nextName = personaAssistantNameDraft.trim();
    if (nextName !== loadedName) {
      delta.assistantName = nextName;
    }
    const loadedTone = canonicalPersonaTone(loaded.tone);
    if (personaToneDraft !== loadedTone) {
      delta.tone = personaToneDraft;
    }
    if (personaStyleDraft !== personaStyle(loaded)) {
      delta.style = personaStyleDraft;
    }
    const loadedUserName = personaUserName(loaded);
    const nextUserName = personaUserNameDraft.trim();
    if (nextUserName !== loadedUserName) {
      delta.userName = nextUserName;
    }
    const loadedAvatar = canonicalPersonaAvatarColor(loaded.avatar);
    if (personaAvatarDraft !== loadedAvatar) {
      delta.avatar = personaAvatarDraft;
    }
    return delta;
  }, [
    personaAssistantNameDraft,
    personaToneDraft,
    personaStyleDraft,
    personaUserNameDraft,
    personaAvatarDraft,
  ]);

  // Shared persona validation so the pane rejects an oversized or drifted
  // field before any network write, mirroring the core normalizer bounds. The
  // inputs clamp with maxLength already, so these checks are the closed-set
  // and pasted-shape backstop, not the primary guard.
  const validatePersonaFields = useCallback((): string | null => {
    if (personaAssistantNameDraft.length > MAX_PERSONA_ASSISTANT_NAME_LENGTH) {
      return `Invalid assistant name: must be at most ${MAX_PERSONA_ASSISTANT_NAME_LENGTH} characters.`;
    }
    if (!(PERSONA_TONES as readonly string[]).includes(personaToneDraft)) {
      return `Invalid tone: must be one of ${(PERSONA_TONES as readonly string[]).join(", ")}.`;
    }
    if (personaStyleDraft.length > MAX_PERSONA_STYLE_LENGTH) {
      return `Invalid style guidance: must be at most ${MAX_PERSONA_STYLE_LENGTH} characters.`;
    }
    if (personaUserNameDraft.length > MAX_PERSONA_USER_NAME_LENGTH) {
      return `Invalid user name: must be at most ${MAX_PERSONA_USER_NAME_LENGTH} characters.`;
    }
    if (
      !(PERSONA_AVATAR_COLORS as readonly string[]).includes(personaAvatarDraft)
    ) {
      return `Invalid avatar accent: must be one of ${(PERSONA_AVATAR_COLORS as readonly string[]).join(", ")}.`;
    }
    return null;
  }, [
    personaAssistantNameDraft,
    personaToneDraft,
    personaStyleDraft,
    personaUserNameDraft,
    personaAvatarDraft,
  ]);

  // Builds the [files] delta for the single page Save via executeSave; no section save remains.


  // Copies one settings fetch into the workspace quota editors, tolerating
  // both snake_case and camelCase DTO aliases and an absent [workspace]
  // section from older engines by keeping the form defaults. Only overwrites
  // keys the engine returns so a stored quota always wins over the fresh-form
  // fallback, keeping the bars and the editors on the same stored truth.
  const populateWorkspaceSettings = useCallback(
    (workspace: WorkspaceConfigData | undefined | null) => {
      if (!workspace) return;
      const quotaMB =
        typeof workspace.quotaMB === "number"
          ? workspace.quotaMB
          : typeof workspace.quotaMB === "number"
            ? workspace.quotaMB
            : null;
      if (quotaMB !== null) {
        setWorkspaceQuotaMB(quotaMB);
      }
      const quotaFiles =
        typeof workspace.quotaFiles === "number"
          ? workspace.quotaFiles
          : typeof workspace.quotaFiles === "number"
            ? workspace.quotaFiles
            : null;
      if (quotaFiles !== null) {
        setWorkspaceQuotaFiles(quotaFiles);
      }
      const tmpTTL =
        typeof workspace.tmpTTLDays === "number"
          ? workspace.tmpTTLDays
          : typeof workspace.tmpTTLDays === "number"
            ? workspace.tmpTTLDays
            : null;
      if (tmpTTL !== null) {
        setWorkspaceTmpTTLDays(tmpTTL);
      }
    },
    []
  );

  // Builds the [workspace] delta from the Tools-tab quota editors so the tab
  // save persists quotas beside the usage bars through one PUT. Sends the
  // snake_case keys the engine persists; reads accept both spellings so a
  // file-configured quota survives the round trip. Numeric fields preserve the
  // raw input so validation surfaces range errors instead of silently
  // coercing back to defaults.
  const buildWorkspacePayload = useCallback(
    (): WorkspaceSettingsUpdate => {
      return {
        quotaMB: Number(workspaceQuotaMB),
        quotaFiles: Number(workspaceQuotaFiles),
        tmpTTLDays: Number(workspaceTmpTTLDays),
      };
    },
    [workspaceQuotaMB, workspaceQuotaFiles, workspaceTmpTTLDays]
  );

  // Shared workspace validation for the tab save so an out-of-range quota or
  // retention fails in the form before any network write with one message.
  // Bounds mirror WorkspaceConfig clamps so the form agrees with the server
  // 400 instead of persisting a quota the loader rejects.
  const validateWorkspaceFields = useCallback((): string | null => {
    const quotaMBNum = Number(workspaceQuotaMB);
    if (!Number.isInteger(quotaMBNum) || quotaMBNum < WORKSPACE_QUOTA_MB_MIN || quotaMBNum > WORKSPACE_QUOTA_MB_MAX) {
      return `Invalid workspace quota: quota must be between ${WORKSPACE_QUOTA_MB_MIN} and ${WORKSPACE_QUOTA_MB_MAX} MB.`;
    }
    const quotaFilesNum = Number(workspaceQuotaFiles);
    if (!Number.isInteger(quotaFilesNum) || quotaFilesNum < WORKSPACE_QUOTA_FILES_MIN || quotaFilesNum > WORKSPACE_QUOTA_FILES_MAX) {
      return `Invalid workspace file quota: max files must be between ${WORKSPACE_QUOTA_FILES_MIN} and ${WORKSPACE_QUOTA_FILES_MAX}.`;
    }
    const tmpTTLNum = Number(workspaceTmpTTLDays);
    if (!Number.isInteger(tmpTTLNum) || tmpTTLNum < WORKSPACE_TMP_TTL_MIN_DAYS || tmpTTLNum > WORKSPACE_TMP_TTL_MAX_DAYS) {
      return `Invalid workspace tmp retention: tmp TTL must be between ${WORKSPACE_TMP_TTL_MIN_DAYS} and ${WORKSPACE_TMP_TTL_MAX_DAYS} days.`;
    }
    return null;
  }, [workspaceQuotaMB, workspaceQuotaFiles, workspaceTmpTTLDays]);

  // Copies one settings fetch into the containers knob editors, tolerating
  // both snake_case and camelCase DTO aliases and an absent [containers]
  // section from older engines by keeping the form defaults. Only overwrites
  // keys the engine returns so a stored knob always wins over the
  // fresh-form fallback.
  const populateContainersSettings = useCallback(
    (containers: ContainersConfigData | undefined | null) => {
      if (!containers) return;
      const memoryMB =
        typeof containers.memoryMb === "number"
          ? containers.memoryMb
          : typeof containers.memoryMb === "number"
            ? containers.memoryMb
            : null;
      if (memoryMB !== null) {
        setContainersMemoryMB(memoryMB);
      }
      const maxConcurrent =
        typeof containers.maxConcurrent === "number"
          ? containers.maxConcurrent
          : null;
      if (maxConcurrent !== null) {
        setContainersMaxConcurrent(maxConcurrent);
      }
      const ttlMinutes =
        typeof containers.ttlMinutes === "number"
          ? containers.ttlMinutes
          : null;
      if (ttlMinutes !== null) {
        setContainersTTLMinutes(ttlMinutes);
      }
    },
    []
  );

  // Builds the [containers] delta from the Security-tab knob editors so the
  // page save persists the three knobs through one PUT.
  // Numeric fields preserve the raw input so validation surfaces range errors instead of silently
  // coercing back to defaults.
  const buildContainersPatch = useCallback(
    (): ContainersSettingsUpdate => {
      return {
        memoryMb: Number(containersMemoryMB),
        maxConcurrent: Number(containersMaxConcurrent),
        ttlMinutes: Number(containersTTLMinutes),
      };
    },
    [containersMemoryMB, containersMaxConcurrent, containersTTLMinutes]
  );

  // Shared containers validation for the page save so an out-of-range knob
  // fails in the form before any network write with one message. Bounds
  // mirror ContainersConfig clamps (256-8192 MB, 1-32 concurrent, 5-1440
  // TTL minutes) so the form agrees with the server 400 instead of
  // persisting a knob the loader rejects.
  const validateContainersFields = useCallback((): string | null => {
    const memoryNum = Number(containersMemoryMB);
    if (!Number.isInteger(memoryNum) || memoryNum < CONTAINERS_MEMORY_MIN_MB || memoryNum > CONTAINERS_MEMORY_MAX_MB) {
      return `Invalid containers memory: memoryMb must be between ${CONTAINERS_MEMORY_MIN_MB} and ${CONTAINERS_MEMORY_MAX_MB} MB.`;
    }
    const maxConcurrentNum = Number(containersMaxConcurrent);
    if (!Number.isInteger(maxConcurrentNum) || maxConcurrentNum < CONTAINERS_MAX_CONCURRENT_MIN || maxConcurrentNum > CONTAINERS_MAX_CONCURRENT_MAX) {
      return `Invalid containers concurrency: max_concurrent must be between ${CONTAINERS_MAX_CONCURRENT_MIN} and ${CONTAINERS_MAX_CONCURRENT_MAX}.`;
    }
    const ttlNum = Number(containersTTLMinutes);
    if (!Number.isInteger(ttlNum) || ttlNum < CONTAINERS_TTL_MIN_MINUTES || ttlNum > CONTAINERS_TTL_MAX_MINUTES) {
      return `Invalid containers TTL: ttl_minutes must be between ${CONTAINERS_TTL_MIN_MINUTES} and ${CONTAINERS_TTL_MAX_MINUTES} minutes.`;
    }
    return null;
  }, [containersMemoryMB, containersMaxConcurrent, containersTTLMinutes]);

  const populateForm = useCallback((data: SettingsResponse) => {
    setSettings(data);
    setEngineName(data.engineName);
    setLogLevel(data.logLevel);
    setCompactionThresholdPercent(data.compactionThresholdPercent ?? 80);
    setMaxToolIterations(engineMaxToolIterations(data));
    setDefaultProvider(data.defaultProvider);
    setFallbackProvider(data.fallbackProvider ?? "");

    // Transform providers record into editable list with stable keys, sorted alphabetically by name
    const pList: ProviderEntry[] = Object.entries(data.providers || {})
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([name, cfg], idx) => ({
        id: `p-${idx}-${name}`,
        name,
        config: {
          enabled: cfg.enabled ?? true,
          model: cfg.model ?? "",
          serverURL: cfg.serverURL || "",
          apiKeyEnv: cfg.apiKeyEnv || "",
          providerType: cfg.providerType || "",
          apiStyle: cfg.apiStyle || "",
          contextLength: cfg.contextLength,
          slotCount: cfg.slotCount,
          cachePrompt: cfg.cachePrompt,
          supportsVision: cfg.supportsVision,
        },
      })
    );
    setProvidersList(pList);


    setMemoryVectorDBPath(data.memoryVectorDBPath);
    setMemoryEpisodesDBPath(data.memoryEpisodesDBPath);
    setMemoryEmbeddingModel(data.memoryEmbeddingModel);
    setMemoryEmbeddingBackend(data.memoryEmbeddingBackend ?? "apple");
    setVoiceSTTProvider(data.voiceSTTProvider);
    setVoiceWhisperModel(data.voiceWhisperModel);
    setVoiceTTSProvider(data.voiceTTSProvider);
    // Search fields read either contract (canonical `browser*` first, then the
    // `search*` alias) and fall back to local defaults when an older engine
    // omits the [browser] section, so the form never renders blank.
    setSearchSearxngURL(
      data.browserSearxngURL ?? data.searchSearxngURL ?? DEFAULT_SEARCH_SEARXNG_URL
    );
    setSearchTimeoutSeconds(
      data.browserSearchTimeoutSeconds ??
        data.searchTimeoutSeconds ??
        DEFAULT_SEARCH_TIMEOUT_SECONDS
    );
    setSearchMaxResults(
      data.browserMaxResults ?? data.searchMaxResults ?? DEFAULT_SEARCH_MAX_RESULTS
    );
    if (data.browserTimeoutSeconds !== undefined) {
      setBrowserTimeoutSeconds(data.browserTimeoutSeconds);
    }
    if (data.browserFetchTimeoutSeconds !== undefined) {
      setBrowserFetchTimeoutSeconds(data.browserFetchTimeoutSeconds);
    }
    setPluginsDir(data.pluginsDir ?? "~/.runeweaver/plugins");
    setPluginsMarketplaceIndexURL(
      data.pluginsMarketplaceIndexURL ??
        "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"
    );
    setPluginsAutoRescan(data.pluginsAutoRescan ?? true);

    // Transform email accounts into editable list
    const eList: EmailEntry[] = (data.emailAccounts || []).map((acc, idx) => ({
      id: `email-${idx}-${acc.name}`,
      account: { ...acc },
    }));
    setEmailAccountsList(eList);

    // Media fields share one helper so load and save stay symmetric; an
    // absent [media] keeps the form defaults instead of blanking the modal.
    populateMediaSettings(data.media);
    // Desktop fields share one helper so load and save stay symmetric; an
    // absent [desktop] keeps the form defaults instead of blanking the modal.
    populateDesktopSettings(data.desktop);
    // Goals fields share one helper so load and save stay symmetric; an
    // absent [goals] keeps the form defaults instead of blanking the pane.
    populateGoalsSettings(data.goals);
    // Ideas enable toggle shares one helper so load and save stay symmetric; an
    // absent [ideas] keeps the form default instead of blanking the pane.
    populateIdeasSettings(data.ideas);
    // Proactivity fields share one helper so load and save stay symmetric; an
    // absent [proactive] keeps the form defaults instead of blanking the pane.
    populateProactiveSettings(data.proactive);
    // Persona fields share one helper so load and save stay symmetric; an
    // absent [persona] keeps the stock identity instead of blanking the pane.
    // Every settings read then republishes the persona into the shared store
    // so the profile block and chat header mirror this pane exactly, including
    // after a persona save whose response carries the merged snapshot.
    populatePersonaSettings(data.persona);
    publishPersonaFromSettings(data.persona);
    // Fan-out knobs share one helper so load and save stay symmetric; an
    // absent [fanout] keeps the modal defaults instead of blanking the modal.
    populateFanoutSettings(data.fanout);
    // Workspace quotas share one helper so load and save stay symmetric; an
    // absent [workspace] keeps the editor defaults instead of blanking the
    // Tools-tab quota fields.
    populateWorkspaceSettings(data.workspace);
    // Containers knobs share one helper so load and save stay symmetric; an
    // absent [containers] keeps the editor defaults instead of blanking the
    // Security-tab knob fields.
    populateContainersSettings(data.containers);
    // Network bind tolerates older engines without [server]: absent keys keep
    // the loopback defaults so the pane never renders blank, and the textarea
    // formats the stored list so blank lines only exist while editing.
    setServerHostname(
      typeof data.serverHostname === "string" && data.serverHostname.trim()
        ? data.serverHostname
        : DEFAULT_SERVER_HOSTNAME
    );
    // A freshly loaded preset never starts in explicit custom mode, while a
    // stored custom address does, so the selector reflects the file instead
    // of lingering on a prior custom pick. Compared case-insensitively via
    // the restart canonicalization so casing the gate ignores never forces
    // custom.
    setServerHostnameCustom(
      typeof data.serverHostname === "string" && data.serverHostname.trim()
        ? !isServerBindPreset(data.serverHostname)
        : false
    );
    setServerPort(
      typeof data.serverPort === "number" && Number.isInteger(data.serverPort)
        ? data.serverPort
        : DEFAULT_SERVER_PORT
    );
    setServerAllowedHostsText(formatServerAllowedHostsText(data.serverAllowedHosts));
    // Seed the boot snapshot once from the first fetch; later PUTs preserve
    // the original boot via the pre-save snapshot in executeSave, so the
    // banner keeps comparing pending file versus boot instead of file versus
    // file. The flag itself mirrors the server: true only when the last PUT
    // really moved the bind (the route diffs old versus new), while the
    // render-time file-vs-boot check preserves the banner across non-server
    // saves that return false.
    const fileBindHostname =
      typeof data.serverHostname === "string" && data.serverHostname.trim()
        ? data.serverHostname
        : DEFAULT_SERVER_HOSTNAME;
    const fileBindPort =
      typeof data.serverPort === "number" && Number.isInteger(data.serverPort)
        ? data.serverPort
        : DEFAULT_SERVER_PORT;
    const fileBindHosts = Array.isArray(data.serverAllowedHosts)
      ? [...data.serverAllowedHosts]
      : [];
    setLiveServerBind((prev) =>
      prev ?? { hostname: fileBindHostname, port: fileBindPort, allowedHosts: fileBindHosts }
    );
    setServerRestartRequired(Boolean(data.requiresRestart));
  }, [populateMediaSettings, populateDesktopSettings, populateGoalsSettings, populateIdeasSettings, populateProactiveSettings, populatePersonaSettings, populateFanoutSettings, populateWorkspaceSettings]);

  // Reconciles the boot snapshot from /health when the engine advertises its
  // live bind. Older engines omit the keys, in which case the pre-save file
  // snapshot above stays as the live source of truth. Newer engines correct an
  // initial seed that assumed file equals boot (for example a file edited
  // without a restart before the first fetch) and re-anchor live after a
  // restart so the banner clears once file converges with boot.
  const refreshBootBind = useCallback(async () => {
    try {
      const res = await fetch("/health", {
        headers: authHeaders(),
        credentials: "same-origin",
      });
      if (!res.ok) return;
      const payload = (await res.json()) as {
        serverHostname?: unknown;
        serverPort?: unknown;
        serverAllowedHosts?: unknown;
      };
      const bootHostname =
        typeof payload.serverHostname === "string" && payload.serverHostname.trim()
          ? payload.serverHostname
          : null;
      const bootPort =
        typeof payload.serverPort === "number" && Number.isInteger(payload.serverPort)
          ? (payload.serverPort as number)
          : null;
      const bootHosts = Array.isArray(payload.serverAllowedHosts)
        ? (payload.serverAllowedHosts as unknown[]).filter(
            (h): h is string => typeof h === "string"
          )
        : null;
      if (bootHostname !== null && bootPort !== null && bootHosts !== null) {
        setLiveServerBind({ hostname: bootHostname, port: bootPort, allowedHosts: [...bootHosts] });
      }
    } catch {
      // Health without boot keys (older engines) or an unreachable probe keeps
      // the file snapshot; the banner degrades to same-session truth.
    }
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await getSettings();
      populateForm(data);
      void refreshBootBind();
      void loadPluginsData();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to load settings");
    } finally {
      setLoading(false);
    }
  }, [populateForm, refreshBootBind, loadPluginsData]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Loads live container health when the Web pane opens so the health
  // line reflects the running container rather than the saved URL alone.
  // Runs on tab entry only; Start/Stop update directly from their action
  // response without an extra probe so the health line never flashes stale.
  useEffect(() => {
    if (activeTab === "search") {
      void refreshSearchHealth();
      void refreshBrowserHealth();
    }
  }, [activeTab, refreshSearchHealth, refreshBrowserHealth]);

  // Re-anchors the boot snapshot when the Network pane opens so a restart
  // performed outside the dashboard (file now converges with the new boot)
  // clears the banner without a manual Refresh. Runs on tab entry only; the
  // pending-restart poll below covers a restart while the pane stays open.
  useEffect(() => {
    if (activeTab === "network") {
      void refreshBootBind();
    }
  }, [activeTab, refreshBootBind]);

  // Loads scratch quotas plus the pinned registry when the Tools tab opens so
  // the bars reflect the live tree rather than a stale mount. Runs on tab
  // entry only; prune, toggle, run, and promote refresh their own slice
  // without an extra probe so the pane never flashes empty mid-action.
  useEffect(() => {
    if (activeTab === "tools") {
      void refreshWorkspaceUsage();
      void refreshAgentTools();
      void refreshWorkspaceMachine();
    }
  }, [activeTab, refreshWorkspaceUsage, refreshAgentTools, refreshWorkspaceMachine]);

  // Clears the sticky restart flag once the saved file converges with the
  // re-anchored boot: the health poll moves live to the new boot after an
  // external restart, so equality proves the pending bind is live and the
  // banner must clear instead of staying stuck on the pre-restart PUT flag.
  useEffect(() => {
    if (!serverRestartRequired || !settings || !liveServerBind) return;
    const fileHostname =
      typeof settings.serverHostname === "string" && settings.serverHostname.trim()
        ? settings.serverHostname
        : DEFAULT_SERVER_HOSTNAME;
    const filePort =
      typeof settings.serverPort === "number" && Number.isInteger(settings.serverPort)
        ? settings.serverPort
        : DEFAULT_SERVER_PORT;
    const fileHosts = Array.isArray(settings.serverAllowedHosts)
      ? (settings.serverAllowedHosts as string[])
      : [];
    const converged =
      canonicalRestartHost(fileHostname) ===
        canonicalRestartHost(liveServerBind.hostname) &&
      filePort === liveServerBind.port &&
      areServerAllowedHostsEqual(fileHosts, liveServerBind.allowedHosts);
    if (converged) {
      setServerRestartRequired(false);
    }
  }, [serverRestartRequired, settings, liveServerBind]);

  // Polls the live bind while the Network pane shows a pending restart so an
  // external restart re-anchors live when file converges with boot and the
  // banner clears. Idle while converged so steady state adds no QPS; cleared
  // on tab change or unmount.
  useEffect(() => {
    if (activeTab !== "network") return;
    const fileHostname =
      typeof settings?.serverHostname === "string" && settings.serverHostname.trim()
        ? settings.serverHostname
        : DEFAULT_SERVER_HOSTNAME;
    const filePort =
      typeof settings?.serverPort === "number" && Number.isInteger(settings.serverPort)
        ? settings.serverPort
        : DEFAULT_SERVER_PORT;
    const fileHosts = Array.isArray(settings?.serverAllowedHosts)
      ? (settings.serverAllowedHosts as string[])
      : [];
    const bootHostname = liveServerBind?.hostname ?? fileHostname;
    const bootPort = liveServerBind?.port ?? filePort;
    const bootHosts = liveServerBind?.allowedHosts ?? fileHosts;
    const fileDiffersFromBoot =
      canonicalRestartHost(fileHostname) !== canonicalRestartHost(bootHostname) ||
      filePort !== bootPort ||
      !areServerAllowedHostsEqual(fileHosts, bootHosts);
    if (!serverRestartRequired && !fileDiffersFromBoot) return;
    const timer = setInterval(() => {
      void refreshBootBind();
    }, SERVER_BOOT_POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [activeTab, settings, liveServerBind, serverRestartRequired, refreshBootBind]);

  // Unmount must never leave the browser provision poll or media/desktop/fanout tick
  // running behind a closed pane.
  useEffect(() => {
    const pollRef = browserTimerRef;
    const mediaRef = mediaSaveTimerRef;
    const browserSaveRef = browserSaveTimerRef;
    const desktopSaveRef = desktopSaveTimerRef;
    const fanoutSaveRef = fanoutSaveTimerRef;
    return () => {
      if (pollRef.current !== null) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
      if (mediaRef.current !== null) {
        clearTimeout(mediaRef.current);
        mediaRef.current = null;
      }
      if (browserSaveRef.current !== null) {
        clearTimeout(browserSaveRef.current);
        browserSaveRef.current = null;
      }
      if (desktopSaveRef.current !== null) {
        clearTimeout(desktopSaveRef.current);
        desktopSaveRef.current = null;
      }
      if (fanoutSaveRef.current !== null) {
        clearTimeout(fanoutSaveRef.current);
        fanoutSaveRef.current = null;
      }
    };
  }, []);

  // Force Advanced open whenever a provision error lands: the inline banner
  // names the cause, and the venv path plus manual fallback inside Advanced are
  // the operator's recovery route. The ref (not a controlled `open` prop) keeps
  // the disclosure user-togglable the rest of the time.
  useEffect(() => {
    if (browserError && browserAdvancedRef.current) {
      browserAdvancedRef.current.open = true;
    }
  }, [browserError]);

  // Validates the form and persists it through PUT /settings, then hot-reloads
  // safe sections live. Providers, engine identity, and DB paths still need a
  // restart to take effect, but the notice stays a plain saved confirmation
  // without blanket restart claims.
  const executeSave = async () => {
    setSaving(true);
    setError(null);

    // The persona tab owns the identity drafts alone: its save folds the
    // changed-only delta into this shared footer path so validation and server
    // 400s surface through the same banner as every other pane. The engine
    // merge preserves every omitted key, and an untouched tab never reaches
    // the network.
    if (activeTab === "persona") {
      const personaValidationError = validatePersonaFields();
      if (personaValidationError) {
        setError(personaValidationError);
        setSaving(false);
        return;
      }
      const personaDelta = buildPersonaDelta();
      if (Object.keys(personaDelta).length === 0) {
        setSaving(false);
        return;
      }
      try {
        const updated = await updateSettings({ persona: personaDelta });
        // Repopulating reseeds every draft from the PUT response, re-arms the
        // delta baseline, and publishes the persona into the shared store so the
        // profile block and chat header adopt the new identity without a reload.
        populateForm(updated);
        onSettingsSaved?.();
        pushSuccessToast(
          "Persona saved. The agent adopts the new identity on engine reload.",
        );
      } catch (failure) {
        setError(failure instanceof ApiError ? failure.message : "Failed to save persona");
      } finally {
        setSaving(false);
      }
      return;
    }

    // Provider names become TOML table keys, so rejects must surface here
    // rather than silently dropping or overwriting an entry on save.
    const seenNames = new Set<string>();
    for (const entry of providersList) {
      const trimmedName = entry.name.trim();
      if (!trimmedName) {
        setError("Provider names cannot be empty.");
        setSaving(false);
        return;
      }
      if (seenNames.has(trimmedName)) {
        setError(`Duplicate provider name: "${trimmedName}". Provider names must be unique.`);
        setSaving(false);
        return;
      }
      seenNames.add(trimmedName);
    }

    // Reassemble providers dictionary
    const providersMap: Record<string, ProviderConfigData> = {};
    for (const entry of providersList) {
      const trimmedName = entry.name.trim();
      if (!trimmedName) continue;
      const sUrl = entry.config.serverURL || entry.config.serverURL;
      const kEnv = entry.config.apiKeyEnv || entry.config.apiKeyEnv;
      const pType = entry.config.providerType || entry.config.providerType;
      const aStyle = entry.config.apiStyle || entry.config.apiStyle;
      // Absent contextLength means backend-default (nil), so only send a Number when the user
      // entered a value; empty stays omitted. Present values fail closed on non-positive or non-
      // integer input instead of coercing to the backend default, mirroring Config+Validation.
      const cLenRaw = entry.config.contextLength ?? entry.config.contextLength;
      if (
        cLenRaw !== undefined &&
        cLenRaw !== null &&
        (cLenRaw as unknown) !== ""
      ) {
        const cLenCheck = Number(cLenRaw);
        if (!Number.isInteger(cLenCheck) || cLenCheck <= 0) {
          const label = trimmedName || "(unnamed)";
          setError(
            `Invalid contextLength for provider "${label}": contextLength must be a positive integer.`
          );
          setSaving(false);
          return;
        }
      }
      const cLenNum =
        cLenRaw === undefined || cLenRaw === null || (cLenRaw as unknown) === ""
          ? undefined
          : Number(cLenRaw);
      const cLen =
        cLenNum === undefined || Number.isNaN(cLenNum) ? undefined : cLenNum;
      // Absent slotCount keeps server auto-assignment (nil), so only send a Number when the user
      // entered a value; empty stays omitted. Present values fail closed on non-positive or non-
      // integer input instead of pinning an out-of-range id, mirroring Config+Validation.
      const slotRaw = entry.config.slotCount ?? entry.config.slotCount;
      if (
        slotRaw !== undefined &&
        slotRaw !== null &&
        (slotRaw as unknown) !== ""
      ) {
        const slotCheck = Number(slotRaw);
        if (!Number.isInteger(slotCheck) || slotCheck <= 0) {
          const label = trimmedName || "(unnamed)";
          setError(
            `Invalid slotCount for provider "${label}": slotCount must be a positive integer.`
          );
          setSaving(false);
          return;
        }
      }
      const slotNum =
        slotRaw === undefined || slotRaw === null || (slotRaw as unknown) === ""
          ? undefined
          : Number(slotRaw);
      const slot =
        slotNum === undefined || Number.isNaN(slotNum) ? undefined : slotNum;
      // Tri-state cache hint: unset omits both keys (always-on default), while explicit true/false
      // dual-writes so an intentionally disabled hint survives the PUT instead of resetting to nil.
      // Nullish coalescing preserves false; string forms from the select normalize to booleans.
      const cacheRaw = entry.config.cachePrompt ?? entry.config.cachePrompt;
      let cache: boolean | undefined;
      if (
        cacheRaw === undefined ||
        cacheRaw === null ||
        (cacheRaw as unknown) === ""
      ) {
        cache = undefined;
      } else if (cacheRaw === true || (cacheRaw as unknown) === "true") {
        cache = true;
      } else if (cacheRaw === false || (cacheRaw as unknown) === "false") {
        cache = false;
      } else {
        // Unrecognized cache values fail closed rather than coercing via Boolean(), which would
        // silently treat 0/"maybe" as enabled. Mirrors slotCount validation above.
        const label = trimmedName || "(unnamed)";
        setError(
          `Invalid cachePrompt for provider "${label}": cachePrompt must be true, false, or empty (unset).`
        );
        setSaving(false);
        return;
      }

      const visionRaw =
        entry.config.supportsVision ?? entry.config.supportsVision;
      let vision: boolean | undefined;
      if (
        visionRaw === undefined ||
        visionRaw === null ||
        (visionRaw as unknown) === ""
      ) {
        vision = undefined;
      } else if (visionRaw === true || (visionRaw as unknown) === "true") {
        vision = true;
      } else if (visionRaw === false || (visionRaw as unknown) === "false") {
        vision = false;
      } else {
        const label = trimmedName || "(unnamed)";
        setError(
          `Invalid supportsVision for provider "${label}": supportsVision must be true, false, or empty (unset).`
        );
        setSaving(false);
        return;
      }

      providersMap[trimmedName] = {
        enabled: entry.config.enabled,
        model: entry.config.model?.trim() || undefined,
        serverURL: sUrl?.trim() || undefined,
        apiKeyEnv: kEnv?.trim() || undefined,
        providerType: pType?.trim() || undefined,
        apiStyle: aStyle?.trim() || undefined,
        contextLength: cLen != null ? Number(cLen) : undefined,
        slotCount: slot != null ? Number(slot) : undefined,
        cachePrompt: cache,
        supportsVision: vision,
      };
    }


    // Workspace quotas share their validation helper so the Tools-tab save
    // rejects an out-of-range quota or retention before any network write.
    // Mirrors WorkspaceConfig clamps (10-10240 MB, 100-100000 files, 0-90
    // days) so the form agrees with the server 400.
    const workspaceValidationError = validateWorkspaceFields();
    if (workspaceValidationError) {
      setError(workspaceValidationError);
      setSaving(false);
      return;
    }
    // Container knobs share their validation helper so the page save rejects
    // an out-of-range memory, concurrency, or TTL before any network write.
    // Mirrors ContainersConfig clamps (256-8192 MB, 1-32 concurrent, 5-1440
    // TTL minutes) so the form agrees with the server 400.
    const containersValidationError = validateContainersFields();
    if (containersValidationError) {
      setError(containersValidationError);
      setSaving(false);
      return;
    }
    // Goals and proactivity share their validation helpers so the full-save
    // rejects the same shapes a modal would before any network write. Mirrors
    // GoalsConfig bounds (5-20160, 1-50) plus the ProactiveMode closed set and
    // the 1-120 judge bound.
    const goalsValidationError = validateGoalsFields();
    if (goalsValidationError) {
      setError(goalsValidationError);
      setSaving(false);
      return;
    }
    const ideasValidationError = validateIdeasFields();
    if (ideasValidationError) {
      setError(ideasValidationError);
      setSaving(false);
      return;
    }
    const proactiveValidationError = validateProactiveFields();
    if (proactiveValidationError) {
      setError(proactiveValidationError);
      setSaving(false);
      return;
    }

    // Reassemble email accounts array, preserving optional SMTP overrides. Blank smtpHost
    // collapses to omitted (derived fallback) and blank smtpPort omits so auto tries 587 then 465;
    // smtpSecurity defaults to auto when blank or unknown.
    for (const entry of emailAccountsList) {
      const trimmedName = entry.account.name.trim();
      const trimmedHost = entry.account.host.trim();
      const trimmedUsername = entry.account.username.trim();
      if (!trimmedName || !trimmedHost || !trimmedUsername) {
        setError(
          "Email accounts require a name, host, and username. Complete or remove incomplete rows before saving."
        );
        setSaving(false);
        return;
      }
    }
    // IMAP ports fail closed on non-integer or out-of-range values instead
    // of coercing to 993, mirroring Config+Validation 1-65535; explicit
    // SMTP ports follow the narrow submission allowlist (25, 465, 587, 2525)
    // mirroring Config+Validation/EmailConfig so a saved port never fails
    // server load validation.
    for (const entry of emailAccountsList) {
      const label = entry.account.name.trim() || "(unnamed)";
      const portNum = Number(entry.account.port);
      if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
        setError(
          `Invalid port for email account "${label}": port must be between 1 and 65535.`
        );
        setSaving(false);
        return;
      }
      const rawSmtpPort = entry.account.smtpPort ?? entry.account.smtpPort;
      if (
        rawSmtpPort !== undefined &&
        rawSmtpPort !== null &&
        String(rawSmtpPort).trim() !== ""
      ) {
        const smtpNum = Number(rawSmtpPort);
        const allowedSmtpPorts = [25, 465, 587, 2525];
        if (!Number.isInteger(smtpNum) || !allowedSmtpPorts.includes(smtpNum)) {
          setError(
            `Invalid SMTP port for email account "${label}": smtpPort must be one of 25, 465, 587, 2525 (got ${String(rawSmtpPort).trim()}).`
          );
          setSaving(false);
          return;
        }
      }
    }
    // Search fields fail closed before any network write so a bad URL or out-of-range limit never
    // persists to config.toml.
    const trimmedSearxngURL = searchSearxngURL.trim();
    if (!trimmedSearxngURL) {
      setError("Search SearXNG URL cannot be empty.");
      setSaving(false);
      return;
    }
    try {
      const parsedSearchURL = new URL(trimmedSearxngURL);
      if (
        parsedSearchURL.protocol !== "http:" &&
        parsedSearchURL.protocol !== "https:"
      ) {
        throw new Error("bad protocol");
      }
    } catch {
      setError(
        `Invalid SearXNG URL: "${trimmedSearxngURL}". Use an absolute http(s) URL.`
      );
      setSaving(false);
      return;
    }
    const timeoutNum = Number(searchTimeoutSeconds);
    if (!Number.isInteger(timeoutNum) || timeoutNum < 1 || timeoutNum > 120) {
      setError("Invalid search timeout: timeout must be between 1 and 120 seconds.");
      setSaving(false);
      return;
    }
    const maxResultsNum = Number(searchMaxResults);
    if (
      !Number.isInteger(maxResultsNum) ||
      maxResultsNum < 1 ||
      maxResultsNum > 50
    ) {
      setError("Invalid search max results: max results must be between 1 and 50.");
      setSaving(false);
      return;
    }
    // Browser automation, HTTP request, and media request timeouts share their
    // bounds helpers so the full-save rejects the same shapes their modal saves
    // do before any network write. Mirrors browser 5-300, fetch 1-120, and
    // media 5-120.
    const browserTimeoutError = validateBrowserTimeoutSeconds(browserTimeoutSeconds);
    if (browserTimeoutError) {
      setError(browserTimeoutError);
      setSaving(false);
      return;
    }
    const browserFetchTimeoutError = validateBrowserFetchTimeoutSeconds(browserFetchTimeoutSeconds);
    if (browserFetchTimeoutError) {
      setError(browserFetchTimeoutError);
      setSaving(false);
      return;
    }
    const mediaTimeoutError = validateMediaTimeoutSeconds(mediaTimeoutSeconds);
    if (mediaTimeoutError) {
      setError(mediaTimeoutError);
      setSaving(false);
      return;
    }
    // Desktop capture knobs fail closed before any network write so a bad
    // dimension or quality never persists to config.toml, via the shared
    // bounds helper (Mirrors Config+Validation bounds: 256-3840, 0.1-1.0).
    const desktopBoundsError = validateDesktopCaptureBounds(
      desktopMaxImageDimension,
      desktopJpegQuality
    );
    if (desktopBoundsError) {
      setError(desktopBoundsError);
      setSaving(false);
      return;
    }
    // [server] bind fails closed before any network write so a bad hostname,
    // port, or allowed_hosts entry never persists to config.toml. Mirrors
    // ServerEndpointConfig plus RuneWeaverConfig.validateServerHostname and
    // validateAllowedHosts: port 1-65535, exact-only hostname and hosts
    // (lowercase, port-stripped, no scheme/wildcard/CIDR/bare *,
    // unbalanced brackets, or trailing dot, max 20 hosts, max 253 chars).
    // A non-loopback hostname without a resolvable owner token is refused
    // server-side (400, never a silent downgrade); the form lets the attempt
    // through so that authoritative message surfaces instead of a stale
    // client-side block.
    const trimmedServerHostname = serverHostname.trim();
    if (!trimmedServerHostname) {
      setError("Server hostname cannot be empty.");
      setSaving(false);
      return;
    }
    const serverHostnameError = validateServerHostname(trimmedServerHostname);
    if (serverHostnameError) {
      setError(`Invalid server hostname: ${serverHostnameError}`);
      setSaving(false);
      return;
    }
    const serverPortNum = Number(serverPort);
    if (!Number.isInteger(serverPortNum) || serverPortNum < 1 || serverPortNum > 65535) {
      setError("Invalid server port: port must be between 1 and 65535.");
      setSaving(false);
      return;
    }
    const trimmedServerHosts = parseServerAllowedHostsText(serverAllowedHostsText);
    const serverHostsError = validateServerAllowedHosts(trimmedServerHosts);
    if (serverHostsError) {
      setError(`Invalid allowed hosts: ${serverHostsError}`);
      setSaving(false);
      return;
    }
    const emailAccounts: EmailAccountData[] = emailAccountsList.map((entry) => {
      const rawHost = entry.account.smtpHost ?? entry.account.smtpHost ?? "";
      const trimmedSmtpHost = String(rawHost).trim();
      const rawPort = entry.account.smtpPort ?? entry.account.smtpPort;
      const portNum =
        rawPort === undefined || rawPort === null || (rawPort as unknown) === ""
          ? undefined
          : Number(rawPort);
      const rawSecurity = entry.account.smtpSecurity ?? entry.account.smtpSecurity ?? "";
      const trimmedSecurity = String(rawSecurity).trim().toLowerCase();
      const security =
        trimmedSecurity === "ssl" || trimmedSecurity === "starttls" ? trimmedSecurity : undefined;
      const rebuilt: EmailAccountData = {
        name: entry.account.name.trim(),
        type: entry.account.type.trim() || "imap",
        host: entry.account.host.trim(),
        port: Number(entry.account.port),
        username: entry.account.username.trim(),
      };
      if (trimmedSmtpHost) {
        rebuilt.smtpHost = trimmedSmtpHost;
        rebuilt.smtpHost = trimmedSmtpHost;
      }
      if (portNum !== undefined && Number.isInteger(portNum) && portNum >= 1 && portNum <= 65535) {
        rebuilt.smtpPort = portNum;
        rebuilt.smtpPort = portNum;
      }
      if (security) {
        rebuilt.smtpSecurity = security;
        rebuilt.smtpSecurity = security;
      }
      return rebuilt;
    });

    try {
      // The embedding model has no editable input: provider reuses the active
      // chat model and apple uses its fixed on-device model, so resend the
      // loaded value untouched to keep older configs valid (never blank it).
      const preservedEmbeddingModel =
        memoryEmbeddingModel || settings?.memoryEmbeddingModel || "";
      // Blank means default; explicit values clamp into range.
      const rawMaxToolIterations = String(maxToolIterations ?? "").trim();
      const maxToolIterationsValue =
        rawMaxToolIterations === "" ? DEFAULT_ENGINE_MAX_TOOL_ITERATIONS : Number(rawMaxToolIterations);
      const clampedMaxToolIterations = Number.isFinite(maxToolIterationsValue)
        ? Math.max(TOOL_ROUNDS_MIN, Math.min(TOOL_ROUNDS_MAX, Math.floor(maxToolIterationsValue)))
        : DEFAULT_ENGINE_MAX_TOOL_ITERATIONS;
      // Only send [server] keys when the form differs from the loaded file.
      // Resending unchanged bind keys would trip carriesServerPatch on every
      // save and return requiresRestart true for non-network edits; the route
      // also diffs old versus new server-side as defense in depth.
      const loadedServerHostname =
        typeof settings?.serverHostname === "string" && settings.serverHostname.trim()
          ? settings.serverHostname
          : DEFAULT_SERVER_HOSTNAME;
      const loadedServerPort =
        typeof settings?.serverPort === "number" && Number.isInteger(settings.serverPort)
          ? settings.serverPort
          : DEFAULT_SERVER_PORT;
      const loadedServerHosts = Array.isArray(settings?.serverAllowedHosts)
        ? (settings.serverAllowedHosts as string[])
        : [];
      const serverDirty =
        canonicalRestartHost(trimmedServerHostname) !==
          canonicalRestartHost(loadedServerHostname) ||
        serverPortNum !== loadedServerPort ||
        !areServerAllowedHostsEqual(trimmedServerHosts, loadedServerHosts);
      // Snapshot the pre-save file as the boot source of truth before the PUT
      // overwrites settings: after populateForm the file holds the new values
      // while this snapshot keeps the still-live boot for the banner.
      const preSaveFileBind = {
        hostname: loadedServerHostname,
        port: loadedServerPort,
        allowedHosts: [...loadedServerHosts],
      };
      const updated = await updateSettings({
        engineName,
        logLevel,
        compactionThresholdPercent: Number(compactionThresholdPercent),
        maxToolIterations: clampedMaxToolIterations,
        defaultProvider,
        // Empty string clears the fallback server-side; omitting the field
        // would preserve the previous value instead.
        fallbackProvider: fallbackProvider,
        providers: providersMap,
        containers: buildContainersPatch(),
        memoryVectorDBPath,
        memoryEpisodesDBPath,
        memoryEmbeddingModel: preservedEmbeddingModel,
        memoryEmbeddingBackend,
        voiceSTTProvider,
        voiceWhisperModel,
        voiceTTSProvider,
        // Dual-write both contracts so old (search*) and new (browser*) engines
        // persist the [browser] values the tools dial.
        browserSearxngURL: trimmedSearxngURL,
        browserSearchTimeoutSeconds: timeoutNum,
        browserTimeoutSeconds: Number(browserTimeoutSeconds) || DEFAULT_BROWSER_TIMEOUT_SECONDS,
        browserFetchTimeoutSeconds: Number(browserFetchTimeoutSeconds) || DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
        browserMaxResults: maxResultsNum,
        searchSearxngURL: trimmedSearxngURL,
        searchTimeoutSeconds: timeoutNum,
        searchMaxResults: maxResultsNum,
        emailAccounts,
        pluginsDir,
        pluginsMarketplaceIndexURL,
        pluginsAutoRescan,
        media: buildMediaPayload(),
        desktop: buildDesktopPayload(),
        workspace: buildWorkspacePayload(),
        goals: buildGoalsPayload(),
        proactive: buildProactivePayload(),
        ideas: buildIdeasPayload(),
        ...(serverDirty
          ? {
              serverHostname: trimmedServerHostname,
              serverPort: serverPortNum,
              serverAllowedHosts: trimmedServerHosts.map((h) => normalizeServerAllowedHost(h)),
            }
          : {}),
      });
      // Preserve the original boot across saves: the first network save seeds
      // live from the pre-save file, and later saves keep it so the banner
      // compares the latest file against the still-live boot. populateForm
      // below seeds live only when null, so this pre-save value wins.
      if (updated.requiresRestart) {
        setLiveServerBind((prev) => prev ?? preSaveFileBind);
      }
      populateForm(updated);
      onSettingsSaved?.();
      // The bind never live-reloads: when the save really moved [server] keys
      // the route returns requiresRestart and the Network pane keeps its banner
      // until a restart, while safe sections hot-reload live underneath.
      if (updated.requiresRestart) {
        if (serverDirty) {
          setServerRestartRequired(true);
          pushSuccessToast("Settings saved. Restart required for network changes.");
        } else {
          pushSuccessToast("Settings saved. Restart required.");
        }
      } else {
        // Saved confirmation stays exact so operators recognize it; safe
        // sections hot-reload live while engine identity and DB paths take
        // effect on restart; providers hot-reload live via reloadLiveLLM.
        pushSuccessToast("Settings saved.");
      }
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to save settings");
    } finally {
      setSaving(false);
    }
  };

  // Checks for actively-running work before any PUT so a save never silently
  // cancels an in-flight turn. Only running counts; parked or awaiting_approval
  // rows wait on the inbox and never trigger the guard. A fresh run-log read
  // keeps the check honest when the shared poller has not ticked yet; the
  // shared snapshot backs the probe only when it fails, so a stale poll never
  // overrides a fresh idle read.
  const hasRunningWork = async (): Promise<boolean> => {
    try {
      const live = await listRuns(RUN_LOG_POLL_LIMIT);
      const raw = (live as unknown as { runs?: unknown })?.runs;
      const rows = Array.isArray(raw)
        ? (raw as Array<{ status?: unknown }>)
        : [];
      return hasActiveRuns(rows);
    } catch {
      if (Array.isArray(sharedRuns)) {
        return hasActiveRuns(sharedRuns);
      }
      return false;
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (saving) return;
    let active = false;
    try {
      active = await hasRunningWork();
    } catch {
      active = false;
    }
    if (active) {
      setShowActiveGuard(true);
      return;
    }
    await executeSave();
  };

  // Continue path saves and hot-reloads after the operator accepts that
  // in-progress chats will be cancelled.
  const handleConfirmGuardSave = async () => {
    setShowActiveGuard(false);
    await executeSave();
  };

  const handleCancelGuard = () => {
    setShowActiveGuard(false);
  };

  const handleSaveMediaConfig = async () => {
    const mediaTimeoutError = validateMediaTimeoutSeconds(mediaTimeoutSeconds);
    if (mediaTimeoutError) {
      setMediaModalError(mediaTimeoutError);
      return;
    }
    setMediaSaveLoading(true);
    setMediaModalError(null);
    try {
      const updated = await updateSettings({
        media: buildMediaPayload(),
      });
      populateForm(updated);
      pushSuccessToast("Media settings saved!");
      // Re-arm the close tick through the ref so a repeat save replaces the
      // pending tick and unmount clears it instead of leaking.
      if (mediaSaveTimerRef.current !== null) {
        clearTimeout(mediaSaveTimerRef.current);
        mediaSaveTimerRef.current = null;
      }
      mediaSaveTimerRef.current = setTimeout(() => {
        mediaSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setMediaModalError(err instanceof ApiError ? err.message : "Failed to save media settings");
    } finally {
      setMediaSaveLoading(false);
    }
  };

  const handleSaveBrowserConfig = async () => {
    const browserTimeoutError = validateBrowserTimeoutSeconds(browserTimeoutSeconds);
    if (browserTimeoutError) {
      setBrowserModalError(browserTimeoutError);
      return;
    }
    const browserFetchTimeoutError = validateBrowserFetchTimeoutSeconds(browserFetchTimeoutSeconds);
    if (browserFetchTimeoutError) {
      setBrowserModalError(browserFetchTimeoutError);
      return;
    }
    setBrowserSaveLoading(true);
    setBrowserModalError(null);
    try {
      const bTimeout = Number(browserTimeoutSeconds);
      const fTimeout = Number(browserFetchTimeoutSeconds);
      const updated = await updateSettings({
        browserTimeoutSeconds: isNaN(bTimeout) || bTimeout <= 0 ? DEFAULT_BROWSER_TIMEOUT_SECONDS : bTimeout,
        browserFetchTimeoutSeconds: isNaN(fTimeout) || fTimeout <= 0 ? DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS : fTimeout,
      });
      // Refresh only the timeout fields so unsaved edits in other tabs survive.
      if (updated.browserTimeoutSeconds !== undefined) {
        setBrowserTimeoutSeconds(updated.browserTimeoutSeconds);
      }
      if (updated.browserFetchTimeoutSeconds !== undefined) {
        setBrowserFetchTimeoutSeconds(updated.browserFetchTimeoutSeconds);
      }
      pushSuccessToast("Web, browser & API settings saved!");
      if (browserSaveTimerRef.current !== null) {
        clearTimeout(browserSaveTimerRef.current);
        browserSaveTimerRef.current = null;
      }
      browserSaveTimerRef.current = setTimeout(() => {
        browserSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setBrowserModalError(err instanceof ApiError ? err.message : "Failed to save browser settings");
    } finally {
      setBrowserSaveLoading(false);
    }
  };

  // Saves the unified [desktop] delta for the desktop modal through PUT
  // /settings, mirroring the media-only save shape so unsaved edits in other
  // tabs survive. Validates capture bounds through the shared helper and
  // saves both screen capture knobs and application blocklists without enable
  // keys, which live exclusively in tool-state toggles.
  const handleSaveDesktopConfig = async () => {
    const desktopBoundsError = validateDesktopCaptureBounds(
      desktopMaxImageDimension,
      desktopJpegQuality
    );
    if (desktopBoundsError) {
      setDesktopModalError(desktopBoundsError);
      return;
    }
    setDesktopSaveLoading(true);
    setDesktopModalError(null);
    try {
      const updated = await updateSettings({
        desktop: buildDesktopPayload(),
      });
      populateForm(updated);
      pushSuccessToast("Desktop settings saved!");
      // Re-arm the close tick through the ref so a repeat save replaces the
      // pending tick and unmount clears it instead of leaking.
      if (desktopSaveTimerRef.current !== null) {
        clearTimeout(desktopSaveTimerRef.current);
        desktopSaveTimerRef.current = null;
      }
      desktopSaveTimerRef.current = setTimeout(() => {
        desktopSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setDesktopModalError(err instanceof ApiError ? err.message : "Failed to save desktop settings");
    } finally {
      setDesktopSaveLoading(false);
    }
  };

  // Saves the changed-only [fanout] delta for the fan-out modal through PUT
  // /settings, mirroring the media-only save shape so unsaved edits in other
  // tabs survive. Only knobs travel here — enablement lives in the tool-state
  // toggles — and untouched knobs stay omitted so the stored value survives.
  // A cleared numeric input sends the modal default as an explicit change, and
  // the honest server message surfaces on failure.
  const handleSaveFanoutConfig = async () => {
    setFanoutSaveLoading(true);
    setFanoutModalError(null);
    try {
      const updated = await updateSettings({
        fanout: buildFanoutPayload(),
      });
      populateForm(updated);
      pushSuccessToast("Fan-out settings saved!");
      // Re-arm the close tick through the ref so a repeat save replaces the
      // pending tick and unmount clears it instead of leaking.
      if (fanoutSaveTimerRef.current !== null) {
        clearTimeout(fanoutSaveTimerRef.current);
        fanoutSaveTimerRef.current = null;
      }
      fanoutSaveTimerRef.current = setTimeout(() => {
        fanoutSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setFanoutModalError(err instanceof ApiError ? err.message : "Failed to save fan-out settings");
    } finally {
      setFanoutSaveLoading(false);
    }
  };

  // Provider CRUD helpers
  const handleAddProvider = () => {
    const id = `new-p-${Date.now()}`;
    const name = `provider_${providersList.length + 1}`;
    setProvidersList((prev) => [
      ...prev,
      {
        id,
        name,
        config: {
          enabled: true,
          model: "",
          serverURL: "",
          apiKeyEnv: "",
          providerType: "",
          apiStyle: "",
          contextLength: undefined,
          slotCount: undefined,
          cachePrompt: undefined,
          supportsVision: undefined,
        },
      },
    ]);
  };

  const handleRemoveProvider = (id: string, name: string) => {
    // Keep state updaters pure: derive the next list first, then sync the
    // dependent selections so repeated invocations stay consistent.
    const filtered = providersList.filter((p) => p.id !== id);
    setProvidersList(filtered);
    if (defaultProvider === name) {
      setDefaultProvider(filtered.length > 0 ? filtered[0].name : "");
    }
    if (fallbackProvider === name) {
      setFallbackProvider("");
    }
  };

  const handleProviderNameChange = (id: string, newName: string) => {
    // Keep state updaters pure: sync dependent selections outside the
    // list updater so repeated invocations stay consistent.
    const existing = providersList.find((item) => item.id === id);
    if (existing) {
      if (defaultProvider === existing.name) {
        setDefaultProvider(newName);
      }
      if (fallbackProvider === existing.name) {
        setFallbackProvider(newName);
      }
    }
    setProvidersList((prev) =>
      prev.map((item) => (item.id === id ? { ...item, name: newName } : item))
    );
  };

  const handleProviderFieldChange = (
    id: string,
    field: keyof ProviderConfigData,
    val: string | boolean | number | undefined
  ) => {
    // Resolve the vision tri-state before touching list state so unexpected
    // values block the edit instead of collapsing to false inside the updater.
    let visionNext: boolean | undefined = undefined;
    const isVisionField = field === "supportsVision";
    if (isVisionField) {
      if (val === "" || val === undefined) {
        visionNext = undefined;
      } else if (val === true || val === "true") {
        visionNext = true;
      } else if (val === false || val === "false") {
        visionNext = false;
      } else {
        const label =
          (providersList.find((item) => item.id === id)?.name ?? "").trim() ||
          "(unnamed)";
        setError(
          `Invalid supportsVision for provider "${label}": supportsVision must be true, false, or empty (unset).`
        );
        return;
      }
    }
    setProvidersList((prev) =>
      prev.map((item) => {
        if (item.id === id) {
          const updated = { ...item.config, [field]: val };
          if (field === "serverURL") updated.serverURL = val as string;
          if (field === "apiKeyEnv") updated.apiKeyEnv = val as string;
          if (field === "providerType") updated.providerType = val as string;
          if (field === "apiStyle") updated.apiStyle = val as string;
          // An empty context-length input means backend-default (nil)
          if (field === "contextLength") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.contextLength = next as unknown as number | undefined;
          }
          // An empty slot input means server auto-assign (nil)
          if (field === "slotCount") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.slotCount = next as unknown as number | undefined;
          }
          // Tri-state cache hint: empty means unset (always-on default)
          if (field === "cachePrompt") {
            const next =
              val === "" || val === undefined
                ? undefined
                : val === true || val === "true"
                  ? true
                  : val === false || val === "false"
                    ? false
                    : (val as unknown as boolean | undefined);
            updated.cachePrompt = next;
          }
          if (field === "supportsVision") {
            updated.supportsVision = visionNext;
          }
          return { ...item, config: updated };
        }
        return item;
      })
    );
  };

  // Email Accounts CRUD helpers
  const handleAddEmailAccount = () => {
    const id = `new-email-${Date.now()}`;
    const name = `mail_${emailAccountsList.length + 1}`;
    setEmailAccountsList((prev) => [
      ...prev,
      {
        id,
        account: {
          name,
          type: "imap",
          host: "imap.example.com",
          port: 993,
          username: "",
        },
      },
    ]);
  };

  const handleRemoveEmailAccount = (id: string) => {
    setEmailAccountsList((prev) => prev.filter((item) => item.id !== id));
  };

  const handleEmailFieldChange = (
    id: string,
    field: keyof EmailAccountData,
    val: string | number
  ) => {
    setEmailAccountsList((prev) =>
      prev.map((item) => {
        if (item.id === id) {
          const next = { ...item.account };
          if (field === "port") {
            next.port = Number(val);
          } else if (field === "smtpPort") {
            const num = val === "" || val === undefined ? undefined : Number(val);
            next.smtpPort = num as unknown as number | undefined;
          } else if (field === "smtpHost") {
            next.smtpHost = val as string;
          } else if (field === "smtpSecurity") {
            next.smtpSecurity = val as string;
          } else {
            (next as Record<string, unknown>)[field] = val;
          }
          return {
            ...item,
            account: next as EmailAccountData,
          };
        }
        return item;
      })
    );
  };


  // Live parsed allowed-hosts entries share the same single-source pattern:
  // the badge and the save path read from the raw textarea text.
  const serverAllowedHostsCount = parseServerAllowedHostsText(serverAllowedHostsText).length;
  const serverAllowedHostsError = validateServerAllowedHosts(
    parseServerAllowedHostsText(serverAllowedHostsText),
  );
  // File-vs-boot truth for the Network badge: the saved file from settings
  // against the boot snapshot (or the file itself before the first snapshot).
  // ORed with the server flag so a pending restart survives non-server saves
  // that return false, while an unchanged bind never lights the badge.
  const serverFileHostnameForBadge =
    typeof settings?.serverHostname === "string" && settings.serverHostname.trim()
      ? settings.serverHostname
      : DEFAULT_SERVER_HOSTNAME;
  const serverFilePortForBadge =
    typeof settings?.serverPort === "number" && Number.isInteger(settings.serverPort)
      ? settings.serverPort
      : DEFAULT_SERVER_PORT;
  const serverFileHostsForBadge = Array.isArray(settings?.serverAllowedHosts)
    ? (settings.serverAllowedHosts as string[])
    : [];
  const serverBootHostnameForBadge = liveServerBind?.hostname ?? serverFileHostnameForBadge;
  const serverBootPortForBadge = liveServerBind?.port ?? serverFilePortForBadge;
  const serverBootHostsForBadge = liveServerBind?.allowedHosts ?? serverFileHostsForBadge;
  const serverFileDiffersFromBootForBadge =
    canonicalRestartHost(serverFileHostnameForBadge) !==
      canonicalRestartHost(serverBootHostnameForBadge) ||
    serverFilePortForBadge !== serverBootPortForBadge ||
    !areServerAllowedHostsEqual(serverFileHostsForBadge, serverBootHostsForBadge);
  const serverRestartVisible = serverRestartRequired || serverFileDiffersFromBootForBadge;

  // Section-finder visibility: a tab shows when its keyword index matches the
  // trimmed query or when it is the active tab, so narrowing the list never
  // hides the pane the owner is already looking at. A blank query keeps the
  // full list.
  const settingsNavFilter = settingsNavQuery.trim().toLowerCase();
  const navTabVisible = (tab: SettingsTab) =>
    activeTab === tab || matchesSettingsTab(tab, settingsNavFilter);

  if (loading && !settings) {
    return (
      <div className="section-loading">
        <div className="spinner" />
        <p>Loading configuration...</p>
      </div>
    );
  }

  const providerNames = providersList.map((p) => p.name).filter(Boolean);
  const safePlugins = Array.isArray(pluginsList) ? pluginsList : [];
  const safeTools = Array.isArray(allTools) ? allTools : [];
  const pendingCount = safePlugins.filter((p) => p?.status === "discovered").length;
  const tamperedCount = safePlugins.filter((p) => p?.status === "tampered").length;

  return (
    <section className="panel settings-panel" aria-label="Settings and configuration">
      <div className="panel-header-row">
        {/* Handheld drawer trigger at the top-left of the header. Stylesheet
            reveals it only on narrow widths; desktop keeps the inline sidenav
            with no duplicate control. */}
        <button
          type="button"
          ref={menuButtonRef}
          className="settings-menu-btn"
          aria-label="Open settings menu"
          aria-expanded={settingsMenuOpen}
          onClick={() => setSettingsMenuOpen((previous) => !previous)}
        >
          <MenuIcon size={20} />
        </button>
        <div>
          <h2>Settings & Configuration</h2>
          <p className="muted text-sm">
            Manage LLM model routing, engine parameters, container policy, web search, and email accounts.
          </p>
        </div>

        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void refresh()}
            disabled={loading || saving}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
        </div>
      </div>

      {settings && (
        <div className="settings-config-badge">
          <span>Config file:</span>
          <code>{settings.configPath}</code>
        </div>
      )}

      {error && <div className="error-banner">{error}</div>}
      <ToastStack toasts={toasts} onDismiss={dismissToast} />

      {/* Vertical sidenav: stacked categories beside the content pane so every
          section stays visible without horizontal scrolling. On handheld
          widths the same list becomes a fixed drawer above a dim backdrop,
          mirroring the chat history drawer interaction. A section finder above
          the tabs narrows the list by label or keyword so every pane — Access
          especially, whose editors live behind its rail — stays reachable with
          one word. */}
      <div className="settings-layout">
        {settingsMenuOpen ? (
          <button
            type="button"
            className="settings-backdrop"
            data-testid="settings-backdrop"
            aria-label="Close settings menu"
            onClick={handleSettingsBackdropClick}
          />
        ) : null}
        <div
          className={`settings-nav-column${settingsMenuOpen ? " open" : ""}`}
        >
          <div className="settings-nav-search-wrapper">
            <SearchIcon size={14} className="settings-nav-search-icon" />
            <input
              type="search"
              className="settings-nav-search-input"
              data-testid="settings-nav-search"
              aria-label="Search settings sections"
              placeholder="Search settings sections…"
              value={settingsNavQuery}
              onChange={(e) => setSettingsNavQuery(e.target.value)}
            />
          </div>
          <nav
            className="settings-sidenav"
            aria-label="Settings categories"
            role="tablist"
          >
          {navTabVisible("access") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "access"}
              className={`settings-tab-btn ${activeTab === "access" ? "active" : ""}`}
              onClick={() => selectSettingsTab("access")}
            >
              <KeyIcon size={16} />
              <span>Access</span>
            </button>
          ) : null}

          {navTabVisible("providers") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "providers"}
              className={`settings-tab-btn ${activeTab === "providers" ? "active" : ""}`}
              onClick={() => selectSettingsTab("providers")}
            >
              <ChatIcon size={16} />
              <span>LLM Providers</span>
            </button>
          ) : null}

          {navTabVisible("persona") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "persona"}
              className={`settings-tab-btn ${activeTab === "persona" ? "active" : ""}`}
              onClick={() => selectSettingsTab("persona")}
            >
              <UserIcon size={16} />
              <span>Persona</span>
            </button>
          ) : null}

          {navTabVisible("voice") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "voice"}
              className={`settings-tab-btn ${activeTab === "voice" ? "active" : ""}`}
              onClick={() => selectSettingsTab("voice")}
            >
              <MicIcon size={16} />
              <span>Voice</span>
            </button>
          ) : null}

          {navTabVisible("memory") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "memory"}
              className={`settings-tab-btn ${activeTab === "memory" ? "active" : ""}`}
              onClick={() => selectSettingsTab("memory")}
            >
              <MemoryIcon size={16} />
              <span>Memory and Storage</span>
            </button>
          ) : null}

          {navTabVisible("goals") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "goals"}
              className={`settings-tab-btn ${activeTab === "goals" ? "active" : ""}`}
              onClick={() => selectSettingsTab("goals")}
            >
              <TargetIcon size={16} />
              <span>Goals</span>
            </button>
          ) : null}

          {navTabVisible("tools") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "tools"}
              className={`settings-tab-btn ${activeTab === "tools" ? "active" : ""}`}
              onClick={() => selectSettingsTab("tools")}
            >
              <WrenchIcon size={16} />
              <span>Tools and Runes</span>
              {/* Pending and tampered counts stay on the nav item so review and
                  quarantine signals remain visible without opening the pane. */}
              {pendingCount > 0 && (
                <span
                  className="settings-tab-badge"
                  style={{ backgroundColor: "#ed8936", color: "#ffffff" }}
                  title={`${pendingCount} runes pending human review`}
                >
                  {pendingCount}
                </span>
              )}
              {tamperedCount > 0 && (
                <span
                  className="settings-tab-badge"
                  style={{ backgroundColor: "#f56565", color: "#ffffff" }}
                  title={`${tamperedCount} runes modified since approval`}
                >
                  {tamperedCount}
                </span>
              )}
            </button>
          ) : null}

          {navTabVisible("indexing") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "indexing"}
              className={`settings-tab-btn ${activeTab === "indexing" ? "active" : ""}`}
              onClick={() => selectSettingsTab("indexing")}
            >
              <MemoryIcon size={16} />
              <span>Indexing</span>
            </button>
          ) : null}

          {navTabVisible("search") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "search"}
              className={`settings-tab-btn ${activeTab === "search" ? "active" : ""}`}
              onClick={() => selectSettingsTab("search")}
            >
              <SearchIcon size={16} />
              <span>Web</span>
            </button>
          ) : null}

          {navTabVisible("email") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "email"}
              className={`settings-tab-btn ${activeTab === "email" ? "active" : ""}`}
              onClick={() => selectSettingsTab("email")}
            >
              <MailIcon size={16} />
              <span>Email Accounts</span>
            </button>
          ) : null}

          {navTabVisible("security") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "security"}
              className={`settings-tab-btn ${activeTab === "security" ? "active" : ""}`}
              onClick={() => selectSettingsTab("security")}
            >
              <ApprovalsIcon size={16} />
              <span>Security</span>
            </button>
          ) : null}

          {navTabVisible("network") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "network"}
              className={`settings-tab-btn ${activeTab === "network" ? "active" : ""}`}
              onClick={() => selectSettingsTab("network")}
            >
              <SettingsIcon size={16} />
              <span>Network</span>
              {serverRestartVisible ? (
                <span
                  className="settings-tab-badge"
                  style={{ backgroundColor: "#ed8936", color: "#ffffff" }}
                  title="Network changes need a restart"
                >
                  !
                </span>
              ) : null}
            </button>
          ) : null}

          {navTabVisible("engine") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "engine"}
              className={`settings-tab-btn ${activeTab === "engine" ? "active" : ""}`}
              onClick={() => selectSettingsTab("engine")}
            >
              <SettingsIcon size={16} />
              <span>Engine and Logs</span>
            </button>
          ) : null}

          {/* Starved queries keep the active row visible as context (a
              selected tab may never leave its own list), so this note — not a
              blank rail — explains that nothing matched the query itself. */}
          {settingsNavFilter &&
          SETTINGS_TABS.every((tab) => !matchesSettingsTab(tab, settingsNavFilter)) ? (
            <p className="muted text-sm" data-testid="settings-nav-empty" style={{ padding: "8px 6px", margin: 0 }}>
              No settings sections match.
            </p>
          ) : null}
          </nav>
        </div>

        <div className="settings-content">
          {/* Access owns the owner "what the agent may do" surface: standing
              rules, Bash & Shell, Network, Credentials, and Files write
              posture on its section rail, each saving live outside the shared
              config form — the indexing panel precedent, so policy writes never
              share the config save path. */}
          {activeTab === "access" ? <AccessPane /> : null}
          {activeTab === "indexing" ? <IndexPolicyPanel /> : null}
          {activeTab !== "access" && activeTab !== "indexing" ? (
          <form onSubmit={handleSave} className="settings-form">
        {/* TAB 1: LLM Providers */}
        {activeTab === "providers" && (
          <div className="settings-section card">
            <div className="settings-section-header">
              <div className="settings-section-title-group">
                <h3>LLM Providers</h3>
                <p className="settings-section-hint">
                  Configure active model routing, provider API endpoints, keys, and parameters.
                </p>
              </div>
              <button
                type="button"
                className="ghost icon-text-btn"
                onClick={handleAddProvider}
              >
                <PlusIcon size={14} />
                <span>Add Provider</span>
              </button>
            </div>

            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="default-provider">Default Provider</label>
                <select
                  id="default-provider"
                  className="input-field"
                  value={defaultProvider}
                  onChange={(e) => setDefaultProvider(e.target.value)}
                  required
                >
                  {providerNames.map((name) => (
                    <option key={name} value={name}>
                      {name}
                    </option>
                  ))}
                </select>
              </div>

              <div className="form-group flex-1">
                <label htmlFor="fallback-provider">Fallback Provider (Optional)</label>
                <select
                  id="fallback-provider"
                  className="input-field"
                  value={fallbackProvider}
                  onChange={(e) => setFallbackProvider(e.target.value)}
                >
                  <option value="">(None)</option>
                  {providerNames.map((name) => (
                    <option key={name} value={name}>
                      {name}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="providers-grid">
              {providersList.map((item) => {
                const entry = item.config;
                // Preserve the raw backend value so aliases like llama-cpp /
                // llama_cpp or an absent type do not render as a blank row.
                const rawProviderType =
                  entry.providerType || entry.providerType || "";
                const knownProviderTypes = [
                  "",
                  "custom",
                  "openrouter",
                  "openai",
                  "anthropic",
                  "gemini",
                  "ollama",
                  "mlx",
                  "lmstudio",
                  "llamacpp",
                  "llama-cpp",
                  "llama_cpp",
                  "local",
                ];
                return (
                  <div key={item.id} className="provider-card">
                    <div className="provider-card-header">
                      <div className="provider-header-left">
                        <label htmlFor={`provider-name-${item.id}`} className="sr-only">
                          Provider Name
                        </label>
                        <input
                          id={`provider-name-${item.id}`}
                          type="text"
                          className="provider-name-input"
                          value={item.name}
                          onChange={(e) =>
                            handleProviderNameChange(item.id, e.target.value)
                          }
                          placeholder="Provider Name"
                          title="Click to rename provider"
                          required
                        />
                      </div>
                      <div className="provider-header-actions">
                        <label className="toggle-label">
                          <input
                            type="checkbox"
                            checked={entry.enabled}
                            onChange={(e) =>
                              handleProviderFieldChange(
                                item.id,
                                "enabled",
                                e.target.checked
                              )
                            }
                          />
                          <span>Enabled</span>
                        </label>
                        <button
                          type="button"
                          className="icon-button danger"
                          onClick={() => handleRemoveProvider(item.id, item.name)}
                          title={`Delete provider ${item.name}`}
                          aria-label={`Delete provider ${item.name}`}
                        >
                          <TrashIcon size={14} />
                        </button>
                      </div>
                    </div>

                    <div className="provider-fields">
                      <div className="form-group">
                        <label htmlFor={`model-${item.id}`}>Model</label>
                        <input
                          id={`model-${item.id}`}
                          type="text"
                          className="input-field"
                          value={entry.model ?? ""}
                          onChange={(e) =>
                            handleProviderFieldChange(item.id, "model", e.target.value)
                          }
                          placeholder="e.g. gemma-4-9b or claude-3-5-sonnet"
                        />
                      </div>

                      <div className="form-row">
                        <div className="form-group flex-1">
                          <label htmlFor={`type-${item.id}`}>Provider Type</label>
                          <select
                            id={`type-${item.id}`}
                            className="input-field"
                            value={rawProviderType}
                            onChange={(e) =>
                              handleProviderFieldChange(
                                item.id,
                                "providerType",
                                e.target.value
                              )
                            }
                          >
                            <option value="">(Auto from name)</option>
                            <option value="custom">Custom</option>
                            <option value="openrouter">OpenRouter</option>
                            <option value="openai">OpenAI</option>
                            <option value="anthropic">Anthropic</option>
                            <option value="gemini">Gemini</option>
                            <option value="ollama">Ollama</option>
                            <option value="mlx">MLX</option>
                            <option value="lmstudio">LM Studio</option>
                            <option value="llamacpp">llama.cpp</option>
                            <option value="local">Local</option>
                            {rawProviderType &&
                              !knownProviderTypes.includes(rawProviderType) && (
                                <option value={rawProviderType}>
                                  {rawProviderType}
                                </option>
                              )}
                          </select>
                        </div>

                        <div className="form-group flex-1">
                          <label htmlFor={`style-${item.id}`}>API Style (Optional)</label>
                          <input
                            id={`style-${item.id}`}
                            type="text"
                            className="input-field"
                            value={entry.apiStyle || entry.apiStyle || ""}
                            onChange={(e) =>
                              handleProviderFieldChange(
                                item.id,
                                "apiStyle",
                                e.target.value
                              )
                            }
                            placeholder="e.g. chat-completions, responses"
                          />
                        </div>
                      </div>

                      <div className="form-group">
                        <label htmlFor={`server-${item.id}`}>Server URL</label>
                        <input
                          id={`server-${item.id}`}
                          type="text"
                          className="input-field"
                          value={entry.serverURL || entry.serverURL || ""}
                          onChange={(e) =>
                            handleProviderFieldChange(
                              item.id,
                              "serverURL",
                              e.target.value
                            )
                          }
                          placeholder="https://openrouter.ai/api/v1 or http://localhost:11434/v1"
                        />
                      </div>

                      <div className="form-group">
                        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "4px", flexWrap: "wrap", gap: "6px" }}>
                          <label htmlFor={`keyenv-${item.id}`}>API Key Env Var</label>
                          {(() => {
                            const keyEnv = (entry.apiKeyEnv || entry.apiKeyEnv || "").trim();
                            if (!keyEnv) return null;
                            const isStored = !!secretStatus[keyEnv];
                            return (
                              <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                                {isStored ? (
                                  <span className="keychain-status-badge stored">
                                    <CheckIcon size={12} /> Stored in Keychain
                                  </span>
                                ) : (
                                  <span className="keychain-status-badge missing">
                                    Not Set in Keychain
                                  </span>
                                )}
                                <button
                                  type="button"
                                  className="keychain-action-btn"
                                  onClick={() => handleOpenStoreSecretModal(keyEnv, `API Key for ${item.name || "Provider"}`, isStored)}
                                  title={isStored ? `Update secret for ${keyEnv}` : `Store secret for ${keyEnv} in Keychain`}
                                >
                                  <KeyIcon size={12} />
                                  <span>{isStored ? "Update Key" : "Store Key"}</span>
                                </button>
                              </div>
                            );
                          })()}
                        </div>
                        <input
                          id={`keyenv-${item.id}`}
                          type="text"
                          className="input-field"
                          value={entry.apiKeyEnv || entry.apiKeyEnv || ""}
                          onChange={(e) =>
                            handleProviderFieldChange(
                              item.id,
                              "apiKeyEnv",
                              e.target.value
                            )
                          }
                          placeholder="e.g. OPENROUTER_API_KEY or OPENAI_API_KEY"
                        />
                      </div>

                      <div className="form-group">
                        <label htmlFor={`context-${item.id}`}>Context Length (Tokens)</label>
                        <input
                          id={`context-${item.id}`}
                          type="number"
                          min="1000"
                          step="1000"
                          className="input-field"
                          value={entry.contextLength ?? entry.contextLength ?? ""}
                          onChange={(e) => {
                            const raw = e.target.value;
                            handleProviderFieldChange(
                              item.id,
                              "contextLength",
                              raw === "" ? undefined : Number(raw)
                            );
                          }}
                          placeholder="Backend default"
                        />
                      </div>

                      {/* llama.cpp prefix reuse: sticky slot pool plus cache hint. Both stay unset by
                          default so small servers keep auto-assignment and the always-on hint; the
                          select keeps the cache tri-state (unset vs explicit on/off) visible. */}
                      <div className="form-row">
                        <div className="form-group flex-1">
                          <label htmlFor={`slot-${item.id}`}>Slot Count (llama.cpp)</label>
                          <input
                            id={`slot-${item.id}`}
                            type="number"
                            min="1"
                            step="1"
                            className="input-field"
                            value={entry.slotCount ?? entry.slotCount ?? ""}
                            onChange={(e) => {
                              const raw = e.target.value;
                              handleProviderFieldChange(
                                item.id,
                                "slotCount",
                                raw === "" ? undefined : Number(raw)
                              );
                            }}
                            placeholder="Server auto-assign"
                          />
                        </div>

                        <div className="form-group flex-1">
                          <label htmlFor={`cache-${item.id}`}>Prefix Cache (llama.cpp)</label>
                          <select
                            id={`cache-${item.id}`}
                            className="input-field"
                            value={
                              (entry.cachePrompt ?? entry.cachePrompt) === undefined
                                ? ""
                                : (entry.cachePrompt ?? entry.cachePrompt)
                                  ? "true"
                                  : "false"
                            }
                            onChange={(e) =>
                              handleProviderFieldChange(
                                item.id,
                                "cachePrompt",
                                e.target.value === "" ? undefined : e.target.value === "true"
                              )
                            }
                          >
                            <option value="">Default (enabled)</option>
                            <option value="true">Enabled</option>
                            <option value="false">Disabled</option>
                          </select>
                        </div>
                      </div>

                      <div className="form-group">
                        <label htmlFor={`vision-${item.id}`}>Supports Vision</label>
                        <select
                          id={`vision-${item.id}`}
                          className="input-field"
                          value={
                            (entry.supportsVision ?? entry.supportsVision) === undefined
                              ? ""
                              : (entry.supportsVision ?? entry.supportsVision)
                                ? "true"
                                : "false"
                          }
                          onChange={(e) => {
                            // Map the locked tri-state explicitly so an
                            // unexpected option blocks the edit instead of
                            // collapsing to text-only.
                            const raw = e.target.value;
                            if (raw === "") {
                              handleProviderFieldChange(
                                item.id,
                                "supportsVision",
                                undefined
                              );
                              return;
                            }
                            if (raw === "true") {
                              handleProviderFieldChange(
                                item.id,
                                "supportsVision",
                                true
                              );
                              return;
                            }
                            if (raw === "false") {
                              handleProviderFieldChange(
                                item.id,
                                "supportsVision",
                                false
                              );
                              return;
                            }
                            const label =
                              (item.name ?? "").trim() || "(unnamed)";
                            setError(
                              `Invalid supportsVision for provider "${label}": supportsVision must be true, false, or empty (unset).`
                            );
                          }}
                        >
                          <option value="">Default (Auto from provider)</option>
                          <option value="true">Enabled (Accepts images/screenshots)</option>
                          <option value="false">Disabled (Text-only)</option>
                        </select>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Persona: the owner-authored assistant identity ([persona]) gets direct
            nav because identity edits are as frequent as model routing. The tab
            form owns the save through the shared footer, folding the
            changed-only delta into the same PUT posture as the modal saves so
            untouched keys survive and validation plus 400s surface through the
            shared banner. */}
        {activeTab === "persona" && (
          <div
            className="settings-section card"
            data-testid="persona-pane"
          >
            <div className="settings-section-title-group">
              <h3>Persona</h3>
              <p className="settings-section-hint">
                Assistant name, tone, style guidance, and avatar accent. Takes
                effect on engine reload.
              </p>
            </div>
            <div className="form-row" style={{ marginTop: "1rem" }}>
              <div className="form-group flex-1">
                <label htmlFor="persona-assistant-name">Assistant Name</label>
                <input
                  id="persona-assistant-name"
                  type="text"
                  className="input-field"
                  maxLength={MAX_PERSONA_ASSISTANT_NAME_LENGTH}
                  placeholder="Rune Weaver"
                  value={personaAssistantNameDraft}
                  onChange={(e) => setPersonaAssistantNameDraft(e.target.value)}
                />
                <p
                  className="settings-field-hint"
                  style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}
                >
                  How the agent names itself. Blank falls back to the stock
                  identity. Max {MAX_PERSONA_ASSISTANT_NAME_LENGTH} characters.
                </p>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="persona-tone">Tone</label>
                <select
                  id="persona-tone"
                  className="input-field"
                  value={personaToneDraft}
                  onChange={(e) =>
                    setPersonaToneDraft(
                      normalizePersonaTone(e.target.value) || personaToneDraft,
                    )
                  }
                >
                  {PERSONA_TONE_OPTIONS.map((option) => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
                <span className="form-group-hint">
                  One preset posture sentence folded into the identity line.
                </span>
              </div>
            </div>
            <div className="form-row" style={{ marginTop: "1rem" }}>
              <div className="form-group flex-1">
                <label htmlFor="persona-user-name">Your Name</label>
                <input
                  id="persona-user-name"
                  type="text"
                  className="input-field"
                  maxLength={MAX_PERSONA_USER_NAME_LENGTH}
                  placeholder="(leave blank for no address clause)"
                  value={personaUserNameDraft}
                  onChange={(e) => setPersonaUserNameDraft(e.target.value)}
                />
                <p
                  className="settings-field-hint"
                  style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}
                >
                  Preferred spelling for the address clause. Optional. Max{" "}
                  {MAX_PERSONA_USER_NAME_LENGTH} characters.
                </p>
              </div>
            </div>
            <div className="form-group" style={{ marginTop: "1rem" }}>
              <label htmlFor="persona-style">Style Guidance</label>
              <textarea
                id="persona-style"
                className="input-field"
                rows={4}
                maxLength={MAX_PERSONA_STYLE_LENGTH}
                placeholder="Free-form guidance the agent appends to its identity."
                value={personaStyleDraft}
                onChange={(e) => setPersonaStyleDraft(e.target.value)}
              />
              {/* Live count keeps the owner honest about the stored cap; the
                  maxLength attribute already refuses overlong input, so this
                  is visibility, not enforcement. */}
              <p
                className="settings-field-hint"
                data-testid="persona-style-count"
                style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}
              >
                {personaStyleDraft.length} / {MAX_PERSONA_STYLE_LENGTH} characters
              </p>
            </div>
            <div className="form-group" style={{ marginTop: "1rem" }}>
              <p
                className="settings-field-hint"
                style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)" }}
              >
                Avatar accent — a client-side colorway for the assistant sprite.
                It never reaches the prompt.
              </p>
              <div
                className="persona-avatar-grid"
                role="group"
                aria-label="Avatar accent"
                data-testid="persona-avatar-grid"
              >
                {PERSONA_AVATAR_COLORS.map((accent) => (
                  <button
                    key={accent}
                    type="button"
                    data-testid={`persona-avatar-${accent}`}
                    className={`persona-avatar-option${
                      personaAvatarDraft === accent ? " selected" : ""
                    }`}
                    aria-pressed={personaAvatarDraft === accent}
                    aria-label={`Avatar accent ${accent}`}
                    onClick={() => setPersonaAvatarDraft(accent)}
                  >
                    {/* The picker swatch is the avatar component itself with
                        the blink opted out: a live identity surface blinks
                        because a resting assistant reads as alive, while a
                        settings swatch that flickered would claim a state it
                        cannot acknowledge. Same validation and glyph fallback
                        as every other surface, so a missing frame never
                        breaks the picker either. */}
                    <PersonaAvatar
                      color={accent}
                      state="idle"
                      size={64}
                      blink={false}
                      label=""
                    />
                  </button>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* Goals: steady pursuit policy ([goals] plus ideas cadence) gets direct
            nav because durable goals are a first-class surface beside chat. The
            tab form owns the save through the shared footer, reusing the same
            goals payload path as the full save so stored bounds stay single-shaped. */}
        {activeTab === "goals" && (
          <div className="settings-section card" data-testid="goals-pane">
            <div className="settings-section-title-group">
              <h3>Goals</h3>
              <p className="settings-section-hint">
                Steady long-horizon pursuit and proactive suggestions.
                Takes effect after restart.
              </p>
            </div>
            <div className="form-group checkbox-group">
              <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
                <input
                  id="goals-enabled"
                  type="checkbox"
                  checked={goalsEnabled}
                  onChange={(e) => setGoalsEnabled(e.target.checked)}
                />
                <span>Enable goal pursuit</span>
              </label>
              <span className="form-group-hint">
                Off by default so a fresh install never spends planning calls
                until you opt in. Goals advance on cadence via the service
                worker and the CLI foreground loop.
              </span>
            </div>
            <div className="form-group checkbox-group">
              <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
                <input
                  id="ideas-enabled"
                  type="checkbox"
                  checked={ideasEnabled}
                  onChange={(e) => setIdeasEnabled(e.target.checked)}
                />
                <span>Enable proactive ideas</span>
              </label>
              <span className="form-group-hint">
                Off by default. When enabled, the agent proposes next moves it
                thinks you would value; each suggestion waits for Accept or
                Dismiss before anything changes.
              </span>
            </div>
            <div className="form-row" style={{ marginTop: "1rem" }}>
              <div className="form-group flex-1">
                <label htmlFor="goals-step-interval">Default Cadence (minutes)</label>
                <input
                  id="goals-step-interval"
                  type="number"
                  className="input-field"
                  min={GOALS_STEP_INTERVAL_MIN_MINUTES}
                  max={GOALS_STEP_INTERVAL_MAX_MINUTES}
                  step={1}
                  value={goalsStepIntervalMinutes}
                  onChange={(e) => setGoalsStepIntervalMinutes(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Cadence hint stored on each new goal. Range: {GOALS_STEP_INTERVAL_MIN_MINUTES}–{GOALS_STEP_INTERVAL_MAX_MINUTES}. Default is {DEFAULT_GOALS_STEP_INTERVAL_MINUTES} (daily).
                </p>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="goals-max-active">Max Active Goals</label>
                <input
                  id="goals-max-active"
                  type="number"
                  className="input-field"
                  min={GOALS_MAX_ACTIVE_MIN}
                  max={GOALS_MAX_ACTIVE_MAX}
                  step={1}
                  value={goalsMaxActiveGoals}
                  onChange={(e) => setGoalsMaxActiveGoals(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Maximum goals in the active state at once. Range: {GOALS_MAX_ACTIVE_MIN}–{GOALS_MAX_ACTIVE_MAX}. Default is {DEFAULT_GOALS_MAX_ACTIVE_GOALS}.
                </p>
              </div>
            </div>
            <div className="form-row" style={{ marginTop: "1rem" }}>
              <div className="form-group flex-1">
                <label htmlFor="goals-max-steps">Max Steps Per Goal</label>
                <input
                  id="goals-max-steps"
                  type="number"
                  className="input-field"
                  min={1}
                  max={24}
                  step={1}
                  value={goalsMaxStepsPerGoal}
                  onChange={(e) => setGoalsMaxStepsPerGoal(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Maximum plan steps generated per goal. Range: 1–24. Default is {DEFAULT_GOALS_MAX_STEPS_PER_GOAL}.
                </p>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="goals-plan-timeout">Planning Timeout (seconds)</label>
                <input
                  id="goals-plan-timeout"
                  type="number"
                  className="input-field"
                  min={0}
                  max={86400}
                  step={1}
                  value={goalsPlanTimeoutSeconds}
                  onChange={(e) => setGoalsPlanTimeoutSeconds(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Timeout in seconds for model goal decomposition planning (0 for unlimited). Default is 0 (unlimited).
                </p>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="goals-max-triggers">Max Triggers Per Goal</label>
                <input
                  id="goals-max-triggers"
                  type="number"
                  className="input-field"
                  min={0}
                  max={32}
                  step={1}
                  value={goalsMaxTriggersPerGoal}
                  onChange={(e) => setGoalsMaxTriggersPerGoal(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Event wake-up triggers allowed per goal. Range: 0–32. Default is {DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL}.
                </p>
              </div>
            </div>
            <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
              Goal runs use {goalsMaxToolIterations(settings?.goals)} consecutive tool rounds per turn (range {TOOL_ROUNDS_MIN}–{TOOL_ROUNDS_MAX}, set via [goals] max_tool_iterations in config.toml). When a goal run reaches its budget it synthesizes a summary and records budget_exceeded instead of parking for approval.
            </p>
            <div className="form-row" style={{ marginTop: "1rem" }}>
              <div className="form-group flex-1">
                <label htmlFor="ideas-max-per-cycle">Max Ideas Per Cycle</label>
                <input
                  id="ideas-max-per-cycle"
                  type="number"
                  className="input-field"
                  min={1}
                  max={10}
                  step={1}
                  value={ideasMaxPerCycle}
                  onChange={(e) => setIdeasMaxPerCycle(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Maximum proactive suggestions generated per cycle. Range: 1–10. Default is {DEFAULT_IDEAS_MAX_PER_CYCLE}.
                </p>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="ideas-timeout-seconds">Idea Review Timeout (seconds)</label>
                <input
                  id="ideas-timeout-seconds"
                  type="number"
                  className="input-field"
                  min={1}
                  max={120}
                  step={1}
                  value={ideasTimeoutSeconds}
                  onChange={(e) => setIdeasTimeoutSeconds(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Timeout in seconds for proactive ideas generation review. Range: 1–120. Default is {DEFAULT_IDEAS_TIMEOUT_SECONDS}s.
                </p>
              </div>
            </div>
          </div>
        )}

        {/* TAB 2: Engine & Logs */}
        {activeTab === "engine" && (
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
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Chats use {engineMaxToolIterations(settings)} rounds per turn (parks for approval). Scheduled runs use {schedulerMaxToolIterations(settings)} rounds by default with per-job override (synthesizes plus budget_exceeded, or parks when the job sets on_tool_limit to park). Goal runs use {goalsMaxToolIterations(settings?.goals)} rounds (always synthesizes plus budget_exceeded).
                </p>
              </div>
            </div>
          </div>
          {/* Proactivity: the background interruption policy ([proactive]) stays
              with the engine knobs because both govern autonomous runtime
              behavior rather than durable pursuit. The save still carries the
              goals and ideas deltas alongside so the stored autonomous policy
              never forks across tabs. */}
          <div className="settings-section card" style={{ marginTop: "16px" }} data-testid="proactive-pane">
            <div className="settings-section-title-group">
              <h3>Proactivity</h3>
              <p className="settings-section-hint">
                Background interruption policy.
                Takes effect after restart.
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
          </>
        )}

        {/* TAB 3: Tools & Runes */}
        {activeTab === "tools" && (
          <div className="settings-section card">
            <div className="settings-section-header">
              <div className="settings-section-title-group">
                <h3>Tools & Runes</h3>
                <p className="settings-section-hint">
                  Manage internal and external tools. Discovered and newly installed runes remain disabled by default until reviewed and approved.
                </p>
              </div>
              <div className="row">
                {/* Marketplace entry points stay hidden while the catalog UX is
                    deferred; the modal remains mounted below so re-enabling is
                    UI-only and server routes stay untouched. */}
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={handleRescanPlugins}
                  disabled={rescanLoading}
                >
                  <RefreshIcon size={14} className={rescanLoading ? "spin" : ""} />
                  <span>{rescanLoading ? "Scanning..." : "Rescan Plugins"}</span>
                </button>
              </div>
            </div>


            {/* Metrics cards */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(130px, 1fr))", gap: "12px", margin: "16px 0" }}>
              <div style={{ padding: "12px", background: "var(--bg-secondary, #141822)", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)" }}>
                <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", textTransform: "uppercase", fontWeight: 600 }}>Active Tools</div>
                <div style={{ fontSize: "1.4rem", fontWeight: 700, color: "#48bb78", marginTop: "4px" }}>
                  {safeTools.filter((t) => t.isEnabled).length}
                </div>
              </div>
              <div style={{ padding: "12px", background: "var(--bg-secondary, #141822)", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)" }}>
                <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", textTransform: "uppercase", fontWeight: 600 }}>External Runes</div>
                <div style={{ fontSize: "1.4rem", fontWeight: 700, marginTop: "4px" }}>
                  {pluginsList.length}
                </div>
              </div>
              <div style={{ padding: "12px", background: "var(--bg-secondary, #141822)", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)" }}>
                <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", textTransform: "uppercase", fontWeight: 600 }}>Pending Review</div>
                <div style={{ fontSize: "1.4rem", fontWeight: 700, color: pendingCount > 0 ? "#ed8936" : "inherit", marginTop: "4px" }}>
                  {pendingCount}
                </div>
              </div>
              {tamperedCount > 0 && (
                <div style={{ padding: "12px", background: "rgba(245, 101, 101, 0.1)", borderRadius: "8px", border: "1px solid rgba(245, 101, 101, 0.3)" }}>
                  <div style={{ fontSize: "0.75rem", color: "#f56565", textTransform: "uppercase", fontWeight: 600 }}>Tampered</div>
                  <div style={{ fontSize: "1.4rem", fontWeight: 700, color: "#f56565", marginTop: "4px" }}>
                    {tamperedCount}
                  </div>
                </div>
              )}
            </div>

            {/* Agent scratch workspace: live usage bars stay read-only from
                GET /workspace/usage while quota editors persist through the tab
                save as a workspace delta. */}
            <section aria-label="Workspace storage" style={{ margin: "8px 0 16px 0", padding: "16px", borderRadius: "8px", backgroundColor: "var(--bg-card, #1e2533)", border: "1px solid var(--border-color, #2d3748)" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", flexWrap: "wrap", gap: "8px", marginBottom: "8px" }}>
                <div>
                  <h4 style={{ margin: 0 }}>Workspace Storage</h4>
                  <p className="settings-section-hint" style={{ margin: "4px 0 0 0" }}>
                    Bounded agent scratch under ~/.runeweaver/workspace. Quotas save with the tab below.
                  </p>
                </div>
                <div style={{ display: "flex", gap: "8px" }}>
                  <button
                    type="button"
                    className="ghost icon-text-btn"
                    onClick={() => void refreshWorkspaceUsage()}
                    disabled={workspaceLoading || pruningWorkspace}
                  >
                    <RefreshIcon size={14} className={workspaceLoading ? "spin" : ""} />
                    <span>{workspaceLoading ? "Loading…" : "Refresh"}</span>
                  </button>
                  <button
                    type="button"
                    className="ghost icon-text-btn"
                    onClick={() => setPendingPruneWorkspace(true)}
                    disabled={workspaceLoading || pruningWorkspace}
                  >
                    <TrashIcon size={14} />
                    <span>{pruningWorkspace ? "Pruning…" : "Prune tmp"}</span>
                  </button>
                </div>
              </div>
              {workspaceError ? (
                <div className="error-banner" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                  <AlertTriangleIcon size={16} />
                  <span>{workspaceError}</span>
                </div>
              ) : workspaceLoading && !workspaceUsage ? (
                <p className="muted text-sm" style={{ margin: 0 }}>Loading workspace usage…</p>
              ) : workspaceUsage ? (
                <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
                  {(() => {
                    const quotaBytes = workspaceUsage.quotaMB * 1024 * 1024;
                    const bytesPercent = workspaceQuotaPercent(workspaceUsage.bytes, quotaBytes);
                    const filesPercent = workspaceQuotaPercent(workspaceUsage.files, workspaceUsage.quotaFiles);
                    const bar = (percent: number) => (
                      <div style={{ height: "8px", borderRadius: "4px", background: "var(--bg-secondary, #141822)", overflow: "hidden" }}>
                        <div style={{ width: `${percent}%`, height: "100%", background: percent >= 90 ? "#f56565" : percent >= 70 ? "#ed8936" : "#48bb78", transition: "width 0.2s ease" }} />
                      </div>
                    );
                    return (
                      <>
                        <div>
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.85rem", marginBottom: "4px" }}>
                            <span>Disk usage</span>
                            <span className="muted">
                              {formatWorkspaceBytes(workspaceUsage.bytes)} of {workspaceUsage.quotaMB} MB ({bytesPercent}%)
                            </span>
                          </div>
                          {bar(bytesPercent)}
                        </div>
                        <div>
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.85rem", marginBottom: "4px" }}>
                            <span>File usage</span>
                            <span className="muted">
                              {workspaceUsage.files.toLocaleString("en-US")} of {workspaceUsage.quotaFiles.toLocaleString("en-US")} files ({filesPercent}%)
                            </span>
                          </div>
                          {bar(filesPercent)}
                        </div>
                        {workspaceUsage.truncated ? (
                          <div style={{ fontSize: "0.78rem", color: "var(--text-secondary, #a0aec0)" }}>
                            Walk truncated; actual usage may be higher.
                          </div>
                        ) : null}
                      </>
                    );
                  })()}
                </div>
              ) : (
                <p className="muted text-sm" style={{ margin: 0 }}>Workspace usage unknown.</p>
              )}
              <div style={{ marginTop: "14px", padding: "12px", borderRadius: "8px", background: "var(--bg-secondary, #141822)", border: "1px solid var(--border-color, #2d3748)" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "8px" }}>
                  <div>
                    <div style={{ fontSize: "0.85rem", fontWeight: 600 }}>Workspace machine</div>
                    <div data-testid="workspace-machine-status" style={{ fontSize: "0.82rem", color: "var(--text-secondary, #a0aec0)", marginTop: "4px" }}>
                      {workspaceMachineLoading && !workspaceMachine
                        ? "Loading machine status…"
                        : workspaceMachineError
                          ? workspaceMachineError
                          : workspaceMachine
                            ? `Machine exists: ${workspaceMachine.exists ? "yes" : "no"} · running: ${workspaceMachine.running ? "yes" : "no"} · image: ${workspaceMachine.image || "none"} · config: ${workspaceMachine.configMatch == null ? "unknown" : workspaceMachine.configMatch ? "match" : "mismatch"}`
                            : "Machine status unknown."}
                    </div>
                  </div>
                  <div style={{ display: "flex", gap: "8px" }}>
                    <button
                      type="button"
                      className="ghost icon-text-btn"
                      onClick={() => void handleStopWorkspaceMachine()}
                      disabled={workspaceMachineAction !== null}
                    >
                      <StopIcon size={14} />
                      <span>{workspaceMachineAction === "stop" ? "Stopping…" : "Stop"}</span>
                    </button>
                    <button
                      type="button"
                      className="ghost icon-text-btn"
                      onClick={() => void handleRecycleWorkspaceMachine()}
                      disabled={workspaceMachineAction !== null}
                    >
                      <RefreshIcon size={14} />
                      <span>{workspaceMachineAction === "recycle" ? "Recycling…" : "Recycle"}</span>
                    </button>
                  </div>
                </div>
              </div>
              {/* Workspace quota editors omit native min/max on purpose: range
                  enforcement lives in validateWorkspaceFields so an out-of-range
                  value surfaces the custom Invalid workspace quota banner without
                  a network write. Native min/max would block submit with a
                  browser bubble before the shared save runs, while every other
                  tab keeps its native constraints untouched. Bounds stay
                  single-sourced to the engine clamps; step keeps the spinner. */}
              <div className="form-row" style={{ display: "flex", gap: "10px", flexWrap: "wrap", marginTop: "14px" }}>
                <div className="form-group" style={{ flex: "1 1 140px" }}>
                  <label htmlFor="workspace-quota-mb">Quota (MB)</label>
                  <input
                    id="workspace-quota-mb"
                    type="number"
                    step={1}
                    className="input-field"
                    value={workspaceQuotaMB}
                    onChange={(e) =>
                      setWorkspaceQuotaMB(
                        e.target.value === "" ? "" : Number(e.target.value)
                      )
                    }
                    placeholder="500"
                  />
                  <span className="form-group-hint">
                    Total bytes permitted under the workspace root.
                  </span>
                </div>
                <div className="form-group" style={{ flex: "1 1 140px" }}>
                  <label htmlFor="workspace-quota-files">Max files</label>
                  <input
                    id="workspace-quota-files"
                    type="number"
                    step={1}
                    className="input-field"
                    value={workspaceQuotaFiles}
                    onChange={(e) =>
                      setWorkspaceQuotaFiles(
                        e.target.value === "" ? "" : Number(e.target.value)
                      )
                    }
                    placeholder="10000"
                  />
                  <span className="form-group-hint">
                    Total files permitted under the workspace root.
                  </span>
                </div>
                <div className="form-group" style={{ flex: "1 1 140px" }}>
                  <label htmlFor="workspace-tmp-ttl">Tmp TTL (days)</label>
                  <input
                    id="workspace-tmp-ttl"
                    type="number"
                    step={1}
                    className="input-field"
                    value={workspaceTmpTTLDays}
                    onChange={(e) =>
                      setWorkspaceTmpTTLDays(
                        e.target.value === "" ? "" : Number(e.target.value)
                      )
                    }
                    placeholder="7"
                  />
                  <span className="form-group-hint">
                    Days tmp entries survive; TTL applies on next prune.
                  </span>
                </div>
              </div>
            </section>

            {/* Warning banners */}
            {pendingCount > 0 && (
              <div
                style={{
                  padding: "12px 16px",
                  borderRadius: "8px",
                  backgroundColor: "rgba(237, 137, 54, 0.15)",
                  border: "1px solid rgba(237, 137, 54, 0.4)",
                  marginBottom: "16px",
                  display: "flex",
                  alignItems: "flex-start",
                  gap: "12px",
                  color: "#ed8936",
                }}
              >
                <AlertTriangleIcon size={20} style={{ flexShrink: 0, marginTop: "2px" }} />
                <div style={{ fontSize: "0.88rem", lineHeight: "1.4" }}>
                  <strong>{pendingCount} newly discovered rune(s) awaiting review.</strong>
                  <div style={{ marginTop: "2px", color: "var(--text-primary, #e2e8f0)" }}>
                    In accordance with security policy, new tools start disabled by default. Review their code and permissions below before enabling.
                  </div>
                </div>
              </div>
            )}

            {tamperedCount > 0 && (
              <div
                style={{
                  padding: "12px 16px",
                  borderRadius: "8px",
                  backgroundColor: "rgba(245, 101, 101, 0.15)",
                  border: "1px solid rgba(245, 101, 101, 0.4)",
                  marginBottom: "16px",
                  display: "flex",
                  alignItems: "flex-start",
                  gap: "12px",
                  color: "#f56565",
                }}
              >
                <AlertTriangleIcon size={20} style={{ flexShrink: 0, marginTop: "2px" }} />
                <div style={{ fontSize: "0.88rem", lineHeight: "1.4" }}>
                  <strong>Security Alert: {tamperedCount} plugin(s) have been modified on disk since approval!</strong>
                  <div style={{ marginTop: "2px", color: "var(--text-primary, #e2e8f0)" }}>
                    Cryptographic tree hash does not match the approved signature. They have been quarantined and disabled.
                  </div>
                </div>
              </div>
            )}

            {/* External Runes List */}
            <h4 style={{ margin: "20px 0 12px 0", display: "flex", alignItems: "center", gap: "8px" }}>
              <span>Installed Runes & Plugins</span>
            </h4>

            {pluginsList.length === 0 ? (
              <div className="empty-state-box" style={{ padding: "28px", textAlign: "center" }}>
                <WrenchIcon size={32} />
                <p>No external runes discovered in plugins directory.</p>
                <p className="muted text-sm" style={{ marginTop: "8px" }}>
                  Add rune packages to the plugins directory below, then use
                  Rescan Plugins to discover them.
                </p>
              </div>
            ) : (
              <div style={{ display: "flex", flexDirection: "column", gap: "14px" }}>
                {pluginsList.map((plugin) => {
                  const isPending = plugin.status === "discovered";
                  const isTampered = plugin.status === "tampered";
                  return (
                    <div
                      key={plugin.id}
                      style={{
                        padding: "16px",
                        borderRadius: "8px",
                        backgroundColor: "var(--bg-card, #1e2533)",
                        border: isTampered
                          ? "1px solid rgba(245, 101, 101, 0.5)"
                          : isPending
                          ? "1px solid rgba(237, 137, 54, 0.5)"
                          : "1px solid var(--border-color, #2d3748)",
                      }}
                    >
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: "8px", flexWrap: "wrap", gap: "8px" }}>
                        <div>
                          <div style={{ display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" }}>
                            <span style={{ fontWeight: 600, fontSize: "1.02rem" }}>{plugin.name}</span>
                            <span style={{ fontSize: "0.75rem", padding: "2px 6px", borderRadius: "4px", backgroundColor: "#2d3748", color: "#a0aec0" }}>
                              v{plugin.version}
                            </span>
                            <span style={{ fontSize: "0.75rem", padding: "2px 6px", borderRadius: "4px", backgroundColor: "#2c3e50", color: "#63b3ed" }}>
                              {plugin.runtime}
                            </span>

                            {plugin.isEnabled ? (
                              <span style={{ fontSize: "0.75rem", padding: "2px 8px", borderRadius: "4px", backgroundColor: "rgba(72, 187, 120, 0.2)", color: "#48bb78", fontWeight: 600 }}>
                                ENABLED
                              </span>
                            ) : isPending ? (
                              <span style={{ fontSize: "0.75rem", padding: "2px 8px", borderRadius: "4px", backgroundColor: "rgba(237, 137, 54, 0.2)", color: "#ed8936", fontWeight: 600 }}>
                                PENDING REVIEW
                              </span>
                            ) : isTampered ? (
                              <span style={{ fontSize: "0.75rem", padding: "2px 8px", borderRadius: "4px", backgroundColor: "rgba(245, 101, 101, 0.2)", color: "#f56565", fontWeight: 600 }}>
                                TAMPERED
                              </span>
                            ) : (
                              <span style={{ fontSize: "0.75rem", padding: "2px 8px", borderRadius: "4px", backgroundColor: "rgba(160, 174, 192, 0.2)", color: "#a0aec0" }}>
                                DISABLED
                              </span>
                            )}
                          </div>
                          <div style={{ fontSize: "0.8rem", color: "var(--text-secondary, #a0aec0)", marginTop: "3px" }}>
                            <code>{plugin.id}</code> {plugin.author ? `• by ${plugin.author}` : ""}
                          </div>
                        </div>

                        <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                          <button
                            type="button"
                            className={plugin.isEnabled ? "ghost icon-text-btn" : "primary icon-text-btn"}
                            onClick={() => handleToggleEnable(plugin)}
                            disabled={updatingPluginId === plugin.id}
                          >
                            {updatingPluginId === plugin.id
                              ? "Updating..."
                              : plugin.isEnabled
                              ? "Disable"
                              : isPending
                              ? "Approve & Enable"
                              : isTampered
                              ? "Re-verify & Enable"
                              : "Enable"}
                          </button>

                          <button
                            type="button"
                            className="icon-button danger"
                            onClick={() =>
                              setPendingUninstallPlugin({
                                id: plugin.id,
                                name: plugin.name,
                              })
                            }
                            disabled={updatingPluginId === plugin.id}
                            title={`Uninstall ${plugin.name}`}
                            aria-label={`Uninstall ${plugin.name}`}
                          >
                            <TrashIcon size={14} />
                          </button>
                        </div>
                      </div>

                      {plugin.description && (
                        <p style={{ margin: "4px 0 10px 0", fontSize: "0.88rem", color: "var(--text-secondary, #cbd5e0)" }}>
                          {plugin.description}
                        </p>
                      )}

                      {plugin.integrityHash && (
                        <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", marginBottom: "10px", display: "flex", alignItems: "center", gap: "6px" }}>
                          <span>SHA-256 Hash:</span>
                          <code style={{ fontSize: "0.72rem" }}>{plugin.integrityHash.substring(0, 16)}...</code>
                          {isTampered ? (
                            <span style={{ color: "#f56565" }}>(MISMATCH DETECTED)</span>
                          ) : (
                            <span style={{ color: "#48bb78" }}>✓ Verified</span>
                          )}
                        </div>
                      )}

                      <div style={{ borderTop: "1px solid var(--border-color, #2d3748)", paddingTop: "8px" }}>
                        <div style={{ fontSize: "0.75rem", fontWeight: 600, color: "var(--text-secondary, #a0aec0)", marginBottom: "6px", textTransform: "uppercase" }}>
                          Declared Tools ({plugin.tools.length})
                        </div>
                        <div style={{ display: "flex", flexDirection: "column", gap: "6px" }}>
                          {plugin.tools.map((tool) => {
                            const override = plugin.permissionOverrides[tool.name];
                            return (
                              <div
                                key={tool.name}
                                style={{
                                  display: "flex",
                                  justifyContent: "space-between",
                                  alignItems: "center",
                                  padding: "6px 10px",
                                  borderRadius: "6px",
                                  backgroundColor: "var(--bg-secondary, #141822)",
                                  fontSize: "0.85rem",
                                  flexWrap: "wrap",
                                  gap: "8px",
                                }}
                              >
                                <div>
                                  <code style={{ fontWeight: 600, color: "#63b3ed" }}>{tool.name}</code>
                                  {tool.description && (
                                    <span style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", marginLeft: "6px" }}>
                                      ({tool.description})
                                    </span>
                                  )}
                                </div>

                                <div style={{ display: "flex", alignItems: "center", gap: "6px" }}>
                                  <span style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)" }}>
                                    Permission:
                                  </span>
                                  <select
                                    value={override || "default"}
                                    onChange={(e) => handlePermissionChange(plugin.id, tool.name, e.target.value)}
                                    disabled={updatingPluginId === plugin.id}
                                    style={{
                                      fontSize: "0.78rem",
                                      padding: "2px 6px",
                                      borderRadius: "4px",
                                      backgroundColor: "var(--bg-card, #1e2533)",
                                      color: "inherit",
                                      border: "1px solid var(--border-color, #2d3748)",
                                    }}
                                  >
                                    <option value="default">Default ({tool.permissionLevel})</option>
                                    <option value="readOnly">readOnly</option>
                                    <option value="requiresApproval">requiresApproval</option>
                                  </select>
                                </div>
                              </div>
                            );
                          })}
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            {/* Built-in Core Tools Section */}
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", margin: "28px 0 8px 0", flexWrap: "wrap", gap: "10px" }}>
              <h4 style={{ margin: 0, display: "flex", alignItems: "center", gap: "8px" }}>
                <span>Built-in Engine Tools</span>
              </h4>
              <span className="muted text-sm">
                {safeTools.filter((t) => t.isBuiltIn && t.isEnabled).length} of {safeTools.filter((t) => t.isBuiltIn).length} enabled
              </span>
            </div>

            {/* Search and Category Filter Bar */}
            <div className="tools-filter-bar">
              <div className="tools-search-wrapper">
                <SearchIcon size={16} className="tools-search-icon" />
                <input
                  type="search"
                  className="tools-search-input"
                  placeholder="Search tools by name or description..."
                  value={toolSearchQuery}
                  onChange={(e) => setToolSearchQuery(e.target.value)}
                />
              </div>

              {/* Category Pills */}
              <div className="tools-category-pills">
                <button
                  type="button"
                  className={`tools-category-pill ${selectedToolCategory === "all" ? "active" : ""}`}
                  onClick={() => setSelectedToolCategory("all")}
                >
                  <span>All</span>
                  <span className="tools-category-pill-count">
                    {safeTools.filter((t) => t.isBuiltIn).length}
                  </span>
                </button>
                {TOOL_CATEGORIES.map((cat) => {
                  const catToolCount = safeTools.filter((t) => t.isBuiltIn && getToolCategory(t) === cat.id).length;
                  if (catToolCount === 0) return null;
                  const Icon = cat.icon;
                  return (
                    <button
                      key={cat.id}
                      type="button"
                      className={`tools-category-pill ${selectedToolCategory === cat.id ? "active" : ""}`}
                      onClick={() => setSelectedToolCategory(cat.id)}
                    >
                      <Icon size={13} />
                      <span>{cat.name.replace(/,/g, "").split(" ")[0]}</span>
                      <span className="tools-category-pill-count">{catToolCount}</span>
                    </button>
                  );
                })}
              </div>
            </div>

            {(() => {
              const builtIns = safeTools.filter((t) => t.isBuiltIn);
              const q = toolSearchQuery.trim().toLowerCase();
              const filteredTools = builtIns.filter((tool) => {
                if (q && !tool.name.toLowerCase().includes(q) && !(tool.description?.toLowerCase().includes(q))) {
                  return false;
                }
                if (selectedToolCategory !== "all" && getToolCategory(tool) !== selectedToolCategory) {
                  return false;
                }
                return true;
              });

              if (builtIns.length === 0) {
                return (
                  <div className="empty-state-box">
                    <WrenchIcon size={32} />
                    <p>No built-in tools available.</p>
                  </div>
                );
              }

              if (filteredTools.length === 0) {
                return (
                  <div className="empty-state-box" style={{ padding: "32px 16px" }}>
                    <SearchIcon size={28} />
                    <p style={{ margin: "8px 0 4px 0" }}>No tools match your filter criteria.</p>
                    <button
                      type="button"
                      className="accent-ghost"
                      onClick={() => {
                        setToolSearchQuery("");
                        setSelectedToolCategory("all");
                      }}
                      style={{ marginTop: "8px", fontSize: "0.82rem" }}
                    >
                      Reset filters
                    </button>
                  </div>
                );
              }

              // Group filtered tools by category preserving TOOL_CATEGORIES order
              const visibleCategories = TOOL_CATEGORIES.map((cat) => ({
                ...cat,
                tools: filteredTools.filter((t) => getToolCategory(t) === cat.id),
              })).filter((cat) => cat.tools.length > 0);

              return (
                <div className="tool-categories-container">
                  {visibleCategories.map((cat) => {
                    const enabledCount = cat.tools.filter((t) => t.isEnabled).length;
                    const allEnabled = enabledCount === cat.tools.length;
                    const anyEnabled = enabledCount > 0;
                    const isTogglingCat = togglingCategory === cat.id;
                    const Icon = cat.icon;
                    // Header Configure resolves once per rendered category: the config key
                    // must exist and at least one tool in this filtered view must report
                    // hasConfig, so search or pill filtering never offers a dead editor.
                    // Clearing all modal errors first keeps a prior failed save
                    // from lingering when a different category editor opens.
                    const categoryConfigKey = getCategoryConfigKey(cat.id);
                    const categoryHasConfig = cat.tools.some((t) => t.hasConfig);
                    const categoryConfigTitle =
                      categoryConfigKey === "desktop"
                        ? "Configure Desktop Integration"
                        : categoryConfigKey === "media.arr"
                          ? "Configure Sonarr & Radarr"
                          : categoryConfigKey === "fanout.run"
                            ? "Configure Parallel Fan-Out"
                            : "Configure Browser & Web Automation";

                    return (
                      <section key={cat.id} className="tool-category-section">
                        <div className="tool-category-header">
                          <div className="tool-category-title-group">
                            <Icon size={18} />
                            <h4 className="tool-category-title">{cat.name}</h4>
                            <span
                              className={`tool-category-badge ${
                                allEnabled ? "all-enabled" : anyEnabled ? "partial" : "all-disabled"
                              }`}
                            >
                              {enabledCount} of {cat.tools.length} enabled
                            </span>
                          </div>
                          <div className="tool-category-actions">
                            <button
                              type="button"
                              className="tool-category-action-btn"
                              onClick={() => void handleToggleCategory(cat.id, !allEnabled)}
                              disabled={isTogglingCat}
                            >
                              {isTogglingCat ? "Updating…" : allEnabled ? "Disable All" : "Enable All"}
                            </button>
                            {categoryConfigKey !== null && categoryHasConfig ? (
                              <button
                                type="button"
                                className="tool-category-action-btn configure accent-ghost icon-text-btn"
                                title={categoryConfigTitle}
                                onClick={() => {
                                  setMediaModalError(null);
                                  setBrowserModalError(null);
                                  setDesktopModalError(null);
                                  setFanoutModalError(null);
                                  setConfiguringToolName(categoryConfigKey);
                                }}
                                style={{ padding: "4px 8px", fontSize: "0.78rem" }}
                              >
                                <SettingsIcon size={12} />
                                <span>Configure</span>
                              </button>
                            ) : null}
                          </div>
                        </div>

                        <div className="builtin-tools-grid">
                          {cat.tools.map((tool) => {
                            const isToggling = togglingToolName === tool.name;
                            return (
                              <article key={tool.name} className="builtin-tool-card">
                                <div className="builtin-tool-card-header">
                                  <code className="builtin-tool-name" title={tool.name}>
                                    {tool.name}
                                  </code>
                                  <span className="builtin-tool-permission">{tool.permissionLevel}</span>
                                </div>
                                <p className="builtin-tool-desc" title={tool.description}>
                                  {tool.description}
                                </p>
                                {tool.description && (
                                  <details className="builtin-tool-details">
                                    <summary>Details</summary>
                                    <p className="builtin-tool-details-body">{tool.description}</p>
                                  </details>
                                )}
                                {/* Single-switch footer: configuration lives on the category
                                    header so one editor owns the whole integration surface.
                                    Per-card buttons duplicated editors and drifted from the
                                    server hasConfig authority, so the switch stays alone here. */}
                                <div className="builtin-tool-footer">
                                  <label
                                    className="toggle-label tool-switch"
                                    style={{ display: "flex", alignItems: "center", gap: "8px", flexShrink: 0, cursor: isToggling ? "wait" : "pointer" }}
                                  >
                                    <input
                                      type="checkbox"
                                      role="switch"
                                      className="tool-switch-input"
                                      aria-label={`${tool.name} ${tool.isEnabled ? "Enabled" : "Disabled"}`}
                                      aria-checked={tool.isEnabled}
                                      checked={tool.isEnabled}
                                      onChange={() => void handleToggleTool(tool)}
                                      disabled={isToggling}
                                    />
                                    <span
                                      className="tool-switch-track"
                                      data-on={tool.isEnabled ? "true" : "false"}
                                      aria-hidden="true"
                                    >
                                      <span className="tool-switch-thumb" />
                                    </span>
                                    <span className="tool-switch-state">
                                      {isToggling ? "Updating…" : tool.isEnabled ? "Enabled" : "Disabled"}
                                    </span>
                                  </label>
                                </div>
                              </article>
                            );
                          })}
                        </div>
                      </section>
                    );
                  })}
                </div>
              );
            })()}

            {/* Promoted agent tools: hash-pinned workspace/tools/ scripts the
                owner blessed for later runs. Promotion pins exact bytes, runs
                re-hash before dispatch, and a changed script lands disabled
                instead of executing silently. */}
            <section aria-label="Promoted agent tools" style={{ marginTop: "24px", paddingTop: "20px", borderTop: "1px solid var(--border-color, #2d3748)" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", flexWrap: "wrap", gap: "8px", marginBottom: "8px" }}>
                <div className="settings-section-title-group">
                  <h4 style={{ margin: "0 0 4px 0" }}>Promoted Agent Tools</h4>
                  <p className="settings-section-hint" style={{ margin: 0 }}>
                    Owner-blessed scripts from {WORKSPACE_TOOLS_PREFIX}. Only that directory is eligible; every run verifies the pinned hash first.
                  </p>
                </div>
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={() => void refreshAgentTools()}
                  disabled={agentToolsLoading}
                >
                  <RefreshIcon size={14} className={agentToolsLoading ? "spin" : ""} />
                  <span>{agentToolsLoading ? "Loading…" : "Refresh"}</span>
                </button>
              </div>
              {agentToolsError ? (
                <div className="error-banner" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                  <AlertTriangleIcon size={16} />
                  <span>{agentToolsError}</span>
                </div>
              ) : agentToolsLoading && agentTools.length === 0 ? (
                <p className="muted text-sm">Loading promoted tools…</p>
              ) : agentTools.length === 0 ? (
                <div className="empty-state-box" style={{ padding: "20px", textAlign: "center" }}>
                  <WrenchIcon size={28} />
                  <p>No agent tools promoted yet.</p>
                  <p className="muted text-sm" style={{ marginTop: "4px" }}>
                    Promote a script from {WORKSPACE_TOOLS_PREFIX} below to bless it for later runs.
                  </p>
                </div>
              ) : (
                <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
                  {agentTools.map((tool) => {
                    const enabled = tool.status === "enabled";
                    const busy = togglingAgentToolId === tool.id || runningAgentToolId === tool.id;
                    const output = agentRunOutput[tool.id];
                    return (
                      <div
                        key={tool.id}
                        style={{ padding: "12px 14px", borderRadius: "8px", backgroundColor: "var(--bg-card, #1e2533)", border: "1px solid var(--border-color, #2d3748)" }}
                      >
                        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "8px" }}>
                          <div style={{ display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" }}>
                            <code style={{ fontWeight: 600 }}>{tool.name}</code>
                            <span style={{ fontSize: "0.72rem", padding: "2px 6px", borderRadius: "4px", backgroundColor: "#2d3748", color: "#a0aec0" }} title={tool.sha256}>
                              {shortAgentToolHash(tool.sha256) || "no-pin"}
                            </span>
                            <span
                              style={{
                                fontSize: "0.72rem",
                                padding: "2px 8px",
                                borderRadius: "4px",
                                fontWeight: 600,
                                backgroundColor: enabled ? "rgba(72, 187, 120, 0.2)" : "rgba(160, 174, 192, 0.2)",
                                color: enabled ? "#48bb78" : "#a0aec0",
                              }}
                            >
                              {enabled ? "ENABLED" : "DISABLED"}
                            </span>
                          </div>
                          <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                            <label className="toggle-label tool-switch" style={{ display: "flex", alignItems: "center", gap: "8px", cursor: busy ? "wait" : "pointer" }}>
                              <input
                                type="checkbox"
                                role="switch"
                                className="tool-switch-input"
                                aria-label={`${tool.name} ${enabled ? "Enabled" : "Disabled"}`}
                                aria-checked={enabled}
                                checked={enabled}
                                onChange={() => void handleToggleAgentTool(tool)}
                                disabled={busy}
                              />
                              <span className="tool-switch-track" data-on={enabled ? "true" : "false"} aria-hidden="true">
                                <span className="tool-switch-thumb" />
                              </span>
                              <span className="tool-switch-state">
                                {togglingAgentToolId === tool.id ? "Updating…" : enabled ? "Enabled" : "Disabled"}
                              </span>
                            </label>
                            <button
                              type="button"
                              className="ghost icon-text-btn"
                              onClick={() => void handleRunAgentTool(tool)}
                              disabled={busy || !enabled}
                              title={enabled ? `Run ${tool.name}` : `Re-enable ${tool.name} before running`}
                            >
                              <span>{runningAgentToolId === tool.id ? "Running…" : "Run"}</span>
                            </button>
                          </div>
                        </div>
                        <div className="muted text-sm" style={{ marginTop: "4px", fontSize: "0.78rem" }}>
                          <code>{tool.scriptPath}</code>
                        </div>
                        {output ? (
                          <pre style={{ margin: "8px 0 0 0", padding: "8px 10px", borderRadius: "6px", background: "var(--bg-secondary, #141822)", fontSize: "0.78rem", whiteSpace: "pre-wrap", wordBreak: "break-word" }}>
                            {output}
                          </pre>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              )}
              {/* Promote editor is a div, not a form: the Tools tab already
                  lives inside the shared settings <form>, and a nested form
                  is invalid HTML (validateDOMNesting) that would also bubble
                  Enter to the outer Save. Enter is handled via onKeyDown
                  below so keyboard submit still promotes. */}
              <div
                style={{ marginTop: "14px", padding: "12px", borderRadius: "8px", background: "var(--bg-secondary, #141822)", border: "1px solid var(--border-color, #2d3748)" }}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && !promotingTool) {
                    e.preventDefault();
                    void handlePromoteAgentTool();
                  }
                }}
              >
                <h5 style={{ margin: "0 0 8px 0" }}>Promote a script</h5>
                <div className="form-row" style={{ display: "flex", gap: "10px", flexWrap: "wrap" }}>
                  <div className="form-group" style={{ flex: "1 1 160px" }}>
                    <label htmlFor="promote-tool-name">Tool name</label>
                    <input
                      id="promote-tool-name"
                      type="text"
                      className="input-field"
                      placeholder="cleanup"
                      value={promoteName}
                      onChange={(e) => {
                        setPromoteName(e.target.value);
                        if (promoteError) setPromoteError(null);
                      }}
                      disabled={promotingTool}
                    />
                  </div>
                  <div className="form-group" style={{ flex: "2 1 240px" }}>
                    <label htmlFor="promote-tool-path">Script path</label>
                    <input
                      id="promote-tool-path"
                      type="text"
                      className="input-field"
                      placeholder="workspace/tools/cleanup.sh"
                      value={promoteScriptPath}
                      onChange={(e) => {
                        setPromoteScriptPath(e.target.value);
                        if (promoteError) setPromoteError(null);
                      }}
                      disabled={promotingTool}
                    />
                    <span className="form-group-hint">
                      Only scripts inside {WORKSPACE_TOOLS_PREFIX} can be promoted.
                    </span>
                  </div>
                </div>
                {promoteScriptPath.trim() && !isPromotableScriptPath(promoteScriptPath) ? (
                  <p className="muted text-sm" style={{ color: "#ed8936", margin: "6px 0 0 0" }}>
                    Only scripts inside {WORKSPACE_TOOLS_PREFIX} can be promoted.
                  </p>
                ) : null}
                {promoteError ? (
                  <div className="error-banner" style={{ marginTop: "8px", display: "flex", alignItems: "center", gap: "8px" }}>
                    <AlertTriangleIcon size={16} />
                    <span>{promoteError}</span>
                  </div>
                ) : null}
                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: "10px" }}>
                  <button type="button" className="primary" disabled={promotingTool} onClick={() => void handlePromoteAgentTool()}>
                    {promotingTool ? "Promoting…" : "Promote tool"}
                  </button>
                </div>
              </div>
            </section>

            {/* Plugin Configuration */}
            <div style={{ marginTop: "24px", paddingTop: "20px", borderTop: "1px solid var(--border-color, #2d3748)" }}>
              <div className="settings-section-title-group">
                <h4 style={{ margin: "0 0 4px 0" }}>Plugin Configuration</h4>
                <p className="settings-section-hint">
                  Configure directory location, remote marketplace index, and startup scanning behavior.
                </p>
              </div>
              <div className="form-row">
                <div className="form-group flex-2">
                  <label htmlFor="plugins-dir">Plugins Directory</label>
                  <input
                    id="plugins-dir"
                    type="text"
                    className="input-field"
                    value={pluginsDir}
                    onChange={(e) => setPluginsDir(e.target.value)}
                    required
                  />
                  <span className="form-group-hint">
                    Directory scanned for external rune packages (defaults to ~/.runeweaver/plugins).
                  </span>
                </div>
                <div className="form-group flex-2">
                  <label htmlFor="marketplace-url">Marketplace Index URL</label>
                  <input
                    id="marketplace-url"
                    type="url"
                    className="input-field"
                    value={pluginsMarketplaceIndexURL}
                    onChange={(e) => setPluginsMarketplaceIndexURL(e.target.value)}
                    required
                  />
                  <span className="form-group-hint">
                    Remote catalog URL for community runes.
                  </span>
                </div>
              </div>
              <div className="form-row" style={{ marginTop: "12px" }}>
                <div className="form-group checkbox-group">
                  <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
                    <input
                      id="plugins-autorescan"
                      type="checkbox"
                      checked={pluginsAutoRescan}
                      onChange={(e) => setPluginsAutoRescan(e.target.checked)}
                    />
                    <span>Automatically scan plugins directory on startup</span>
                  </label>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Security pane owns containers governance plus Files & Access plus access
            management. Files & Access is the single files editor: both guard
            textareas live here through the shared files payload helper, so
            Security is the only home for file policy. */}
        {activeTab === "security" && (
          <>
            <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Containers</h3>
              <p className="settings-section-hint">
                One [containers] table governs memory, concurrency, and idle TTL across the bash execution tiers and detonation containers, while the long-lived workspace machine box is governed by its Stop and Recycle controls.
              </p>
            </div>

            {/* Container images are pinned in code so every caller shares one
                spelling; the pane names both pinned images as read-only text
                with no editor rather than inputs that suggest a choice. */}
            <div className="form-row">
              <div className="form-group flex-1">
                <span className="form-group-label">Strict Container Image</span>
                <p data-testid="containers-strict-image">
                  <code>debian:stable-slim</code>{" "}
                  <span className="muted text-sm">Pinned in code (fixed)</span>
                </p>
                <span className="form-group-hint">
                  Per-turn strict containers always run the pinned guest image; no image selection.
                </span>
              </div>
              <div className="form-group flex-1">
                <span className="form-group-label">Machine Image</span>
                <p data-testid="containers-machine-image">
                  <code>debian:stable-slim</code>{" "}
                  <span className="muted text-sm">Pinned in code (fixed)</span>
                </p>
                <span className="form-group-hint">
                  Machine-scoped containers always use the pinned machine image; no image selection.
                </span>
              </div>
              <div className="form-group flex-1">
                <span className="form-group-label">Detonation Image</span>
                <p data-testid="containers-detonation-image">
                  <code>alpine:3.22</code>{" "}
                  <span className="muted text-sm">Pinned in code (fixed)</span>
                </p>
                <span className="form-group-hint">
                  Detonation containers always use the pinned detonation image; no image selection.
                </span>
              </div>
            </div>
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="containers-memory-mb">Memory (MB)</label>
                <input
                  id="containers-memory-mb"
                  type="number"
                  step={1}
                  className="input-field"
                  value={containersMemoryMB}
                  onChange={(e) => setContainersMemoryMB(e.target.value)}
                />
                <span className="form-group-hint">
                  Memory budget for one container; a tiny budget fails every spawn while a host-scale one crowds the host.
                </span>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="containers-max-concurrent">Max Concurrent Containers</label>
                <input
                  id="containers-max-concurrent"
                  type="number"
                  step={1}
                  className="input-field"
                  value={containersMaxConcurrent}
                  onChange={(e) => setContainersMaxConcurrent(e.target.value)}
                />
                <span className="form-group-hint">
                  Maximum containers running at once; excess spawns fail closed until capacity frees.
                </span>
              </div>
            </div>
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="containers-ttl-minutes">Idle TTL (minutes)</label>
                <input
                  id="containers-ttl-minutes"
                  type="number"
                  step={1}
                  className="input-field"
                  value={containersTTLMinutes}
                  onChange={(e) => setContainersTTLMinutes(e.target.value)}
                />
                <span className="form-group-hint">
                  Idle lifetime before a container is reclaimed; live containers are never reaped mid-turn.
                </span>
              </div>
            </div>
            </div>
            {/* Access management: the single owner token gate. Rotation lives
                here rather than in a general settings save because it changes a
                credential and signs other devices out immediately, not a config
                value. The reveal is one-time and dismissal is acknowledged. */}
            <div className="settings-section card">
              <div className="settings-section-header">
                <div className="settings-section-title-group">
                  <h3>Access Management</h3>
                  <p className="settings-section-hint">
                    Owner token that guards the engine surface. Rotating it signs
                    out every other device immediately; this tab adopts the new
                    token. The token is kept in memory and this tab&apos;s session
                    only, never in persistent storage.
                  </p>
                </div>
                <div className="row">
                  <button
                    type="button"
                    className="ghost icon-text-btn"
                    data-testid="rotate-token"
                    onClick={() => {
                      setRotateError(null);
                      setRotateConfirmStep(1);
                    }}
                    disabled={rotating}
                  >
                    <RefreshIcon size={14} className={rotating ? "spin" : ""} />
                    <span>{rotating ? "Rotating…" : "Rotate Token"}</span>
                  </button>
                  {hasOwnerSession ? (
                    <button
                      type="button"
                      className="danger icon-text-btn"
                      data-testid="logout"
                      onClick={handleLogout}
                    >
                      <UserIcon size={14} />
                      <span>Log Out</span>
                    </button>
                  ) : null}
                </div>
              </div>
              <p className="muted text-sm" style={{ margin: "0 0 4px 0" }}>
                The current token is never shown. After a rotation, save the new
                token from the one-time reveal; if it is lost, re-mint one on the
                Mac Studio with <code>rune-weaver auth token rotate</code>.
              </p>
              {rotateError ? (
                <div className="error-banner" data-testid="rotate-error">
                  {rotateError}
                </div>
              ) : null}
            </div>
          </>
        )}

        {/* TAB 4: Memory & Persistence */}
        {activeTab === "memory" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Memory & Persistence</h3>
              <p className="settings-section-hint">
                Paths to long-term memory, episode history databases, and embedding backend.
              </p>
            </div>
            {/* Backend leads because it decides whether any model choice
                applies: apple is fixed on-device, provider follows the chat
                model, and none disables vectors entirely. */}
            <div className="form-group">
              <label htmlFor="embedding-backend">Embedding Backend</label>
              <select
                id="embedding-backend"
                className="input-field"
                value={memoryEmbeddingBackend}
                onChange={(e) => setMemoryEmbeddingBackend(e.target.value)}
              >
                <option value="apple">apple</option>
                <option value="provider">provider</option>
                <option value="none">none</option>
              </select>
              <span className="form-group-hint">
                Apple keeps vectors on-device with no model config, provider
                uses the active chat model for embeddings via /v1/embeddings,
                and none stays keyword-only with no vectors. Switching chat
                models under provider may require a vector reset due to width
                pinning.
              </span>
            </div>
            <div className="form-group">
              <label htmlFor="episodes-path">Episodes SQLite Database Path</label>
              <input
                id="episodes-path"
                type="text"
                className="input-field"
                value={memoryEpisodesDBPath}
                onChange={(e) => setMemoryEpisodesDBPath(e.target.value)}
                required
              />
            </div>
            <div className="form-group">
              <label htmlFor="vector-path">Vector Storage Path</label>
              <input
                id="vector-path"
                type="text"
                className="input-field"
                value={memoryVectorDBPath}
                onChange={(e) => setMemoryVectorDBPath(e.target.value)}
                required
              />
            </div>
          </div>
        )}

        {/* TAB 5: Voice Pipeline */}
        {activeTab === "voice" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Voice Pipeline</h3>
              <p className="settings-section-hint">
                Speech-to-text and text-to-speech voice providers and models.
              </p>
            </div>
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="stt-provider">Speech-to-Text (STT) Provider</label>
                <input
                  id="stt-provider"
                  type="text"
                  className="input-field"
                  value={voiceSTTProvider}
                  onChange={(e) => setVoiceSTTProvider(e.target.value)}
                />
              </div>
              <div className="form-group flex-1">
                <label htmlFor="tts-provider">Text-to-Speech (TTS) Provider</label>
                <input
                  id="tts-provider"
                  type="text"
                  className="input-field"
                  value={voiceTTSProvider}
                  onChange={(e) => setVoiceTTSProvider(e.target.value)}
                />
              </div>
              <div className="form-group flex-1">
                <label htmlFor="whisper-model">Whisper Model</label>
                <input
                  id="whisper-model"
                  type="text"
                  className="input-field"
                  value={voiceWhisperModel}
                  onChange={(e) => setVoiceWhisperModel(e.target.value)}
                />
              </div>
            </div>
          </div>
        )}

        {/* Web pane: private search (SearXNG) plus browser automation under one
            card because both share the [browser] policy. The internal tab id
            stays "search" so the search health routes and the search* API
            aliases keep working; only the display name moves to Web. Config
            edits save through the form; Start/Stop act immediately on the
            container so health stays honest. */}
        {activeTab === "search" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Web</h3>
              <p className="settings-section-hint">
                Private web search and browser automation, backed by the
                [browser] policy.
              </p>
            </div>
            {/* Web Search subsection: SearXNG endpoint plus request limits and
                the container lifecycle, with its actions in the subsection
                header to match the Security pane. */}
            <div
              className="settings-section-header"
              style={{ marginTop: "16px" }}
            >
              <div className="settings-section-title-group">
                <h4 style={{ margin: "0 0 4px 0" }}>Web Search (SearXNG)</h4>
                <p className="settings-section-hint">
                  Web search runs locally through SearXNG. No Docker needed,
                  it uses the Apple Container CLI. First start pulls the SearXNG
                  image (about 150 MB), later starts reuse it.
                </p>
              </div>
              {/* Lifecycle actions in the header: stopped and unknown offer Start, running
                  offers Stop, and a guarded Remove sits beside the toggle for a stopped or
                  unknown entry only — never while running and never while any action runs.
                  Starting…/Stopping…/Removing… lock both controls while the action runs. */}
              <div className="row">
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  data-testid="search-toggle"
                  onClick={() => void handleToggleSearch()}
                  disabled={searchActionBusy}
                  aria-label={searchRunning ? "Stop SearXNG" : "Start SearXNG"}
                  title={searchRunning ? "Stop SearXNG" : "Start SearXNG"}
                >
                  {searchAction === "start" ? (
                    <>
                      <SearchIcon size={14} />
                      <span>Starting…</span>
                    </>
                  ) : searchAction === "stop" ? (
                    <>
                      <StopIcon size={14} />
                      <span>Stopping…</span>
                    </>
                  ) : searchRunning ? (
                    <>
                      <StopIcon size={14} />
                      <span>Stop SearXNG</span>
                    </>
                  ) : (
                    <>
                      <SearchIcon size={14} />
                      <span>Start SearXNG</span>
                    </>
                  )}
                </button>
                {/* Guarded delete beside the toggle: danger styling marks the
                    destructive step, and the enablement matrix (stopped or
                    unknown only, never running, never busy) keeps a live entry
                    from half-deleting — a running entry must stop first. */}
                <button
                  type="button"
                  className="danger icon-text-btn"
                  data-testid="search-remove"
                  onClick={() => setPendingRemoveSearch(true)}
                  disabled={!searchRemoveEnabled}
                  aria-label="Remove SearXNG container"
                  title={
                    searchRunning
                      ? "Stop SearXNG before removing"
                      : "Remove SearXNG container"
                  }
                >
                  {searchAction === "remove" ? (
                    <>
                      <TrashIcon size={14} />
                      <span>Removing…</span>
                    </>
                  ) : (
                    <>
                      <TrashIcon size={14} />
                      <span>Remove container</span>
                    </>
                  )}
                </button>
              </div>
            </div>
            <div className="form-group">
              <label htmlFor="search-searxng-url">SearXNG URL</label>
              <input
                id="search-searxng-url"
                type="url"
                className="input-field"
                value={searchSearxngURL}
                onChange={(e) => setSearchSearxngURL(e.target.value)}
                placeholder={DEFAULT_SEARCH_SEARXNG_URL}
                required
              />
              <span className="form-group-hint">
                Base URL of the local SearXNG service (default{" "}
                {DEFAULT_SEARCH_SEARXNG_URL}). Saved to searxng_url under
                [browser]; changes need a restart to take effect.
              </span>
            </div>
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="search-timeout">Timeout (seconds)</label>
                <input
                  id="search-timeout"
                  type="number"
                  min={1}
                  max={120}
                  step={1}
                  className="input-field"
                  value={searchTimeoutSeconds}
                  onChange={(e) => setSearchTimeoutSeconds(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Per-request timeout in seconds (1 to 120). Saved to search_timeout_seconds
                  under [browser].
                </span>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="search-max-results">Max Results</label>
                <input
                  id="search-max-results"
                  type="number"
                  min={1}
                  max={50}
                  step={1}
                  className="input-field"
                  value={searchMaxResults}
                  onChange={(e) => setSearchMaxResults(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Max results per query (1 to 50). Saved to max_results under
                  [browser].
                </span>
              </div>
            </div>
            {/* Health line stays below the policy fields so container state
                remains visible without a pane-level refresh; the pane probes
                on open and Start/Stop update directly from their action
                response while the global header Refresh stays the single
                manual refresh. */}
            {/* Health line stays pill-only: the SearXNG URL input above is the
                single editor and display, so repeating the endpoint here only
                duplicates long URLs and forces wrapping in narrow panes. */}
            <span
              data-testid="search-health-text"
              className="search-health-line"
            >
              {searchAction === "start" ? (
                <>
                  <span
                    className="status-pill running"
                    data-testid="search-starting-pill"
                  >
                    Starting
                  </span>
                  <span
                    className="muted text-sm"
                    data-testid="search-start-stage"
                  >
                    {searchStageCopy(searchStage)} · {searchStartElapsed}s
                  </span>
                </>
              ) : searchHealthLoading ? (
                <span className="muted text-sm">Checking search health…</span>
              ) : searchReachable === null ? (
                <span className="status-pill skipped">Unknown</span>
              ) : searchReachable ? (
                <span className="status-pill ok">Reachable</span>
              ) : (
                <span className="status-pill error">Stopped</span>
              )}
            </span>
            {searchHealthError ? (
              <div className="error-banner" data-testid="search-health-error">
                {searchHealthError}
              </div>
            ) : null}
            {/* Collapsed per-stage diagnostics stay out of the banner so install, daemon, pull,
                and timeout each render once inline; operators expand this only when the banner
                plus warn logs are not enough. */}
            {searchDiagnostics ? (
              <details
                className="muted text-sm"
                data-testid="search-health-diagnostics"
              >
                <summary>Diagnostics</summary>
                <pre style={{ whiteSpace: "pre-wrap", margin: "8px 0 0 0" }}>
                  {searchDiagnostics}
                </pre>
              </details>
            ) : null}
            {/* Single lifecycle hint keeps the three-way contract explicit: stop
                preserves the entry for a fast restart, remove deletes it fully
                while the image stays cached, and quit intentionally leaves the
                container running. */}
            <p
              className="muted text-sm"
              data-testid="search-lifecycle-hint"
              style={{ margin: "8px 0 0 0" }}
            >
              Stop keeps the container for fast restart, Remove deletes it
              fully, and quit leaves it running by design.
            </p>
            {/* Browser automation (Playwright) lifecycle: managed venv under
                ~/.runeweaver/python provisioned on first navigate or serve
                boot (venv, pip install playwright, playwright install
                chromium). Resolution prefers RUNEWEAVER_PYTHON_BIN, then the
                managed venv, then PATH python3; pipx and Homebrew
                playwright-cli never satisfy `import playwright`. The header
                action is state-aware: Ready offers only a health re-probe,
                Missing installs, Unknown checks then installs, and an
                in-flight provision disables the action while naming the live
                stage. Setup internals stay behind Advanced, which opens
                itself only when a failure banner needs the fallback path. */}
            <div
              style={{
                marginTop: "20px",
                paddingTop: "16px",
                borderTop: "1px solid var(--border-color, #2d3748)",
              }}
            >
              <div className="settings-section-header">
                <div className="settings-section-title-group">
                  <h4 style={{ margin: "0 0 4px 0" }}>Browser automation</h4>
                  <p className="settings-section-hint">
                    Browser automation for browser.navigate and browser.act
                    runs through an isolated managed Python environment. First
                    use provisions Playwright plus Chromium; later uses reuse
                    it.
                  </p>
                </div>
                <div className="row">
                  {browserActionBusy ? (
                    // In-flight: the disabled action doubles as the progress
                    // line so the operator sees which step is running without
                    // reading the pill below.
                    <button
                      type="button"
                      className="ghost icon-text-btn"
                      data-testid="browser-preparing"
                      disabled
                      aria-label="Preparing browser environment"
                      title="Preparing browser environment"
                    >
                      <WrenchIcon size={14} />
                      <span>
                        Preparing… {browserStageCopy(browserStage)} ·{" "}
                        {browserElapsed}s
                      </span>
                    </button>
                  ) : browserReady === true ? (
                    // Ready hides the install action entirely so an already
                    // provisioned environment is never re-installed by accident;
                    // only an explicit health re-probe remains.
                    <button
                      type="button"
                      className="ghost icon-text-btn"
                      data-testid="browser-recheck"
                      onClick={() => void refreshBrowserHealth()}
                      disabled={browserHealthLoading}
                      aria-label="Re-check browser Python"
                      title="Re-check browser Python"
                    >
                      <RefreshIcon
                        size={14}
                        className={browserHealthLoading ? "spin" : ""}
                      />
                      <span>Re-check</span>
                    </button>
                  ) : browserReady === false ? (
                    <button
                      type="button"
                      className="primary icon-text-btn"
                      data-testid="browser-ensure"
                      onClick={() => void handleEnsureBrowser()}
                      aria-label="Install browser environment"
                      title="Install browser environment"
                    >
                      <WrenchIcon size={14} />
                      <span>Install browser environment</span>
                    </button>
                  ) : (
                    // Unknown covers a probe that has not returned a boolean yet
                    // and an older engine without a health route; the action
                    // checks then installs, matching the ensure path.
                    <button
                      type="button"
                      className="primary icon-text-btn"
                      data-testid="browser-ensure"
                      onClick={() => void handleEnsureBrowser()}
                      aria-label="Check & install"
                      title="Check & install"
                    >
                      <WrenchIcon size={14} />
                      <span>Check &amp; install</span>
                    </button>
                  )}
                </div>
              </div>
              {/* Health line stays pill-only: one glanceable state for the
                  pane, while paths and fallback guidance live in Advanced. */}
              <span
                data-testid="browser-health-text"
                className="search-health-line"
              >
                {browserAction === "ensure" ? (
                  <>
                    <span
                      className="status-pill running"
                      data-testid="browser-starting-pill"
                    >
                      Preparing
                    </span>
                    <span
                      className="muted text-sm"
                      data-testid="browser-start-stage"
                    >
                      {browserStageCopy(browserStage)} · {browserElapsed}s
                    </span>
                  </>
                ) : browserHealthLoading ? (
                  <span className="muted text-sm">
                    Checking browser health…
                  </span>
                ) : browserReady === null ? (
                  <span className="status-pill skipped">Unknown</span>
                ) : browserReady ? (
                  <span className="status-pill ok">Ready</span>
                ) : (
                  <span className="status-pill error">Missing</span>
                )}
              </span>
              {browserError ? (
                <div
                  className="error-banner"
                  data-testid="browser-health-error"
                >
                  {browserError}
                </div>
              ) : null}
              {browserDiagnostics ? (
                <details
                  className="muted text-sm"
                  data-testid="browser-health-diagnostics"
                >
                  <summary>Diagnostics</summary>
                  <pre style={{ whiteSpace: "pre-wrap", margin: "8px 0 0 0" }}>
                    {browserDiagnostics}
                  </pre>
                </details>
              ) : null}
              {/* Advanced carries setup internals that matter only while
                  troubleshooting: the managed venv location, the resolved
                  interpreter, and the copy-paste recovery command. It stays
                  collapsed in normal use and is force-opened by the error
                  effect above so a failed provision reveals its fallback. */}
              <details
                ref={browserAdvancedRef}
                className="muted text-sm"
                data-testid="browser-advanced"
                style={{ margin: "8px 0 0 0" }}
              >
                <summary>Advanced</summary>
                <p style={{ margin: "8px 0 0 0" }}>
                  Managed Python at {browserVenvPath}. Override with
                  RUNEWEAVER_PYTHON_BIN, then managed venv, then PATH python3;
                  pipx and brew playwright-cli do not provide import
                  playwright.
                </p>
                {browserPythonPath ? (
                  <p style={{ margin: "8px 0 0 0" }}>
                    Python: <code>{browserPythonPath}</code>
                  </p>
                ) : null}
                <p style={{ margin: "8px 0 0 0" }}>
                  Manual fallback:{" "}
                  <code>
                    {browserVenvPath}/bin/python -m pip install{" "}
                    {BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT} &&{" "}
                    {browserVenvPath}/bin/python -m playwright install chromium
                  </code>{" "}
                  (on Linux also run {browserVenvPath}/bin/python -m playwright
                  install-deps or install system browser dependencies
                  manually). Offline installs fail closed without changing the
                  existing venv.
                </p>
              </details>
            </div>
            {/* Guarded remove confirmation via the shared modal so the entry is
                never deleted by an accidental click. */}
            {pendingRemoveSearch ? (
              <Modal
                label="Confirm remove search container"
                onClose={() => {
                  if (searchAction !== null) return;
                  setPendingRemoveSearch(false);
                }}
                containerClassName="modal-container session-delete-modal"
              >
                <div className="modal-header">
                  <h3>Remove search container?</h3>
                  <button
                    type="button"
                    className="icon-button"
                    onClick={() => setPendingRemoveSearch(false)}
                    disabled={searchAction !== null}
                    aria-label="Close"
                  >
                    <CloseIcon size={16} />
                  </button>
                </div>
                <div className="modal-body">
                  <p className="muted" style={{ margin: 0 }}>
                    This will stop (if running) and delete the
                    runeweaver-searxng container. The image cache stays and
                    next Start recreates the container.
                  </p>
                </div>
                <div className="modal-footer">
                  <button
                    type="button"
                    className="ghost"
                    onClick={() => setPendingRemoveSearch(false)}
                    disabled={searchAction !== null}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="danger"
                    onClick={() => void handleConfirmRemoveSearch()}
                    disabled={searchAction !== null}
                  >
                    Remove container
                  </button>
                </div>
              </Modal>
            ) : null}
          </div>
        )}

        {/* TAB 6: Email Accounts */}
        {activeTab === "email" && (
          <div className="settings-section card">
            <div className="settings-section-header">
              <div className="settings-section-title-group">
                <h3>Email Accounts</h3>
                <p className="settings-section-hint">
                  Configure IMAP email accounts for background monitoring and automated schedules.
                </p>
              </div>
              <div className="row">
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={handleAddEmailAccount}
                >
                  <PlusIcon size={14} />
                  <span>Add Account</span>
                </button>
              </div>
            </div>

            {emailAccountsList.length === 0 ? (
              <div className="empty-state-box">
                <MailIcon size={32} />
                <p>No email accounts configured yet.</p>
                <button
                  type="button"
                  className="primary icon-text-btn"
                  onClick={handleAddEmailAccount}
                >
                  <PlusIcon size={14} />
                  <span>Configure First Email Account</span>
                </button>
              </div>
            ) : (
              <div className="email-accounts-list">
                {emailAccountsList.map((item) => {
                  const acc = item.account;
                  const passwordEnv = getEmailPasswordEnv(acc.name);
                  return (
                    <div key={item.id} className="email-account-card">
                      <div className="email-card-header">
                        <div className="email-card-title">
                          <MailIcon size={18} />
                          <h4>{acc.name || "Untitled Account"}</h4>
                          <span className="email-card-type-badge">{acc.type}</span>
                        </div>
                        <button
                          type="button"
                          className="icon-button danger"
                          onClick={() => handleRemoveEmailAccount(item.id)}
                          title={`Delete account ${acc.name}`}
                          aria-label={`Delete account ${acc.name}`}
                        >
                          <TrashIcon size={14} />
                        </button>
                      </div>

                      <div className="email-fields-grid">
                        <div className="form-group">
                          <label htmlFor={`email-name-${item.id}`}>Nickname</label>
                          <input
                            id={`email-name-${item.id}`}
                            type="text"
                            className="input-field"
                            value={acc.name}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "name", e.target.value)
                            }
                            placeholder="e.g. icloud, work"
                            required
                          />
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-type-${item.id}`}>Type</label>
                          <select
                            id={`email-type-${item.id}`}
                            className="input-field"
                            value={acc.type}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "type", e.target.value)
                            }
                          >
                            <option value="imap">IMAP</option>
                            <option value="pop3">POP3</option>
                          </select>
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-host-${item.id}`}>Host</label>
                          <input
                            id={`email-host-${item.id}`}
                            type="text"
                            className="input-field"
                            value={acc.host}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "host", e.target.value)
                            }
                            placeholder="imap.mail.me.com"
                            required
                          />
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-port-${item.id}`}>Port</label>
                          <input
                            id={`email-port-${item.id}`}
                            type="number"
                            className="input-field"
                            value={acc.port}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "port", e.target.value)
                            }
                            placeholder="993"
                            required
                          />
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-user-${item.id}`}>Username / Email</label>
                          <input
                            id={`email-user-${item.id}`}
                            type="text"
                            className="input-field"
                            value={acc.username}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "username", e.target.value)
                            }
                            placeholder="user@example.com"
                            required
                          />
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-smtp-host-${item.id}`}>
                            SMTP Host (Optional)
                          </label>
                          <input
                            id={`email-smtp-host-${item.id}`}
                            type="text"
                            className="input-field"
                            value={acc.smtpHost ?? acc.smtpHost ?? ""}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "smtpHost", e.target.value)
                            }
                            placeholder="Blank means derived host"
                          />
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-smtp-port-${item.id}`}>
                            SMTP Port (Optional)
                          </label>
                          <input
                            id={`email-smtp-port-${item.id}`}
                            type="number"
                            className="input-field"
                            value={acc.smtpPort ?? acc.smtpPort ?? ""}
                            onChange={(e) =>
                              handleEmailFieldChange(
                                item.id,
                                "smtpPort",
                                e.target.value === "" ? "" : Number(e.target.value)
                              )
                            }
                            placeholder="Blank means 587 then 465"
                          />
                        </div>

                        <div className="form-group">
                          <label htmlFor={`email-smtp-security-${item.id}`}>
                            SMTP Security
                          </label>
                          <select
                            id={`email-smtp-security-${item.id}`}
                            className="input-field"
                            value={acc.smtpSecurity ?? acc.smtpSecurity ?? "auto"}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "smtpSecurity", e.target.value)
                            }
                          >
                            <option value="auto">Auto (STARTTLS then SSL)</option>
                            <option value="starttls">STARTTLS</option>
                            <option value="ssl">SSL (implicit TLS)</option>
                          </select>
                        </div>
                      </div>

                      <div className="email-env-hint" style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: "8px" }}>
                        <div>
                          <span>Password resolved via SecretsManager from: </span>
                          <code>{passwordEnv}</code>
                        </div>
                        <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                          {secretStatus[passwordEnv] ? (
                            <span className="keychain-status-badge stored">
                              <CheckIcon size={12} /> Stored in Keychain
                            </span>
                          ) : (
                            <span className="keychain-status-badge missing">
                              Not Set in Keychain
                            </span>
                          )}
                          <button
                            type="button"
                            className="keychain-action-btn"
                            onClick={() =>
                              handleOpenStoreSecretModal(
                                passwordEnv,
                                `Password for ${acc.name || "Email Account"}`,
                                !!secretStatus[passwordEnv]
                              )
                            }
                            title={
                              secretStatus[passwordEnv]
                                ? `Update password for ${acc.name} in Keychain`
                                : `Store password for ${acc.name} in Keychain`
                            }
                          >
                            <KeyIcon size={12} />
                            <span>
                              {secretStatus[passwordEnv]
                                ? "Update Password in Keychain"
                                : "Store Password to Keychain"}
                            </span>
                          </button>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        )}

        {/* TAB: Network bind ([server] hostname, port, allowed_hosts). The socket
            and the Host gate are fixed at boot, so saves persist to the file and
            return requiresRestart without live-reloading; the banner below tracks
            pending-vs-live until a restart. */}
        {activeTab === "network" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Network</h3>
              <p className="settings-section-hint">
                HTTP bind interface, port, and exact-only allowed hosts from [server].
                Changes persist to config.toml and need a restart to take effect.
              </p>
            </div>
            {(() => {
              // File holds the last saved values from GET/PUT; boot holds the
              // still-live socket from the pre-save snapshot (or /health when
              // advertised); pending holds the unsaved form. Comparing file
              // against boot keeps the restart banner truthful after
              // populateForm syncs the form to the file, instead of rendering
              // identical file-versus-file values.
              const fileHostname =
                typeof settings?.serverHostname === "string" && settings.serverHostname.trim()
                  ? settings.serverHostname
                  : DEFAULT_SERVER_HOSTNAME;
              const filePort =
                typeof settings?.serverPort === "number" ? settings.serverPort : DEFAULT_SERVER_PORT;
              const fileHosts = Array.isArray(settings?.serverAllowedHosts)
                ? (settings?.serverAllowedHosts as string[])
                : [];
              const bootHostname = liveServerBind?.hostname ?? fileHostname;
              const bootPort = liveServerBind?.port ?? filePort;
              const bootHosts = liveServerBind?.allowedHosts ?? fileHosts;
              const pendingHostname = serverHostname.trim();
              const pendingPort = Number(serverPort);
              const pendingHosts = parseServerAllowedHostsText(serverAllowedHostsText);
              const pendingHostsEqualFile = areServerAllowedHostsEqual(pendingHosts, fileHosts);
              const isDirty =
                canonicalRestartHost(pendingHostname) !==
                  canonicalRestartHost(fileHostname) ||
                (Number.isInteger(pendingPort) ? pendingPort !== filePort : true) ||
                !pendingHostsEqualFile;
              const fileDiffersFromBoot =
                canonicalRestartHost(fileHostname) !==
                  canonicalRestartHost(bootHostname) ||
                filePort !== bootPort ||
                !areServerAllowedHostsEqual(fileHosts, bootHosts);
              const restartVisible = serverRestartRequired || fileDiffersFromBoot;
              return (
                <>
                  {restartVisible ? (
                    <div
                      className="error-banner"
                      data-testid="server-restart-banner"
                      style={{
                        backgroundColor: "rgba(237, 137, 54, 0.15)",
                        border: "1px solid rgba(237, 137, 54, 0.4)",
                        color: "#ed8936",
                      }}
                    >
                      Restart required: network changes are saved but the live bind is still{" "}
                      <code>
                        {bootHostname}:{bootPort}
                      </code>
                      . Restart the engine to serve{" "}
                      <code>
                        {fileHostname}:{filePort}
                      </code>
                      .
                    </div>
                  ) : null}
                  {isDirty && !restartVisible ? (
                    <div
                      className="muted text-sm"
                      data-testid="server-pending-banner"
                      style={{
                        padding: "10px 14px",
                        borderRadius: "8px",
                        border: "1px solid var(--border-color, #2d3748)",
                        marginBottom: "12px",
                      }}
                    >
                      Unsaved network changes: pending{" "}
                      <code>
                        {pendingHostname || "(empty)"}:{String(serverPort) || "(empty)"}
                      </code>{" "}
                      vs saved{" "}
                      <code>
                        {fileHostname}:{filePort}
                      </code>
                      . Save, then restart to apply.
                    </div>
                  ) : null}
                </>
              );
            })()}
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="server-hostname-select">Bind interface</label>
                <select
                  id="server-hostname-select"
                  className="input-field"
                  data-testid="server-hostname-select"
                  value={serverHostnameCustom || !isServerBindPreset(serverHostname) ? "custom" : (SERVER_BIND_PRESETS.find((preset) => canonicalRestartHost(preset) === canonicalRestartHost(serverHostname)) ?? serverHostname.trim())}
                  onChange={(e) => {
                    const next = e.target.value;
                    if (next === "custom") {
                      // Entering custom mode preserves the preset value in the
                      // revealed input instead of clearing to empty, so the
                      // pending bind never forces a required-field error nor
                      // loses the preset until the operator edits it.
                      setServerHostnameCustom(true);
                    } else {
                      setServerHostnameCustom(false);
                      setServerHostname(next);
                    }
                  }}
                >
                  <option value="127.0.0.1">127.0.0.1 (Loopback only, no token needed)</option>
                  <option value="0.0.0.0">0.0.0.0 (All interfaces, LAN needs owner token)</option>
                  <option value="custom">Custom</option>
                </select>
                <span className="form-group-hint">
                  Which interface the engine listens on. This is separate from Allowed
                  hosts below, which controls which Host headers the gate accepts.
                </span>
              </div>
              {serverHostnameCustom || !isServerBindPreset(serverHostname) ? (
                <div className="form-group flex-1">
                  <label htmlFor="server-hostname">Bind address</label>
                  <input
                    id="server-hostname"
                    type="text"
                    className="input-field"
                    data-testid="server-hostname"
                    value={serverHostname}
                    onChange={(e) => setServerHostname(e.target.value)}
                    placeholder="127.0.0.1"
                    required
                  />
                </div>
              ) : null}
              <div className="form-group flex-1">
                <label htmlFor="server-port">Port</label>
                <input
                  id="server-port"
                  type="number"
                  min={1}
                  max={65535}
                  step={1}
                  className="input-field"
                  data-testid="server-port"
                  value={serverPort}
                  onChange={(e) => setServerPort(e.target.value === "" ? "" : Number(e.target.value))}
                  placeholder={String(DEFAULT_SERVER_PORT)}
                  required
                />
                <span className="form-group-hint">
                  TCP port 1-65535. Saved to port under [server].
                </span>
              </div>
            </div>
            {!isLoopbackHostname(serverHostname) ? (
              <div
                className="muted text-sm"
                data-testid="server-lan-hint"
                style={{
                  padding: "10px 14px",
                  borderRadius: "8px",
                  border: "1px solid var(--border-color, #2d3748)",
                  margin: "12px 0",
                }}
              >
                A non-loopback bind serves on your local network and requires a resolvable owner
                token. Without one the save is refused (400) instead of silently downgrading.
                {hasOwnerSession ? (
                  <span> An owner session is active in this tab.</span>
                ) : (
                  <span>
                    {" "}
                    Generate one on the Mac Studio with <code>rune-weaver auth token generate</code>,
                    then sign in before saving a LAN bind.
                  </span>
                )}
              </div>
            ) : null}
            <div className="settings-subsection-header" style={{ marginTop: "20px" }}>
              <div className="settings-section-title-group">
                <h4 style={{ margin: "0 0 4px 0" }}>Allowed hosts</h4>
                <p className="settings-section-hint">
                  Exact-only extra Host entries (max {MAX_SERVER_ALLOWED_HOSTS}, max{" "}
                  {MAX_SERVER_ALLOWED_HOST_LENGTH} chars each). Lowercased and port-stripped on
                  save; schemes, wildcards, CIDR, bare *, unbalanced brackets, and trailing
                  dots are rejected.
                </p>
              </div>
              <div className="row">
                <span className="muted text-sm" data-testid="server-allowed-count">
                  {serverAllowedHostsCount} {serverAllowedHostsCount === 1 ? "host" : "hosts"}
                </span>
              </div>
            </div>
            <div className="form-group" style={{ marginTop: "8px" }}>
              <label htmlFor="server-allowed-hosts-textarea">
                Allowed hosts, one per line{" "}
                <span className="muted text-sm">
                  ({serverAllowedHostsCount} {serverAllowedHostsCount === 1 ? "host" : "hosts"})
                </span>
              </label>
              <textarea
                id="server-allowed-hosts-textarea"
                className="input-field server-allowed-hosts-textarea"
                data-testid="server-allowed-hosts"
                aria-label="Allowed hosts, one per line"
                value={serverAllowedHostsText}
                onChange={(e) => setServerAllowedHostsText(e.target.value)}
                placeholder="e.g. mac-studio.local"
                rows={6}
              />
              <span className="form-group-hint">
                One exact host per line. Blank lines are ignored. Entries are lowercased and
                port-stripped on save; schemes, wildcards, CIDR, bare *, unbalanced brackets,
                and trailing dots are rejected with line numbers.
              </span>
              {serverAllowedHostsError ? (
                <span
                  className="form-group-hint"
                  data-testid="server-allowed-error"
                  style={{ color: "#f56565" }}
                >
                  {serverAllowedHostsError}
                </span>
              ) : null}
            </div>
          </div>
        )}

        <div className="settings-footer">
          {/* Short Save copy keeps the sticky footer compact on handheld
              widths; the disabled plus submit wiring stays unchanged so the
              busy state still blocks double submits. */}
          <button
            type="submit"
            className="primary-button save-button"
            disabled={saving}
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
          </form>
          ) : null}
        </div>
      </div>

      <RuneMarketplaceModal
        isOpen={marketplaceOpen}
        onClose={() => setMarketplaceOpen(false)}
        onPluginInstalled={() => {
          void loadPluginsData();
        }}
      />

      {/* Workspace tmp prune confirmation via the shared modal: pruning
          deletes expired tmp/ entries and cannot be undone, so an explicit
          confirm stands between the button and the POST. */}
      {pendingPruneWorkspace ? (
        <Modal
          label="Confirm prune workspace tmp"
          onClose={() => {
            if (pruningWorkspace) return;
            setPendingPruneWorkspace(false);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Prune workspace tmp?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setPendingPruneWorkspace(false)}
              disabled={pruningWorkspace}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This deletes expired entries under workspace/tmp/. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setPendingPruneWorkspace(false)}
              disabled={pruningWorkspace}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void handleConfirmPruneWorkspace()}
              disabled={pruningWorkspace}
              aria-label="Confirm prune workspace tmp"
            >
              {pruningWorkspace ? "Pruning…" : "Prune tmp"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Persisted plugin uninstall confirmation via the shared modal. */}
      {pendingUninstallPlugin ? (
        <Modal
          label="Confirm uninstall plugin"
          onClose={() => {
            if (updatingPluginId === pendingUninstallPlugin.id) return;
            cancelUninstallPlugin();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Uninstall rune?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelUninstallPlugin}
              disabled={updatingPluginId === pendingUninstallPlugin.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently uninstall and remove &lsquo;
              {pendingUninstallPlugin.name}&rsquo;. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelUninstallPlugin}
              disabled={updatingPluginId === pendingUninstallPlugin.id}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmUninstallPlugin()}
              disabled={updatingPluginId === pendingUninstallPlugin.id}
              aria-label="Confirm uninstall plugin"
            >
              {updatingPluginId === pendingUninstallPlugin.id
                ? "Uninstalling…"
                : "Uninstall"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Rotate confirmation step one: name the blast radius (every other device
          signed out immediately) before anything is minted. */}
      {rotateConfirmStep === 1 ? (
        <Modal
          label="Confirm token rotation"
          onClose={() => {
            if (rotating) return;
            setRotateConfirmStep(0);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Rotate owner token?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              Rotating the owner token invalidates the current token immediately
              and signs out every other device. This device adopts the new token.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => setRotateConfirmStep(2)}
              disabled={rotating}
            >
              Continue
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Rotate confirmation step two: the final gate, spelling out the one-time
          reveal and the CLI recovery path so the consequence is explicit before
          the irreversible call. */}
      {rotateConfirmStep === 2 ? (
        <Modal
          label="Confirm token rotation again"
          onClose={() => {
            if (rotating) return;
            setRotateConfirmStep(0);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Rotate now?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This is the final confirmation. The new token is shown once and
              cannot be retrieved again from the dashboard. Save it before
              dismissing; if you lose it, re-mint one on the Mac Studio with
              <code> rune-weaver auth token rotate</code>.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void handleConfirmRotate()}
              disabled={rotating}
              aria-label="Confirm rotate token"
            >
              {rotating ? "Rotating…" : "Rotate token now"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* One-time token reveal. Dismissal is gated on the saved acknowledgement
          because the value cannot be fetched again; backdrop click and Escape
          share the same guard so a stray interaction cannot discard it. */}
      {newToken ? (
        <Modal
          label="New owner token"
          onClose={() => {
            if (!tokenSavedAck) return;
            handleDismissNewToken();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Save your new token</h3>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ marginTop: 0 }}>
              This is the only time the new token is shown. Store it somewhere
              safe now; every other device has already been signed out.
            </p>
            <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
              <code
                data-testid="new-token"
                style={{
                  flex: 1,
                  wordBreak: "break-all",
                  padding: "8px 10px",
                  borderRadius: "6px",
                  background: "var(--bg-secondary, #10131a)",
                  border: "1px solid var(--border-color, #2d3748)",
                }}
              >
                {newToken}
              </code>
              <button
                type="button"
                className="ghost icon-text-btn"
                onClick={() => void handleCopyNewToken()}
              >
                {tokenCopyState === "copied" ? <CheckIcon size={14} /> : null}
                <span>
                  {tokenCopyState === "copied"
                    ? "Copied"
                    : tokenCopyState === "failed"
                      ? "Copy failed"
                      : "Copy"}
                </span>
              </button>
            </div>
            <label
              style={{
                display: "flex",
                alignItems: "center",
                gap: "8px",
                marginTop: "14px",
                cursor: "pointer",
              }}
            >
              <input
                type="checkbox"
                checked={tokenSavedAck}
                onChange={(event) => setTokenSavedAck(event.target.checked)}
              />
              <span>
                I have saved this token and understand it will not be shown
                again.
              </span>
            </label>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="primary"
              onClick={handleDismissNewToken}
              disabled={!tokenSavedAck}
            >
              Done
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Active-run guard: saving while a chat turn, tool call, or scheduler
          run is in flight cancels that work, so the operator confirms first.
          Parked approvals never trigger this path. Cancel aborts the PUT;
          Continue saves and hot-reloads. */}
      {showActiveGuard ? (
        <Modal
          label="Confirm save during active run"
          onClose={handleCancelGuard}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Save while work is running?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={handleCancelGuard}
              disabled={saving}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              If you continue, in progress chats will be cancelled. Do you want to continue?
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={handleCancelGuard}
              disabled={saving}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void handleConfirmGuardSave()}
              disabled={saving}
            >
              {saving ? "Saving…" : "Continue"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Browser, Web, and API tools configuration modal (browser.navigate, browser.act, web.fetch, web.search, api.request).
          Configures automation and request timeouts; domain allow/deny rules and local network access live on the Access tab. */}
      {configuringToolName === "browser.navigate" ||
      configuringToolName === "browser.act" ||
      configuringToolName === "web.fetch" ||
      configuringToolName === "web.search" ||
      configuringToolName === "api.request" ? (
        <Modal
          label="Configure Web, Browser & API Automation"
          onClose={() => {
            if (!browserSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Web, Browser & API Automation</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => {
                if (!browserSaveLoading) setConfiguringToolName(null);
              }}
              disabled={browserSaveLoading}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body" style={{ maxHeight: "calc(85vh - 130px)", overflowY: "auto" }}>
            {browserModalError && (
              <div className="error-banner" style={{ marginBottom: "14px", display: "flex", alignItems: "center", gap: "8px" }}>
                <AlertTriangleIcon size={16} />
                <span>{browserModalError}</span>
              </div>
            )}

            <p className="muted text-sm" style={{ marginBottom: "16px" }}>
              Configure timeouts and execution limits for browser automation (<code>browser.navigate</code>, <code>browser.act</code>), web fetch &amp; search (<code>web.fetch</code>, <code>web.search</code>), and external API requests (<code>api.request</code>).
            </p>

            {/* Timeouts Section */}
            <div style={{ padding: "14px", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)", marginBottom: "16px", backgroundColor: "var(--bg-secondary, #141822)" }}>
              <h4 style={{ margin: "0 0 12px 0", fontSize: "0.88rem" }}>Request &amp; Automation Timeouts</h4>
              <div className="form-group" style={{ marginBottom: "12px" }}>
                <label htmlFor="browser-timeout-seconds" style={{ fontSize: "0.82rem" }}>
                  Browser Automation Timeout (seconds)
                </label>
                <input
                  id="browser-timeout-seconds"
                  type="number"
                  min={5}
                  max={300}
                  className="input-field"
                  value={browserTimeoutSeconds}
                  onChange={(e) => setBrowserTimeoutSeconds(e.target.value)}
                />
                <span className="form-group-hint" style={{ marginTop: "4px", display: "block" }}>
                  Timeout in seconds for Playwright actions (navigation, clicking, waiting for selectors). Default is {DEFAULT_BROWSER_TIMEOUT_SECONDS}s.
                </span>
              </div>

              <div className="form-group" style={{ marginBottom: 0 }}>
                <label htmlFor="browser-fetch-timeout-seconds" style={{ fontSize: "0.82rem" }}>
                  HTTP Request Timeout (seconds)
                </label>
                <input
                  id="browser-fetch-timeout-seconds"
                  type="number"
                  min={1}
                  max={120}
                  className="input-field"
                  value={browserFetchTimeoutSeconds}
                  onChange={(e) => setBrowserFetchTimeoutSeconds(e.target.value)}
                />
                <span className="form-group-hint" style={{ marginTop: "4px", display: "block" }}>
                  Timeout in seconds for direct HTTP requests made by <code>web.fetch</code> and <code>api.request</code>. Default is {DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS}s.
                </span>
              </div>
            </div>

            {/* Security Policy pointer: domain allow/deny rules, local
                network access, and credentials live on the Access tab's
                Network and Credentials sections, so this modal keeps only
                a compact pointer to that surface. */}
            <div style={{ padding: "14px", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)", marginBottom: "16px", backgroundColor: "var(--bg-secondary, #141822)" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: "12px" }}>
                <div>
                  <h4 style={{ margin: "0 0 6px 0", fontSize: "0.88rem" }}>Security &amp; Network Policy</h4>
                  <p className="muted text-sm" style={{ margin: 0 }}>
                    Domain allow/deny rules and local network access are managed under the Access tab.
                  </p>
                </div>
                <button
                  type="button"
                  className="ghost"
                  style={{ whiteSpace: "nowrap", fontSize: "0.8rem", padding: "6px 10px" }}
                  onClick={() => {
                    setActiveTab("access");
                    setConfiguringToolName(null);
                  }}
                >
                  Manage Security Policy &rarr;
                </button>
              </div>
            </div>
          </div>
          <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}>
            <button
              type="button"
              className="ghost"
              onClick={() => setConfiguringToolName(null)}
              disabled={browserSaveLoading}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void handleSaveBrowserConfig()}
              disabled={browserSaveLoading}
            >
              {browserSaveLoading ? "Saving…" : "Save Configuration"}
            </button>
          </div>
        </Modal>
      ) : configuringToolName === "media.arr" ||
      configuringToolName === "media.arr.read" ? (
        <Modal
          label="Configure Sonarr & Radarr"
          onClose={() => {
            if (!mediaSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Media Automation (Sonarr & Radarr)</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => {
                if (!mediaSaveLoading) setConfiguringToolName(null);
              }}
              disabled={mediaSaveLoading}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body" style={{ maxHeight: "70vh", overflowY: "auto" }}>
            {mediaModalError && (
              <div className="error-banner" style={{ marginBottom: "14px", display: "flex", alignItems: "center", gap: "8px" }}>
                <AlertTriangleIcon size={16} />
                <span>{mediaModalError}</span>
              </div>
            )}

            <p className="muted text-sm" style={{ marginBottom: "16px" }}>
              Configure your local or network Sonarr (TV) and Radarr (Movie) instances.
              API keys are resolved from environment variables or macOS Keychain (<code>com.runeweaver.secrets</code>) and never stored in plaintext config.
            </p>

            {/* Sonarr Card */}
            <div style={{ padding: "14px", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)", marginBottom: "16px", backgroundColor: "var(--bg-secondary, #141822)" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "12px" }}>
                <h4 style={{ margin: 0, display: "flex", alignItems: "center", gap: "8px" }}>
                  <span>Sonarr (TV Shows)</span>
                </h4>
                <label style={{ display: "flex", alignItems: "center", gap: "6px", fontSize: "0.85rem", cursor: "pointer" }}>
                  <input
                    type="checkbox"
                    checked={sonarrEnabled}
                    onChange={(e) => setSonarrEnabled(e.target.checked)}
                  />
                  <span>Enabled</span>
                </label>
              </div>

              <div className="form-group" style={{ marginBottom: "10px" }}>
                <label htmlFor="sonarr-url" style={{ fontSize: "0.82rem" }}>Server URL</label>
                <input
                  id="sonarr-url"
                  type="text"
                  className="input-field"
                  value={sonarrUrl}
                  onChange={(e) => setSonarrUrl(e.target.value)}
                  placeholder="e.g. http://localhost:8989 or http://192.168.1.100:8989"
                />
              </div>

              <div className="form-group" style={{ marginBottom: "10px" }}>
                <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "4px", flexWrap: "wrap", gap: "6px" }}>
                  <label htmlFor="sonarr-key-env" style={{ fontSize: "0.82rem" }}>API Key Environment Variable / Keychain Key</label>
                  {(() => {
                    const keyEnv = sonarrApiKeyEnv.trim();
                    if (!keyEnv) return null;
                    const isStored = !!secretStatus[keyEnv];
                    return (
                      <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                        {isStored ? (
                          <span className="keychain-status-badge stored">
                            <CheckIcon size={12} /> Stored in Keychain
                          </span>
                        ) : (
                          <span className="keychain-status-badge missing">
                            Not Set in Keychain
                          </span>
                        )}
                        <button
                          type="button"
                          className="keychain-action-btn"
                          onClick={() => handleOpenStoreSecretModal(keyEnv, "Sonarr API Key", isStored)}
                          title={isStored ? `Update secret for ${keyEnv}` : `Store secret for ${keyEnv} in Keychain`}
                        >
                          <KeyIcon size={12} />
                          <span>{isStored ? "Update Key" : "Store Key"}</span>
                        </button>
                      </div>
                    );
                  })()}
                </div>
                <input
                  id="sonarr-key-env"
                  type="text"
                  className="input-field"
                  value={sonarrApiKeyEnv}
                  onChange={(e) => setSonarrApiKeyEnv(e.target.value)}
                  placeholder="SONARR_API_KEY"
                />
              </div>

              <div className="form-row" style={{ display: "flex", gap: "10px" }}>
                <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                  <label htmlFor="sonarr-quality" style={{ fontSize: "0.82rem" }}>Default Quality Profile (Optional)</label>
                  <input
                    id="sonarr-quality"
                    type="text"
                    className="input-field"
                    value={sonarrDefaultQuality}
                    onChange={(e) => setSonarrDefaultQuality(e.target.value)}
                    placeholder="e.g. HD-1080p"
                  />
                </div>
                <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                  <label htmlFor="sonarr-root" style={{ fontSize: "0.82rem" }}>Default Root Folder (Optional)</label>
                  <input
                    id="sonarr-root"
                    type="text"
                    className="input-field"
                    value={sonarrDefaultRoot}
                    onChange={(e) => setSonarrDefaultRoot(e.target.value)}
                    placeholder="e.g. /data/media/tv"
                  />
                </div>
              </div>
            </div>

            {/* Radarr Card */}
            <div style={{ padding: "14px", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)", backgroundColor: "var(--bg-secondary, #141822)" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "12px" }}>
                <h4 style={{ margin: 0, display: "flex", alignItems: "center", gap: "8px" }}>
                  <span>Radarr (Movies)</span>
                </h4>
                <label style={{ display: "flex", alignItems: "center", gap: "6px", fontSize: "0.85rem", cursor: "pointer" }}>
                  <input
                    type="checkbox"
                    checked={radarrEnabled}
                    onChange={(e) => setRadarrEnabled(e.target.checked)}
                  />
                  <span>Enabled</span>
                </label>
              </div>

              <div className="form-group" style={{ marginBottom: "10px" }}>
                <label htmlFor="radarr-url" style={{ fontSize: "0.82rem" }}>Server URL</label>
                <input
                  id="radarr-url"
                  type="text"
                  className="input-field"
                  value={radarrUrl}
                  onChange={(e) => setRadarrUrl(e.target.value)}
                  placeholder="e.g. http://localhost:7878 or http://192.168.1.100:7878"
                />
              </div>

              <div className="form-group" style={{ marginBottom: "10px" }}>
                <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "4px", flexWrap: "wrap", gap: "6px" }}>
                  <label htmlFor="radarr-key-env" style={{ fontSize: "0.82rem" }}>API Key Environment Variable / Keychain Key</label>
                  {(() => {
                    const keyEnv = radarrApiKeyEnv.trim();
                    if (!keyEnv) return null;
                    const isStored = !!secretStatus[keyEnv];
                    return (
                      <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                        {isStored ? (
                          <span className="keychain-status-badge stored">
                            <CheckIcon size={12} /> Stored in Keychain
                          </span>
                        ) : (
                          <span className="keychain-status-badge missing">
                            Not Set in Keychain
                          </span>
                        )}
                        <button
                          type="button"
                          className="keychain-action-btn"
                          onClick={() => handleOpenStoreSecretModal(keyEnv, "Radarr API Key", isStored)}
                          title={isStored ? `Update secret for ${keyEnv}` : `Store secret for ${keyEnv} in Keychain`}
                        >
                          <KeyIcon size={12} />
                          <span>{isStored ? "Update Key" : "Store Key"}</span>
                        </button>
                      </div>
                    );
                  })()}
                </div>
                <input
                  id="radarr-key-env"
                  type="text"
                  className="input-field"
                  value={radarrApiKeyEnv}
                  onChange={(e) => setRadarrApiKeyEnv(e.target.value)}
                  placeholder="RADARR_API_KEY"
                />
              </div>

              <div className="form-row" style={{ display: "flex", gap: "10px" }}>
                <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                  <label htmlFor="radarr-quality" style={{ fontSize: "0.82rem" }}>Default Quality Profile (Optional)</label>
                  <input
                    id="radarr-quality"
                    type="text"
                    className="input-field"
                    value={radarrDefaultQuality}
                    onChange={(e) => setRadarrDefaultQuality(e.target.value)}
                    placeholder="e.g. HD-1080p"
                  />
                </div>
                <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                  <label htmlFor="radarr-root" style={{ fontSize: "0.82rem" }}>Default Root Folder (Optional)</label>
                  <input
                    id="radarr-root"
                    type="text"
                    className="input-field"
                    value={radarrDefaultRoot}
                    onChange={(e) => setRadarrDefaultRoot(e.target.value)}
                    placeholder="e.g. /data/media/movies"
                  />
                </div>
              </div>
            </div>

            {/* Media Request Timeout Card */}
            <div style={{ padding: "14px", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)", marginTop: "16px", backgroundColor: "var(--bg-secondary, #141822)" }}>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label htmlFor="media-timeout-seconds" style={{ fontSize: "0.82rem" }}>
                  Request Timeout (seconds)
                </label>
                <input
                  id="media-timeout-seconds"
                  type="number"
                  min={5}
                  max={120}
                  className="input-field"
                  value={mediaTimeoutSeconds}
                  onChange={(e) => setMediaTimeoutSeconds(e.target.value)}
                />
                <span className="form-group-hint" style={{ marginTop: "4px", display: "block" }}>
                  Timeout in seconds for API calls to Sonarr and Radarr. Default is {DEFAULT_MEDIA_TIMEOUT_SECONDS}s.
                </span>
              </div>
            </div>
          </div>
          <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}>
            <button
              type="button"
              className="ghost"
              onClick={() => setConfiguringToolName(null)}
              disabled={mediaSaveLoading}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void handleSaveMediaConfig()}
              disabled={mediaSaveLoading}
            >
              {mediaSaveLoading ? "Saving…" : "Save Configuration"}
            </button>
          </div>
        </Modal>
      ) : configuringToolName === "desktop" ||
          configuringToolName === "desktop.screenshot" ||
          configuringToolName === "desktop.action" ? (
        <Modal
          label="Configure Desktop Integration"
          onClose={() => {
            if (!desktopSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Desktop Integration</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => {
                if (!desktopSaveLoading) setConfiguringToolName(null);
              }}
              disabled={desktopSaveLoading}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body" style={{ maxHeight: "70vh", overflowY: "auto" }}>
            {desktopModalError && (
              <div className="error-banner" style={{ marginBottom: "14px", display: "flex", alignItems: "center", gap: "8px" }}>
                <AlertTriangleIcon size={16} />
                <span>{desktopModalError}</span>
              </div>
            )}

            <p className="muted text-sm" style={{ marginBottom: "16px" }}>
              Configure screen capture resolution, vision downscaling, and application safety blocklists for desktop control.
            </p>

            {/* Section 1: Screen Capture & Vision */}
            <div style={{ marginBottom: "20px" }}>
              <h4 style={{ fontSize: "0.9rem", margin: "0 0 10px 0", color: "var(--text-primary, #ffffff)" }}>
                Screen Capture & Vision
              </h4>
              <div className="form-row" style={{ display: "flex", gap: "10px", marginBottom: "4px" }}>
                <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                  <label htmlFor="desktop-max-dimension" style={{ fontSize: "0.82rem" }}>Max Image Dimension (px)</label>
                  <input
                    id="desktop-max-dimension"
                    type="number"
                    min={256}
                    max={3840}
                    step={1}
                    className="input-field"
                    value={desktopMaxImageDimension}
                    onChange={(e) =>
                      setDesktopMaxImageDimension(
                        e.target.value === "" ? "" : Number(e.target.value)
                      )
                    }
                    placeholder="1280"
                  />
                  <span className="form-group-hint">
                    Longest edge of the downscaled screenshot (256-3840).
                  </span>
                </div>
                <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                  <label htmlFor="desktop-jpeg-quality" style={{ fontSize: "0.82rem" }}>JPEG Quality (0.1-1.0)</label>
                  <input
                    id="desktop-jpeg-quality"
                    type="number"
                    min={0.1}
                    max={1.0}
                    step={0.05}
                    className="input-field"
                    value={desktopJpegQuality}
                    onChange={(e) =>
                      setDesktopJpegQuality(
                        e.target.value === "" ? "" : Number(e.target.value)
                      )
                    }
                    placeholder="0.75"
                  />
                  <span className="form-group-hint">
                    In-memory JPEG quality for downscaled captures.
                  </span>
                </div>
              </div>
            </div>

            {/* Section 2: Control & Safety Blocklist */}
            <div style={{ paddingTop: "14px", borderTop: "1px solid var(--border-color, #2d3748)" }}>
              <h4 style={{ fontSize: "0.9rem", margin: "0 0 10px 0", color: "var(--text-primary, #ffffff)" }}>
                Control & Security Blocklist
              </h4>
              <div className="form-group" style={{ marginBottom: "10px" }}>
                <label htmlFor="desktop-blocked-apps-textarea" style={{ fontSize: "0.85rem", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <span>
                    Blocked Apps{" "}
                    <span className="muted text-sm">
                      ({parseBlockedAppsText(desktopBlockedAppsText).length}{" "}
                      {parseBlockedAppsText(desktopBlockedAppsText).length === 1 ? "app" : "apps"})
                    </span>
                  </span>
                </label>
                <textarea
                  id="desktop-blocked-apps-textarea"
                  className="input-field allowed-origins-textarea"
                  value={desktopBlockedAppsText}
                  onChange={(e) => setDesktopBlockedAppsText(e.target.value)}
                  placeholder={"Terminal\nKeychain Access\n1Password"}
                />
                <span className="form-group-hint" style={{ marginTop: "4px", display: "block" }}>
                  One application name per line. Blocked targets refuse automated
                  input before dispatch. Blank lines are ignored.
                </span>
              </div>
            </div>
          </div>
          <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}>
            <button
              type="button"
              className="ghost"
              onClick={() => setConfiguringToolName(null)}
              disabled={desktopSaveLoading}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void handleSaveDesktopConfig()}
              disabled={desktopSaveLoading}
            >
              {desktopSaveLoading ? "Saving…" : "Save Configuration"}
            </button>
          </div>
        </Modal>
      ) : configuringToolName === "fanout.run" ||
          (typeof configuringToolName === "string" &&
            configuringToolName.startsWith("fanout.")) ? (
        <Modal
          label="Configure Parallel Fan-Out"
          onClose={() => {
            if (!fanoutSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Parallel Fan-Out</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => {
                if (!fanoutSaveLoading) setConfiguringToolName(null);
              }}
              disabled={fanoutSaveLoading}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body" style={{ maxHeight: "70vh", overflowY: "auto" }}>
            {fanoutModalError && (
              <div className="error-banner" style={{ marginBottom: "14px", display: "flex", alignItems: "center", gap: "8px" }}>
                <AlertTriangleIcon size={16} />
                <span>{fanoutModalError}</span>
              </div>
            )}

            <p className="muted text-sm" style={{ marginBottom: "16px" }}>
              Tune the parallel worker swarm for <code>fanout.run</code>. Workers
              fan out over caller-composed subtasks and merge through one
              reviewer pass; these knobs take effect without a restart.
            </p>

            <div className="form-row" style={{ display: "flex", gap: "10px", marginBottom: "4px" }}>
              <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                <label htmlFor="fanout-max-workers" style={{ fontSize: "0.82rem" }}>Max workers</label>
                <input
                  id="fanout-max-workers"
                  type="number"
                  min={1}
                  max={8}
                  step={1}
                  className="input-field"
                  value={fanoutMaxWorkers}
                  onChange={(e) =>
                    setFanoutMaxWorkers(
                      e.target.value === "" ? "" : Number(e.target.value)
                    )
                  }
                  placeholder="2 (default)"
                />
                <span className="form-group-hint">
                  Maximum workers running at once. Clearing the field saves 2.
                </span>
              </div>
              <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                <label htmlFor="fanout-worker-timeout" style={{ fontSize: "0.82rem" }}>Worker timeout (seconds)</label>
                <input
                  id="fanout-worker-timeout"
                  type="number"
                  min={0}
                  step={1}
                  className="input-field"
                  value={fanoutWorkerTimeoutSeconds}
                  onChange={(e) =>
                    setFanoutWorkerTimeoutSeconds(
                      e.target.value === "" ? "" : Number(e.target.value)
                    )
                  }
                  placeholder="0 (unlimited)"
                />
                <span className="form-group-hint">
                  0 = no timeout — recommended for local models. Clearing the field saves 0 (unlimited).
                </span>
              </div>
            </div>

            <div className="form-group checkbox-group" style={{ marginTop: "16px" }}>
              <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
                <input
                  id="fanout-full-tools"
                  type="checkbox"
                  checked={fanoutFullTools}
                  onChange={(e) => setFanoutFullTools(e.target.checked)}
                />
                <span>Full tools</span>
              </label>
              <span className="form-group-hint">
                Lets workers call the full tool registry, not just read-only tools.
              </span>
            </div>
          </div>
          <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}>
            <button
              type="button"
              className="ghost"
              onClick={() => setConfiguringToolName(null)}
              disabled={fanoutSaveLoading}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void handleSaveFanoutConfig()}
              disabled={fanoutSaveLoading}
            >
              {fanoutSaveLoading ? "Saving…" : "Save Configuration"}
            </button>
          </div>
        </Modal>
      ) : configuringToolName !== null ? (
        // Honest fallback for any future hasConfig tool without a dedicated
        // editor: the Configure button stays flag-driven, so an unmapped name
        // must explain itself instead of rendering nothing on click.
        <Modal
          label={`Configure ${configuringToolName}`}
          onClose={() => setConfiguringToolName(null)}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure {configuringToolName}</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setConfiguringToolName(null)}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted text-sm">
              No configuration UI is available for &ldquo;
              {configuringToolName}&rdquo; yet. This tool reports settings
              support, but the dashboard has no editor for it, so nothing was
              changed.
            </p>
          </div>
          <div
            className="modal-footer"
            style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}
          >
            <button
              type="button"
              className="primary"
              onClick={() => setConfiguringToolName(null)}
            >
              Close
            </button>
          </div>
        </Modal>
      ) : null}


      {secretModal && secretModal.isOpen && (
        <StoreSecretModal
          isOpen={secretModal.isOpen}
          secretKey={secretModal.secretKey}
          title={secretModal.title}
          isUpdate={secretModal.isUpdate}
          onClose={() => setSecretModal(null)}
          onSuccess={handleSecretSaved}
        />
      )}
    </section>
  );
}
