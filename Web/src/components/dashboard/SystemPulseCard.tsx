// Rune Weaver Dashboard — Verified System Pulse card.

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
  onOpenInbox?: () => void;
  onOpenPolicy?: () => void;
}

// Closed pulse presentation: red parks fail-closed, yellow degrades when degradedReasons is
// non-empty, and green requires an explicit green/ok status. Anything else with a payload present
// still reads as degraded.
type PulseState = "green" | "yellow" | "red";

function resolvePulseReasons(health: HealthResponse | null): string[] {
  const raw = health?.degradedReasons;
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") continue;
    const trimmed = entry.trim();
    if (!trimmed) continue;
    out.push(trimmed);
  }
  return out;
}

// Info notes ride the Details disclosure with no dot effect: gestation
// countdown plus other non-safety copy lives here, never in degradedReasons.
function resolvePulseInfoNotes(health: HealthResponse | null): string[] {
  const raw = health?.infoNotes;
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") continue;
    const trimmed = entry.trim();
    if (!trimmed) continue;
    out.push(trimmed);
  }
  return out;
}

function resolvePulseState(health: HealthResponse | null): PulseState {
  if (!health) return "yellow";
  if (health.status === "red") return "red";
  if (resolvePulseReasons(health).length > 0) return "yellow";
  if (health.status === "green" || health.status === "ok") return "green";
  return "yellow";
}

export default function SystemPulseCard({
  health,
  stagedFilesCount = 0,
  onOpenStagedDrawer,
  onOpenSettings,
  onOpenInbox,
  onOpenPolicy,
}: SystemPulseCardProps) {
  const [liveHealth, setLiveHealth] = useState<HealthResponse | null>(health);
  const [liveStagedCount, setLiveStagedCount] = useState<number>(stagedFilesCount);
  // Retry busy flag so double-clicks cannot stack verification probes; the
  // heartbeat and socket paths share the refresh below without the flag.
  const [retrying, setRetrying] = useState(false);

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
      // A failed probe never clears a parked red: only a fresh passing
      // snapshot moves the pulse, never a timeout or a fetch error.
      if (hRes) setLiveHealth(hRes);
      if (sRes && Array.isArray(sRes.files)) setLiveStagedCount(sRes.files.length);
    } catch {
      // Best-effort telemetry
    }
  }, []);

  const handleRetryVerification = useCallback(async () => {
    setRetrying(true);
    try {
      await refreshTelemetry();
    } finally {
      setRetrying(false);
    }
  }, [refreshTelemetry]);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const type = (frame as { type?: string }).type;
      if (
        type === "file_accepted" ||
        type === "file_discarded" ||
        type === "tool_end" ||
        type === "health_updated"
      ) {
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
  const pulse = resolvePulseState(effectiveHealth);
  const reasons = resolvePulseReasons(effectiveHealth);
  const infoNotes = resolvePulseInfoNotes(effectiveHealth);
  const modelName = effectiveHealth?.model || "Configured LLM";
  const provider = effectiveHealth?.provider || effectiveHealth?.engine || "RuneWeaver";

  const dotClass =
    pulse === "green" ? "status-green" : pulse === "yellow" ? "status-amber" : "status-red";
  const pillClass =
    pulse === "green" ? "pill-ok" : pulse === "yellow" ? "pill-amber" : "pill-red";
  const pillLabel =
    pulse === "green" ? "Operational" : pulse === "yellow" ? "Degraded" : "Needs action";

  return (
    <section className="dashboard-section system-pulse-section" aria-label="System status & telemetry">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <span className={`pulse-indicator ${dotClass}`} />
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
            <span className={`status-pill ${pillClass}`}>
              {pillLabel}
            </span>
          </div>
        </div>

        {(pulse === "yellow" || infoNotes.length > 0) && pulse !== "red" && (
          <details className="pulse-details">
            <summary>Details</summary>
            {effectiveHealth ? (
              reasons.length > 0 || infoNotes.length > 0 ? (
                <>
                  {reasons.length > 0 && (
                    <ul className="pulse-reasons">
                      {reasons.map((reason) => (
                        <li key={reason}>{reason}</li>
                      ))}
                    </ul>
                  )}
                  {infoNotes.length > 0 && (
                    <ul className="pulse-info-notes">
                      {infoNotes.map((note) => (
                        <li key={note}>{note}</li>
                      ))}
                    </ul>
                  )}
                </>
              ) : (
                <p className="text-xs muted">No details reported.</p>
              )
            ) : (
              <p className="text-xs muted">Engine probe did not answer.</p>
            )}
          </details>
        )}

        {pulse === "red" && (
          <div className="pulse-actions">
            <button
              type="button"
              className="btn pulse-inbox-btn"
              onClick={onOpenInbox ?? onOpenSettings}
            >
              Open inbox
            </button>
            <button
              type="button"
              className="btn pulse-retry-btn"
              onClick={() => void handleRetryVerification()}
              disabled={retrying}
            >
              {retrying ? "Retrying…" : "Retry verification"}
            </button>
            <button
              type="button"
              className="btn pulse-policy-btn"
              onClick={onOpenPolicy ?? onOpenSettings}
            >
              Open Policy
            </button>
          </div>
        )}

        <div className="pulse-metric-row">
          <div className="pulse-metric-label">Model Provider</div>
          <div className="pulse-metric-value text-xs font-mono">
            {modelName} ({provider})
          </div>
        </div>

        {effectiveHealth?.version && (
          <div className="pulse-metric-row">
            <div className="pulse-metric-label">Engine Version</div>
            <div className="pulse-metric-value text-xs muted font-mono">
              v{effectiveHealth.version}
            </div>
          </div>
        )}

        <div className="pulse-metric-row staged-changes-row">
          <div className="pulse-metric-label" title="Files staged by the agent (.rune_*) awaiting review before applying">
            Staged File Edits
          </div>
          <div className="pulse-metric-value">
            {liveStagedCount > 0 ? (
              <button
                type="button"
                className="btn-staged-pill active"
                onClick={onOpenStagedDrawer}
                aria-label={`View ${liveStagedCount} staged files`}
              >
                <FileDiffIcon size={12} />
                <span>{liveStagedCount} {liveStagedCount === 1 ? "file" : "files"}</span>
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
