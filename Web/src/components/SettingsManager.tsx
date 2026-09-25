// Rune Weaver Dashboard — Settings manager for config.toml configuration.
// Allows managing LLM providers, engine identity, sandbox policy, memory, voice, web search, and email accounts.

import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS,
  DEFAULT_FILES_DENY_PATTERNS_TEXT,
  formatDenyPatternsText,
  parseDenyPatternsText,
  DEFAULT_BROWSER_ALLOWED_ORIGINS_TEXT,
  formatAllowedOriginsText,
  parseAllowedOriginsText,
  DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES,
  DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE,
  DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES,
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
  formatBlockedAppsText,
  parseBlockedAppsText,
  type DesktopConfigData,
  type DesktopSettingsUpdate,
  type EmailAccountData,
  type MediaConfigData,
  type ProviderConfigData,
  type SettingsResponse,
  type PluginSummary,
  type ToolInfo,
} from "../api";
import {
  AlertTriangleIcon,
  ApprovalsIcon,
  ChatIcon,
  CheckIcon,
  CloseIcon,
  MailIcon,
  MemoryIcon,
  MenuIcon,
  MicIcon,
  PlusIcon,
  RefreshIcon,
  SearchIcon,
  SettingsIcon,
  StopIcon,
  TrashIcon,
  UserIcon,
  WrenchIcon,
} from "./icons";
import Modal from "./Modal";
import RuneMarketplaceModal from "./RuneMarketplaceModal";
import { IndexPolicyPanel } from "./IndexingPanel";
import { ToastStack } from "./Toast";
import { useRunningRuns } from "../hooks/useRunningRuns";
import { useToastStack } from "../hooks/useToastStack";
import { useSearchStartProgress } from "../hooks/useSearchStartProgress";
import { useIsMobile } from "../hooks/useIsMobile";

// Vertical navigation keeps every category visible without horizontal scrolling; sandbox
// and file policy share one Security pane so the sidebar stays within the width budget as settings
// grow. The `search` id stays verbatim while the pane displays as Web: the search* API aliases and
// the /search/* health routes are keyed to that id, so only the label moves. The `network` pane
// owns the [server] bind (hostname, port, allowed_hosts) plus the restart banner.
type SettingsTab =
  | "providers"
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
  "providers",
  "engine",
  "tools",
  "security",
  "memory",
  "voice",
  "search",
  "email",
  "network",
  "indexing",
];

