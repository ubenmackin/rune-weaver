// Rune Weaver Dashboard — Audit log viewer for inspecting chat turns and scheduler job runs.

import { useCallback, useEffect, useState } from "react";
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
import { useToastStack } from "../hooks/useToastStack";
import { ToastStack } from "./Toast";
import { ChevronDownIcon, ChevronRightIcon, CloseIcon, RefreshIcon, TrashIcon, WrenchIcon } from "./icons";
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

// One rendered row group: the parent record plus the fan-out worker rows that
// belong to its swarm. Non-fan-out parents carry no children.
export interface RunRowGroup {
  parent: RunLogEntry;
  children: RunLogEntry[];
}

// Groups fan-out worker rows under their parent swarm record.
export function groupFanOutRows(runs: RunLogEntry[]): RunRowGroup[] {
  const groups: RunRowGroup[] = [];
  let pendingWorkers: RunLogEntry[] = [];
  for (const run of runs) {
    if (run.kind === "fanout_worker") {
      pendingWorkers.push(run);
      continue;
    }
    if (run.kind === "fanout") {
      groups.push({ parent: run, children: pendingWorkers.reverse() });
      pendingWorkers = [];
      continue;
    }
    groups.push({ parent: run, children: [] });
  }
  for (const worker of pendingWorkers.reverse()) {
    groups.push({ parent: worker, children: [] });
  }
  return groups;
}

// Display label per run kind; fan-out rows read their own family so the swarm
// shape and its worker turns never mislabel as chat turns.
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
    "all",
  );
}

export function getSavedRunsTimeRange(): TimeRange {
  return getSavedEnum<TimeRange>(
    "rw_runs_filter_time",
    ["all", "24h", "7d", "30d"],
    "all",
  );
}

// Matches unresolved approvals to one run by owning session, falling back to
// overlapping tool call identifiers so older payloads without a session tag
// still surface when the same gated call is awaiting a decision.
export function runPendingApprovals(
  run: RunLogEntry,
  approvals: PermissionRequest[] | undefined | null,
): PermissionRequest[] {
  if (!run || !approvals || approvals.length === 0) return [];
  const runSID = runSessionID(run);
  const runCallIDs = new Set<string>();
  if (run.toolActions) {
    for (const action of run.toolActions) {
      if (typeof action.callID === "string" && action.callID.trim()) {
        runCallIDs.add(action.callID.trim());
      }
    }
  }
  return approvals.filter((request) => {
    const approvalSID = approvalSessionID(request);
    if (isSameSession(approvalSID, runSID)) {
      return true;
    }
    const approvalCallID =
      typeof request.input?.callID === "string"
        ? request.input.callID.trim()
        : "";
    if (approvalCallID && runCallIDs.has(approvalCallID)) {
      return true;
    }
    return false;
  });
}

