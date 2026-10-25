// Rune Weaver Dashboard — Workspace Storage & Machine control section.

import {
  formatWorkspaceBytes,
  workspaceQuotaPercent,
  type WorkspaceMachineResponse,
  type WorkspaceUsageResponse,
} from "../../api";
import { AlertTriangleIcon, RefreshIcon, StopIcon, TrashIcon } from "../icons";

export interface WorkspaceStorageSectionProps {
  workspaceLoading: boolean;
  pruningWorkspace: boolean;
  workspaceError: string | null;
  workspaceUsage: WorkspaceUsageResponse | null;
  refreshWorkspaceUsage: () => Promise<void>;
  setPendingPruneWorkspace: (val: boolean) => void;
  workspaceMachineLoading: boolean;
  workspaceMachine: WorkspaceMachineResponse | null;
  workspaceMachineError: string | null;
  workspaceMachineAction: "stop" | "recycle" | null;
  handleStopWorkspaceMachine: () => Promise<void>;
  handleRecycleWorkspaceMachine: () => Promise<void>;
  workspaceQuotaMB: number | string;
  setWorkspaceQuotaMB: (val: number | string) => void;
  workspaceQuotaFiles: number | string;
  setWorkspaceQuotaFiles: (val: number | string) => void;
  workspaceTmpTTLDays: number | string;
  setWorkspaceTmpTTLDays: (val: number | string) => void;
}

