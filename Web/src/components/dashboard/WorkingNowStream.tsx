// Rune Weaver Dashboard — Working Right Now Stream.
//
// Real-time visibility into active agent tasks and background executions:
// - Running goal turns and automated schedule jobs
// - Active tool calls with progress counters and live elapsed duration
// - Immediate intervention actions: "View Live in Chat" and "Stop"

import { useCallback, useEffect, useState } from "react";
import {
  cancelRun,
  formatRunDuration,
  isActiveRunStatus,
  listRuns,
  parseRunTimestamp,
  type RunLogEntry,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import { MessageSquareIcon, StopIcon, WrenchIcon } from "../icons";

interface WorkingNowStreamProps {
  onOpenSession?: (sessionId: string) => void;
  onRunCancelled?: () => void;
}

export default function WorkingNowStream({
  onOpenSession,
  onRunCancelled,
}: WorkingNowStreamProps) {
  const [activeRuns, setActiveRuns] = useState<RunLogEntry[]>([]);
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fetchActiveRuns = useCallback(async () => {
    try {
      setError(null);
      const res = await listRuns(30);
      const running = (res.runs || []).filter((r) => isActiveRunStatus(r.status));
      setActiveRuns(running);
    } catch (err) {
      console.warn("Failed to fetch active runs:", err);
    }
  }, []);

  useEffect(() => {
    fetchActiveRuns();
  }, [fetchActiveRuns]);

  // WebSocket updates on run lifecycle frames
  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (
        frameType === "run_started" ||
        frameType === "run_completed" ||
        frameType === "goal_updated"
      ) {
        fetchActiveRuns();
      }
    },
    [fetchActiveRuns],
  );

  useSharedWebSocket(handleWSFrame);

  // Poll while there are active tasks so timers update
  useEffect(() => {
    if (activeRuns.length === 0) return;
    const interval = setInterval(fetchActiveRuns, 4000);
    return () => clearInterval(interval);
  }, [activeRuns.length, fetchActiveRuns]);

  async function handleStop(run: RunLogEntry) {
    try {
      setCancellingId(run.id);
      await cancelRun(run.id);
      setActiveRuns((prev) => prev.filter((r) => r.id !== run.id));
      onRunCancelled?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to cancel run");
    } finally {
      setCancellingId(null);
    }
  }

  function getRunTitle(run: RunLogEntry): string {
    if (run.message && run.message.trim()) return run.message;
    if (run.goalId) return `Goal Execution: ${run.goalId}`;
    if (run.jobID) return `Scheduled Job: ${run.jobID}`;
    return `Interactive Task ${run.id.slice(0, 8)}`;
  }

  function calculateElapsedSeconds(timestamp: string | number): number {
    const started = parseRunTimestamp(timestamp).getTime();
    const now = Date.now();
    return Math.max(0, Math.floor((now - started) / 1000));
  }

  return (
    <section className="dashboard-section working-now-section" aria-label="Tasks working right now">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <span className={`live-pulse-indicator ${activeRuns.length > 0 ? "active" : "idle"}`} />
          <h2 className="dashboard-section-title">Working Right Now</h2>
          {activeRuns.length > 0 ? (
            <span className="dashboard-count-badge running">{activeRuns.length}</span>
          ) : null}
        </div>
        <span className="dashboard-section-subtitle">
          {activeRuns.length > 0
            ? "Live background tasks and subagents currently executing"
            : "Agent is idle and ready for tasks"}
        </span>
      </div>

      {error && <div className="notice-banner error">{error}</div>}

      {activeRuns.length === 0 ? (
        <div className="dashboard-empty-card idle-card">
          <div className="idle-indicator-row">
            <span className="idle-dot" />
            <span className="idle-title">All Systems Idle</span>
          </div>
          <p className="idle-desc">
            No background runs or goals in flight. Give RuneWeaver a task above or trigger a goal.
          </p>
        </div>
      ) : (
        <div className="working-now-list">
          {activeRuns.map((run) => {
            const isBusy = cancellingId === run.id;
            const elapsedSec = calculateElapsedSeconds(run.timestamp);
            const toolCount = run.toolActions?.length ?? 0;

            return (
              <article key={run.id} className="working-task-card">
                <div className="working-task-header">
                  <div className="working-task-title-wrap">
                    <span className="spinner-small" aria-hidden="true" />
                    <h3 className="working-task-title">{getRunTitle(run)}</h3>
                  </div>
                  <span className="elapsed-timer-badge">
                    {elapsedSec < 60 ? `${elapsedSec}s` : `${Math.floor(elapsedSec / 60)}m ${elapsedSec % 60}s`}
                  </span>
                </div>

                <div className="working-task-meta">
                  <span className="badge run-kind-badge">{run.kind || "task"}</span>
                  {toolCount > 0 && (
                    <span className="tool-count-chip">
                      <WrenchIcon size={12} />
                      <span>{toolCount} tool {toolCount === 1 ? "action" : "actions"}</span>
                    </span>
                  )}
                  {run.durationMs != null && (
                    <span className="duration-chip text-xs muted">
                      {formatRunDuration(run.durationMs)}
                    </span>
                  )}
                </div>

                <div className="working-task-actions">
                  {/* Run kinds with a live chat thread: chat, scheduler, goal,
                      fanout, and fanout_worker sessions all carry a sessionID
                      (matching the sidebar's background-session support); index
                      runs have no chat thread. */}
                  {run.sessionID &&
                    run.sessionID.trim() &&
                    run.kind !== "index" && (
                      <button
                        type="button"
                        className="btn open-live-btn"
                        onClick={() => onOpenSession?.(run.sessionID!)}
                      >
                        <MessageSquareIcon size={14} />
                        <span>View Live Turn</span>
                      </button>
                    )}

                  <button
                    type="button"
                    className="btn stop-task-btn"
                    onClick={() => handleStop(run)}
                    disabled={isBusy}
                    aria-label={`Stop task: ${run.id}`}
                  >
                    <StopIcon size={13} />
                    <span>{isBusy ? "Stopping…" : "Stop"}</span>
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