// Reports whether one row's in-flight work can be stopped from the runs surface.
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
  // Non-blocking single-run delete confirmation: the pending run renders a
  // true modal so an accidental trash click never drops audit history.
  const [pendingDeleteRun, setPendingDeleteRun] = useState<RunLogEntry | null>(
    null,
  );
  const [deletingId, setDeletingId] = useState<string | null>(null);
  // Expanded fan-out swarm: the parent kind=fanout row whose worker children
  // currently render; one swarm stays expanded at a time so the list never
  // collapses into an unreadable wall of worker rows.
  const [expandedRunId, setExpandedRunId] = useState<string | null>(null);
  // Stop affordances for in-flight fan-out work: the parent row stages a confirmation because it
  // stops the whole swarm, while a worker row fires directly for a one-click narrow stop.
  const [pendingCancelRun, setPendingCancelRun] = useState<RunLogEntry | null>(
    null,
  );
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  // Transient cancel feedback in a top-right stack so the honest scope copy
  // never blocks the list; identical copies refresh one notice instead of
  // stacking, matching the shared toast pattern used elsewhere.
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
    // Release the anchor immediately but defer revoking the object URL so
    // the download has time to start before the blob is torn down.
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
    // A stale identifier must fail visibly instead of opening an empty
    // confirmation that would silently no-op on confirm.
    if (!target) {
      setError("Failed to delete run");
      return;
    }
    // Stage the confirmation first; the destructive request only fires from
    // the modal so list-row clicks stay non-destructive by default.
    setPendingDeleteRun(target);
  };

  async function confirmDeleteRun() {
    if (!pendingDeleteRun) return;
    const id = pendingDeleteRun.id;
    setDeletingId(id);
    try {
      await deleteRun(id);
      setRuns((prev) => prev.filter((r) => r.id !== id));
      if (selected?.id === id) {
        setSelected(null);
      }
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

  // Live approval prompts join the badge set immediately so blocked runs
  // show the amber indicator without waiting for the next refresh.
  const handleWSApproval = useCallback((data: unknown) => {
    const request = mergeApprovalFrame(data);
    if (!request) return;
    setApprovals((previous) =>
      previous.some((item) => item.id === request.id) ? previous : [...previous, request],
    );
  }, []);

  useSharedWebSocket(handleWSApproval);

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

  // Live badges track only in-flight turns while parked approvals surface through the approvals
  // badge, so the poller separates the two: running rows keep history fresh and parked rows keep
  // approvals fresh without double-badging one blocked turn.
  const hasRunning = runs.some((r) => isActiveRunStatus(r.status));
  const hasParked = runs.some((r) => r.status === "awaiting_approval");
  useEffect(() => {
    if (!hasRunning && !hasParked) return;

    const interval = setInterval(() => {
      // Parked turns settle through the approvals inbox, so a parked-only
      // tick refreshes approvals without refetching settled history.
      if (hasRunning) {
        void listRuns(RUN_LOG_POLL_LIMIT)
          .then((response) => setRuns(response.runs))
          .catch(() => {
            // Poll is best-effort; the next interval retries while a run stays active.
          });
      }
      void refreshApprovals();
    }, RUN_POLL_INTERVAL_MS);

    return () => clearInterval(interval);
  }, [hasRunning, hasParked, refreshApprovals]);

  // Keep selected modal updated if its run changes while viewing
  useEffect(() => {
    if (!selected) return;
    const updated = runs.find((r) => r.id === selected.id);
    if (updated && (updated.status !== selected.status || updated.response !== selected.response)) {
      setSelected(updated);
    }
  }, [runs, selected]);

  // Fires one stop request and refetches so settled badges appear as workers stop. Scope copy names
  // how far the stop reaches (whole swarm versus one worker) so the operator never has to infer it
  // from the row kind.
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

  // Row entry point: a whole-swarm stop is destructive enough to confirm before
  // firing, while a worker stop fires immediately because its blast radius is
  // one worker.
  function handleCancelClick(run: RunLogEntry, e?: React.MouseEvent) {
    if (e) e.stopPropagation();
    if (run.kind === "fanout") {
      setPendingCancelRun(run);
      return;
    }
    void performCancel(run, "worker");
  }

  function dismissPendingCancel() {
    // A stop already in flight must finish before the dialog can close so the
    // honest outcome can never be swallowed by a dismissed confirmation.
    if (pendingCancelRun && cancellingId === pendingCancelRun.id) return;
    setPendingCancelRun(null);
  }

  async function confirmPendingCancel() {
    if (!pendingCancelRun) return;
    const target = pendingCancelRun;
    await performCancel(target, "run");
    // Close on success and on failure alike: a failure has already surfaced its
    // honest reason through the error toast, and a stale dialog would invite a
    // duplicate request against a run that may have settled.
    setPendingCancelRun(null);
  }

  // Groups form first (on the full fetched list) so a parent and its worker
  // children always travel together, then filters apply to the parent: a
  // group renders only when its parent passes the kind and time filters.
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
            className="ghost icon-text-btn"
            onClick={() => void refresh()}
            disabled={loading}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
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

      {/* Filter Controls: Kind and Time Range */}
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
          // Amber badge only when this run's session (or one of its gated
          // call identifiers) still has an unresolved approval.
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
                  // Worker children render status plus duration each with the
                  // same pill colors as run statuses, indented under their
                  // parent swarm so the audit trail reads the swarm shape.
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

      {/* Full Run Details Modal */}
      {selected ? (
        <RunDetailModal run={selected} onClose={() => setSelected(null)} />
      ) : null}

      {/* Single-run delete confirmation; the bulk Clear Logs dialog below stays untouched. */}
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

      {/* Whole-swarm stop confirmation: cancelling a fan-out parent interrupts
          every worker still in flight, so it never fires from a single click. */}
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

      {/* Clean up / Archive Confirmation Modal */}
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
