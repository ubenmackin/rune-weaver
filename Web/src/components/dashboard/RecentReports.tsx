// Rune Weaver Dashboard — Recent Reports (Run Digests).
//
// Shows executive report summaries of completed background runs rather than
// raw message threads:
// - Status outcome badges (OK, Error)
// - Execution duration and token expenditure
// - Direct inspection of run logs and linked chat turns

import { useCallback, useEffect, useState } from "react";
import {
  formatRunDuration,
  listRuns,
  parseRunTimestamp,
  type RunLogEntry,
} from "../../api";
import { formatRelativeAgo } from "../../relativeTime";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import {
  CheckIcon,
  ChevronRightIcon,
  ClockIcon,
  CloseIcon,
  EyeIcon,
  FanOutIcon,
  MessageSquareIcon,
  RunsIcon,
  SearchIcon,
  TargetIcon,
} from "../icons";

export type ReportRunKind =
  | "goal"
  | "schedule"
  | "index"
  | "fanout"
  | "fanout_worker"
  | "chat";

export interface ReportRunKindInfo {
  kind: ReportRunKind;
  label: string;
  className: string;
}

export function getReportRunKind(run: RunLogEntry): ReportRunKindInfo {
  if (run.goalId || run.kind === "goal") {
    return { kind: "goal", label: "Goal", className: "kind-goal" };
  }
  if (run.jobID || run.kind === "scheduler") {
    return { kind: "schedule", label: "Scheduled", className: "kind-schedule" };
  }
  if (run.kind === "index") {
    return { kind: "index", label: "Index", className: "kind-index" };
  }
  if (run.kind === "fanout") {
    return { kind: "fanout", label: "Fan-out", className: "kind-fanout" };
  }
  if (run.kind === "fanout_worker") {
    return { kind: "fanout_worker", label: "Worker", className: "kind-worker" };
  }
  return { kind: "chat", label: "Chat", className: "kind-chat" };
}

function renderReportKindIcon(kind: ReportRunKind) {
  switch (kind) {
    case "goal":
      return <TargetIcon size={11} />;
    case "schedule":
      return <ClockIcon size={11} />;
    case "index":
      return <SearchIcon size={11} />;
    case "fanout":
    case "fanout_worker":
      return <FanOutIcon size={11} />;
    case "chat":
    default:
      return <MessageSquareIcon size={11} />;
  }
}

interface RecentReportsProps {
  onOpenRuns?: () => void;
  onInspectRun?: (run: RunLogEntry) => void;
  onOpenSession?: (sessionId: string) => void;
}

