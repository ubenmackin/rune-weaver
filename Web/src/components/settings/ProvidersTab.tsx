// Rune Weaver Dashboard — LLM Providers tab pane.

import { useState } from "react";
import type { ProviderConfigData } from "../../api";
import { KNOWN_PROVIDER_TYPES } from "../../api/settings-types";
import { CheckIcon, KeyIcon, PlusIcon, TrashIcon } from "../icons";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import type { ProviderEntry } from "./settingsTypes";

export interface ProvidersTabProps {
  defaultProvider: string;
  setDefaultProvider: (val: string) => void;
  fallbackProvider: string;
  setFallbackProvider: (val: string) => void;
  providerNames: string[];
  providersList: ProviderEntry[];
  handleAddProvider: () => void;
  handleProviderNameChange: (id: string, name: string) => void;
  handleProviderFieldChange: (
    id: string,
    field: keyof ProviderConfigData,
    value: unknown,
  ) => void;
  handleRemoveProvider: (id: string, name: string) => void;
  secretStatus: Record<string, boolean>;
  onOpenStoreSecretModal: (
    keyEnv: string,
    title: string,
    isStored: boolean,
  ) => void;
  setError: (err: string | null) => void;
  validationError?: string | null;
}

const ADVANCED_ERROR_TOKENS = [
  "contextLength",
  "context_length",
  "slotCount",
  "slot_count",
  "cachePrompt",
  "cache_prompt",
  "supportsVision",
  "supports_vision",
  "apiStyle",
  "api_style",
];

function matchesAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return ADVANCED_ERROR_TOKENS.some((token) =>
    lowered.includes(token.toLowerCase())
  );
}

export function ProvidersTab({
  defaultProvider,
  setDefaultProvider,
  fallbackProvider,
  setFallbackProvider,
  providerNames,
  providersList,
  handleAddProvider,
  handleProviderNameChange,
  handleProviderFieldChange,
  handleRemoveProvider,
  secretStatus,
  onOpenStoreSecretModal,
  setError,
  validationError,
}: ProvidersTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const advancedError = matchesAdvancedError(validationError)
    ? validationError
    : null;

  const handleResetAdvanced = () => {
    for (const item of providersList) {
      handleProviderFieldChange(item.id, "apiStyle", "");
      handleProviderFieldChange(item.id, "contextLength", undefined);
      handleProviderFieldChange(item.id, "slotCount", undefined);
      handleProviderFieldChange(item.id, "cachePrompt", undefined);
      handleProviderFieldChange(item.id, "supportsVision", undefined);
    }
  };

  return (
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
          id="providers-add-button"
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
          const rawProviderType =
            entry.providerType || "";
          const knownProviderTypes = KNOWN_PROVIDER_TYPES;
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

                <div className="form-group">
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

                <div className="form-group">
                  <label htmlFor={`server-${item.id}`}>Server URL</label>
                  <input
                    id={`server-${item.id}`}
                    type="text"
                    className="input-field"
                    value={entry.serverURL || ""}
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
                      const keyEnv = (entry.apiKeyEnv || "").trim();
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
                            onClick={() => onOpenStoreSecretModal(keyEnv, `API Key for ${item.name || "Provider"}`, isStored)}
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
                    value={entry.apiKeyEnv || ""}
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
              </div>
            </div>
          );
        })}
      </div>

      <AdvancedDisclosure
        tabName="Providers"
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        validationError={advancedError}
        onReset={handleResetAdvanced}
      >
        <div className="providers-grid">
          {providersList.map((item) => {
            const entry = item.config;
            return (
              <div key={`advanced-${item.id}`} className="provider-card">
                <div className="provider-card-header">
                  <div className="provider-header-left">
                    <h4>{item.name || "(unnamed)"}</h4>
                  </div>
                </div>
                <div className="provider-fields">
                  <div className="form-group">
                    <label htmlFor={`style-${item.id}`}>API Style (Optional)</label>
                    <input
                      id={`style-${item.id}`}
                      type="text"
                      className="input-field"
                      value={entry.apiStyle || ""}
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

                  <div className="form-group">
                    <label htmlFor={`context-${item.id}`}>Context Length (Tokens)</label>
                    <input
                      id={`context-${item.id}`}
                      type="number"
                      min="1000"
                      step="1000"
                      className="input-field"
                      value={entry.contextLength ?? ""}
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

                  <div className="form-row">
                    <div className="form-group flex-1">
                      <label htmlFor={`slot-${item.id}`}>Slot Count (llama.cpp)</label>
                      <input
                        id={`slot-${item.id}`}
                        type="number"
                        min="1"
                        step="1"
                        className="input-field"
                        value={entry.slotCount ?? ""}
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
                          entry.cachePrompt === undefined
                            ? ""
                            : entry.cachePrompt
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
                        entry.supportsVision === undefined
                          ? ""
                          : entry.supportsVision
                            ? "true"
                            : "false"
                      }
                      onChange={(e) => {
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
      </AdvancedDisclosure>
    </div>
  );
}

export default ProvidersTab;
