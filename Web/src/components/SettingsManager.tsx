// Rune Weaver Dashboard — Settings manager for config.toml configuration.
// Allows managing LLM providers, engine identity, sandbox policy, memory, voice, and email accounts.

import React, { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS,
  DEFAULT_SANDBOX_CLEANUP_INTERVAL_SECONDS,
  DEFAULT_SANDBOX_MAX_TOTAL_BYTES,
  DEFAULT_SANDBOX_RETENTION_DAYS,
  getSettings,
  updateSettings,
  getPlugins,
  rescanPlugins,
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
  MailIcon,
  MemoryIcon,
  PlusIcon,
  RefreshIcon,
  SettingsIcon,
  TrashIcon,
  WrenchIcon,
} from "./icons";
import RuneMarketplaceModal from "./RuneMarketplaceModal";

type SettingsTab = "providers" | "engine" | "tools" | "sandbox" | "files" | "memory" | "voice" | "email";

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
  const [sandboxStagingPath, setSandboxStagingPath] = useState("");
  // Sandbox retention caps single-sourced via api.ts defaults mirroring
  // SandboxConfig so a fresh dashboard without stored values still shows
  // the bounded-staging policy before the first fetch resolves.
  const [sandboxRetentionDays, setSandboxRetentionDays] = useState(
    DEFAULT_SANDBOX_RETENTION_DAYS
  );
  const [sandboxMaxTotalBytes, setSandboxMaxTotalBytes] = useState(
    DEFAULT_SANDBOX_MAX_TOTAL_BYTES
  );
  const [sandboxCleanupIntervalSeconds, setSandboxCleanupIntervalSeconds] = useState(
    DEFAULT_SANDBOX_CLEANUP_INTERVAL_SECONDS
  );
  // File access policy mirrors FilesConfig defaults so the deny list stays
  // visible even when an older engine omits the [files] section.
  const [filesDenyPatterns, setFilesDenyPatterns] = useState<string[]>([
    ...DEFAULT_FILES_DENY_PATTERNS,
  ]);
  const [filesAllowRoots, setFilesAllowRoots] = useState<string[]>([
    ...DEFAULT_FILES_ALLOW_ROOTS,
  ]);
  const [filesRequireApprovalOnDeny, setFilesRequireApprovalOnDeny] = useState(true);
  const [memoryVectorDBPath, setMemoryVectorDBPath] = useState("");
  const [memoryEpisodesDBPath, setMemoryEpisodesDBPath] = useState("");
  const [memoryEmbeddingModel, setMemoryEmbeddingModel] = useState("");
  const [memoryEmbeddingBackend, setMemoryEmbeddingBackend] = useState("apple");
  const [voiceSTTProvider, setVoiceSTTProvider] = useState("");
  const [voiceWhisperModel, setVoiceWhisperModel] = useState("");
  const [voiceTTSProvider, setVoiceTTSProvider] = useState("");
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

  const handleUninstall = async (pluginId: string, name: string) => {
    if (!window.confirm(`Are you sure you want to uninstall and remove '${name}'?`)) {
      return;
    }
    setUpdatingPluginId(pluginId);
    setPluginActionError(null);
    setPluginActionSuccess(null);
    try {
      await uninstallPlugin(pluginId);
      setPluginsList((prev) => prev.filter((p) => p.id !== pluginId));
      const toolsRes = await getTools();
      setAllTools(toolsRes.tools);
      setPluginActionSuccess(`Uninstalled '${name}'.`);
    } catch (err) {
      setPluginActionError(err instanceof Error ? err.message : "Failed to uninstall plugin.");
    } finally {
      setUpdatingPluginId(null);
    }
  };

  // Flips one builtin engine tool without a protected list: every builtin
  // toggles independently so closely related tools (email.read vs
  // email.attachment) never change together. Only the acted-on row disables
  // while its request is in flight, and the list refreshes from the server so
  // the switch always reflects the persisted bus state.
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

    setSandboxStagingPath(data.sandboxStagingPath);
    setSandboxRetentionDays(data.sandboxRetentionDays ?? DEFAULT_SANDBOX_RETENTION_DAYS);
    setSandboxMaxTotalBytes(data.sandboxMaxTotalBytes ?? DEFAULT_SANDBOX_MAX_TOTAL_BYTES);
    setSandboxCleanupIntervalSeconds(
      data.sandboxCleanupIntervalSeconds ?? DEFAULT_SANDBOX_CLEANUP_INTERVAL_SECONDS
    );
    setFilesDenyPatterns(
      Array.isArray(data.filesDenyPatterns)
        ? [...data.filesDenyPatterns]
        : [...DEFAULT_FILES_DENY_PATTERNS]
    );
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
      // Absent context_length means backend-default (nil), so only send a
      // Number when the user entered a value; empty stays omitted. Present
      // values fail closed on non-positive or non-integer input instead of
      // coercing to the backend default, mirroring Config+Validation.
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

    // Deny patterns fail closed on blanks and `..` escapes so a bad row
    // never persists a traversal into the policy file; the server enforces
    // the same rule, but surfacing it here avoids a round-trip.
    for (const pattern of filesDenyPatterns) {
      const trimmed = pattern.trim();
      if (!trimmed) {
        setError("Deny patterns cannot be empty.");
        setSaving(false);
        return;
      }
      if (trimmed.includes("..")) {
        setError(`Deny pattern must not contain '..': "${trimmed}".`);
        setSaving(false);
        return;
      }
    }
    for (const root of filesAllowRoots) {
      const trimmed = root.trim();
      if (!trimmed) {
        setError("Allowed roots cannot be empty.");
        setSaving(false);
        return;
      }
      if (trimmed.includes("..")) {
        setError(`Allowed root must not contain '..': "${trimmed}".`);
        setSaving(false);
        return;
      }
    }

    // Reassemble email accounts array, preserving optional SMTP overrides.
    // Blank smtp_host collapses to omitted (derived fallback) and blank
    // smtp_port omits so auto tries 587 then 465; smtp_security defaults
    // to auto when blank or unknown.
    // Incomplete rows abort instead of silently dropping so a half-filled
    // row never vanishes on save; mirrors the provider-name checks above.
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
    // SMTP ports follow the same range when set.
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
        if (!Number.isInteger(smtpNum) || smtpNum < 1 || smtpNum > 65535) {
          setError(
            `Invalid SMTP port for email account "${label}": smtp_port must be between 1 and 65535.`
          );
          setSaving(false);
          return;
        }
      }
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
        sandboxStagingPath,
        sandboxRetentionDays: Number(sandboxRetentionDays),
        sandboxMaxTotalBytes: Number(sandboxMaxTotalBytes),
        sandboxCleanupIntervalSeconds: Number(sandboxCleanupIntervalSeconds),
        filesDenyPatterns: filesDenyPatterns.map((p) => p.trim()).filter(Boolean),
        filesAllowRoots: filesAllowRoots.map((r) => r.trim()).filter(Boolean),
        filesRequireApprovalOnDeny,
        memoryVectorDBPath,
        memoryEpisodesDBPath,
        memoryEmbeddingModel: preservedEmbeddingModel,
        memoryEmbeddingBackend,
        voiceSTTProvider,
        voiceWhisperModel,
        voiceTTSProvider,
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
          // An empty context-length input means backend-default (nil), so
          // clear both aliases. Non-empty values (including NaN from invalid
          // input) are preserved on both aliases so handleSave can fail
          // closed instead of silently falling back to the backend default.
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

  // Files deny-list CRUD helpers: rows are plain strings so add/remove stays
  // index-based; reset restores the guard-mirroring defaults instead of
  // clearing to an unprotected empty list.
  const handleAddDenyPattern = () => {
    setFilesDenyPatterns((prev) => [...prev, ""]);
  };

  const handleRemoveDenyPattern = (index: number) => {
    setFilesDenyPatterns((prev) => prev.filter((_, i) => i !== index));
  };

  const handleDenyPatternChange = (index: number, value: string) => {
    setFilesDenyPatterns((prev) => prev.map((p, i) => (i === index ? value : p)));
  };

  const handleResetDenyPatterns = () => {
    setFilesDenyPatterns([...DEFAULT_FILES_DENY_PATTERNS]);
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

  const handleResetAllowRoots = () => {
    setFilesAllowRoots([...DEFAULT_FILES_ALLOW_ROOTS]);
  };

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
            Manage LLM model routing, engine parameters, sandbox security, and email accounts.
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

      {/* Sub-Tabs Navigation */}
      <nav className="settings-subtabs" aria-label="Settings categories">
        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "providers" ? "active" : ""}`}
          onClick={() => setActiveTab("providers")}
        >
          <ChatIcon size={16} />
          <span>LLM Providers</span>
          <span className="settings-tab-badge">{providersList.length}</span>
        </button>

        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "engine" ? "active" : ""}`}
          onClick={() => setActiveTab("engine")}
        >
          <SettingsIcon size={16} />
          <span>Engine & Logs</span>
        </button>

        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "tools" ? "active" : ""}`}
          onClick={() => setActiveTab("tools")}
        >
          <WrenchIcon size={16} />
          <span>Tools & Runes</span>
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
        </button>

        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "sandbox" ? "active" : ""}`}
          onClick={() => setActiveTab("sandbox")}
        >
          <ApprovalsIcon size={16} />
          <span>Sandbox & Trust</span>
        </button>

        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "files" ? "active" : ""}`}
          onClick={() => setActiveTab("files")}
        >
          <ApprovalsIcon size={16} />
          <span>Files & Access</span>
          {filesDenyPatterns.length > 0 && (
            <span className="settings-tab-badge">{filesDenyPatterns.length}</span>
          )}
        </button>

        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "memory" ? "active" : ""}`}
          onClick={() => setActiveTab("memory")}
        >
          <MemoryIcon size={16} />
          <span>Memory & Storage</span>
        </button>

        <button
          type="button"
          className={`settings-tab-btn ${activeTab === "voice" ? "active" : ""}`}
          onClick={() => setActiveTab("voice")}
        >
          <span>Voice</span>
        </button>

        <button
          type="button"
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
                className="secondary-button"
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
            <div className="settings-section-title-group" style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", flexWrap: "wrap", gap: "12px" }}>
              <div>
                <h3>Tools & Runes</h3>
                <p className="settings-section-hint">
                  Manage internal and external tools. Discovered and newly installed runes remain disabled by default until reviewed and approved.
                </p>
              </div>
              <div style={{ display: "flex", gap: "8px" }}>
                {/* Marketplace entry points stay hidden while the catalog UX is
                    deferred; the modal remains mounted below so re-enabling is
                    UI-only and server routes stay untouched. */}
                <button
                  type="button"
                  className="secondary-button"
                  onClick={handleRescanPlugins}
                  disabled={rescanLoading}
                  style={{ display: "flex", alignItems: "center", gap: "6px" }}
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
                            className={plugin.isEnabled ? "secondary-button" : "primary-button"}
                            onClick={() => handleToggleEnable(plugin)}
                            disabled={updatingPluginId === plugin.id}
                            style={{
                              padding: "5px 12px",
                              fontSize: "0.85rem",
                            }}
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
                            onClick={() => handleUninstall(plugin.id, plugin.name)}
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
                      {/* Redundant status pill mirrors the switch for at-a-glance
                          scanning; colors reuse the rune status tokens (green for
                          on, muted for off). */}
                      <span
                        className="tool-status-pill"
                        data-state={tool.isEnabled ? "enabled" : "disabled"}
                        style={
                          tool.isEnabled
                            ? {
                                backgroundColor: "rgba(72, 187, 120, 0.2)",
                                color: "#48bb78",
                              }
                            : {
                                backgroundColor: "rgba(160, 174, 192, 0.2)",
                                color: "#a0aec0",
                              }
                        }
                      >
                        {tool.isEnabled ? "Enabled" : "Disabled"}
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

        {/* TAB: Sandbox & Trust (staging path plus retention caps) */}
        {activeTab === "sandbox" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Sandbox & Security Policy</h3>
              <p className="settings-section-hint">
                Controls where tool side-effects take place and when actions require user approval.
                Changes need a restart to take effect.
              </p>
            </div>
            <div className="form-group">
              <label htmlFor="staging-path">Sandbox Staging Path</label>
              <input
                id="staging-path"
                type="text"
                className="input-field"
                value={sandboxStagingPath}
                onChange={(e) => setSandboxStagingPath(e.target.value)}
                required
              />
              <span className="form-group-hint">
                Directory where modified files are staged before being committed.
              </span>
            </div>
            {/* Retention caps bound staged-file lifetime and disk growth;
                the sweeper reclaims the oldest files first once limits bite. */}
            <div className="form-row">
              <div className="form-group flex-1">
                <label htmlFor="sandbox-retention-days">Retention (days)</label>
                <input
                  id="sandbox-retention-days"
                  type="number"
                  min={1}
                  max={365}
                  step={1}
                  className="input-field"
                  value={sandboxRetentionDays}
                  onChange={(e) => setSandboxRetentionDays(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Days a staged file stays valid before reclamation (1–365).
                </span>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="sandbox-max-bytes">Max Total Size (bytes)</label>
                <input
                  id="sandbox-max-bytes"
                  type="number"
                  min={1}
                  step={1024}
                  className="input-field"
                  value={sandboxMaxTotalBytes}
                  onChange={(e) => setSandboxMaxTotalBytes(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Total byte cap across staging; oldest files evict first.
                </span>
              </div>
              <div className="form-group flex-1">
                <label htmlFor="sandbox-cleanup-interval">Cleanup Interval (seconds)</label>
                <input
                  id="sandbox-cleanup-interval"
                  type="number"
                  min={1}
                  step={60}
                  className="input-field"
                  value={sandboxCleanupIntervalSeconds}
                  onChange={(e) => setSandboxCleanupIntervalSeconds(Number(e.target.value))}
                  required
                />
                <span className="form-group-hint">
                  Seconds between periodic cleanup passes (hourly default).
                </span>
              </div>
            </div>
          </div>
        )}

        {/* TAB: Files & Access (deny list plus allowed roots) */}
        {activeTab === "files" && (
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
                  className="secondary-button"
                  onClick={handleResetDenyPatterns}
                >
                  <RefreshIcon size={14} />
                  <span>Reset to Defaults</span>
                </button>
                <button
                  type="button"
                  className="secondary-button"
                  onClick={handleAddDenyPattern}
                >
                  <PlusIcon size={14} />
                  <span>Add Pattern</span>
                </button>
              </div>
            </div>

            {filesDenyPatterns.length === 0 ? (
              <div className="empty-state-box">
                <p>No deny patterns configured. File tools will allow all in-scope paths.</p>
                <button
                  type="button"
                  className="secondary-button"
                  onClick={handleResetDenyPatterns}
                >
                  <RefreshIcon size={14} />
                  <span>Reset to Defaults</span>
                </button>
              </div>
            ) : (
              <div style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
                {filesDenyPatterns.map((pattern, index) => (
                  <div
                    key={`deny-${index}`}
                    style={{ display: "flex", gap: "8px", alignItems: "center" }}
                  >
                    <div className="form-group" style={{ flex: 1, margin: 0 }}>
                      <label htmlFor={`deny-pattern-${index}`} className="sr-only">
                        Deny pattern {index + 1}
                      </label>
                      <input
                        id={`deny-pattern-${index}`}
                        type="text"
                        className="input-field"
                        aria-label={`Deny pattern ${index + 1}`}
                        value={pattern}
                        onChange={(e) => handleDenyPatternChange(index, e.target.value)}
                        placeholder='e.g. .env*, *.pem, .ssh/*'
                        required
                      />
                    </div>
                    <button
                      type="button"
                      className="icon-button danger"
                      onClick={() => handleRemoveDenyPattern(index)}
                      title={`Remove deny pattern ${index + 1}`}
                      aria-label={`Remove deny pattern ${index + 1}`}
                    >
                      <TrashIcon size={14} />
                    </button>
                  </div>
                ))}
              </div>
            )}
            <span className="form-group-hint" style={{ marginTop: "8px", display: "block" }}>
              Glob-like patterns: `*` matches within a name, directory prefixes like
              `.ssh/*` guard a whole subtree. Blank rows and `..` escapes are rejected.
            </span>

            <div className="settings-section-title-group" style={{ marginTop: "20px" }}>
              <h4 style={{ margin: "0 0 4px 0" }}>Allowed Roots</h4>
              <p className="settings-section-hint">
                Home containment boundary (`~` expands to the home directory). Paths outside
                these roots escalate to approval.
              </p>
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
            <div className="row" style={{ marginTop: "8px", gap: "8px" }}>
              <button
                type="button"
                className="secondary-button"
                onClick={handleAddAllowRoot}
              >
                <PlusIcon size={14} />
                <span>Add Root</span>
              </button>
              <button
                type="button"
                className="ghost icon-text-btn"
                onClick={handleResetAllowRoots}
              >
                <RefreshIcon size={14} />
                <span>Reset Roots</span>
              </button>
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
              <button
                type="button"
                className="secondary-button"
                onClick={handleAddEmailAccount}
              >
                <PlusIcon size={14} />
                <span>Add Account</span>
              </button>
            </div>

            {emailAccountsList.length === 0 ? (
              <div className="empty-state-box">
                <MailIcon size={32} />
                <p>No email accounts configured yet.</p>
                <button
                  type="button"
                  className="secondary-button"
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

      <RuneMarketplaceModal
        isOpen={marketplaceOpen}
        onClose={() => setMarketplaceOpen(false)}
        onPluginInstalled={() => {
          void loadPluginsData();
        }}
      />
    </section>
  );
}