export default function RecentReports({
  onOpenRuns,
  onInspectRun,
  onOpenSession,
}: RecentReportsProps) {
  const [reports, setReports] = useState<RunLogEntry[]>([]);
  const [error, setError] = useState<string | null>(null);

  const fetchReports = useCallback(async () => {
    try {
      setError(null);
      const res = await listRuns(25);
      // Filter to terminal / completed runs
      const completed = (res.runs || []).filter(
        (r) => r.status === "ok" || r.status === "error" || r.status === "completed" || r.status === "budget_exceeded",
      );
      setReports(completed.slice(0, 5));
    } catch (err) {
      console.warn("Failed to fetch recent reports:", err);
    }
  }, []);

  useEffect(() => {
    fetchReports();
  }, [fetchReports]);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (frameType === "run_started" || frameType === "run_completed") {
        fetchReports();
      }
    },
    [fetchReports],
  );

  useSharedWebSocket(handleWSFrame);

  function getReportTitle(run: RunLogEntry): string {
    if (run.message && run.message.trim()) return run.message;
    if (run.jobID) return `Scheduled Job: ${run.jobID}`;
    if (run.goalId) return `Goal Turn: ${run.goalId}`;
    return `Completed Task ${run.id.slice(0, 8)}`;
  }

  return (
    <section className="dashboard-section recent-reports-section" aria-label="Recent reports">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <RunsIcon size={18} className="dashboard-section-icon accent-purple" />
          <h2 className="dashboard-section-title">Recent Reports</h2>
          {reports.length > 0 ? (
            <span className="dashboard-count-badge">{reports.length}</span>
          ) : null}
        </div>
        <button
          type="button"
          className="btn-link view-all-link"
          onClick={() => onOpenRuns?.()}
        >
          <span>View All</span>
          <ChevronRightIcon size={13} />
        </button>
      </div>

      {error && <div className="notice-banner error">{error}</div>}

      {reports.length === 0 ? (
        <div className="dashboard-empty-card empty-reports-card">
          <p className="empty-reports-desc">
            No completed runs recorded yet. Automated and chat runs will report outcomes here.
          </p>
        </div>
      ) : (
        <div className="recent-reports-list">
          {reports.map((report) => {
            const isOk = report.status === "ok" || report.status === "completed";
            const isBudgetExceeded = report.status === "budget_exceeded";
            const date = parseRunTimestamp(report.timestamp);
            const timeAgo = formatRelativeAgo(Date.now() - date.getTime());
            const kindInfo = getReportRunKind(report);

            return (
              <article key={report.id} className={`report-card ${isOk ? "status-ok" : isBudgetExceeded ? "status-budget-exceeded" : "status-error"}`}>
                <div className="report-card-top">
                  <div className="report-status-badge-row">
                    <span className={`badge report-outcome-badge ${isOk ? "ok" : isBudgetExceeded ? "budget-exceeded" : "error"}`}>
                      {isOk ? <CheckIcon size={12} /> : isBudgetExceeded ? <ClockIcon size={12} /> : <CloseIcon size={12} />}
                      <span>{isOk ? "OK" : isBudgetExceeded ? "BUDGET EXCEEDED" : "FAILED"}</span>
                    </span>
                    <span
                      className={`badge report-kind-badge ${kindInfo.className}`}
                      data-testid="report-kind-badge"
                    >
                      {renderReportKindIcon(kindInfo.kind)}
                      <span>{kindInfo.label}</span>
                    </span>
                    <span className="report-time text-xs muted">{timeAgo}</span>
                  </div>

                  <div className="report-card-metrics text-xs muted">
                    {report.durationMs != null && (
                      <span className="report-metric">{formatRunDuration(report.durationMs)}</span>
                    )}
                    {report.durationMs != null && report.totalTokens != null && report.totalTokens > 0 && (
                      <span className="report-metric-sep" aria-hidden="true">•</span>
                    )}
                    {report.totalTokens != null && report.totalTokens > 0 && (
                      <span className="report-metric">{report.totalTokens.toLocaleString()} tokens</span>
                    )}
                  </div>
                </div>

                <h3 className="report-card-title">{getReportTitle(report)}</h3>

                {report.response && (
                  <p className="report-card-snippet">
                    {report.response.slice(0, 140)}
                    {report.response.length > 140 ? "…" : ""}
                  </p>
                )}

                <div className="report-card-footer">
                  <button
                    type="button"
                    className="btn-link inspect-report-link text-xs"
                    onClick={() => onInspectRun?.(report)}
                  >
                    <EyeIcon size={12} />
                    <span>Inspect Run</span>
                  </button>

                  {/* Run kinds with a live chat thread: chat, scheduler, goal,
                      fanout, and fanout_worker sessions all carry a sessionID
                      (matching the sidebar's background-session support); index
                      runs have no chat thread. */}
                  {report.sessionID &&
                    report.sessionID.trim() &&
                    report.kind !== "index" && (
                      <button
                        type="button"
                        className="btn-link open-session-link text-xs"
                        onClick={() => onOpenSession?.(report.sessionID!)}
                      >
                        <MessageSquareIcon size={12} />
                        <span>Thread</span>
                      </button>
                    )}
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
