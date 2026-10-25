// Rune Weaver Dashboard — Web (SearXNG & Browser Automation) tab pane.

import type React from "react";
import { useState } from "react";
import {
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
  searchStageCopy,
} from "../../api";
import { CloseIcon, RefreshIcon, SearchIcon, StopIcon, TrashIcon, WrenchIcon } from "../icons";
import Modal from "../Modal";
import {
  BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT,
  browserStageCopy,
} from "./settingsTypes";
import { AdvancedDisclosure } from "./AdvancedDisclosure";

// Advanced Web validation messages the disclosure can focus. Shared by the
// panel prop and the shell error router so one message never prints twice.
export const WEB_ADVANCED_ERROR_KEYWORDS = [
  "searxng",
  "search timeout",
  "searxng url",
  "browser",
  "playwright",
  "python",
  "venv",
  "chromium",
] as const;

export function isWebAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return WEB_ADVANCED_ERROR_KEYWORDS.some((keyword) =>
    lowered.includes(keyword)
  );
}

export interface WebSearchTabProps {
  searchActionBusy: boolean;
  searchRunning: boolean;
  handleToggleSearch: () => Promise<void>;
  searchAction: "start" | "stop" | "remove" | null;
  setPendingRemoveSearch: (val: boolean) => void;
  searchRemoveEnabled: boolean;
  searchSearxngURL: string;
  setSearchSearxngURL: (val: string) => void;
  searchTimeoutSeconds: number | string;
  setSearchTimeoutSeconds: (val: number | string) => void;
  searchMaxResults: number | string;
  setSearchMaxResults: (val: number | string) => void;
  searchStage: string | null;
  searchStartElapsed: number;
  searchHealthLoading: boolean;
  searchReachable: boolean | null;
  searchHealthError: string | null;
  searchDiagnostics: string | null;
  browserActionBusy: boolean;
  browserStage: string | null;
  browserElapsed: number;
  browserReady: boolean | null;
  refreshBrowserHealth: () => Promise<void>;
  browserHealthLoading: boolean;
  handleEnsureBrowser: () => Promise<void>;
  browserAction: string | null;
  browserError: string | null;
  browserDiagnostics: string | null;
  browserAdvancedRef: React.RefObject<HTMLDetailsElement>;
  browserVenvPath: string;
  browserPythonPath: string | null;
  pendingRemoveSearch: boolean;
  handleConfirmRemoveSearch: () => Promise<void>;
  validationError?: string | null;
}

