// Rune Weaver Dashboard — Verified System Pulse card.

import { useCallback, useEffect, useState } from "react";
import {
  getHealth,
  getStagedFiles,
  postSovereignRebaseline,
  resolvePulseRemediation,
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

// Display bound mirroring the engine snapshot so an uncapped payload
// never widens the disclosure.
const MAX_PULSE_REASONS = 8;
const MAX_PULSE_REASON_LENGTH = 160;

function resolvePulseReasons(health: HealthResponse | null): string[] {
  const raw = health?.degradedReasons;
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") continue;
    const trimmed = entry.trim();
    if (!trimmed) continue;
    out.push(trimmed.slice(0, MAX_PULSE_REASON_LENGTH));
    if (out.length >= MAX_PULSE_REASONS) break;
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
    out.push(trimmed.slice(0, MAX_PULSE_REASON_LENGTH));
    if (out.length >= MAX_PULSE_REASONS) break;
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
  // Re-baseline busy flag plus server reason: double-clicks cannot stack
  // ceremonies, and a refused ceremony stays visible instead of vanishing.
  const [rebasing, setRebasing] = useState(false);
  const [rebaselineError, setRebaselineError] = useState<string | null>(null);

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

  const handleRebaseline = useCallback(async () => {
    if (rebasing) return;
    setRebasing(true);
    setRebaselineError(null);
    try {
      await postSovereignRebaseline();
      await refreshTelemetry();
    } catch (error) {
      setRebaselineError(
        error instanceof Error && error.message
          ? error.message
          : "Re-baseline failed.",
      );
    } finally {
      setRebasing(false);
    }
  }, [rebasing, refreshTelemetry]);

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
  const remediation = resolvePulseRemediation(effectiveHealth);
  const modelName = effectiveHealth?.model || "Configured LLM";
  const provider = effectiveHealth?.provider || effectiveHealth?.engine || "RuneWeaver";

  const dotClass =
    pulse === "green" ? "status-green" : pulse === "yellow" ? "status-amber" : "status-red";
  const pillClass =
    pulse === "green" ? "pill-ok" : pulse === "yellow" ? "pill-amber" : "pill-red";
  const pillLabel =
    pulse === "green" ? "Operational" : pulse === "yellow" ? "Degraded" : "Needs action";

  // Details stay visible for every non-green pulse so red and yellow alike
  // expose their backing reasons; green opens only with info notes to show.
  const showDetails =
    pulse !== "green" || reasons.length > 0 || infoNotes.length > 0;
  // Exactly one mapped recovery per red: inbox falls back to the settings
  // surface and every action still renders disabled with no opener, so a red
  // never lands with zero buttons.
  const inboxOpener = onOpenInbox ?? onOpenSettings;
  const policyOpener = onOpenPolicy ?? onOpenSettings;
  const showInboxAction = remediation === "openInbox";
  const showPolicyAction = remediation === "openPolicy";
  const showRebaselineAction = remediation === "rebaseline";
  const showRedActions =
    pulse === "red" &&
    remediation !== "none" &&
    (showRebaselineAction || showInboxAction || showPolicyAction);

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

        {showDetails && (
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

        {showRedActions && (
          <div className="pulse-actions">
            {showRebaselineAction && (
              <>
                <button
                  type="button"
                  className="btn pulse-rebaseline-btn pulse-primary-btn"
                  onClick={() => void handleRebaseline()}
                  disabled={rebasing}
                >
                  {rebasing ? "Re-baselining…" : "Re-baseline & re-verify"}
                </button>
                {rebaselineError && (
                  <p className="pulse-error text-xs" role="alert">
                    {rebaselineError}
                  </p>
                )}
              </>
            )}
            {showInboxAction && (
              <button
                type="button"
                className="btn pulse-inbox-btn pulse-primary-btn"
                onClick={inboxOpener}
                disabled={inboxOpener == null}
              >
                Open inbox
              </button>
            )}
            {showPolicyAction && (
              <button
                type="button"
                className="btn pulse-policy-btn pulse-primary-btn"
                onClick={policyOpener}
                disabled={policyOpener == null}
              >
                Open Policy
              </button>
            )}
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
