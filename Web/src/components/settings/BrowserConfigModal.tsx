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
      <div className="modal-body browser-config-body">
        {browserModalError && (
          <div className="error-banner browser-config-error">
            <AlertTriangleIcon size={16} />
            <span>{browserModalError}</span>
          </div>
        )}

        <p className="muted text-sm browser-config-intro">
          Configure timeouts and execution limits for browser automation (
          <code>browser.navigate</code>, <code>browser.act</code>), web fetch
          &amp; search (<code>web.fetch</code>, <code>web.search</code>), and
          external API requests (<code>api.request</code>).
        </p>

        {/* Timeouts Section */}
        <div className="browser-config-card">
          <h4 className="browser-config-heading">
            Request &amp; Automation Timeouts
          </h4>
          <div className="form-group mb-3">
            <label htmlFor="browser-timeout-seconds" className="text-sm">
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
            <span className="form-group-hint browser-config-hint-block">
              Timeout in seconds for Playwright actions (navigation, clicking,
              waiting for selectors). Default is {DEFAULT_BROWSER_TIMEOUT_SECONDS}
              s.
            </span>
          </div>

          <div className="form-group m-0">
            <label htmlFor="browser-fetch-timeout-seconds" className="text-sm">
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
            <span className="form-group-hint browser-config-hint-block">
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
        <div className="browser-config-card">
          <div className="browser-policy-head">
            <div>
              <h4 className="browser-policy-heading">
                Security &amp; Network Policy
              </h4>
              <p className="muted text-sm m-0">
                Domain allow/deny rules and local network access are managed
                under the Access tab.
              </p>
            </div>
            <button
              type="button"
              className="ghost browser-policy-action"
              onClick={onManageSecurityPolicy}
            >
              Manage Security Policy &rarr;
            </button>
          </div>
        </div>
      </div>
      <div className="modal-footer">
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
