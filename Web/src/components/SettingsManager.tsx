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
  DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES,
  DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE,
  DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES,
  DEFAULT_SEARCH_MAX_RESULTS,
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
  ensureSearch,
  getSearchHealth,
  getSettings,
  resolveSearchDiagnostics,
  resolveSearchMessage,
  resolveSearchURL,
  updateSettings,
  getPlugins,
  rescanPlugins,
  stopSearch,
  updatePluginState,
  uninstallPlugin,
  getTools,
  updateToolState,
  type EmailAccountData,
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
  MicIcon,
  PlusIcon,
  RefreshIcon,
  SearchIcon,
  SettingsIcon,
  StopIcon,
  TrashIcon,
  WrenchIcon,
} from "./icons";
import Modal from "./Modal";
import RuneMarketplaceModal from "./RuneMarketplaceModal";

// Eight-item vertical navigation keeps every category visible without horizontal scrolling; sandbox
// and file policy share one Security pane so the sidebar stays within the width budget as settings
// grow.
type SettingsTab =
  | "providers"
  | "engine"
  | "tools"
  | "security"
  | "memory"
  | "voice"
  | "search"
  | "email";

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

export default function SettingsManager() {
  const [settings, setSettings] = useState<SettingsResponse | null>(null);
  const [activeTab, setActiveTab] = useState<SettingsTab>("providers");
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  // Form state
  const [engineName, setEngineName] = useState("");
  const [logLevel, setLogLevel] = useState("info");
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
  // Live container health for the Search pane: probed on tab open and updated
  // directly from Start/Stop action responses so the health line stays honest
  // without a page reload or an extra probe round-trip.
  const [searchReachable, setSearchReachable] = useState<boolean | null>(null);
  const [searchHealthURL, setSearchHealthURL] = useState<string | null>(null);
  const [searchHealthLoading, setSearchHealthLoading] = useState(false);
  // Tracks which lifecycle action is in flight so Start shows Starting… and
  // Stop shows Stopping… instead of sharing one misleading Starting… label.
  const [searchAction, setSearchAction] = useState<"start" | "stop" | null>(
    null
  );
  const searchActionBusy = searchAction !== null;
  const [searchHealthError, setSearchHealthError] = useState<string | null>(
    null
  );
  // Chained per-stage detail for the optional collapsed diagnostics element.
  // The inline banner stays trimmed to terminal cause plus one remediation;
  // this holds the full stage chain for operators without nesting it in the banner.
  const [searchDiagnostics, setSearchDiagnostics] = useState<string | null>(
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
  // Tracks the single builtin tool row with an in-flight toggle so sibling
  // rows stay interactive while one request is pending.
  const [togglingToolName, setTogglingToolName] = useState<string | null>(null);
  const [pluginActionError, setPluginActionError] = useState<string | null>(null);
  const [pluginActionSuccess, setPluginActionSuccess] = useState<string | null>(null);

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

  // Refreshes the Search pane health line without touching the settings form: Start/Stop change
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
        setSearchHealthURL(resolveSearchURL(response, "") || null);
        // Health carries no diagnostics today; clear the collapsed slot so a
        // prior ensure failure never lingers beside fresh health.
        setSearchDiagnostics(resolveSearchDiagnostics(response));
      } else {
        setSearchReachable(null);
        setSearchHealthURL(null);
        setSearchHealthError(
          "Search health returned an unexpected response; status unknown."
        );
      }
    } catch (err) {
      setSearchReachable(null);
      setSearchHealthURL(null);
      setSearchDiagnostics(null);
      setSearchHealthError(
        err instanceof Error ? err.message : "Search health check failed."
      );
    } finally {
      setSearchHealthLoading(false);
    }
  }, []);

  const handleEnsureSearch = async () => {
    setSearchAction("start");
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    try {
      const response = await ensureSearch();
      // Honest tri-state: only a boolean reachable flag may move the dot; shape-drifted payloads
      // preserve the previous state and surface an inline error instead of optimistically flipping.
      // A failed start (reachable false) renders the trimmed banner in the existing error slot
      // with chained detail in the collapsed diagnostics below, instead of flipping silently to red.
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchHealthURL(resolveSearchURL(response, searchSearxngURL));
        setSearchDiagnostics(resolveSearchDiagnostics(response));
        if (!response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(detail ?? "Search start failed; status unchanged.");
        }
      } else {
        setSearchHealthError(
          "Search start returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setSearchHealthError(
        err instanceof Error ? err.message : "Failed to start search."
      );
    } finally {
      setSearchAction(null);
    }
  };

  const handleStopSearch = async () => {
    setSearchAction("stop");
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    try {
      const response = await stopSearch();
      // Honest tri-state: only a boolean reachable flag may move the dot; shape-drifted payloads
      // preserve the previous state and surface an inline error instead of claiming stopped.
      // A failed stop (still reachable) surfaces its message; a clean stop clears the slot.
      // Stop carries no chained diagnostics today, but the slot clears symmetrically with ensure.
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchHealthURL(resolveSearchURL(response, searchSearxngURL));
        setSearchDiagnostics(resolveSearchDiagnostics(response));
        if (response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(detail ?? "Search stop failed; still reachable.");
        }
      } else {
        setSearchHealthError(
          "Search stop returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setSearchHealthError(
        err instanceof Error ? err.message : "Failed to stop search."
      );
    } finally {
      setSearchAction(null);
    }
  };

  const handleRescanPlugins = async () => {
    setRescanLoading(true);
    setPluginActionError(null);
    setPluginActionSuccess(null);
    try {
      const res = await rescanPlugins();
      setPluginsList(Array.isArray(res?.plugins) ? res.plugins : []);
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      setPluginActionSuccess(`Discovered ${res.plugins?.length ?? 0} external runes.`);
    } catch (err) {
      setPluginActionError(err instanceof Error ? err.message : "Failed to rescan plugins.");
    } finally {
      setRescanLoading(false);
    }
  };

  const handleToggleEnable = async (plugin: PluginSummary) => {
    setUpdatingPluginId(plugin.id);
    setPluginActionError(null);
    setPluginActionSuccess(null);
    try {
      const action = plugin.isEnabled ? "disable" : "enable";
      const updated = await updatePluginState(plugin.id, { action });
      setPluginsList((prev) => prev.map((p) => (p.id === updated.id ? updated : p)));
      const toolsRes = await getTools();
      setAllTools(toolsRes.tools);
      setPluginActionSuccess(
        updated.isEnabled
          ? `Enabled rune '${updated.name}' (integrity hash verified).`
          : `Disabled rune '${updated.name}'.`
      );
    } catch (err) {
      setPluginActionError(err instanceof Error ? err.message : "Failed to update plugin state.");
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
    setPluginActionError(null);
    setPluginActionSuccess(null);
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
      setPluginActionSuccess(`Updated permission for '${toolName}' to ${value}.`);
    } catch (err) {
      setPluginActionError(err instanceof Error ? err.message : "Failed to override permission.");
    } finally {
      setUpdatingPluginId(null);
    }
  };

  async function confirmUninstallPlugin() {
    if (!pendingUninstallPlugin) return;
    const { id: pluginId, name } = pendingUninstallPlugin;
    setUpdatingPluginId(pluginId);
    setPluginActionError(null);
    setPluginActionSuccess(null);
    try {
      await uninstallPlugin(pluginId);
      setPluginsList((prev) => prev.filter((p) => p.id !== pluginId));
      const toolsRes = await getTools();
      setAllTools(toolsRes.tools);
      setPluginActionSuccess(`Uninstalled '${name}'.`);
      setPendingUninstallPlugin(null);
    } catch (err) {
      setPluginActionError(err instanceof Error ? err.message : "Failed to uninstall plugin.");
    } finally {
      setUpdatingPluginId(null);
    }
  }

  function cancelUninstallPlugin() {
    setPendingUninstallPlugin(null);
  }

  // Flips one builtin engine tool without a protected list: every builtin toggles independently so
  // closely related tools (email.read vs email.attachment) never change together.
  const handleToggleTool = async (tool: ToolInfo) => {
    const nextEnabled = !tool.isEnabled;
    setTogglingToolName(tool.name);
    setPluginActionError(null);
    setPluginActionSuccess(null);
    try {
      await updateToolState(tool.name, nextEnabled);
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      setPluginActionSuccess(
        nextEnabled ? `Enabled tool '${tool.name}'.` : `Disabled tool '${tool.name}'.`
      );
    } catch (err) {
      setPluginActionError(err instanceof Error ? err.message : `Failed to update tool '${tool.name}'.`);
    } finally {
      setTogglingToolName(null);
    }
  };

  const populateForm = useCallback((data: SettingsResponse) => {
    setSettings(data);
    setEngineName(data.engineName);
    setLogLevel(data.logLevel);
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
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await getSettings();
      populateForm(data);
      void loadPluginsData();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to load settings");
    } finally {
      setLoading(false);
    }
  }, [populateForm, loadPluginsData]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Loads live container health when the Search pane opens so the health
  // line reflects the running container rather than the saved URL alone.
  // Runs on tab entry only; Start/Stop update directly from their action
  // response without an extra probe so the health line never flashes stale.
  useEffect(() => {
    if (activeTab === "search") {
      void refreshSearchHealth();
    }
  }, [activeTab, refreshSearchHealth]);

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    setError(null);
    setSuccess(null);

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
      const updated = await updateSettings({
        engineName,
        logLevel,
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
        searchSearxngURL: trimmedSearxngURL,
        searchTimeoutSeconds: timeoutNum,
        searchMaxResults: maxResultsNum,
        emailAccounts,
        pluginsDir,
        pluginsMarketplaceIndexURL,
        pluginsAutoRescan,
      });
      populateForm(updated);
      // Settings persist to the config file only; live providers, system
      // prompt, and memory pick them up after a restart.
      setSuccess(
        `Settings saved successfully to ${updated.configPath}. Restart engine/app to apply.`
      );
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to save settings");
    } finally {
      setSaving(false);
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
      {success && <div className="success-banner">{success}</div>}

      {/* Vertical sidenav: stacked categories beside the content pane so every
          section stays visible without horizontal scrolling. */}
      <div className="settings-layout">
        <nav className="settings-sidenav" aria-label="Settings categories" role="tablist">
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "providers"}
            className={`settings-tab-btn ${activeTab === "providers" ? "active" : ""}`}
            onClick={() => setActiveTab("providers")}
          >
            <ChatIcon size={16} />
            <span>LLM Providers</span>
            <span className="settings-tab-badge">{providersList.length}</span>
          </button>

          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "engine"}
            className={`settings-tab-btn ${activeTab === "engine" ? "active" : ""}`}
            onClick={() => setActiveTab("engine")}
          >
            <SettingsIcon size={16} />
            <span>Engine and Logs</span>
          </button>

          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "tools"}
            className={`settings-tab-btn ${activeTab === "tools" ? "active" : ""}`}
            onClick={() => setActiveTab("tools")}
          >
            <WrenchIcon size={16} />
            <span>Tools and Runes</span>
            {/* Pending and tampered counts stay on the nav item so review and
                quarantine signals remain visible without opening the pane. */}
            {pendingCount > 0 ? (
              <span
                className="settings-tab-badge"
                style={{ backgroundColor: "#ed8936", color: "#ffffff" }}
                title={`${pendingCount} runes pending human review`}
              >
                {pendingCount}
              </span>
            ) : (
              <span className="settings-tab-badge">{pluginsList.length}</span>
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
            onClick={() => setActiveTab("security")}
          >
            <ApprovalsIcon size={16} />
            <span>Security</span>
            {denyPatternCount > 0 && (
              <span className="settings-tab-badge">{denyPatternCount}</span>
            )}
          </button>

          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "memory"}
            className={`settings-tab-btn ${activeTab === "memory" ? "active" : ""}`}
            onClick={() => setActiveTab("memory")}
          >
            <MemoryIcon size={16} />
            <span>Memory and Storage</span>
          </button>

          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "voice"}
            className={`settings-tab-btn ${activeTab === "voice" ? "active" : ""}`}
            onClick={() => setActiveTab("voice")}
          >
            <MicIcon size={16} />
            <span>Voice</span>
          </button>

          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "search"}
            className={`settings-tab-btn ${activeTab === "search" ? "active" : ""}`}
            onClick={() => setActiveTab("search")}
          >
            <SearchIcon size={16} />
            <span>Search</span>
          </button>

          <button
            type="button"
            role="tab"
            aria-selected={activeTab === "email"}
            className={`settings-tab-btn ${activeTab === "email" ? "active" : ""}`}
            onClick={() => setActiveTab("email")}
          >
            <MailIcon size={16} />
            <span>Email Accounts</span>
            {emailAccountsList.length > 0 && (
              <span className="settings-tab-badge">{emailAccountsList.length}</span>
            )}
          </button>
        </nav>

        <div className="settings-content">
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

            {pluginActionError && (
              <div className="error-banner" style={{ marginBottom: "14px", display: "flex", alignItems: "center", gap: "8px" }}>
                <AlertTriangleIcon size={16} />
                <span>{pluginActionError}</span>
              </div>
            )}
            {pluginActionSuccess && (
              <div className="success-banner" style={{ marginBottom: "14px", display: "flex", alignItems: "center", gap: "8px" }}>
                <CheckIcon size={16} />
                <span>{pluginActionSuccess}</span>
              </div>
            )}

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
              <span className="settings-tab-badge">{pluginsList.length}</span>
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
              <span className="settings-tab-badge">{safeTools.filter((t) => t.isBuiltIn).length}</span>
            </h4>

            <div style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
              {safeTools.filter((t) => t.isBuiltIn).map((tool) => {
                const isToggling = togglingToolName === tool.name;
                return (
                  <div
                    key={tool.name}
                    style={{
                      display: "flex",
                      justifyContent: "space-between",
                      alignItems: "center",
                      padding: "10px 12px",
                      borderRadius: "6px",
                      backgroundColor: "var(--bg-card, #1e2533)",
                      border: "1px solid var(--border-color, #2d3748)",
                      gap: "12px",
                    }}
                  >
                    <div style={{ minWidth: 0 }}>
                      <div style={{ display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" }}>
                        <code style={{ fontWeight: 600, fontSize: "0.85rem", color: "#48bb78" }}>{tool.name}</code>
                        <span style={{ fontSize: "0.7rem", padding: "1px 5px", borderRadius: "3px", backgroundColor: "#2d3748", color: "#a0aec0" }}>
                          {tool.permissionLevel}
                        </span>
                      </div>
                      <p style={{ margin: "4px 0 0 0", fontSize: "0.78rem", color: "var(--text-secondary, #a0aec0)", lineHeight: "1.3" }}>
                        {tool.description}
                      </p>
                    </div>
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
                  </div>
                );
              })}
            </div>

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

        {/* Search pane: SearXNG URL plus request limits and container
            lifecycle. Config edits save through the form; Start/Stop act
            immediately on the container so health stays honest. */}
        {activeTab === "search" && (
          <div className="settings-section card">
            <div className="settings-section-header">
              <div className="settings-section-title-group">
                <h3>Web Search</h3>
                <p className="settings-section-hint">
                  SearXNG runs locally for private web search. No Docker needed,
                  it uses the Apple Container CLI. First start pulls the SearXNG
                  image (about 150 MB), later starts reuse it.
                </p>
              </div>
              <div className="row">
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={() => void handleEnsureSearch()}
                  disabled={searchActionBusy}
                  aria-label="Start SearXNG"
                >
                  <SearchIcon size={14} />
                  <span>
                    {searchAction === "start" ? "Starting…" : "Start SearXNG"}
                  </span>
                </button>
                <button
                  type="button"
                  className="ghost icon-text-btn"
                  onClick={() => void handleStopSearch()}
                  disabled={searchActionBusy}
                  aria-label="Stop SearXNG"
                >
                  <StopIcon size={14} />
                  <span>
                    {searchAction === "stop" ? "Stopping…" : "Stop SearXNG"}
                  </span>
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
            {/* Pill carries the tri-state for at-a-glance scanning while the URL stays muted
                beside it so the probed endpoint remains visible without repeating the sentence. */}
            <span
              data-testid="search-health-text"
              className="search-health-line"
              title={searchHealthURL || searchSearxngURL}
            >
              {searchHealthLoading ? (
                <span className="muted text-sm">Checking search health…</span>
              ) : searchReachable === null ? (
                <>
                  <span className="status-pill skipped">Unknown</span>
                  <span className="muted text-sm search-health-url">
                    {searchHealthURL || searchSearxngURL}
                  </span>
                </>
              ) : searchReachable ? (
                <>
                  <span className="status-pill ok">Reachable</span>
                  <span className="muted text-sm search-health-url">
                    {searchHealthURL || searchSearxngURL}
                  </span>
                </>
              ) : (
                <>
                  <span className="status-pill error">Stopped</span>
                  <span className="muted text-sm search-health-url">
                    {searchHealthURL || searchSearxngURL}
                  </span>
                </>
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

        <div className="settings-footer">
          <button
            type="submit"
            className="primary-button save-button"
            disabled={saving}
          >
            {saving ? "Saving Changes..." : "Save Settings to config.toml"}
          </button>
        </div>
          </form>
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
    </section>
  );
}
