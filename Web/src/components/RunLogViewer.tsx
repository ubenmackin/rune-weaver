// Rune Weaver Dashboard — Audit log viewer for inspecting chat turns and scheduler job runs.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  cancelRun,
  clearRuns,
  deleteRun,
  formatRunDuration,
  indexRunLabelForRun,
  isActiveRunStatus,
  listApprovals,
  listRuns,
  parseRunTimestamp,
  RUN_LOG_POLL_LIMIT,
  RUN_POLL_INTERVAL_MS,
  type PermissionRequest,
  type RunLogEntry,
} from "../api";
import RunDetailModal from "./RunDetailModal";
import Modal from "./Modal";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import type { WSIncomingFrame } from "../hooks/useSharedWebSocket";
import { useToastStack } from "../hooks/useToastStack";
import { ToastStack } from "./Toast";
import {
  ChevronDownIcon,
  ChevronRightIcon,
  CloseIcon,
  TrashIcon,
  WrenchIcon,
} from "./icons";
import {
  approvalSessionID,
  getSavedEnum,
  isSameSession,
  mergeApprovalFrame,
  persistEnum,
  runSessionID,
} from "../approvalsSession";

export type FilterKind = "all" | "chat" | "scheduler";
export type TimeRange = "all" | "24h" | "7d" | "30d";

// Start plus settle bursts fold into one refetch.
const RUNS_REFRESH_COALESCE_MS = 150;

// One row group: parent plus its fan-out workers; others carry no children.
export interface RunRowGroup {
  parent: RunLogEntry;
  children: RunLogEntry[];
}

export function groupFanOutRows(runs: RunLogEntry[]): RunRowGroup[] {
  const groups: RunRowGroup[] = [];
  let pending: RunLogEntry[] = [];
  for (const run of runs) {
    if (run.kind === "fanout_worker") {
      pending.push(run);
      continue;
    }
    if (run.kind === "fanout") {
      groups.push({ parent: run, children: pending.reverse() });
      pending = [];
      continue;
    }
    groups.push({ parent: run, children: [] });
  }
  for (const worker of pending.reverse()) {
    groups.push({ parent: worker, children: [] });
  }
  return groups;
}

// Fan-out rows read their own family so the swarm never mislabels as chat.
export function runKindLabel(run: RunLogEntry): string {
  if (run.kind === "scheduler") return "Scheduled Job";
  if (run.kind === "index") return indexRunLabelForRun(run);
  if (run.kind === "fanout") return "Fan-out Run";
  if (run.kind === "fanout_worker") return "Fan-out Worker";
  return "Chat Turn";
}

export function getSavedRunsFilterKind(): FilterKind {
  return getSavedEnum<FilterKind>(
    "rw_runs_filter_kind",
    ["all", "chat", "scheduler"],
    "all"
  );
}

export function getSavedRunsTimeRange(): TimeRange {
  return getSavedEnum<TimeRange>(
    "rw_runs_filter_time",
    ["all", "24h", "7d", "30d"],
    "all"
  );
}

// Falls back to overlapping call identifiers so older payloads without a
// session tag still surface when the same gated call awaits a decision.
export function runPendingApprovals(
  run: RunLogEntry,
  approvals: PermissionRequest[] | undefined | null,
): PermissionRequest[] {
  if (!run || !approvals || approvals.length === 0) return [];
  const runSID = runSessionID(run);
  const runCallIDs = new Set<string>();
  if (run.toolActions) {
    for (const action of run.toolActions) {
      if (
        typeof action.callID === "string" &&
        action.callID.trim()
      ) {
        runCallIDs.add(action.callID.trim());
      }
    }
  }
  return approvals.filter((request) => {
    if (isSameSession(approvalSessionID(request), runSID)) return true;
    const approvalCallID =
      typeof request.input?.callID === "string"
        ? request.input.callID.trim()
        : "";
    return approvalCallID !== "" && runCallIDs.has(approvalCallID);
  });
}

