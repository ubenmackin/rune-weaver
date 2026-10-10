// Rune Weaver Dashboard — System Pulse & Telemetry.
//
// Displays operational cockpit telemetry:
// - Engine connectivity and active model/provider
// - Workspace staged git changes count
// - Direct shortcuts to Settings and Staged Changes

import { useCallback, useEffect, useState } from "react";
import {
  getHealth,
  getStagedFiles,
  type HealthResponse,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
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
  const [liveHealth, setLiveHealth] = useState<HealthResponse | null>(health);
  const [liveStagedCount, setLiveStagedCount] = useState<number>(stagedFilesCount);

  useEffect(() => {
    if (health) setLiveHealth(health);
  }, [health]);

  useEffect(() => {
    if (stagedFilesCount !== undefined) setLiveStagedCount(stagedFilesCount);
  }, [stagedFilesCount]);

  const refreshTelemetry = useCallback(async () => {
    try {
      const [hRes, sRes] = await Promise.all([
        getHealth().catch(() => null),
        getStagedFiles().catch(() => null),
      ]);
      if (hRes) setLiveHealth(hRes);
      if (sRes && Array.isArray(sRes.files)) setLiveStagedCount(sRes.files.length);
    } catch {
      // Best-effort telemetry
    }
  }, []);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const type = (frame as { type?: string }).type;
      if (type === "file_accepted" || type === "file_discarded" || type === "tool_end") {
        void refreshTelemetry();
      }
    },
    [refreshTelemetry],
  );

  const handleSocketOpen = useCallback(() => {
    void refreshTelemetry();
  }, [refreshTelemetry]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  // Tab visibility resync
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        void refreshTelemetry();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [refreshTelemetry]);

  // Periodic heartbeat keeps telemetry and engine connectivity accurate
  useEffect(() => {
    const interval = setInterval(() => {
      void refreshTelemetry();
    }, 12000);
    return () => clearInterval(interval);
  }, [refreshTelemetry]);

  const effectiveHealth = liveHealth ?? health;
  const effectiveStagedCount = liveStagedCount;
  const isHealthy = effectiveHealth?.status === "ok";
  const modelName = effectiveHealth?.model || "Configured LLM";
  const provider = effectiveHealth?.provider || effectiveHealth?.engine || "RuneWeaver";

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
            {effectiveStagedCount > 0 ? (
              <button
                type="button"
                className="btn-staged-pill active"
                onClick={onOpenStagedDrawer}
                aria-label={`View ${effectiveStagedCount} staged files`}
              >
                <FileDiffIcon size={12} />
                <span>{effectiveStagedCount} {effectiveStagedCount === 1 ? "file" : "files"}</span>
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
