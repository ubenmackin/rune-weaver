// Rune Weaver Dashboard — Browser, Web & API tools configuration modal.

import React from "react";
import {
  DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_TIMEOUT_SECONDS,
} from "../../api";
import { AlertTriangleIcon, CloseIcon } from "../icons";
import Modal from "../Modal";

export interface BrowserConfigModalProps {
  isOpen: boolean;
  onClose: () => void;
  onManageSecurityPolicy: () => void;
  browserSaveLoading: boolean;
  browserModalError: string | null;
  browserTimeoutSeconds: number | string;
  setBrowserTimeoutSeconds: (val: string) => void;
  browserFetchTimeoutSeconds: number | string;
  setBrowserFetchTimeoutSeconds: (val: string) => void;
  handleSaveBrowserConfig: () => Promise<void>;
}

export function BrowserConfigModal({
  isOpen,
  onClose,
  onManageSecurityPolicy,
  browserSaveLoading,
  browserModalError,
  browserTimeoutSeconds,
  setBrowserTimeoutSeconds,
  browserFetchTimeoutSeconds,
  setBrowserFetchTimeoutSeconds,
  handleSaveBrowserConfig,
}: BrowserConfigModalProps): React.JSX.Element | null {
  if (!isOpen) return null;

  return (
    <Modal
      label="Configure Web, Browser & API Automation"
      onClose={() => {
        if (!browserSaveLoading) onClose();
      }}
      containerClassName="modal-container"
    >
      <div className="modal-header">
        <h3>Configure Web, Browser & API Automation</h3>
        <button
          type="button"
          className="icon-button"
          onClick={() => {
            if (!browserSaveLoading) onClose();
          }}
          disabled={browserSaveLoading}
          aria-label="Close"
        >
          <CloseIcon size={16} />
        </button>
      </div>
      <div
        className="modal-body"
        style={{ maxHeight: "calc(85vh - 130px)", overflowY: "auto" }}
      >
        {browserModalError && (
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
            <span>{browserModalError}</span>
          </div>
        )}

        <p className="muted text-sm" style={{ marginBottom: "16px" }}>
          Configure timeouts and execution limits for browser automation (
          <code>browser.navigate</code>, <code>browser.act</code>), web fetch
          &amp; search (<code>web.fetch</code>, <code>web.search</code>), and
          external API requests (<code>api.request</code>).
        </p>

        {/* Timeouts Section */}
        <div
          style={{
            padding: "14px",
            borderRadius: "8px",
            border: "1px solid var(--border-color, #2d3748)",
            marginBottom: "16px",
            backgroundColor: "var(--bg-secondary, #141822)",
          }}
        >
          <h4 style={{ margin: "0 0 12px 0", fontSize: "0.88rem" }}>
            Request &amp; Automation Timeouts
          </h4>
          <div className="form-group" style={{ marginBottom: "12px" }}>
            <label
              htmlFor="browser-timeout-seconds"
              style={{ fontSize: "0.82rem" }}
            >
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
            <span
              className="form-group-hint"
              style={{ marginTop: "4px", display: "block" }}
            >
              Timeout in seconds for Playwright actions (navigation, clicking,
              waiting for selectors). Default is {DEFAULT_BROWSER_TIMEOUT_SECONDS}
              s.
            </span>
          </div>

          <div className="form-group" style={{ marginBottom: 0 }}>
            <label
              htmlFor="browser-fetch-timeout-seconds"
              style={{ fontSize: "0.82rem" }}
            >
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
            <span
              className="form-group-hint"
              style={{ marginTop: "4px", display: "block" }}
            >
              Timeout in seconds for direct HTTP requests made by{" "}
              <code>web.fetch</code> and <code>api.request</code>. Default is{" "}
              {DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS}s.
            </span>
          </div>
        </div>

        {/* Security Policy pointer: domain allow/deny rules, local
            network access, and credentials live on the Access tab's
            Network and Credentials sections, so this modal keeps only
            a compact pointer to that surface. */}
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
              alignItems: "flex-start",
              gap: "12px",
            }}
          >
            <div>
              <h4 style={{ margin: "0 0 6px 0", fontSize: "0.88rem" }}>
                Security &amp; Network Policy
              </h4>
              <p className="muted text-sm" style={{ margin: 0 }}>
                Domain allow/deny rules and local network access are managed
                under the Access tab.
              </p>
            </div>
            <button
              type="button"
              className="ghost"
              style={{
                whiteSpace: "nowrap",
                fontSize: "0.8rem",
                padding: "6px 10px",
              }}
              onClick={onManageSecurityPolicy}
            >
              Manage Security Policy &rarr;
            </button>
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
  );
}
