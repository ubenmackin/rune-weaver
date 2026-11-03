// Rune Weaver Dashboard — Custom Rune / Plugin Configuration Modal.

import React, { useEffect, useState } from "react";
import {
  type PluginSummary,
  updatePluginConfig,
} from "../../api";
import { fetchPolicy, savePolicy } from "../access/AccessNetworkSection";
import {
  AlertTriangleIcon,
  CheckIcon,
  CloseIcon,
  GlobeIcon,
  KeyIcon,
  WrenchIcon,
} from "../icons";
import Modal from "../Modal";
import { SwitchControl } from "./SwitchControl";

export interface PluginConfigModalProps {
  isOpen: boolean;
  onClose: () => void;
  plugin: PluginSummary | null;
  secretStatus: Record<string, boolean>;
  handleOpenStoreSecretModal: (
    secretKey: string,
    label: string,
    isUpdate: boolean
  ) => void;
  onConfigSaved?: (updated: PluginSummary) => void;
}

function isDomainAllowed(host: string, allowedDomains: string[]): boolean {
  const target = host.toLowerCase().trim();
  return allowedDomains.some((d) => {
    const pattern = d.toLowerCase().trim();
    if (pattern === target) return true;
    if (pattern.startsWith("*.")) {
      const suffix = pattern.slice(2);
      return target.endsWith("." + suffix) || target === suffix;
    }
    return false;
  });
}

