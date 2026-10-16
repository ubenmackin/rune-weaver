// Rune Weaver Dashboard — Recent Reports (Run Digests).

import { useCallback, useEffect, useState } from "react";
import {
  formatRunDuration,
  parseRunTimestamp,
  type RunLogEntry,
} from "../../api";
import { getSharedRecentRuns, getSharedRunTitle } from "./sharedRuns";
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
  // True only for the initial load so co-mounted widgets show a spinner instead of flashing their
  // empty state before the shared fetch settles.
  const [isLoading, setIsLoading] = useState(true);

  // Periodic tick for live relative time formatting ("just now" -> "1m ago")
  const [, setTick] = useState(0);
  useEffect(() => {
    const timer = setInterval(() => {
      setTick((t) => t + 1);
    }, 10000);
    return () => clearInterval(timer);
  }, []);

  const fetchReports = useCallback(async (forceRefresh = false) => {
    try {
      setError(null);
      // Shared single-flight fetch: concurrent dashboard widgets collapse onto one `GET /runs`
      // sized for the hungriest caller, then slice locally.
      const runs = await getSharedRecentRuns(25, { forceRefresh });
      // Filter to terminal / completed runs (non-running, non-parked)
      const completed = (runs || []).filter(
        (r) =>
          r.status !== "running" &&
          r.status !== "awaiting_approval" &&
          (r.status === "ok" ||
            r.status === "completed" ||
            r.status === "error" ||
            r.status === "budget_exceeded" ||
            r.status === "cancelled" ||
            r.status === "skipped" ||
            r.status === "interrupted"),
      );
      setReports(completed.slice(0, 5));
    } catch (err) {
      // Surface fetch failures in the banner above: without this the
      // `{error && banner}` outlet stays dead and failures only reach the log.
      setError(
        err instanceof Error && err.message
          ? `Failed to load recent reports: ${err.message}`
          : "Failed to load recent reports.",
      );
      console.warn("Failed to fetch recent reports:", err);
    } finally {
      // Settle loading on success and failure alike so a failed first load
      // falls through to the empty state instead of spinning forever.
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchReports();
  }, [fetchReports]);

  // Periodic heartbeat polling ensures recent reports are kept fresh even if a
  // WebSocket frame was delayed, dropped, or missed during network reconnection.
  useEffect(() => {
    const interval = setInterval(() => {
      fetchReports();
    }, 8000);
    return () => clearInterval(interval);
  }, [fetchReports]);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (frameType === "run_started" || frameType === "run_completed") {
        // Lifecycle frames carry no payload, so force past the shared
        // freshness window: a newly settled run must appear now, not when the
        // TTL lapses.
        fetchReports(true);
      }
    },
    [fetchReports],
  );

  const handleSocketOpen = useCallback(() => {
    fetchReports(true);
  }, [fetchReports]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  // Tab visibility resync ensures returning to the tab immediately refreshes
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchReports(true);
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [fetchReports]);

  // Single-sourced run title: reuses the shared fallback so Recent Reports,
  // the Working Right Now stream, and the greeting caption never disagree on
  // the same run. Intentional divergence would need its own pinned test.
  function getReportTitle(run: RunLogEntry): string {
    return getSharedRunTitle(run);
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

      {isLoading ? (
        <div className="section-loading">
          <div className="spinner" />
          <p>Loading recent reports…</p>
        </div>
      ) : reports.length === 0 ? (
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
            const isCancelled = report.status === "cancelled";
            const isSkipped = report.status === "skipped";
            const isInterrupted = report.status === "interrupted";
            const date = parseRunTimestamp(report.timestamp);
            const timeAgo = formatRelativeAgo(Date.now() - date.getTime());
            const kindInfo = getReportRunKind(report);

            const outcomeBadgeClass = isOk
              ? "ok"
              : isBudgetExceeded
              ? "budget-exceeded"
              : isCancelled || isSkipped || isInterrupted
              ? "skipped"
              : "error";

            const cardClass = isOk
              ? "status-ok"
              : isBudgetExceeded
              ? "status-budget-exceeded"
              : isCancelled || isSkipped || isInterrupted
              ? "status-skipped"
              : "status-error";

            const outcomeLabel = isOk
              ? "OK"
              : isBudgetExceeded
              ? "BUDGET EXCEEDED"
              : isCancelled
              ? "CANCELLED"
              : isSkipped
              ? "SKIPPED"
              : isInterrupted
              ? "INTERRUPTED"
              : "FAILED";

            return (
              <article key={report.id} className={`report-card ${cardClass}`}>
                <div className="report-card-top">
                  <div className="report-status-badge-row">
                    <span className={`badge report-outcome-badge ${outcomeBadgeClass}`}>
                      {isOk ? (
                        <CheckIcon size={12} />
                      ) : isBudgetExceeded || isSkipped ? (
                        <ClockIcon size={12} />
                      ) : (
                        <CloseIcon size={12} />
                      )}
                      <span>{outcomeLabel}</span>
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
