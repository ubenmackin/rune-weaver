// Rune Weaver Dashboard — Settings manager for config.toml configuration.
// Allows managing LLM providers, engine identity, sandbox policy, memory, voice, and email accounts.

import React, { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  getSettings,
  updateSettings,
  type EmailAccountData,
  type ProviderConfigData,
  type SettingsResponse,
} from "../api";
import {
  ApprovalsIcon,
  ChatIcon,
  MailIcon,
  MemoryIcon,
  PlusIcon,
  RefreshIcon,
  SettingsIcon,
  TrashIcon,
} from "./icons";

type SettingsTab = "providers" | "engine" | "sandbox" | "memory" | "voice" | "email";

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
  const safeName = name.toUpperCase().replace(/[^A-Z0-9]/g, "_");
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
  const [sandboxAutoApproveAfter, setSandboxAutoApproveAfter] = useState(0);
  const [memoryVectorDBPath, setMemoryVectorDBPath] = useState("");
  const [memoryEpisodesDBPath, setMemoryEpisodesDBPath] = useState("");
  const [memoryEmbeddingModel, setMemoryEmbeddingModel] = useState("");
  const [memoryEmbeddingBackend, setMemoryEmbeddingBackend] = useState("apple");
  const [voiceSTTProvider, setVoiceSTTProvider] = useState("");
  const [voiceWhisperModel, setVoiceWhisperModel] = useState("");
  const [voiceTTSProvider, setVoiceTTSProvider] = useState("");
  const [emailAccountsList, setEmailAccountsList] = useState<EmailEntry[]>([]);

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
    setSandboxAutoApproveAfter(data.sandboxAutoApproveAfter);
    setMemoryVectorDBPath(data.memoryVectorDBPath);
    setMemoryEpisodesDBPath(data.memoryEpisodesDBPath);
    setMemoryEmbeddingModel(data.memoryEmbeddingModel);
    setMemoryEmbeddingBackend(data.memoryEmbeddingBackend ?? "apple");
    setVoiceSTTProvider(data.voiceSTTProvider);
    setVoiceWhisperModel(data.voiceWhisperModel);
    setVoiceTTSProvider(data.voiceTTSProvider);

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
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to load settings");
    } finally {
      setLoading(false);
    }
  }, [populateForm]);

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
      // Number when the user entered a value; empty stays omitted.
      const cLenRaw = entry.config.context_length ?? entry.config.contextLength;
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

    // Reassemble email accounts array
    const emailAccounts: EmailAccountData[] = emailAccountsList
      .map((entry) => ({
        name: entry.account.name.trim(),
        type: entry.account.type.trim() || "imap",
        host: entry.account.host.trim(),
        port: Number(entry.account.port) || 993,
        username: entry.account.username.trim(),
      }))
      .filter((acc) => acc.name && acc.host && acc.username);

    try {
      const updated = await updateSettings({
        engineName,
        logLevel,
        defaultProvider,
        // Empty string clears the fallback server-side; omitting the field
        // would preserve the previous value instead.
        fallbackProvider: fallbackProvider,
        providers: providersMap,
        sandboxStagingPath,
        sandboxAutoApproveAfter: Number(sandboxAutoApproveAfter),
        memoryVectorDBPath,
        memoryEpisodesDBPath,
        memoryEmbeddingModel,
        memoryEmbeddingBackend,
        voiceSTTProvider,
        voiceWhisperModel,
        voiceTTSProvider,
        emailAccounts,
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
          // clear both aliases instead of coercing to a concrete window.
          if (field === "context_length") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.contextLength =
              next === undefined || Number.isNaN(next) ? undefined : next;
          }
          if (field === "contextLength") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.context_length =
              next === undefined || Number.isNaN(next) ? undefined : next;
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
          return {
            ...item,
            account: {
              ...item.account,
              [field]: field === "port" ? Number(val) || 993 : val,
            },
          };
        }
        return item;
      })
    );
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
          className={`settings-tab-btn ${activeTab === "sandbox" ? "active" : ""}`}
          onClick={() => setActiveTab("sandbox")}
        >
          <ApprovalsIcon size={16} />
          <span>Sandbox & Trust</span>
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

        {/* TAB 3: Sandbox & Trust */}
        {activeTab === "sandbox" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Sandbox & Security Policy</h3>
              <p className="settings-section-hint">
                Controls where tool side-effects take place and when actions require user approval.
              </p>
            </div>
            <div className="form-row">
              <div className="form-group flex-2">
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
              <div className="form-group flex-1">
                <label htmlFor="auto-approve">Auto-Approve After (Executions)</label>
                <input
                  id="auto-approve"
                  type="number"
                  min="0"
                  className="input-field"
                  value={sandboxAutoApproveAfter}
                  onChange={(e) =>
                    setSandboxAutoApproveAfter(
                      Math.max(0, parseInt(e.target.value, 10) || 0)
                    )
                  }
                />
                <span className="form-group-hint">
                  Successful executions before writes may auto-approve (0 to require confirmation every time).
                </span>
              </div>
            </div>
          </div>
        )}

        {/* TAB 4: Memory & Persistence */}
        {activeTab === "memory" && (
          <div className="settings-section card">
            <div className="settings-section-title-group">
              <h3>Memory & Persistence</h3>
              <p className="settings-section-hint">
                Paths to long-term memory, episode history databases, and embedding models.
              </p>
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
            <div className="form-row">
              <div className="form-group flex-1">
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
              <div className="form-group flex-1">
                <label htmlFor="embedding-model">Embedding Model</label>
                <input
                  id="embedding-model"
                  type="text"
                  className="input-field"
                  value={memoryEmbeddingModel}
                  onChange={(e) => setMemoryEmbeddingModel(e.target.value)}
                  required
                />
              </div>
            </div>
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
                Apple keeps vectors on-device by default (local-first). Provider
                opts in to LLM embeddings via the embedding model above, while
                none stays keyword-only with no vectors.
              </span>
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
    </section>
  );
}