// Narrows an unknown tab id to the known vocabulary without throwing, so
// selection stays fail-closed on drifted or persisted values.
function isSettingsTab(value: unknown): value is SettingsTab {
  return (
    typeof value === "string" &&
    (SETTINGS_TABS as readonly string[]).includes(value)
  );
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

export default function SettingsManager() {
  const [settings, setSettings] = useState<SettingsResponse | null>(null);
  const [activeTab, setActiveTab] = useState<SettingsTab>("providers");
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
  const [maxToolIterations, setMaxToolIterations] = useState<number | string>(10);
  const [defaultProvider, setDefaultProvider] = useState("");
  const [fallbackProvider, setFallbackProvider] = useState("");
  const [providersList, setProvidersList] = useState<ProviderEntry[]>([]);
  // Tier-3 detonation policy: ephemeral microVMs with immediate reap. The
  // TTL bounds only crash-orphan reclamation and the cap gates concurrent
  // detonations; the runtime stays pinned server-side with no editor.
  const [sandboxContainerBaseImage, setSandboxContainerBaseImage] = useState(
    DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE
  );
  const [sandboxArchiveSessionTTLMinutes, setSandboxArchiveSessionTTLMinutes] = useState(
    DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES
  );
  const [sandboxMaxConcurrentMachines, setSandboxMaxConcurrentMachines] = useState(
    DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES
  );
  // Blocked-paths editor holds raw textarea text (one glob per line) so blank lines survive editing
  // and only collapse on save; the parsed count drives the live badge while an emptied editor
  // intentionally means allow-all in scope rather than falling back to defaults.
  const [filesDenyText, setFilesDenyText] = useState<string>(
    DEFAULT_FILES_DENY_PATTERNS_TEXT
  );
  const [filesAllowRoots, setFilesAllowRoots] = useState<string[]>([
    ...DEFAULT_FILES_ALLOW_ROOTS,
  ]);
  const [filesRequireApprovalOnDeny, setFilesRequireApprovalOnDeny] = useState(true);
  // Direct handle to the blocked-paths editor so Add Pattern can return
  // keyboard focus without a document-wide lookup that breaks with
  // multiple instances or strict-mode remounts.
  const denyTextareaRef = useRef<HTMLTextAreaElement>(null);
  // Form-local reset confirmations: resetting only rewrites the in-progress
  // form and never persists until Save, so the modal must state counts and
  // the until-Save nature explicitly.
  const [pendingResetDeny, setPendingResetDeny] = useState(false);
  const [pendingResetRoots, setPendingResetRoots] = useState(false);
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

  const [configuringToolName, setConfiguringToolName] = useState<string | null>(null);
  const [mediaSaveLoading, setMediaSaveLoading] = useState(false);
  const [mediaModalError, setMediaModalError] = useState<string | null>(null);
  // Short-lived success-then-close timer for the media modal: held in a ref
  // (not bare setTimeout) so unmount or a second save clears the pending tick
  // instead of firing setState on an unmounted pane or closing a fresh edit.
  const mediaSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Homelab allowed origins for browser & web tools (multiline text, one host/domain per line)
  const [browserAllowedOriginsText, setBrowserAllowedOriginsText] = useState<string>(
    DEFAULT_BROWSER_ALLOWED_ORIGINS_TEXT
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

  // Copies one settings fetch into the Sonarr/Radarr fields, tolerating both
  // snake_case and camelCase DTO aliases and falling back to the conventional
  // key names. Only overwrites sections the engine returns so older engines
  // without [media] leave the form defaults untouched.
  const populateMediaSettings = useCallback(
    (media: MediaConfigData | undefined | null) => {
      if (media?.sonarr) {
        setSonarrEnabled(media.sonarr.enabled ?? true);
        setSonarrUrl(media.sonarr.url ?? "");
        setSonarrApiKeyEnv(
          media.sonarr.api_key_env || media.sonarr.apiKeyEnv || "SONARR_API_KEY"
        );
        setSonarrDefaultQuality(
          media.sonarr.default_quality_profile ||
            media.sonarr.defaultQualityProfile ||
            ""
        );
        setSonarrDefaultRoot(
          media.sonarr.default_root_folder || media.sonarr.defaultRootFolder || ""
        );
      }
      if (media?.radarr) {
        setRadarrEnabled(media.radarr.enabled ?? true);
        setRadarrUrl(media.radarr.url ?? "");
        setRadarrApiKeyEnv(
          media.radarr.api_key_env || media.radarr.apiKeyEnv || "RADARR_API_KEY"
        );
        setRadarrDefaultQuality(
          media.radarr.default_quality_profile ||
            media.radarr.defaultQualityProfile ||
            ""
        );
        setRadarrDefaultRoot(
          media.radarr.default_root_folder || media.radarr.defaultRootFolder || ""
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
        settings?.media?.sonarr?.api_key_env?.trim() ||
        settings?.media?.sonarr?.apiKeyEnv?.trim() ||
        "";
      const storedRadarrEnv =
        settings?.media?.radarr?.api_key_env?.trim() ||
        settings?.media?.radarr?.apiKeyEnv?.trim() ||
        "";
      return {
        sonarr: {
          enabled: sonarrEnabled,
          url: sonarrUrl.trim(),
          api_key_env:
            sonarrApiKeyEnv.trim() || storedSonarrEnv || "SONARR_API_KEY",
          default_quality_profile: sonarrDefaultQuality.trim(),
          default_root_folder: sonarrDefaultRoot.trim(),
        },
        radarr: {
          enabled: radarrEnabled,
          url: radarrUrl.trim(),
          api_key_env:
            radarrApiKeyEnv.trim() || storedRadarrEnv || "RADARR_API_KEY",
          default_quality_profile: radarrDefaultQuality.trim(),
          default_root_folder: radarrDefaultRoot.trim(),
        },
      };
    },
    [
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
      if (typeof desktop.max_image_dimension === "number") {
        setDesktopMaxImageDimension(desktop.max_image_dimension);
      }
      if (typeof desktop.jpeg_quality === "number") {
        setDesktopJpegQuality(desktop.jpeg_quality);
      }
      if (Array.isArray(desktop.blocked_apps)) {
        setDesktopBlockedAppsText(formatBlockedAppsText(desktop.blocked_apps));
      }
    },
    []
  );

  // Builds the [desktop] delta from the knob fields so the full-settings save
  // and the modal-only save share one shape. A per-tool modal sends only its
  // own knobs (capture bounds for desktop.screenshot, the blocklist for
  // desktop.action); the full-settings save sends every knob. Enable keys
  // never travel here — tool enablement lives in the tool-state toggles.
  // Numeric fields preserve the raw input (including empty/invalid) so the
  // modal validation surfaces range errors instead of silently coercing back
  // to defaults.
  const buildDesktopPayload = useCallback(
    (toolName: string | null = null): DesktopSettingsUpdate => {
      if (toolName === "desktop.screenshot") {
        return {
          max_image_dimension: Number(desktopMaxImageDimension),
          jpeg_quality: Number(desktopJpegQuality),
        };
      }
      if (toolName === "desktop.action") {
        return {
          blocked_apps: parseBlockedAppsText(desktopBlockedAppsText),
        };
      }
      return {
        max_image_dimension: Number(desktopMaxImageDimension),
        jpeg_quality: Number(desktopJpegQuality),
        blocked_apps: parseBlockedAppsText(desktopBlockedAppsText),
      };
    },
    [
      desktopMaxImageDimension,
      desktopJpegQuality,
      desktopBlockedAppsText,
    ]
  );

  const populateForm = useCallback((data: SettingsResponse) => {
    setSettings(data);
    setEngineName(data.engineName);
    setLogLevel(data.logLevel);
    setCompactionThresholdPercent(data.compactionThresholdPercent ?? 80);
    setMaxToolIterations(data.maxToolIterations ?? 10);
    setDefaultProvider(data.defaultProvider);
    setFallbackProvider(data.fallbackProvider ?? "");

    // Transform providers record into editable list with stable keys
    const pList: ProviderEntry[] = Object.entries(data.providers || {}).map(
      ([name, cfg], idx) => ({
        id: `p-${idx}-${name}`,
        name,
        config: {
          enabled: cfg.enabled ?? true,
          model: cfg.model ?? "",
          server_url: cfg.server_url || cfg.serverURL || "",
          serverURL: cfg.server_url || cfg.serverURL || "",
          api_key_env: cfg.api_key_env || cfg.apiKeyEnv || "",
          apiKeyEnv: cfg.api_key_env || cfg.apiKeyEnv || "",
          provider_type: cfg.provider_type || cfg.providerType || "",
          providerType: cfg.provider_type || cfg.providerType || "",
          api_style: cfg.api_style || cfg.apiStyle || "",
          apiStyle: cfg.api_style || cfg.apiStyle || "",
          context_length: cfg.context_length ?? cfg.contextLength,
          contextLength: cfg.context_length ?? cfg.contextLength,
          // Prefix-reuse knobs use nullish coalescing (not ||) so an explicit false cache hint
          // survives the load instead of collapsing to unset and being stripped on save.
          slot_count: cfg.slot_count ?? cfg.slotCount,
          slotCount: cfg.slot_count ?? cfg.slotCount,
          cache_prompt: cfg.cache_prompt ?? cfg.cachePrompt,
          cachePrompt: cfg.cache_prompt ?? cfg.cachePrompt,
          supports_vision: cfg.supports_vision ?? cfg.supportsVision,
          supportsVision: cfg.supports_vision ?? cfg.supportsVision,
        },
      })
    );
    setProvidersList(pList);

    setSandboxContainerBaseImage(
      data.sandboxContainerBaseImage ?? DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE
    );
    setSandboxArchiveSessionTTLMinutes(
      data.sandboxArchiveSessionTTLMinutes ?? DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES
    );
    setSandboxMaxConcurrentMachines(
      data.sandboxMaxConcurrentMachines ?? DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES
    );
    setFilesDenyText(formatDenyPatternsText(data.filesDenyPatterns));
    setFilesAllowRoots(
      Array.isArray(data.filesAllowRoots)
        ? [...data.filesAllowRoots]
        : [...DEFAULT_FILES_ALLOW_ROOTS]
    );
    setFilesRequireApprovalOnDeny(data.filesRequireApprovalOnDeny ?? true);
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
    setBrowserAllowedOriginsText(formatAllowedOriginsText(data.browserAllowedOrigins));
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
  }, [populateMediaSettings, populateDesktopSettings]);

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

  // Unmount must never leave the browser provision poll or media/desktop tick
  // running behind a closed pane.
  useEffect(() => {
    const pollRef = browserTimerRef;
    const mediaRef = mediaSaveTimerRef;
    const browserSaveRef = browserSaveTimerRef;
    const desktopSaveRef = desktopSaveTimerRef;
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
      const sUrl = entry.config.server_url || entry.config.serverURL;
      const kEnv = entry.config.api_key_env || entry.config.apiKeyEnv;
      const pType = entry.config.provider_type || entry.config.providerType;
      const aStyle = entry.config.api_style || entry.config.apiStyle;
      // Absent context_length means backend-default (nil), so only send a Number when the user
      // entered a value; empty stays omitted. Present values fail closed on non-positive or non-
      // integer input instead of coercing to the backend default, mirroring Config+Validation.
      const cLenRaw = entry.config.context_length ?? entry.config.contextLength;
      if (
        cLenRaw !== undefined &&
        cLenRaw !== null &&
        (cLenRaw as unknown) !== ""
      ) {
        const cLenCheck = Number(cLenRaw);
        if (!Number.isInteger(cLenCheck) || cLenCheck <= 0) {
          const label = trimmedName || "(unnamed)";
          setError(
            `Invalid context_length for provider "${label}": context_length must be a positive integer.`
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
      // Absent slot_count keeps server auto-assignment (nil), so only send a Number when the user
      // entered a value; empty stays omitted. Present values fail closed on non-positive or non-
      // integer input instead of pinning an out-of-range id, mirroring Config+Validation.
      const slotRaw = entry.config.slot_count ?? entry.config.slotCount;
      if (
        slotRaw !== undefined &&
        slotRaw !== null &&
        (slotRaw as unknown) !== ""
      ) {
        const slotCheck = Number(slotRaw);
        if (!Number.isInteger(slotCheck) || slotCheck <= 0) {
          const label = trimmedName || "(unnamed)";
          setError(
            `Invalid slot_count for provider "${label}": slot_count must be a positive integer.`
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
      const cacheRaw = entry.config.cache_prompt ?? entry.config.cachePrompt;
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
        // silently treat 0/"maybe" as enabled. Mirrors slot_count validation above.
        const label = trimmedName || "(unnamed)";
        setError(
          `Invalid cache_prompt for provider "${label}": cache_prompt must be true, false, or empty (unset).`
        );
        setSaving(false);
        return;
      }

      const visionRaw =
        entry.config.supports_vision ?? entry.config.supportsVision;
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
          `Invalid supports_vision for provider "${label}": supports_vision must be true, false, or empty (unset).`
        );
        setSaving(false);
        return;
      }

      providersMap[trimmedName] = {
        enabled: entry.config.enabled,
        model: entry.config.model?.trim() || undefined,
        server_url: sUrl?.trim() || undefined,
        serverURL: sUrl?.trim() || undefined,
        api_key_env: kEnv?.trim() || undefined,
        apiKeyEnv: kEnv?.trim() || undefined,
        provider_type: pType?.trim() || undefined,
        providerType: pType?.trim() || undefined,
        api_style: aStyle?.trim() || undefined,
        apiStyle: aStyle?.trim() || undefined,
        context_length: cLen != null ? Number(cLen) : undefined,
        contextLength: cLen != null ? Number(cLen) : undefined,
        slot_count: slot != null ? Number(slot) : undefined,
        slotCount: slot != null ? Number(slot) : undefined,
        cache_prompt: cache,
        cachePrompt: cache,
        supports_vision: vision,
        supportsVision: vision,
      };
    }

    // Blocked-paths textarea validates per line with original numbers so a bad glob points at its
    // editor row; blank lines collapse on save and an emptied editor stays a valid allow-all, while
    // `..` fails closed here and authoritatively on the server guard.
    const denyLines = filesDenyText.split("\n");
    for (let lineIndex = 0; lineIndex < denyLines.length; lineIndex += 1) {
      const trimmed = denyLines[lineIndex].trim();
      // Blank lines filter on save (empty editor means allow all in scope),
      // so only traversal escapes fail the form with their line number.
      if (!trimmed) continue;
      if (trimmed.includes("..")) {
        setError(
          `Line ${lineIndex + 1}: Deny pattern must not contain '..': "${trimmed}".`
        );
        setSaving(false);
        return;
      }
    }
    const parsedDenyPatterns = parseDenyPatternsText(filesDenyText);
    for (let rootIndex = 0; rootIndex < filesAllowRoots.length; rootIndex += 1) {
      const trimmed = filesAllowRoots[rootIndex].trim();
      // An empty root would dissolve the home containment boundary, so it
      // fails closed with its row number instead of being filtered.
      if (!trimmed) {
        setError(`Line ${rootIndex + 1}: Allowed roots cannot be empty.`);
        setSaving(false);
        return;
      }
      if (trimmed.includes("..")) {
        setError(`Line ${rootIndex + 1}: Allowed root must not contain '..': "${trimmed}".`);
        setSaving(false);
        return;
      }
    }

    // Reassemble email accounts array, preserving optional SMTP overrides. Blank smtp_host
    // collapses to omitted (derived fallback) and blank smtp_port omits so auto tries 587 then 465;
    // smtp_security defaults to auto when blank or unknown.
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
      const rawSmtpPort = entry.account.smtp_port ?? entry.account.smtpPort;
      if (
        rawSmtpPort !== undefined &&
        rawSmtpPort !== null &&
        String(rawSmtpPort).trim() !== ""
      ) {
        const smtpNum = Number(rawSmtpPort);
        const allowedSmtpPorts = [25, 465, 587, 2525];
        if (!Number.isInteger(smtpNum) || !allowedSmtpPorts.includes(smtpNum)) {
          setError(
            `Invalid SMTP port for email account "${label}": smtp_port must be one of 25, 465, 587, 2525 (got ${String(rawSmtpPort).trim()}).`
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
      const rawHost = entry.account.smtp_host ?? entry.account.smtpHost ?? "";
      const trimmedSmtpHost = String(rawHost).trim();
      const rawPort = entry.account.smtp_port ?? entry.account.smtpPort;
      const portNum =
        rawPort === undefined || rawPort === null || (rawPort as unknown) === ""
          ? undefined
          : Number(rawPort);
      const rawSecurity = entry.account.smtp_security ?? entry.account.smtpSecurity ?? "";
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
        rebuilt.smtp_host = trimmedSmtpHost;
        rebuilt.smtpHost = trimmedSmtpHost;
      }
      if (portNum !== undefined && Number.isInteger(portNum) && portNum >= 1 && portNum <= 65535) {
        rebuilt.smtp_port = portNum;
        rebuilt.smtpPort = portNum;
      }
      if (security) {
        rebuilt.smtp_security = security;
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
        rawMaxToolIterations === "" ? 10 : Number(rawMaxToolIterations);
      const clampedMaxToolIterations = Number.isFinite(maxToolIterationsValue)
        ? Math.max(1, Math.min(100, Math.floor(maxToolIterationsValue)))
        : 10;
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
        sandboxContainerBaseImage,
        sandboxArchiveSessionTTLMinutes: Number(sandboxArchiveSessionTTLMinutes),
        sandboxMaxConcurrentMachines: Number(sandboxMaxConcurrentMachines),
        filesDenyPatterns: parsedDenyPatterns,
        filesAllowRoots: filesAllowRoots.map((r) => r.trim()).filter(Boolean),
        filesRequireApprovalOnDeny,
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
        browserMaxResults: maxResultsNum,
        browserAllowedOrigins: parseAllowedOriginsText(browserAllowedOriginsText),
        searchSearxngURL: trimmedSearxngURL,
        searchTimeoutSeconds: timeoutNum,
        searchMaxResults: maxResultsNum,
        emailAccounts,
        pluginsDir,
        pluginsMarketplaceIndexURL,
        pluginsAutoRescan,
        media: buildMediaPayload(),
        desktop: buildDesktopPayload(),
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
      // The bind never live-reloads: when the save really moved [server] keys
      // the route returns requiresRestart and the Network pane keeps its banner
      // until a restart, while safe sections hot-reload live underneath.
      if (updated.requiresRestart) {
        setServerRestartRequired(true);
        pushSuccessToast("Settings saved. Restart required for network changes.");
      } else {
        // Saved confirmation stays exact so operators recognize it; safe
        // sections hot-reload live while providers, engine identity, and DB
        // paths take effect on restart without blanket restart claims here.
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
    setBrowserSaveLoading(true);
    setBrowserModalError(null);
    try {
      const updated = await updateSettings({
        browserAllowedOrigins: parseAllowedOriginsText(browserAllowedOriginsText),
      });
      // Refresh only the browser field so unsaved edits in other tabs survive.
      setBrowserAllowedOriginsText(formatAllowedOriginsText(updated.browserAllowedOrigins));
      pushSuccessToast("Browser & web settings saved!");
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

  // Saves only the [desktop] delta for the open per-tool modal through PUT
  // /settings, mirroring the media-only save shape so unsaved edits in other
  // tabs survive. The screenshot modal validates its capture bounds through
  // the same shared bounds helper as the full save instead of coercing to
  // defaults; the control modal carries only the blocklist, which needs no
  // range check. Each modal sends only its own knobs and never enable keys,
  // and the engine live-reloads capture knobs without a restart.
  const handleSaveDesktopConfig = async () => {
    if (configuringToolName !== "desktop.action") {
      const desktopBoundsError = validateDesktopCaptureBounds(
        desktopMaxImageDimension,
        desktopJpegQuality
      );
      if (desktopBoundsError) {
        setDesktopModalError(desktopBoundsError);
        return;
      }
    }
    setDesktopSaveLoading(true);
    setDesktopModalError(null);
    try {
      const updated = await updateSettings({
        desktop: buildDesktopPayload(configuringToolName),
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
          server_url: "",
          serverURL: "",
          api_key_env: "",
          apiKeyEnv: "",
          provider_type: "",
          providerType: "",
          api_style: "",
          apiStyle: "",
          context_length: undefined,
          contextLength: undefined,
          slot_count: undefined,
          slotCount: undefined,
          cache_prompt: undefined,
          cachePrompt: undefined,
          supports_vision: undefined,
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
    const isVisionField =
      field === "supports_vision" || field === "supportsVision";
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
          `Invalid supports_vision for provider "${label}": supports_vision must be true, false, or empty (unset).`
        );
        return;
      }
    }
    setProvidersList((prev) =>
      prev.map((item) => {
        if (item.id === id) {
          const updated = { ...item.config, [field]: val };
          // Keep aliases synchronized
          if (field === "server_url") updated.serverURL = val as string;
          if (field === "serverURL") updated.server_url = val as string;
          if (field === "api_key_env") updated.apiKeyEnv = val as string;
          if (field === "apiKeyEnv") updated.api_key_env = val as string;
          if (field === "provider_type") updated.providerType = val as string;
          if (field === "providerType") updated.provider_type = val as string;
          if (field === "api_style") updated.apiStyle = val as string;
          if (field === "apiStyle") updated.api_style = val as string;
          // An empty context-length input means backend-default (nil), so clear both aliases. Non-
          // empty values (including NaN from invalid input) are preserved on both aliases so
          // handleSave can fail closed instead of silently falling back to the backend default.
          if (field === "context_length") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.context_length = next as unknown as number | undefined;
            updated.contextLength = next as unknown as number | undefined;
          }
          if (field === "contextLength") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.context_length = next as unknown as number | undefined;
            updated.contextLength = next as unknown as number | undefined;
          }
          // An empty slot input means server auto-assign (nil), so clear both aliases. Non-empty
          // values (including NaN from invalid input) are preserved on both aliases so handleSave
          // can fail closed instead of pinning an out-of-range id.
          if (field === "slot_count") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.slot_count = next as unknown as number | undefined;
            updated.slotCount = next as unknown as number | undefined;
          }
          if (field === "slotCount") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.slot_count = next as unknown as number | undefined;
            updated.slotCount = next as unknown as number | undefined;
          }
          // Tri-state cache hint: empty means unset (always-on default), otherwise normalize the
          // select strings to booleans on both aliases so an explicit false survives the PUT.
          if (field === "cache_prompt") {
            const next =
              val === "" || val === undefined
                ? undefined
                : val === true || val === "true"
                  ? true
                  : val === false || val === "false"
                    ? false
                    : (val as unknown as boolean | undefined);
            updated.cache_prompt = next;
            updated.cachePrompt = next;
          }
          if (field === "cachePrompt") {
            const next =
              val === "" || val === undefined
                ? undefined
                : val === true || val === "true"
                  ? true
                  : val === false || val === "false"
                    ? false
                    : (val as unknown as boolean | undefined);
            updated.cache_prompt = next;
            updated.cachePrompt = next;
          }
          if (field === "supports_vision" || field === "supportsVision") {
            updated.supports_vision = visionNext;
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
          // Keep snake and camel aliases synchronized so saves round-trip
          // regardless of which key the engine echoes back.
          const next = { ...item.account } as EmailAccountData & Record<string, unknown>;
          if (field === "port") {
            // Preserve the raw numeric value (including 0/NaN from empty input)
            // so handleSave validation surfaces Invalid port 1-65535 instead
            // of silently coercing back to 993.
            (next as EmailAccountData).port = Number(val);
          } else if (field === "smtp_port" || field === "smtpPort") {
            // Preserve the raw numeric value (including 0/NaN from invalid
            // input) so handleSave validation surfaces Invalid SMTP port
            // 1-65535 instead of silently omitting back to the 587/465 fallback.
            const num = val === "" || val === undefined ? undefined : Number(val);
            next.smtp_port = num as unknown as number | undefined;
            next.smtpPort = num as unknown as number | undefined;
          } else if (field === "smtp_host" || field === "smtpHost") {
            next.smtp_host = val as string;
            next.smtpHost = val as string;
          } else if (field === "smtp_security" || field === "smtpSecurity") {
            next.smtp_security = val as string;
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

  // Blocked-paths editing is a single textarea (small-screen friendly for
  // long guard lists); reset only rewrites the form text after an explicit
  // modal confirm and never persists until Save.
  const handleAddDenyPattern = () => {
    // No row model exists for the textarea, so Add focuses the editor for
    // keyboard flow; ensure a trailing newline exists so typed globs start
    // on a fresh line without altering the parsed count by itself.
    setFilesDenyText((prev) => {
      if (!prev) return prev;
      return prev.endsWith("\n") ? prev : `${prev}\n`;
    });
    denyTextareaRef.current?.focus();
  };

  const handleConfirmResetDenyPatterns = () => {
    setFilesDenyText(DEFAULT_FILES_DENY_PATTERNS_TEXT);
    setPendingResetDeny(false);
  };

  const handleCancelResetDenyPatterns = () => {
    setPendingResetDeny(false);
  };

  const handleAddAllowRoot = () => {
    setFilesAllowRoots((prev) => [...prev, ""]);
  };

  const handleRemoveAllowRoot = (index: number) => {
    setFilesAllowRoots((prev) => prev.filter((_, i) => i !== index));
  };

  const handleAllowRootChange = (index: number, value: string) => {
    setFilesAllowRoots((prev) => prev.map((r, i) => (i === index ? value : r)));
  };

  const handleConfirmResetAllowRoots = () => {
    setFilesAllowRoots([...DEFAULT_FILES_ALLOW_ROOTS]);
    setPendingResetRoots(false);
  };

  const handleCancelResetAllowRoots = () => {
    setPendingResetRoots(false);
  };

  // Live parsed count keeps the badge and the textarea hint in sync without
  // storing a second source of truth beside the raw editor text.
  const denyPatternCount = parseDenyPatternsText(filesDenyText).length;
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
            Manage LLM model routing, engine parameters, sandbox security, web search, and email accounts.
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
          mirroring the chat history drawer interaction. */}
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
        <nav
          className={`settings-sidenav${settingsMenuOpen ? " open" : ""}`}
          aria-label="Settings categories"
          role="tablist"
        >
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
        </nav>

        <div className="settings-content">
          {/* The indexing pane hosts the index policy form, which uses the
              shared save control (settings-footer with a primary-button
              save-button) while still patching only the [index] section, so it
              renders outside the shared settings form and its own controls
              never submit the unrelated config values. Status cards, charts,
              and run controls live on the Memory → Index Status tab instead. */}
          {activeTab === "indexing" ? <IndexPolicyPanel /> : null}
          {activeTab !== "indexing" ? (
          <form onSubmit={handleSave} className="settings-form">
        {/* TAB 1: LLM Providers */}
        {activeTab === "providers" && (
          <div className="settings-section card">
            <div className="settings-section-header">
              <div className="settings-section-title-group">
                <h3>LLM & Providers</h3>
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
                  entry.provider_type || entry.providerType || "";
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
                                "provider_type",
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
                            value={entry.api_style || entry.apiStyle || ""}
                            onChange={(e) =>
                              handleProviderFieldChange(
                                item.id,
                                "api_style",
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
                          value={entry.server_url || entry.serverURL || ""}
                          onChange={(e) =>
                            handleProviderFieldChange(
                              item.id,
                              "server_url",
                              e.target.value
                            )
                          }
                          placeholder="https://openrouter.ai/api/v1 or http://localhost:11434/v1"
                        />
                      </div>

                      <div className="form-group">
                        <label htmlFor={`keyenv-${item.id}`}>API Key Env Var</label>
                        <input
                          id={`keyenv-${item.id}`}
                          type="text"
                          className="input-field"
                          value={entry.api_key_env || entry.apiKeyEnv || ""}
                          onChange={(e) =>
                            handleProviderFieldChange(
                              item.id,
                              "api_key_env",
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
                          value={entry.context_length ?? entry.contextLength ?? ""}
                          onChange={(e) => {
                            const raw = e.target.value;
                            handleProviderFieldChange(
                              item.id,
                              "context_length",
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
                            value={entry.slot_count ?? entry.slotCount ?? ""}
                            onChange={(e) => {
                              const raw = e.target.value;
                              handleProviderFieldChange(
                                item.id,
                                "slot_count",
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
                              (entry.cache_prompt ?? entry.cachePrompt) === undefined
                                ? ""
                                : (entry.cache_prompt ?? entry.cachePrompt)
                                  ? "true"
                                  : "false"
                            }
                            onChange={(e) =>
                              handleProviderFieldChange(
                                item.id,
                                "cache_prompt",
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
                            (entry.supports_vision ?? entry.supportsVision) === undefined
                              ? ""
                              : (entry.supports_vision ?? entry.supportsVision)
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
                                "supports_vision",
                                undefined
                              );
                              return;
                            }
                            if (raw === "true") {
                              handleProviderFieldChange(
                                item.id,
                                "supports_vision",
                                true
                              );
                              return;
                            }
                            if (raw === "false") {
                              handleProviderFieldChange(
                                item.id,
                                "supports_vision",
                                false
                              );
                              return;
                            }
                            const label =
                              (item.name ?? "").trim() || "(unnamed)";
                            setError(
                              `Invalid supports_vision for provider "${label}": supports_vision must be true, false, or empty (unset).`
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

        {/* TAB 2: Engine & Logs */}
        {activeTab === "engine" && (
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
                  Max Tool Rounds per Turn
                </label>
                <input
                  id="max-tool-iterations"
                  type="number"
                  className="input-field"
                  min={1}
                  max={100}
                  step={1}
                  value={maxToolIterations}
                  onChange={(e) => setMaxToolIterations(e.target.value)}
                />
                <p className="settings-field-hint" style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}>
                  Maximum number of consecutive tool rounds the agent may execute before pausing for user approval to continue. Range: 1–100. Default is 10.
                </p>
              </div>
            </div>
          </div>
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
            <h4 style={{ margin: "28px 0 12px 0", display: "flex", alignItems: "center", gap: "8px" }}>
              <span>Built-in Engine Tools</span>
            </h4>

            {/* Responsive cards grid keeps 13 engine tools above the fold: dense
                3–4-up cards on wide panes collapse to one column on narrow
                screens so the Tools tab no longer scrolls through full rows. */}
            {safeTools.filter((t) => t.isBuiltIn).length === 0 ? (
              <div className="empty-state-box">
                <WrenchIcon size={32} />
                <p>No built-in tools available.</p>
              </div>
            ) : (
              <div className="builtin-tools-grid">
                {safeTools.filter((t) => t.isBuiltIn).map((tool) => {
                  const isToggling = togglingToolName === tool.name;
                  return (
                    <article key={tool.name} className="builtin-tool-card">
                      <div className="builtin-tool-card-header">
                        <code className="builtin-tool-name" title={tool.name}>
                          {tool.name}
                        </code>
                        <span className="builtin-tool-permission">{tool.permissionLevel}</span>
                      </div>
                      {/* Single-line clamp with full-text tooltip keeps cards even;
                          native details below reveals the complete wording on
                          demand for keyboard and screen-reader users. */}
                      <p className="builtin-tool-desc" title={tool.description}>
                        {tool.description}
                      </p>
                      {tool.description && (
                        <details className="builtin-tool-details">
                          <summary>Details</summary>
                          <p className="builtin-tool-details-body">{tool.description}</p>
                        </details>
                      )}
                      <div className="builtin-tool-footer builtin-tool-footer--split">
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
                          {/* Visual switch affordance: data-on drives the accent/muted
                              fill and knob side in CSS while the native checkbox keeps
                              keyboard and screen-reader semantics. */}
                          <span
                            className="tool-switch-track"
                            data-on={tool.isEnabled ? "true" : "false"}
                            aria-hidden="true"
                          >
                            <span className="tool-switch-thumb" />
                          </span>
                          {/* State-first text reports the persisted bus state instead of
                              the next action so the row reads like a mobile setting. */}
                          <span className="tool-switch-state">
                            {isToggling ? "Updating…" : tool.isEnabled ? "Enabled" : "Disabled"}
                          </span>
                        </label>
                        {/* Configure affordance follows the server hasConfig flag
                            alone so capability detection stays with the tool
                            listing route instead of a client name allowlist. */}
                        {tool.hasConfig && (
                          <button
                            type="button"
                            className="accent-ghost icon-text-btn"
                            onClick={() => {
                              setMediaModalError(null);
                              setBrowserModalError(null);
                              setDesktopModalError(null);
                              setConfiguringToolName(tool.name);
                            }}
                            style={{ padding: "4px 8px", fontSize: "0.78rem" }}
                            title="Edit this tool's configuration"
                          >
                            <SettingsIcon size={12} />
                            <span>Configure</span>
                          </button>
                        )}
                      </div>
                    </article>
                  );
                })}
              </div>
            )}

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

        {/* Security merge shell: sandbox isolation plus file guard share one
            pane so the sidenav stays at eight items without losing either
            surface. Both sections save together through the same form. */}
        {activeTab === "security" && (
          <>
            <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Sandbox & Security Policy</h3>
              <p className="settings-section-hint">
                Controls ephemeral Tier-3 detonation isolation and crash-orphan reclamation. Document writes use Seatbelt-confined temp with an atomic move on approval.
                Changes need a restart to take effect.
              </p>
            </div>

            {/* Container Machine (Apple Container microVM for Tier 3 detonation) */}
            <div className="settings-section-title-group" style={{ marginTop: "10px" }}>
              <h4>Apple Container Machine</h4>
              <p className="settings-section-hint">
                MicroVM settings for untrusted external payloads (email attachments, archives). Zero host directory mounts.
              </p>
            </div>
            <div className="form-row">
              {/* Detonation runtime is pinned server-side so every caller shares
                  one spelling; the pane shows the fixed value as text with no
                  editor rather than an input that suggests a choice. */}
              <div className="form-group flex-1">
                <span className="form-group-label">Container Runtime</span>
                <p data-testid="sandbox-container-runtime">
                  <code>container</code>{" "}
                  <span className="muted text-sm">Apple Container CLI (fixed)</span>
                </p>
                <span className="form-group-hint">
                  Tier 3 detonation always uses the Apple Container CLI; no runtime selection.
                </span>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="sandbox-container-base-image">Base Image</label>
                <input
                  id="sandbox-container-base-image"
                  type="text"
                  className="input-field"
                  value={sandboxContainerBaseImage}
                  onChange={(e) => setSandboxContainerBaseImage(e.target.value)}
                  placeholder="alpine:latest"
                  required
                />
                <span className="form-group-hint">
                  OCI base image for detonation microVMs (default "alpine:latest").
                </span>
              </div>
            </div>
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="sandbox-archive-ttl">Archive Session TTL (minutes)</label>
                <input
                  id="sandbox-archive-ttl"
                  type="number"
                  min={1}
                  max={120}
                  step={1}
                  className="input-field"
                  value={sandboxArchiveSessionTTLMinutes}
                  onChange={(e) => setSandboxArchiveSessionTTLMinutes(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Crash-orphan reclamation TTL for ephemeral detonation machines; live detonations reap immediately.
                </span>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="sandbox-max-machines">Max Concurrent Machines</label>
                <input
                  id="sandbox-max-machines"
                  type="number"
                  min={1}
                  max={10}
                  step={1}
                  className="input-field"
                  value={sandboxMaxConcurrentMachines}
                  onChange={(e) => setSandboxMaxConcurrentMachines(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Maximum simultaneous microVM container machines allowed.
                </span>
              </div>
            </div>
            </div>
            {/* File guard stays in the same Security pane below sandbox policy
                so deny-list edits and detonation-policy edits save together. */}
            <div className="settings-section card">
            <div className="settings-section-header">
              <div className="settings-section-title-group">
                <h3>Files & Access</h3>
                <p className="settings-section-hint">
                  Sensitive-path deny list for file tools, mirroring the engine guard.
                  Changes need a restart to take effect.
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
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={handleAddDenyPattern}
                >
                  <PlusIcon size={14} />
                  <span>Add Pattern</span>
                </button>
              </div>
            </div>

            {/* Blocked-paths deny list: multiline editor keeps long guard lists compact;
                blank lines collapse on save and an emptied editor means allow-all in scope,
                with the server guard as the authoritative enforcer. */}
            <div className="settings-section-title-group" style={{ marginTop: "4px" }}>
              <h4 style={{ margin: "0 0 4px 0" }}>Blocked Paths</h4>
              <p className="settings-section-hint">
                One glob per line. Denied paths escalate or fail per the toggle below.
              </p>
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
                ref={denyTextareaRef}
                className="input-field deny-patterns-textarea"
                aria-label="Deny patterns, one per line"
                value={filesDenyText}
                onChange={(e) => setFilesDenyText(e.target.value)}
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

            {/* Allowed roots stay row-based (small N) with Reset-then-Add in
                the subsection header to mirror Files & Access; both use the
                ghost icon treatment so hover and alignment match. */}
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
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={handleAddAllowRoot}
                >
                  <PlusIcon size={14} />
                  <span>Add Root</span>
                </button>
              </div>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
              {filesAllowRoots.map((root, index) => (
                <div
                  key={`allow-${index}`}
                  style={{ display: "flex", gap: "8px", alignItems: "center" }}
                >
                  <div className="form-group" style={{ flex: 1, margin: 0 }}>
                    <label htmlFor={`allow-root-${index}`} className="sr-only">
                      Allowed root {index + 1}
                    </label>
                    <input
                      id={`allow-root-${index}`}
                      type="text"
                      className="input-field"
                      aria-label={`Allowed root ${index + 1}`}
                      value={root}
                      onChange={(e) => handleAllowRootChange(index, e.target.value)}
                      placeholder="e.g. ~"
                      required
                    />
                  </div>
                  <button
                    type="button"
                    className="icon-button danger"
                    onClick={() => handleRemoveAllowRoot(index)}
                    title={`Remove allowed root ${index + 1}`}
                    aria-label={`Remove allowed root ${index + 1}`}
                  >
                    <TrashIcon size={14} />
                  </button>
                </div>
              ))}
            </div>
            <div className="form-group checkbox-group" style={{ marginTop: "16px" }}>
              <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
                <input
                  id="files-require-approval"
                  type="checkbox"
                  checked={filesRequireApprovalOnDeny}
                  onChange={(e) => setFilesRequireApprovalOnDeny(e.target.checked)}
                />
                <span>Require approval on deny</span>
              </label>
              <span className="form-group-hint">
                When on, denied paths escalate to the approvals inbox instead of failing silently.
              </span>
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
            {/* Form-local reset confirmations share the modal so destructive
                rewrites stay explicit: counts show what is lost and the copy
                stresses nothing persists until Save. */}
            {pendingResetDeny ? (
              <Modal
                label="Confirm reset deny patterns"
                onClose={handleCancelResetDenyPatterns}
                containerClassName="modal-container session-delete-modal"
              >
                <div className="modal-header">
                  <h3>Reset deny patterns?</h3>
                  <button
                    type="button"
                    className="icon-button"
                    onClick={handleCancelResetDenyPatterns}
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
                    form — nothing is saved until you choose Save Settings.
                  </p>
                </div>
                <div className="modal-footer">
                  <button
                    type="button"
                    className="ghost"
                    onClick={handleCancelResetDenyPatterns}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="danger"
                    onClick={handleConfirmResetDenyPatterns}
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
                onClose={handleCancelResetAllowRoots}
                containerClassName="modal-container session-delete-modal"
              >
                <div className="modal-header">
                  <h3>Reset allowed roots?</h3>
                  <button
                    type="button"
                    className="icon-button"
                    onClick={handleCancelResetAllowRoots}
                    aria-label="Close"
                  >
                    <CloseIcon size={16} />
                  </button>
                </div>
                <div className="modal-body">
                  <p className="muted" style={{ margin: 0 }}>
                    This will replace {filesAllowRoots.length}{" "}
                    {filesAllowRoots.length === 1 ? "custom root" : "custom roots"} with{" "}
                    {DEFAULT_FILES_ALLOW_ROOTS.length}{" "}
                    {DEFAULT_FILES_ALLOW_ROOTS.length === 1 ? "default" : "defaults"} (
                    {DEFAULT_FILES_ALLOW_ROOTS.join(", ")}). This only updates the form —
                    nothing is saved until you choose Save Settings.
                  </p>
                </div>
                <div className="modal-footer">
                  <button
                    type="button"
                    className="ghost"
                    onClick={handleCancelResetAllowRoots}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="danger"
                    onClick={handleConfirmResetAllowRoots}
                    aria-label="Confirm reset allowed roots"
                  >
                    Reset Roots
                  </button>
                </div>
              </Modal>
            ) : null}
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
                            value={acc.smtp_host ?? acc.smtpHost ?? ""}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "smtp_host", e.target.value)
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
                            value={acc.smtp_port ?? acc.smtpPort ?? ""}
                            onChange={(e) =>
                              handleEmailFieldChange(
                                item.id,
                                "smtp_port",
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
                            value={acc.smtp_security ?? acc.smtpSecurity ?? "auto"}
                            onChange={(e) =>
                              handleEmailFieldChange(item.id, "smtp_security", e.target.value)
                            }
                          >
                            <option value="auto">Auto (STARTTLS then SSL)</option>
                            <option value="starttls">STARTTLS</option>
                            <option value="ssl">SSL (implicit TLS)</option>
                          </select>
                        </div>
                      </div>

                      <div className="email-env-hint">
                        <span>Password resolved via SecretsManager from:</span>
                        <code>{passwordEnv}</code>
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

      {/* Browser and Web tools configuration modal (browser.navigate, browser.act, web.fetch).
          Configures homelab allowlist patterns and displays auto-allowed media servers. */}
      {configuringToolName === "browser.navigate" ||
      configuringToolName === "browser.act" ||
      configuringToolName === "web.fetch" ? (
        <Modal
          label="Configure Browser & Web Automation"
          onClose={() => {
            if (!browserSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Browser & Web Automation</h3>
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
              Configure allowed homelab hosts and domain patterns for <code>browser.navigate</code>, <code>browser.act</code>, and <code>web.fetch</code>.
              Requests to private RFC 1918 IPs and internal networks are blocked by default to prevent SSRF, but allowed origins and auto-allowed services can be safely accessed.
            </p>

            {/* Auto-Allowed Services Card */}
            <div style={{ padding: "14px", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)", marginBottom: "16px", backgroundColor: "var(--bg-secondary, #141822)" }}>
              <h4 style={{ margin: "0 0 6px 0", fontSize: "0.88rem" }}>Auto-Allowed Services</h4>
              <p className="muted text-sm" style={{ margin: "0 0 10px 0" }}>
                Configured media automation servers and SearXNG are automatically trusted and exempt from SSRF blocking without needing to be re-entered.
              </p>
              <div style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", fontSize: "0.85rem", padding: "6px 10px", borderRadius: "6px", backgroundColor: "var(--bg-tertiary, #1a202c)" }}>
                  <span style={{ fontWeight: 500 }}>Sonarr (TV Shows)</span>
                  {sonarrUrl.trim() ? (
                    <span className="badge badge-success" style={{ fontSize: "0.75rem" }}>
                      {sonarrUrl.trim()}
                    </span>
                  ) : (
                    <span className="muted text-xs">Not configured</span>
                  )}
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", fontSize: "0.85rem", padding: "6px 10px", borderRadius: "6px", backgroundColor: "var(--bg-tertiary, #1a202c)" }}>
                  <span style={{ fontWeight: 500 }}>Radarr (Movies)</span>
                  {radarrUrl.trim() ? (
                    <span className="badge badge-success" style={{ fontSize: "0.75rem" }}>
                      {radarrUrl.trim()}
                    </span>
                  ) : (
                    <span className="muted text-xs">Not configured</span>
                  )}
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", fontSize: "0.85rem", padding: "6px 10px", borderRadius: "6px", backgroundColor: "var(--bg-tertiary, #1a202c)" }}>
                  <span style={{ fontWeight: 500 }}>SearXNG (Search)</span>
                  {searchSearxngURL.trim() ? (
                    <span className="badge badge-success" style={{ fontSize: "0.75rem" }}>
                      {searchSearxngURL.trim()}
                    </span>
                  ) : (
                    <span className="muted text-xs">Not configured</span>
                  )}
                </div>
              </div>
            </div>

            {/* Allowed Origins Multiline Textarea */}
            <div className="form-group" style={{ marginBottom: "10px" }}>
              <label htmlFor="browser-allowed-origins-textarea" style={{ fontSize: "0.85rem", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span>
                  Allowed Hosts & Domains{" "}
                  <span className="muted text-sm">
                    ({parseAllowedOriginsText(browserAllowedOriginsText).length}{" "}
                    {parseAllowedOriginsText(browserAllowedOriginsText).length === 1 ? "host" : "hosts"})
                  </span>
                </span>
              </label>
              <textarea
                id="browser-allowed-origins-textarea"
                className="input-field allowed-origins-textarea"
                value={browserAllowedOriginsText}
                onChange={(e) => setBrowserAllowedOriginsText(e.target.value)}
                placeholder={"*.homelab.local\n192.168.1.*\nhomeassistant.local\n10.0.0.5:8123"}
              />
              <span className="form-group-hint" style={{ marginTop: "4px", display: "block" }}>
                One host, domain pattern, or IP pattern per line. Supports exact hostnames (e.g. <code>nas.local</code>),
                exact origins with ports (e.g. <code>192.168.1.50:8080</code>), or wildcards (e.g. <code>*.homelab.local</code> or <code>192.168.1.*</code>). Blank lines are ignored.
              </span>
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
                <label htmlFor="sonarr-key-env" style={{ fontSize: "0.82rem" }}>API Key Environment Variable / Keychain Key</label>
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
                <label htmlFor="radarr-key-env" style={{ fontSize: "0.82rem" }}>API Key Environment Variable / Keychain Key</label>
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
      ) : configuringToolName === "desktop.screenshot" ? (
        <Modal
          label="Configure Desktop Screenshot"
          onClose={() => {
            if (!desktopSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Desktop Screenshot</h3>
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
              Read-only display or app-window capture with downscaled JPEG plus
              coordinate metadata for control actions. Captures stay in memory
              for the turn with only the content hash plus dimensions retained
              afterwards.
            </p>

            {/* Capture knobs */}
            <div className="form-row" style={{ display: "flex", gap: "10px", marginBottom: "10px" }}>
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
      ) : configuringToolName === "desktop.action" ? (
        <Modal
          label="Configure Desktop Control"
          onClose={() => {
            if (!desktopSaveLoading) setConfiguringToolName(null);
          }}
          containerClassName="modal-container"
        >
          <div className="modal-header">
            <h3>Configure Desktop Control</h3>
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
              Approval-gated mouse, keyboard, and app-switch actions. Every batch
              parks in the approvals inbox and never runs without approval.
            </p>

            {/* Blocked apps */}
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
    </section>
  );
}