export function canCancelRun(run: RunLogEntry): boolean {
  return (
    isActiveRunStatus(run.status) &&
    (run.kind === "fanout" || run.kind === "fanout_worker")
  );
}

export default function RunLogViewer() {
  const [runs, setRuns] = useState<RunLogEntry[]>([]);
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<RunLogEntry | null>(null);
  const [filter, setFilter] = useState<FilterKind>(getSavedRunsFilterKind);
  const [timeRange, setTimeRange] = useState<TimeRange>(getSavedRunsTimeRange);
  const [clearModalOpen, setClearModalOpen] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [pendingDeleteRun, setPendingDeleteRun] =
    useState<RunLogEntry | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  // One swarm stays expanded at a time so the list never fills with workers.
  const [expandedRunId, setExpandedRunId] = useState<string | null>(null);
  const [pendingCancelRun, setPendingCancelRun] =
    useState<RunLogEntry | null>(null);
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast } =
    useToastStack();

  const handleFilterChange = (nextFilter: FilterKind) => {
    setFilter(nextFilter);
    persistEnum("rw_runs_filter_kind", nextFilter);
  };

  const handleTimeRangeChange = (nextRange: TimeRange) => {
    setTimeRange(nextRange);
    persistEnum("rw_runs_filter_time", nextRange);
  };

  const exportRunsJson = () => {
    const data = JSON.stringify(runs, null, 2);
    const blob = new Blob([data], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `runs-export-${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(a);
    a.click();
    // Defer revoking the object URL so the download starts before teardown.
    a.removeAttribute("href");
    document.body.removeChild(a);
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  const handleClearAllRuns = async () => {
    setClearing(true);
    try {
      await clearRuns();
      setRuns((prev) => prev.filter((r) => isActiveRunStatus(r.status)));
      setSelected((prev) => (prev && isActiveRunStatus(prev.status) ? prev : null));
      setClearModalOpen(false);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to clear runs");
    } finally {
      setClearing(false);
    }
  };

  const handleDeleteRun = async (id: string, e?: React.MouseEvent) => {
    if (e) e.stopPropagation();
    const target = runs.find((r) => r.id === id) ?? null;
    // A stale identifier fails visibly instead of opening an empty confirm.
    if (!target) {
      setError("Failed to delete run");
      return;
    }
    setPendingDeleteRun(target);
  };

  async function confirmDeleteRun() {
    if (!pendingDeleteRun) return;
    const id = pendingDeleteRun.id;
    setDeletingId(id);
    try {
      await deleteRun(id);
      setRuns((prev) => prev.filter((r) => r.id !== id));
      if (selected?.id === id) setSelected(null);
      setPendingDeleteRun(null);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to delete run");
    } finally {
      setDeletingId(null);
    }
  }

  function cancelDeleteRun() {
    setPendingDeleteRun(null);
  }

  const refreshApprovals = useCallback(async () => {
    try {
      const response = await listApprovals();
      if (response && Array.isArray(response.approvals)) {
        setApprovals(response.approvals);
      }
    } catch {
      // Badge is best-effort; runs remain visible without it.
    }
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listRuns(RUN_LOG_POLL_LIMIT);
      setRuns(response.runs);
      await refreshApprovals();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Runs failed");
    } finally {
      setLoading(false);
    }
  }, [refreshApprovals]);

  // First frame schedules, frames inside the window are absorbed.
  const refreshTimerRef = useRef<ReturnType<typeof window.setTimeout> | null>(null);

  const scheduleRunsRefresh = useCallback(() => {
    if (refreshTimerRef.current !== null) return;
    refreshTimerRef.current = window.setTimeout(() => {
      refreshTimerRef.current = null;
      void refresh();
    }, RUNS_REFRESH_COALESCE_MS);
  }, [refresh]);

  useEffect(() => {
    return () => {
      if (refreshTimerRef.current !== null) window.clearTimeout(refreshTimerRef.current);
      refreshTimerRef.current = null;
    };
  }, []);

  // Approval prompts join the badge set immediately; run frames are
  // type-only wake-ups that refetch the list while unknown types stay ignored.
  const handleWSFrame = useCallback(
    (data: WSIncomingFrame) => {
      switch (data.type) {
        case "run_started":
        case "run_completed":
          scheduleRunsRefresh();
          return;
        default:
          break;
      }
      const request = mergeApprovalFrame(data);
      if (request) {
        setApprovals((previous) =>
          previous.some((item) => item.id === request.id)
            ? previous
            : [...previous, request]
        );
      }
    },
    [scheduleRunsRefresh]
  );

  // A reconnect may have missed frames, so the open event revalidates
  // through the same coalescing window as a burst.
  const handleSocketOpen = useCallback(() => {
    scheduleRunsRefresh();
  }, [scheduleRunsRefresh]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  // A backgrounded tab may miss frames, so foreground return revalidates
  // through the same coalescer as a near-simultaneous reopen.
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") scheduleRunsRefresh();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [scheduleRunsRefresh]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    Promise.all([listRuns(RUN_LOG_POLL_LIMIT), listApprovals().catch(() => null)])
      .then(([runsResponse, approvalsResponse]) => {
        if (cancelled) return;
        setRuns(runsResponse.runs);
        if (approvalsResponse && Array.isArray(approvalsResponse.approvals)) {
          setApprovals(approvalsResponse.approvals);
        }
      })
      .catch((failure) => {
        if (!cancelled) {
          setError(failure instanceof ApiError ? failure.message : "Runs failed");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Running rows keep history fresh and parked rows keep approvals fresh.
  const hasRunning = runs.some((r) => isActiveRunStatus(r.status));
  const hasParked = runs.some((r) => r.status === "awaiting_approval");
  useEffect(() => {
    if (!hasRunning && !hasParked) return;
    const interval = setInterval(() => {
      // The poll is a backstop only, so it rides the same coalescer
      // as WS bursts instead of firing parallel GETs beside them.
      if (hasRunning) {
        scheduleRunsRefresh();
      } else {
        void refreshApprovals();
      }
    }, RUN_POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [hasRunning, hasParked, refreshApprovals, scheduleRunsRefresh]);

  useEffect(() => {
    if (!selected) return;
    const updated = runs.find((r) => r.id === selected.id);
    if (
      updated &&
      (updated.status !== selected.status ||
        updated.response !== selected.response)
    ) {
      setSelected(updated);
    }
  }, [runs, selected]);

  // Fires one stop request and refetches so settled badges appear as workers stop.
  async function performCancel(run: RunLogEntry, scope: "run" | "worker") {
    setCancellingId(run.id);
    try {
      await cancelRun(run.id);
      pushSuccessToast(
        scope === "run"
          ? "Cancel requested for this fan-out run. The whole swarm is stopping; completed worker output is kept."
          : "Cancel requested for this worker. The rest of the swarm keeps running.",
      );
      // While any row still reads running the poller keeps converging the
      // remaining workers, so one refetch here is enough to start the settle.
      await refresh();
    } catch (failure) {
      pushErrorToast(
        failure instanceof ApiError ? failure.message : "Failed to cancel run",
      );
    } finally {
      setCancellingId(null);
    }
  }

  // A whole-swarm stop confirms first; a worker stop fires immediately.
  function handleCancelClick(run: RunLogEntry, e?: React.MouseEvent) {
    if (e) e.stopPropagation();
    if (run.kind === "fanout") { setPendingCancelRun(run); return; }
    void performCancel(run, "worker");
  }

  function dismissPendingCancel() {
    // A stop in flight must finish before the dialog closes.
    if (pendingCancelRun && cancellingId === pendingCancelRun.id) return;
    setPendingCancelRun(null);
  }

  async function confirmPendingCancel() {
    if (!pendingCancelRun) return;
    const target = pendingCancelRun;
    await performCancel(target, "run");
    // Close on success and failure alike; a failure already toasted honestly.
    setPendingCancelRun(null);
  }

  // Groups form first so parent plus workers travel together, then the
  // parent alone decides whether the group passes the kind/time filters.
  const groups = groupFanOutRows(runs);
  const filteredGroups = groups.filter((group) => {
    const run = group.parent;
    if (filter === "chat" && run.kind !== "chat") return false;
    if (filter === "scheduler" && run.kind !== "scheduler") return false;

    if (timeRange !== "all") {
      const runTime = parseRunTimestamp(run.timestamp).getTime();
      const now = Date.now();
      if (timeRange === "24h" && now - runTime > 86_400_000) return false;
      if (timeRange === "7d" && now - runTime > 7 * 86_400_000) return false;
      if (timeRange === "30d" && now - runTime > 30 * 86_400_000) return false;
    }
    return true;
  });

  return (
    <section className="panel" aria-label="Run log viewer">
      <div className="panel-header-row">
        <div>
          <h2>Run Log</h2>
          <p className="muted text-sm">
            Audit history of interactive chat turns and background scheduled
            jobs. Running fan-out runs can be stopped here; cancelling a
            fan-out tool call from chat stops its whole swarm.
          </p>
        </div>

        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn danger-hover"
            onClick={() => setClearModalOpen(true)}
            disabled={loading || runs.length === 0}
            title="Clean up or archive run history"
            aria-label="Clean up run history"
          >
            <TrashIcon size={14} />
            <span>Clear Logs</span>
          </button>
          <span className="muted text-sm">
            {filteredGroups.length === groups.length
              ? `${groups.length} entries`
              : `${filteredGroups.length} of ${groups.length} entries`}
          </span>
        </div>
      </div>

      <div className="filter-controls-container">
        <div className="filter-chip-row">
          <span className="filter-group-label muted text-xs">Source:</span>
          <button
            type="button"
            className={`filter-chip ${filter === "all" ? "active" : ""}`}
            onClick={() => handleFilterChange("all")}
          >
            All Runs ({runs.length})
          </button>
          <button
            type="button"
            className={`filter-chip ${filter === "scheduler" ? "active" : ""}`}
            onClick={() => handleFilterChange("scheduler")}
          >
            Scheduled Jobs ({runs.filter((r) => r.kind === "scheduler").length})
          </button>
          <button
            type="button"
            className={`filter-chip ${filter === "chat" ? "active" : ""}`}
            onClick={() => handleFilterChange("chat")}
          >
            Chat Turns ({runs.filter((r) => r.kind === "chat").length})
          </button>
        </div>

        <div className="filter-chip-row time-filter-row">
          <span className="filter-group-label muted text-xs">Time:</span>
          <button
            type="button"
            className={`filter-chip ${timeRange === "all" ? "active" : ""}`}
            onClick={() => handleTimeRangeChange("all")}
          >
            All Time
          </button>
          <button
            type="button"
            className={`filter-chip ${timeRange === "24h" ? "active" : ""}`}
            onClick={() => handleTimeRangeChange("24h")}
          >
            Last Day
          </button>
          <button
            type="button"
            className={`filter-chip ${timeRange === "7d" ? "active" : ""}`}
            onClick={() => handleTimeRangeChange("7d")}
          >
            Last Week
          </button>
          <button
            type="button"
            className={`filter-chip ${timeRange === "30d" ? "active" : ""}`}
            onClick={() => handleTimeRangeChange("30d")}
          >
            Last Month
          </button>
        </div>
      </div>

      {error ? <p className="error">{error}</p> : null}

      {filteredGroups.length === 0 && !loading ? (
        <div className="empty-state-box">
          <p className="muted">
            {runs.length === 0
              ? "No runs yet. Chat turns and scheduled job firings will appear here with complete responses and execution audits."
              : "No runs match the selected filters."}
          </p>
        </div>
      ) : null}

      <div className="run-cards-list">
        {filteredGroups.map((group) => {
          // Amber badge only while this run still has an unresolved approval.
          const run = group.parent;
          const pendingCount = runPendingApprovals(run, approvals).length;
          const duration = formatRunDuration(run.durationMs);
          const workerCount = group.children.length;
          const isFanOutParent = run.kind === "fanout" && workerCount > 0;
          const isExpanded = expandedRunId === run.id;
          return (
            <div className="run-card" key={run.id}>
              <div className="run-card-main">
                <div className="run-card-header">
                  <span className={`status-pill ${run.status}`}>
                    {run.status === "running"
                      ? "IN PROGRESS"
                      : run.status === "awaiting_approval"
                        ? "AWAITING APPROVAL"
                        : run.status === "budget_exceeded"
                          ? "BUDGET EXCEEDED"
                          : run.status.toUpperCase()}
                  </span>
                  {pendingCount > 0 ? (
                    <span
                      className="pending-approval-badge"
                      data-testid={`run-pending-${run.id}`}
                      title={`${pendingCount} approval${pendingCount > 1 ? "s" : ""} awaiting decision for this run`}
                    >
                      Pending approval ({pendingCount})
                    </span>
                  ) : null}
                  <span className="run-kind-tag">{runKindLabel(run)}</span>
                  <span className="run-time-muted">
                    {parseRunTimestamp(run.timestamp).toLocaleString()}
                  </span>
                  {duration ? (
                    <span className="run-time-muted">• {duration}</span>
                  ) : null}
                </div>

                <div className="run-prompt-preview">{run.message}</div>

                {run.toolActions && run.toolActions.length > 0 ? (
                  <div className="run-tool-pills">
                    <WrenchIcon size={12} className="muted" />
                    <span className="text-xs muted">
                      {run.toolActions.map((t) => t.toolName).join(", ")}
                    </span>
                  </div>
                ) : null}

                {isFanOutParent ? (
                  <div className="run-tool-pills">
                    <button
                      type="button"
                      className="ghost text-sm"
                      onClick={() => setExpandedRunId(isExpanded ? null : run.id)}
                      aria-expanded={isExpanded}
                      aria-label={
                        isExpanded
                          ? `Collapse worker turns for run ${run.id}`
                          : `Expand worker turns for run ${run.id}`
                      }
                    >
                      {isExpanded ? (
                        <ChevronDownIcon size={12} />
                      ) : (
                        <ChevronRightIcon size={12} />
                      )}
                    </button>
                    <span className="text-xs muted">
                      {workerCount} worker turn{workerCount > 1 ? "s" : ""}
                    </span>
                  </div>
                ) : null}

                {isFanOutParent && isExpanded ? (
                  <div className="run-workers-indent">
                    {group.children.map((worker) => {
                      const workerDuration = formatRunDuration(worker.durationMs);
                      return (
                        <div className="run-tool-pills" key={worker.id}>
                          <span className={`status-pill ${worker.status}`}>
                            {worker.status === "running"
                              ? "IN PROGRESS"
                              : worker.status === "awaiting_approval"
                                ? "AWAITING APPROVAL"
                                : worker.status === "budget_exceeded"
                                  ? "BUDGET EXCEEDED"
                                  : worker.status.toUpperCase()}
                          </span>
                          <span className="run-kind-tag">{runKindLabel(worker)}</span>
                          <span className="run-prompt-preview">{worker.message}</span>
                          {workerDuration ? (
                            <span className="run-time-muted">• {workerDuration}</span>
                          ) : null}
                          {canCancelRun(worker) ? (
                            <button
                              type="button"
                              className="ghost text-sm danger-hover"
                              onClick={(e) => handleCancelClick(worker, e)}
                              disabled={cancellingId === worker.id}
                              title="Stop this worker only"
                            >
                              {cancellingId === worker.id ? "Cancelling…" : "Cancel"}
                            </button>
                          ) : null}
                        </div>
                      );
                    })}
                  </div>
                ) : null}
              </div>

              <div className="run-card-action">
                {canCancelRun(run) ? (
                  <button
                    type="button"
                    className="ghost text-sm danger-hover"
                    onClick={(e) => handleCancelClick(run, e)}
                    disabled={cancellingId === run.id}
                    title={
                      run.kind === "fanout"
                        ? "Stop the whole swarm"
                        : "Stop this worker only"
                    }
                  >
                    {cancellingId === run.id
                      ? "Cancelling…"
                      : run.kind === "fanout"
                        ? "Cancel run"
                        : "Cancel"}
                  </button>
                ) : null}
                <button
                  type="button"
                  className="ghost text-sm"
                  onClick={() => setSelected(run)}
                >
                  Details
                </button>
                <button
                  type="button"
                  className="icon-button danger-hover"
                  onClick={(e) => void handleDeleteRun(run.id, e)}
                  disabled={deletingId === run.id}
                  title="Delete run entry"
                  aria-label="Delete run"
                >
                  <TrashIcon size={13} />
                </button>
              </div>
            </div>
          );
        })}
      </div>

      {selected ? (
        <RunDetailModal run={selected} onClose={() => setSelected(null)} />
      ) : null}

      {pendingDeleteRun ? (
        <Modal
          label="Confirm delete run"
          onClose={() => {
            if (deletingId === pendingDeleteRun.id) return;
            cancelDeleteRun();
          }}
          onConfirm={() => {
            if (deletingId === pendingDeleteRun.id) return;
            void confirmDeleteRun();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete run entry?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDeleteRun}
              disabled={deletingId === pendingDeleteRun.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted run-modal-paragraph">
              This will permanently delete this run entry. This cannot be
              undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDeleteRun}
              disabled={deletingId === pendingDeleteRun.id}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDeleteRun()}
              disabled={deletingId === pendingDeleteRun.id}
              aria-label="Confirm delete run"
            >
              {deletingId === pendingDeleteRun.id ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* A fan-out stop never fires from a single click. */}
      {pendingCancelRun ? (
        <Modal
          label="Confirm cancel run"
          onClose={dismissPendingCancel}
          onConfirm={() => {
            if (cancellingId === pendingCancelRun.id) return;
            void confirmPendingCancel();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Cancel fan-out run?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={dismissPendingCancel}
              disabled={cancellingId === pendingCancelRun.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted run-modal-paragraph">
              This stops the whole swarm. Every worker still in flight is
              asked to stop. Completed worker output is kept.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={dismissPendingCancel}
              disabled={cancellingId === pendingCancelRun.id}
            >
              Keep running
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmPendingCancel()}
              disabled={cancellingId === pendingCancelRun.id}
              aria-label="Confirm cancel run"
            >
              {cancellingId === pendingCancelRun.id
                ? "Cancelling…"
                : "Cancel run"}
            </button>
          </div>
        </Modal>
      ) : null}

      {clearModalOpen ? (
        <Modal
          label="Clean up run history"
          onClose={() => {
            if (!clearing) setClearModalOpen(false);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Clean up Run History</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setClearModalOpen(false)}
              disabled={clearing}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted run-modal-paragraph-spaced">
              You can archive your execution history by downloading an audit export (JSON) before clearing.
              Clearing will permanently delete all completed run entries. In-progress runs will be preserved.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={exportRunsJson}
              title="Download all runs as JSON before clearing"
            >
              Export JSON
            </button>
            <button
              type="button"
              className="ghost"
              onClick={() => setClearModalOpen(false)}
              disabled={clearing}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void handleClearAllRuns()}
              disabled={clearing}
              aria-label="Confirm clear all runs"
            >
              {clearing ? "Clearing…" : "Clear All"}
            </button>
          </div>
        </Modal>
      ) : null}

      <ToastStack toasts={toasts} onDismiss={dismissToast} />
    </section>
  );
}
