// Rune Weaver Dashboard — System Pulse & Telemetry.
//
// Displays operational cockpit telemetry:
// - Engine connectivity and active model/provider
// - Workspace staged git changes count
// - Direct shortcuts to Settings and Staged Changes

import type { HealthResponse } from "../../api";
import { FileDiffIcon, SettingsIcon } from "../icons";

interface SystemPulseCardProps {
  health: HealthResponse | null;
  stagedFilesCount?: number;
  onOpenStagedDrawer?: () => void;
  onOpenSettings?: () => void;
}

export default function SystemPulseCard({
  health,
  stagedFilesCount = 0,
  onOpenStagedDrawer,
  onOpenSettings,
}: SystemPulseCardProps) {
  const isHealthy = health?.status === "ok";
  const modelName = health?.model || "Configured LLM";
  const provider = health?.provider || health?.engine || "RuneWeaver";

  return (
    <section className="dashboard-section system-pulse-section" aria-label="System status & telemetry">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <span className={`pulse-indicator ${isHealthy ? "status-green" : "status-amber"}`} />
          <h2 className="dashboard-section-title">System Pulse</h2>
        </div>
        {onOpenSettings && (
          <button
            type="button"
            className="icon-button settings-shortcut-btn"
            onClick={onOpenSettings}
            title="Open Settings"
            aria-label="Open Settings"
          >
            <SettingsIcon size={15} />
          </button>
        )}
      </div>

      <div className="system-pulse-card">
        <div className="pulse-metric-row">
          <div className="pulse-metric-label">Engine Status</div>
          <div className="pulse-metric-value">
            <span className={`status-pill ${isHealthy ? "pill-ok" : "pill-amber"}`}>
              {isHealthy ? "Operational" : "Degraded"}
            </span>
          </div>
        </div>

        <div className="pulse-metric-row">
          <div className="pulse-metric-label">Model Provider</div>
          <div className="pulse-metric-value text-xs font-mono">
            {modelName} ({provider})
          </div>
        </div>

        {health?.version && (
          <div className="pulse-metric-row">
            <div className="pulse-metric-label">Engine Version</div>
            <div className="pulse-metric-value text-xs muted font-mono">
              v{health.version}
            </div>
          </div>
        )}

        <div className="pulse-metric-row staged-changes-row">
          <div className="pulse-metric-label" title="Files staged by the agent (.rune_*) awaiting review before applying">
            Staged File Edits
          </div>
          <div className="pulse-metric-value">
            {stagedFilesCount > 0 ? (
              <button
                type="button"
                className="btn-staged-pill active"
                onClick={onOpenStagedDrawer}
                aria-label={`View ${stagedFilesCount} staged files`}
              >
                <FileDiffIcon size={12} />
                <span>{stagedFilesCount} {stagedFilesCount === 1 ? "file" : "files"}</span>
              </button>
            ) : (
              <span className="text-xs muted">Clean workspace</span>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}
