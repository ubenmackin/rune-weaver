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
    <section
      aria-label="Workspace storage"
      style={{
        margin: "8px 0 16px 0",
        padding: "16px",
        borderRadius: "8px",
        backgroundColor: "var(--bg-card, #1e2533)",
        border: "1px solid var(--border-color, #2d3748)",
      }}
    >
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "flex-start",
          flexWrap: "wrap",
          gap: "8px",
          marginBottom: "8px",
        }}
      >
        <div>
          <h4 style={{ margin: 0 }}>Workspace Storage</h4>
          <p className="settings-section-hint" style={{ margin: "4px 0 0 0" }}>
            Bounded agent scratch under ~/.runeweaver/workspace. Quotas save with the tab below.
          </p>
        </div>
        <div style={{ display: "flex", gap: "8px" }}>
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
        <div className="error-banner" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
          <AlertTriangleIcon size={16} />
          <span>{workspaceError}</span>
        </div>
      ) : workspaceLoading && !workspaceUsage ? (
        <p className="muted text-sm" style={{ margin: 0 }}>Loading workspace usage…</p>
      ) : workspaceUsage ? (
        <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
          {(() => {
            const quotaBytes = workspaceUsage.quotaMB * 1024 * 1024;
            const bytesPercent = workspaceQuotaPercent(workspaceUsage.bytes, quotaBytes);
            const filesPercent = workspaceQuotaPercent(workspaceUsage.files, workspaceUsage.quotaFiles);
            const bar = (percent: number) => (
              <div style={{ height: "8px", borderRadius: "4px", background: "var(--bg-secondary, #141822)", overflow: "hidden" }}>
                <div style={{ width: `${percent}%`, height: "100%", background: percent >= 90 ? "#f56565" : percent >= 70 ? "#ed8936" : "#48bb78", transition: "width 0.2s ease" }} />
              </div>
            );
            return (
              <>
                <div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.85rem", marginBottom: "4px" }}>
                    <span>Disk usage</span>
                    <span className="muted">
                      {formatWorkspaceBytes(workspaceUsage.bytes)} of {workspaceUsage.quotaMB} MB ({bytesPercent}%)
                    </span>
                  </div>
                  {bar(bytesPercent)}
                </div>
                <div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.85rem", marginBottom: "4px" }}>
                    <span>File usage</span>
                    <span className="muted">
                      {(workspaceUsage.files ?? 0).toLocaleString("en-US")} of {(workspaceUsage.quotaFiles ?? 0).toLocaleString("en-US")} files ({filesPercent}%)
                    </span>
                  </div>
                  {bar(filesPercent)}
                </div>
                {workspaceUsage.truncated ? (
                  <div style={{ fontSize: "0.78rem", color: "var(--text-secondary, #a0aec0)" }}>
                    Walk truncated; actual usage may be higher.
                  </div>
                ) : null}
              </>
            );
          })()}
        </div>
      ) : (
        <p className="muted text-sm" style={{ margin: 0 }}>Workspace usage unknown.</p>
      )}
      <div style={{ marginTop: "14px", padding: "12px", borderRadius: "8px", background: "var(--bg-secondary, #141822)", border: "1px solid var(--border-color, #2d3748)" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "8px" }}>
          <div>
            <div style={{ fontSize: "0.85rem", fontWeight: 600 }}>Workspace machine</div>
            <div data-testid="workspace-machine-status" style={{ fontSize: "0.82rem", color: "var(--text-secondary, #a0aec0)", marginTop: "4px" }}>
              {workspaceMachineLoading && !workspaceMachine
                ? "Loading machine status…"
                : workspaceMachineError
                  ? workspaceMachineError
                  : workspaceMachine
                    ? `Machine exists: ${workspaceMachine.exists ? "yes" : "no"} · running: ${workspaceMachine.running ? "yes" : "no"} · image: ${workspaceMachine.image || "none"} · config: ${workspaceMachine.configMatch == null ? "unknown" : workspaceMachine.configMatch ? "match" : "mismatch"}`
                    : "Machine status unknown."}
            </div>
          </div>
          <div style={{ display: "flex", gap: "8px" }}>
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
      <div className="form-row" style={{ display: "flex", gap: "10px", flexWrap: "wrap", marginTop: "14px" }}>
        <div className="form-group" style={{ flex: "1 1 140px" }}>
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
        <div className="form-group" style={{ flex: "1 1 140px" }}>
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
        <div className="form-group" style={{ flex: "1 1 140px" }}>
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
