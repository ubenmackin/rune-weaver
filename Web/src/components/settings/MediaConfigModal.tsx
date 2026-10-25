// Rune Weaver Dashboard — Media tools configuration modal (Sonarr & Radarr).

import React from "react";
import { DEFAULT_MEDIA_TIMEOUT_SECONDS } from "../../api";
import { AlertTriangleIcon, CheckIcon, CloseIcon, KeyIcon } from "../icons";
import Modal from "../Modal";
import { SwitchControl } from "./SwitchControl";

export interface MediaConfigModalProps {
  isOpen: boolean;
  onClose: () => void;
  mediaSaveLoading: boolean;
  mediaModalError: string | null;
  sonarrEnabled: boolean;
  setSonarrEnabled: (enabled: boolean) => void;
  sonarrUrl: string;
  setSonarrUrl: (url: string) => void;
  sonarrApiKeyEnv: string;
  setSonarrApiKeyEnv: (env: string) => void;
  sonarrDefaultQuality: string;
  setSonarrDefaultQuality: (quality: string) => void;
  sonarrDefaultRoot: string;
  setSonarrDefaultRoot: (root: string) => void;
  radarrEnabled: boolean;
  setRadarrEnabled: (enabled: boolean) => void;
  radarrUrl: string;
  setRadarrUrl: (url: string) => void;
  radarrApiKeyEnv: string;
  setRadarrApiKeyEnv: (env: string) => void;
  radarrDefaultQuality: string;
  setRadarrDefaultQuality: (quality: string) => void;
  radarrDefaultRoot: string;
  setRadarrDefaultRoot: (root: string) => void;
  mediaTimeoutSeconds: number | string;
  setMediaTimeoutSeconds: (timeout: string) => void;
  handleSaveMediaConfig: () => Promise<void>;
  secretStatus: Record<string, boolean>;
  handleOpenStoreSecretModal: (
    secretKey: string,
    label: string,
    isUpdate: boolean
  ) => void;
}