export function WebSearchTab({
  searchActionBusy,
  searchRunning,
  handleToggleSearch,
  searchAction,
  setPendingRemoveSearch,
  searchRemoveEnabled,
  searchSearxngURL,
  setSearchSearxngURL,
  searchTimeoutSeconds,
  setSearchTimeoutSeconds,
  searchMaxResults,
  setSearchMaxResults,
  searchStage,
  searchStartElapsed,
  searchHealthLoading,
  searchReachable,
  searchHealthError,
  searchDiagnostics,
  browserActionBusy,
  browserStage,
  browserElapsed,
  browserReady,
  refreshBrowserHealth,
  browserHealthLoading,
  handleEnsureBrowser,
  browserAction,
  browserError,
  browserDiagnostics,
  browserAdvancedRef,
  browserVenvPath,
  browserPythonPath,
  pendingRemoveSearch,
  handleConfirmRemoveSearch,
  validationError = null,
}: WebSearchTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);

  // Reset restores stock SearXNG endpoint plus timeout defaults.
  const resetWebAdvanced = () => {
    setSearchSearxngURL(DEFAULT_SEARCH_SEARXNG_URL);
    setSearchTimeoutSeconds(DEFAULT_SEARCH_TIMEOUT_SECONDS);
  };

  // Browser provision failures ride the shared disclosure error channel
  // so its force-open path alone owns venv fallback visibility.
  const advancedError = validationError || browserError;

  return (
    <>
    <div className="settings-section card">
      <div className="settings-section-title-group">
        <h3>Web</h3>
        <p className="settings-section-hint">
          Private web search and browser automation, backed by the [browser] policy.
        </p>
      </div>

      <div className="settings-section-header mt-4">
        <div className="settings-section-title-group">
          <h4 className="m-0 mb-1">Web Search (SearXNG)</h4>
          <p className="settings-section-hint">
            Web search runs locally through SearXNG. No Docker needed, it uses the Apple Container CLI. First start pulls the SearXNG image (about 150 MB), later starts reuse it.
          </p>
        </div>
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
        <label htmlFor="search-max-results">Max Results (Provider Pick)</label>
        <input
          id="search-max-results"
          type="number"
          min={1}
          max={50}
          step={1}
          className="input-field"
          value={searchMaxResults}
          onChange={(e) => setSearchMaxResults(e.target.value)}
          required
        />
        <span className="form-group-hint">
          Max results per query (1 to 50). Saved to max_results under [browser]. Provider pick for the Simple web surface.
        </span>
      </div>

      <span data-testid="search-health-text" className="search-health-line">
        {searchAction === "start" ? (
          <>
            <span className="status-pill running" data-testid="search-starting-pill">
              Starting
            </span>
            <span className="muted text-sm" data-testid="search-start-stage">
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

      {searchDiagnostics ? (
        <details className="muted text-sm" data-testid="search-health-diagnostics">
          <summary>Diagnostics</summary>
          <pre className="web-diagnostics-pre">
            {searchDiagnostics}
          </pre>
        </details>
      ) : null}

      <p className="muted text-sm m-0 mt-2" data-testid="search-lifecycle-hint">
        Stop keeps the container for fast restart, Remove deletes it fully, and quit leaves it running by design.
      </p>

      {/* Browser automation section */}
      <div className="web-section-divider">
        <div className="settings-section-header">
          <div className="settings-section-title-group">
            <h4 className="m-0 mb-1">Browser automation</h4>
            <p className="settings-section-hint">
              Browser automation for browser.navigate and browser.act runs through an isolated managed Python environment. First use provisions Playwright plus Chromium; later uses reuse it.
            </p>
          </div>
          <div className="row">
            {browserActionBusy ? (
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
                  Preparing… {browserStageCopy(browserStage)} · {browserElapsed}s
                </span>
              </button>
            ) : browserReady === true ? (
              <button
                type="button"
                className="ghost icon-text-btn"
                data-testid="browser-recheck"
                onClick={() => void refreshBrowserHealth()}
                disabled={browserHealthLoading}
                aria-label="Re-check browser Python"
                title="Re-check browser Python"
              >
                <RefreshIcon size={14} className={browserHealthLoading ? "spin" : ""} />
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

        <span data-testid="browser-health-text" className="search-health-line">
          {browserAction === "ensure" ? (
            <>
              <span className="status-pill running" data-testid="browser-starting-pill">
                Preparing
              </span>
              <span className="muted text-sm" data-testid="browser-start-stage">
                {browserStageCopy(browserStage)} · {browserElapsed}s
              </span>
            </>
          ) : browserHealthLoading ? (
            <span className="muted text-sm">Checking browser health…</span>
          ) : browserReady === null ? (
            <span className="status-pill skipped">Unknown</span>
          ) : browserReady ? (
            <span className="status-pill ok">Ready</span>
          ) : (
            <span className="status-pill error">Missing</span>
          )}
        </span>

        {browserError ? (
          <div className="error-banner" data-testid="browser-health-error">
            {browserError}
          </div>
        ) : null}

        {browserDiagnostics ? (
          <details className="muted text-sm" data-testid="browser-health-diagnostics">
            <summary>Diagnostics</summary>
            <pre className="web-diagnostics-pre">
              {browserDiagnostics}
            </pre>
          </details>
        ) : null}
      </div>
      <AdvancedDisclosure
        tabName="Web"
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        testId="advanced-web"
        validationError={advancedError}
        errorKeywords={[...WEB_ADVANCED_ERROR_KEYWORDS]}
        onReset={resetWebAdvanced}
        detailsRef={browserAdvancedRef}
      >
        <div className="form-group">
          <label htmlFor="search-searxng-url">SearXNG URL (Endpoint Override)</label>
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
            Base URL of the local SearXNG service (default {DEFAULT_SEARCH_SEARXNG_URL}). Saved to searxng_url under [browser]; applies live with no restart.
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
              onChange={(e) => setSearchTimeoutSeconds(e.target.value)}
              required
            />
            <span className="form-group-hint">
              Per-request timeout in seconds (1 to 120). Saved to search_timeout_seconds under [browser].
            </span>
          </div>
        </div>
        <details className="muted text-sm mt-4" data-testid="browser-troubleshooting-details">
          <summary className="web-troubleshooting-toggle">Manual environment setup &amp; troubleshooting</summary>
          <div className="web-troubleshooting-body">
            <p className="m-0 mt-1">
              Managed Python at <code>{browserVenvPath}</code>.
            </p>
            {browserPythonPath ? (
              <p className="m-0 mt-1">
                Active interpreter: <code>{browserPythonPath}</code>
              </p>
            ) : null}
            <p className="m-0 mt-2">
              Manual fallback:
            </p>
            <pre className="code-block web-manual-fallback-code">
              {browserVenvPath}/bin/python -m pip install {BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT} &amp;&amp; {browserVenvPath}/bin/python -m playwright install chromium
            </pre>
          </div>
        </details>
      </AdvancedDisclosure>
    </div>

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
          <p className="muted m-0">
            This will stop (if running) and delete the runeweaver-searxng container. The image cache stays and next Start recreates the container.
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
    </>
  );
}

export default WebSearchTab;