export function WorkspaceStorageSection({
  workspaceLoading,
  pruningWorkspace,
  workspaceError,
  workspaceUsage,
  refreshWorkspaceUsage,
  setPendingPruneWorkspace,
  workspaceMachineLoading,
  workspaceMachine,
  workspaceMachineError,
  workspaceMachineAction,
  handleStopWorkspaceMachine,
  handleRecycleWorkspaceMachine,
  workspaceQuotaMB,
  setWorkspaceQuotaMB,
  workspaceQuotaFiles,
  setWorkspaceQuotaFiles,
  workspaceTmpTTLDays,
  setWorkspaceTmpTTLDays,
}: WorkspaceStorageSectionProps) {
  return (
    <section aria-label="Workspace storage" className="workspace-storage-section">
      <div className="workspace-storage-head">
        <div>
          <h4 className="m-0">Workspace Storage</h4>
          <p className="settings-section-hint workspace-storage-hint">
            Bounded agent scratch under ~/.runeweaver/workspace. Quotas save with the tab below.
          </p>
        </div>
        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void refreshWorkspaceUsage()}
            disabled={workspaceLoading || pruningWorkspace}
          >
            <RefreshIcon size={14} className={workspaceLoading ? "spin" : ""} />
            <span>{workspaceLoading ? "Loading…" : "Refresh"}</span>
          </button>
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => setPendingPruneWorkspace(true)}
            disabled={workspaceLoading || pruningWorkspace}
          >
            <TrashIcon size={14} />
            <span>{pruningWorkspace ? "Pruning…" : "Prune tmp"}</span>
          </button>
        </div>
      </div>
      {workspaceError ? (
        <div className="error-banner row">
          <AlertTriangleIcon size={16} />
          <span>{workspaceError}</span>
        </div>
      ) : workspaceLoading && !workspaceUsage ? (
        <p className="muted text-sm m-0">Loading workspace usage…</p>
      ) : workspaceUsage ? (
        <div className="workspace-usage-stack">
          {(() => {
            const quotaBytes = workspaceUsage.quotaMB * 1024 * 1024;
            const bytesPercent = workspaceQuotaPercent(workspaceUsage.bytes, quotaBytes);
            const filesPercent = workspaceQuotaPercent(workspaceUsage.files, workspaceUsage.quotaFiles);
            // Threshold color rides a token-bound modifier; only the width stays inline.
            const bar = (percent: number) => {
              const level = percent >= 90 ? "is-critical" : percent >= 70 ? "is-warning" : "is-ok";
              return (
                <div className="progress-track">
                  <div className={`progress-fill workspace-quota-fill ${level}`} style={{ width: `${percent}%` }} />
                </div>
              );
            };
            return (
              <>
                <div>
                  <div className="workspace-usage-row text-sm">
                    <span>Disk usage</span>
                    <span className="muted">
                      {formatWorkspaceBytes(workspaceUsage.bytes)} of {workspaceUsage.quotaMB} MB ({bytesPercent}%)
                    </span>
                  </div>
                  {bar(bytesPercent)}
                </div>
                <div>
                  <div className="workspace-usage-row text-sm">
                    <span>File usage</span>
                    <span className="muted">
                      {(workspaceUsage.files ?? 0).toLocaleString("en-US")} of {(workspaceUsage.quotaFiles ?? 0).toLocaleString("en-US")} files ({filesPercent}%)
                    </span>
                  </div>
                  {bar(filesPercent)}
                </div>
                {workspaceUsage.truncated ? (
                  <div className="text-xs workspace-truncated-note">
                    Walk truncated; actual usage may be higher.
                  </div>
                ) : null}
              </>
            );
          })()}
        </div>
      ) : (
        <p className="muted text-sm m-0">Workspace usage unknown.</p>
      )}
      <div className="workspace-machine-panel">
        <div className="workspace-machine-head">
          <div>
            <div className="workspace-machine-title">Workspace machine</div>
            <div data-testid="workspace-machine-status" className="text-sm workspace-machine-status">
              {workspaceMachineLoading && !workspaceMachine
                ? "Loading machine status…"
                : workspaceMachineError
                  ? workspaceMachineError
                  : workspaceMachine
                    ? `Machine exists: ${workspaceMachine.exists ? "yes" : "no"} · running: ${workspaceMachine.running ? "yes" : "no"} · image: ${workspaceMachine.image || "none"} · config: ${workspaceMachine.configMatch == null ? "unknown" : workspaceMachine.configMatch ? "match" : "mismatch"}`
                    : "Machine status unknown."}
            </div>
          </div>
          <div className="row">
            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={() => void handleStopWorkspaceMachine()}
              disabled={workspaceMachineAction !== null}
            >
              <StopIcon size={14} />
              <span>{workspaceMachineAction === "stop" ? "Stopping…" : "Stop"}</span>
            </button>
            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={() => void handleRecycleWorkspaceMachine()}
              disabled={workspaceMachineAction !== null}
            >
              <RefreshIcon size={14} />
              <span>{workspaceMachineAction === "recycle" ? "Recycling…" : "Recycle"}</span>
            </button>
          </div>
        </div>
      </div>
      <div className="form-row workspace-quota-row">
        <div className="form-group workspace-quota-field">
          <label htmlFor="workspace-quota-mb">Quota (MB)</label>
          <input
            id="workspace-quota-mb"
            type="number"
            step={1}
            className="input-field"
            value={workspaceQuotaMB}
            onChange={(e) =>
              setWorkspaceQuotaMB(
                e.target.value === "" ? "" : Number(e.target.value)
              )
            }
            placeholder="500"
          />
          <span className="form-group-hint">
            Total bytes permitted under the workspace root.
          </span>
        </div>
        <div className="form-group workspace-quota-field">
          <label htmlFor="workspace-quota-files">Max files</label>
          <input
            id="workspace-quota-files"
            type="number"
            step={1}
            className="input-field"
            value={workspaceQuotaFiles}
            onChange={(e) =>
              setWorkspaceQuotaFiles(
                e.target.value === "" ? "" : Number(e.target.value)
              )
            }
            placeholder="10000"
          />
          <span className="form-group-hint">
            Total files permitted under the workspace root.
          </span>
        </div>
        <div className="form-group workspace-quota-field">
          <label htmlFor="workspace-tmp-ttl">Tmp TTL (days)</label>
          <input
            id="workspace-tmp-ttl"
            type="number"
            step={1}
            className="input-field"
            value={workspaceTmpTTLDays}
            onChange={(e) =>
              setWorkspaceTmpTTLDays(
                e.target.value === "" ? "" : Number(e.target.value)
              )
            }
            placeholder="7"
          />
          <span className="form-group-hint">
            Days tmp entries survive; TTL applies on next prune.
          </span>
        </div>
      </div>
    </section>
  );
}

export default WorkspaceStorageSection;