export function PluginConfigModal({
  isOpen,
  onClose,
  plugin,
  secretStatus,
  handleOpenStoreSecretModal,
  onConfigSaved,
}: PluginConfigModalProps): React.JSX.Element | null {
  const [configState, setConfigState] = useState<Record<string, string>>({});
  const [allowedDomains, setAllowedDomains] = useState<string[]>([]);
  const [addingDomain, setAddingDomain] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [modalError, setModalError] = useState<string | null>(null);
  const [successBanner, setSuccessBanner] = useState<string | null>(null);

  // Initialize config state from plugin
  useEffect(() => {
    if (plugin) {
      const initial: Record<string, string> = {};
      if (plugin.options) {
        for (const opt of plugin.options) {
          initial[opt.key] = plugin.userConfig?.[opt.key] ?? opt.defaultValue ?? "";
        }
      }
      if (plugin.userConfig) {
        Object.assign(initial, plugin.userConfig);
      }
      setConfigState(initial);
      setModalError(null);
      setSuccessBanner(null);
    }
  }, [plugin, isOpen]);

  // Load policy network allowed domains
  useEffect(() => {
    if (!isOpen) return;
    let isCancelled = false;
    fetchPolicy()
      .then((res) => {
        if (!isCancelled) {
          setAllowedDomains(res.policy.network.allowed_domains ?? []);
        }
      })
      .catch((err) => {
        console.warn("Failed loading policy for plugin config modal:", err);
      });
    return () => {
      isCancelled = true;
    };
  }, [isOpen]);

  if (!isOpen || !plugin) return null;

  const credentials = plugin.credentials ?? [];
  const options = plugin.options ?? [];
  const declaredHosts = plugin.declaredNetworkHosts ?? [];

  const handleConfigChange = (key: string, value: string) => {
    setConfigState((prev) => ({ ...prev, [key]: value }));
  };

  const handleAllowDomain = async (host: string) => {
    setAddingDomain(host);
    setModalError(null);
    setSuccessBanner(null);
    try {
      const policyRes = await fetchPolicy();
      const current = policyRes.policy.network.allowed_domains ?? [];
      if (!current.includes(host)) {
        const updated = {
          ...policyRes.policy,
          network: {
            ...policyRes.policy.network,
            allowed_domains: [...current, host],
          },
        };
        await savePolicy(updated);
        setAllowedDomains((prev) => [...prev, host]);
        setSuccessBanner(`Added '${host}' to policy allowlist.`);
      }
    } catch (err) {
      setModalError(err instanceof Error ? err.message : `Failed to allow domain '${host}'.`);
    } finally {
      setAddingDomain(null);
    }
  };

  const handleSaveOptions = async () => {
    setSaving(true);
    setModalError(null);
    setSuccessBanner(null);
    try {
      const updated = await updatePluginConfig(plugin.id, configState);
      setSuccessBanner("Configuration saved successfully.");
      onConfigSaved?.(updated);
    } catch (err) {
      setModalError(err instanceof Error ? err.message : "Failed to save configuration.");
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      label={`Configure ${plugin.name}`}
      onClose={() => {
        if (!saving) onClose();
      }}
      containerClassName="modal-container"
    >
      <div className="modal-header">
        <div className="row items-center gap-2">
          <WrenchIcon size={18} />
          <h3 className="m-0">Configure {plugin.name}</h3>
          <span className="tool-category-badge all-disabled text-xs">v{plugin.version}</span>
        </div>
        <button
          type="button"
          className="icon-button"
          onClick={() => {
            if (!saving) onClose();
          }}
          disabled={saving}
          aria-label="Close"
        >
          <CloseIcon size={16} />
        </button>
      </div>

      <div className="modal-body plugin-config-body">
        {modalError && (
          <div className="error-banner media-config-error">
            <AlertTriangleIcon size={16} />
            <span>{modalError}</span>
          </div>
        )}

        {successBanner && (
          <div className="rune-marketplace-success text-sm mb-3">
            <CheckIcon size={16} />
            <span>{successBanner}</span>
          </div>
        )}

        {plugin.description && (
          <p className="muted text-sm media-config-intro">{plugin.description}</p>
        )}

        {/* Credentials Section */}
        {credentials.length > 0 && (
          <div className="plugin-config-card">
            <h4>Credentials & API Keys</h4>
            <p className="muted text-xs mb-3">
              Credentials are encrypted in macOS Keychain (<code>com.runeweaver.secrets</code>) and
              injected into the plugin environment when tools run.
            </p>
            <p className="muted text-xs mb-3">
              Only one auth method needed. Priority: Token first, then Cookie, then Email plus
              Password with MFA Secret when MFA is on.
            </p>
            <div className="plugin-credentials-list">
              {credentials.map((cred) => {
                const isStored = !!secretStatus[cred.key];
                return (
                  <div key={cred.key} className="plugin-credential-item">
                    <div className="plugin-credential-info">
                      <div className="row items-center gap-2">
                        <span className="font-semibold text-sm">
                          {cred.label || cred.key}
                        </span>
                        {cred.required && (
                          <span className="badge-required">Required</span>
                        )}
                      </div>
                      <code className="text-xs muted">{cred.key}</code>
                      {cred.description && (
                        <p className="text-xs text-secondary mt-1 mb-0">
                          {cred.description}
                        </p>
                      )}
                    </div>
                    <div className="plugin-credential-action">
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
                        onClick={() =>
                          handleOpenStoreSecretModal(
                            cred.key,
                            cred.label || cred.key,
                            isStored
                          )
                        }
                        title={
                          isStored
                            ? `Update ${cred.key} in Keychain`
                            : `Store ${cred.key} in Keychain`
                        }
                      >
                        <KeyIcon size={12} />
                        <span>{isStored ? "Update Key" : "Store Key"}</span>
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Network Policy & Egress Section */}
        {declaredHosts.length > 0 && (
          <div className="plugin-config-card">
            <h4>Network Access & Policy</h4>
            <p className="muted text-xs mb-3">
              This plugin declares outbound network access to the following hosts. Requests to
              unlisted hosts are blocked by <code>policy.toml</code>.
            </p>
            <div className="plugin-network-list">
              {declaredHosts.map((host) => {
                const allowed = isDomainAllowed(host, allowedDomains);
                return (
                  <div key={host} className="plugin-network-item">
                    <div className="plugin-network-info">
                      <GlobeIcon size={14} />
                      <code className="text-sm">{host}</code>
                    </div>
                    <div className="plugin-network-action">
                      {allowed ? (
                        <span className="keychain-status-badge stored">
                          <CheckIcon size={12} /> Allowed in Policy
                        </span>
                      ) : (
                        <div className="row items-center gap-2">
                          <span className="keychain-status-badge missing">
                            Not in Policy
                          </span>
                          <button
                            type="button"
                            className="keychain-action-btn"
                            onClick={() => handleAllowDomain(host)}
                            disabled={addingDomain === host}
                          >
                            <CheckIcon size={12} />
                            <span>
                              {addingDomain === host ? "Allowing..." : "Allow in Policy"}
                            </span>
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Custom Options / User Configuration */}
        {options.length > 0 && (
          <div className="plugin-config-card">
            <h4>Plugin Options</h4>
            <div className="plugin-options-form">
              {options.map((opt) => (
                <div key={opt.key} className="form-group media-config-field">
                  <label htmlFor={`opt-${opt.key}`} className="text-sm font-semibold">
                    {opt.label || opt.key}
                  </label>
                  {opt.description && (
                    <p className="text-xs muted mb-1">{opt.description}</p>
                  )}
                  {opt.type === "boolean" ? (
                    <SwitchControl
                      checked={configState[opt.key] === "true"}
                      onChange={(e) =>
                        handleConfigChange(opt.key, e.target.checked ? "true" : "false")
                      }
                      label={opt.label || opt.key}
                      hint={configState[opt.key] === "true" ? "Enabled" : "Disabled"}
                    />
                  ) : opt.options && opt.options.length > 0 ? (
                    <select
                      id={`opt-${opt.key}`}
                      className="input-field"
                      value={configState[opt.key] ?? opt.defaultValue ?? ""}
                      onChange={(e) => handleConfigChange(opt.key, e.target.value)}
                    >
                      {opt.options.map((choice) => (
                        <option key={choice} value={choice}>
                          {choice}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input
                      id={`opt-${opt.key}`}
                      type={opt.type === "number" ? "number" : "text"}
                      className="input-field"
                      value={configState[opt.key] ?? ""}
                      onChange={(e) => handleConfigChange(opt.key, e.target.value)}
                      placeholder={opt.defaultValue ?? ""}
                    />
                  )}
                </div>
              ))}
            </div>
            <div className="row justify-end mt-3">
              <button
                type="button"
                className="btn primary"
                onClick={handleSaveOptions}
                disabled={saving}
              >
                {saving ? "Saving..." : "Save Options"}
              </button>
            </div>
          </div>
        )}

        {credentials.length === 0 && declaredHosts.length === 0 && options.length === 0 && (
          <div className="empty-state-box p-4 text-center">
            <p className="muted text-sm">
              This rune does not declare any credentials, network endpoints, or configurable options.
            </p>
          </div>
        )}
      </div>

      <div className="modal-footer">
        <button
          type="button"
          className="btn btn-secondary"
          onClick={onClose}
          disabled={saving}
        >
          Close
        </button>
      </div>
    </Modal>
  );
}

export default PluginConfigModal;
