// Rune Weaver Dashboard — Security & Containers tab pane.

import { RefreshIcon, UserIcon } from "../icons";

export interface SecurityTabProps {
  containersMemoryMB: number | string;
  setContainersMemoryMB: (val: number | string) => void;
  containersMaxConcurrent: number | string;
  setContainersMaxConcurrent: (val: number | string) => void;
  containersTTLMinutes: number | string;
  setContainersTTLMinutes: (val: number | string) => void;
  onPromptRotate: () => void;
  rotating: boolean;
  hasOwnerSession: boolean;
  handleLogout: () => void;
  rotateError: string | null;
}

export function SecurityTab({
  containersMemoryMB,
  setContainersMemoryMB,
  containersMaxConcurrent,
  setContainersMaxConcurrent,
  containersTTLMinutes,
  setContainersTTLMinutes,
  onPromptRotate,
  rotating,
  hasOwnerSession,
  handleLogout,
  rotateError,
}: SecurityTabProps) {
  return (
    <>
      <div className="settings-section card">
        <div className="settings-section-title-group">
          <h3>Containers</h3>
          <p className="settings-section-hint">
            One [containers] table governs memory, concurrency, and idle TTL across the bash execution tiers and detonation containers, while the long-lived workspace machine box is governed by its Stop and Recycle controls.
          </p>
        </div>

        <div className="form-row">
          <div className="form-group flex-1">
            <span className="form-group-label">Strict Container Image</span>
            <p data-testid="containers-strict-image">
              <code>debian:stable-slim</code>{" "}
              <span className="muted text-sm">Pinned in code (fixed)</span>
            </p>
            <span className="form-group-hint">
              Per-turn strict containers always run the pinned guest image; no image selection.
            </span>
          </div>
          <div className="form-group flex-1">
            <span className="form-group-label">Machine Image</span>
            <p data-testid="containers-machine-image">
              <code>debian:stable-slim</code>{" "}
              <span className="muted text-sm">Pinned in code (fixed)</span>
            </p>
            <span className="form-group-hint">
              Machine-scoped containers always use the pinned machine image; no image selection.
            </span>
          </div>
          <div className="form-group flex-1">
            <span className="form-group-label">Detonation Image</span>
            <p data-testid="containers-detonation-image">
              <code>alpine:3.22</code>{" "}
              <span className="muted text-sm">Pinned in code (fixed)</span>
            </p>
            <span className="form-group-hint">
              Detonation containers always use the pinned detonation image; no image selection.
            </span>
          </div>
        </div>
        <div className="form-row">
          <div className="form-group flex-1">
            <label htmlFor="containers-memory-mb">Memory (MB)</label>
            <input
              id="containers-memory-mb"
              type="number"
              step={1}
              className="input-field"
              value={containersMemoryMB}
              onChange={(e) => setContainersMemoryMB(e.target.value)}
            />
            <span className="form-group-hint">
              Memory budget for one container; a tiny budget fails every spawn while a host-scale one crowds the host.
            </span>
          </div>
          <div className="form-group flex-1">
            <label htmlFor="containers-max-concurrent">Max Concurrent Containers</label>
            <input
              id="containers-max-concurrent"
              type="number"
              step={1}
              className="input-field"
              value={containersMaxConcurrent}
              onChange={(e) => setContainersMaxConcurrent(e.target.value)}
            />
            <span className="form-group-hint">
              Maximum containers running at once; excess spawns fail closed until capacity frees.
            </span>
          </div>
        </div>
        <div className="form-row">
          <div className="form-group flex-1">
            <label htmlFor="containers-ttl-minutes">Idle TTL (minutes)</label>
            <input
              id="containers-ttl-minutes"
              type="number"
              step={1}
              className="input-field"
              value={containersTTLMinutes}
              onChange={(e) => setContainersTTLMinutes(e.target.value)}
            />
            <span className="form-group-hint">
              Idle lifetime before a container is reclaimed; live containers are never reaped mid-turn.
            </span>
          </div>
        </div>
      </div>

      <div className="settings-section card">
        <div className="settings-section-header">
          <div className="settings-section-title-group">
            <h3>Access Management</h3>
            <p className="settings-section-hint">
              Owner token that guards the engine surface. Rotating it signs out every other device immediately; this tab adopts the new token. The token is kept in memory and this tab&apos;s session only, never in persistent storage.
            </p>
          </div>
          <div className="row">
            <button
              type="button"
              className="ghost icon-text-btn"
              data-testid="rotate-token"
              onClick={onPromptRotate}
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
          The current token is never shown. After a rotation, save the new token from the one-time reveal; if it is lost, re-mint one on the Mac Studio with <code>rune-weaver auth token rotate</code>.
        </p>
        {rotateError ? (
          <div className="error-banner" data-testid="rotate-error">
            {rotateError}
          </div>
        ) : null}
      </div>
    </>
  );
}

export default SecurityTab;