export function MediaConfigModal({
  isOpen,
  onClose,
  mediaSaveLoading,
  mediaModalError,
  sonarrEnabled,
  setSonarrEnabled,
  sonarrUrl,
  setSonarrUrl,
  sonarrApiKeyEnv,
  setSonarrApiKeyEnv,
  sonarrDefaultQuality,
  setSonarrDefaultQuality,
  sonarrDefaultRoot,
  setSonarrDefaultRoot,
  radarrEnabled,
  setRadarrEnabled,
  radarrUrl,
  setRadarrUrl,
  radarrApiKeyEnv,
  setRadarrApiKeyEnv,
  radarrDefaultQuality,
  setRadarrDefaultQuality,
  radarrDefaultRoot,
  setRadarrDefaultRoot,
  mediaTimeoutSeconds,
  setMediaTimeoutSeconds,
  handleSaveMediaConfig,
  secretStatus,
  handleOpenStoreSecretModal,
}: MediaConfigModalProps): React.JSX.Element | null {
  if (!isOpen) return null;

  return (
    <Modal
      label="Configure Sonarr & Radarr"
      onClose={() => {
        if (!mediaSaveLoading) onClose();
      }}
      containerClassName="modal-container"
    >
      <div className="modal-header">
        <h3>Configure Media Automation (Sonarr & Radarr)</h3>
        <button
          type="button"
          className="icon-button"
          onClick={() => {
            if (!mediaSaveLoading) onClose();
          }}
          disabled={mediaSaveLoading}
          aria-label="Close"
        >
          <CloseIcon size={16} />
        </button>
      </div>
      <div className="modal-body" style={{ maxHeight: "70vh", overflowY: "auto" }}>
        {mediaModalError && (
          <div
            className="error-banner"
            style={{
              marginBottom: "14px",
              display: "flex",
              alignItems: "center",
              gap: "8px",
            }}
          >
            <AlertTriangleIcon size={16} />
            <span>{mediaModalError}</span>
          </div>
        )}

        <p className="muted text-sm" style={{ marginBottom: "16px" }}>
          Configure your local or network Sonarr (TV) and Radarr (Movie) instances.
          API keys are resolved from environment variables or macOS Keychain (
          <code>com.runeweaver.secrets</code>) and never stored in plaintext config.
        </p>

        {/* Sonarr Card */}
        <div
          style={{
            padding: "14px",
            borderRadius: "8px",
            border: "1px solid var(--border-color, #2d3748)",
            marginBottom: "16px",
            backgroundColor: "var(--bg-secondary, #141822)",
          }}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              marginBottom: "12px",
            }}
          >
            <h4 style={{ margin: 0, display: "flex", alignItems: "center", gap: "8px" }}>
              <span>Sonarr (TV Shows)</span>
            </h4>
            <SwitchControl
              checked={sonarrEnabled}
              onChange={(e) => setSonarrEnabled(e.target.checked)}
              label="Enable Sonarr"
              hint="Enabled"
            />
          </div>

          <div className="form-group" style={{ marginBottom: "10px" }}>
            <label htmlFor="sonarr-url" style={{ fontSize: "0.82rem" }}>
              Server URL
            </label>
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
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                marginBottom: "4px",
                flexWrap: "wrap",
                gap: "6px",
              }}
            >
              <label htmlFor="sonarr-key-env" style={{ fontSize: "0.82rem" }}>
                API Key Environment Variable / Keychain Key
              </label>
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
                      onClick={() =>
                        handleOpenStoreSecretModal(keyEnv, "Sonarr API Key", isStored)
                      }
                      title={
                        isStored
                          ? `Update secret for ${keyEnv}`
                          : `Store secret for ${keyEnv} in Keychain`
                      }
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
              <label htmlFor="sonarr-quality" style={{ fontSize: "0.82rem" }}>
                Default Quality Profile (Optional)
              </label>
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
              <label htmlFor="sonarr-root" style={{ fontSize: "0.82rem" }}>
                Default Root Folder (Optional)
              </label>
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
        <div
          style={{
            padding: "14px",
            borderRadius: "8px",
            border: "1px solid var(--border-color, #2d3748)",
            backgroundColor: "var(--bg-secondary, #141822)",
          }}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              marginBottom: "12px",
            }}
          >
            <h4 style={{ margin: 0, display: "flex", alignItems: "center", gap: "8px" }}>
              <span>Radarr (Movies)</span>
            </h4>
            <SwitchControl
              checked={radarrEnabled}
              onChange={(e) => setRadarrEnabled(e.target.checked)}
              label="Enable Radarr"
              hint="Enabled"
            />
          </div>

          <div className="form-group" style={{ marginBottom: "10px" }}>
            <label htmlFor="radarr-url" style={{ fontSize: "0.82rem" }}>
              Server URL
            </label>
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
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                marginBottom: "4px",
                flexWrap: "wrap",
                gap: "6px",
              }}
            >
              <label htmlFor="radarr-key-env" style={{ fontSize: "0.82rem" }}>
                API Key Environment Variable / Keychain Key
              </label>
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
                      onClick={() =>
                        handleOpenStoreSecretModal(keyEnv, "Radarr API Key", isStored)
                      }
                      title={
                        isStored
                          ? `Update secret for ${keyEnv}`
                          : `Store secret for ${keyEnv} in Keychain`
                      }
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
              <label htmlFor="radarr-quality" style={{ fontSize: "0.82rem" }}>
                Default Quality Profile (Optional)
              </label>
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
              <label htmlFor="radarr-root" style={{ fontSize: "0.82rem" }}>
                Default Root Folder (Optional)
              </label>
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
        <div
          style={{
            padding: "14px",
            borderRadius: "8px",
            border: "1px solid var(--border-color, #2d3748)",
            marginTop: "16px",
            backgroundColor: "var(--bg-secondary, #141822)",
          }}
        >
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
            <span
              className="form-group-hint"
              style={{ marginTop: "4px", display: "block" }}
            >
              Timeout in seconds for API calls to Sonarr and Radarr. Default is{" "}
              {DEFAULT_MEDIA_TIMEOUT_SECONDS}s.
            </span>
          </div>
        </div>
      </div>
      <div
        className="modal-footer"
        style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}
      >
        <button
          type="button"
          className="ghost"
          onClick={onClose}
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
  );
}
