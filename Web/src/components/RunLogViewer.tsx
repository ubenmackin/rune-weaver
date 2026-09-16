// Rune Weaver Dashboard — Audit log viewer for inspecting chat turns and scheduler job runs.
// Features filter chips, clear status badges, duration/token metrics, and full detail modal.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  clearRuns,
  deleteRun,
  listApprovals,
  listRuns,
  parseRunTimestamp,
  type PermissionRequest,
  type RunLogEntry,
} from "../api";
import RunDetailModal from "./RunDetailModal";
import Modal from "./Modal";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { CloseIcon, RefreshIcon, TrashIcon, WrenchIcon } from "./icons";
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
      if (action.callID) {
        runCallIDs.add(action.callID);
      }
    }
  }
  return approvals.filter((request) => {
    const approvalSID = approvalSessionID(request);
    if (isSameSession(approvalSID, runSID)) {
      return true;
    }
    const approvalCallID = request.input?.callID;
    if (approvalCallID && runCallIDs.has(approvalCallID)) {
      return true;
    }
    return false;
  });
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
      setRuns([]);
      setSelected(null);
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
      const response = await listRuns(100);
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
    Promise.all([listRuns(100), listApprovals().catch(() => null)])
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

  // Poll while any run is in progress or parked awaiting approval, so blocked turns refresh without
  // a manual reload. Both runs and approvals refresh together so pending-approval badges never go
  // stale during poll.
  const hasRunning = runs.some(
    (r) => r.status === "running" || r.status === "awaiting_approval",
  );
  useEffect(() => {
    if (!hasRunning) return;

    const interval = setInterval(() => {
      void Promise.all([
        listRuns(100)
          .then((response) => setRuns(response.runs))
          .catch(() => {
            // Poll is best-effort; the next interval retries while a run stays active.
          }),
        refreshApprovals(),
      ]);
    }, 2500);

    return () => clearInterval(interval);
  }, [hasRunning, refreshApprovals]);

  // Keep selected modal updated if its run changes while viewing
  useEffect(() => {
    if (!selected) return;
    const updated = runs.find((r) => r.id === selected.id);
    if (updated && (updated.status !== selected.status || updated.response !== selected.response)) {
      setSelected(updated);
    }
  }, [runs, selected]);

  const filteredRuns = runs.filter((run) => {
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
            Audit history of interactive chat turns and background scheduled jobs.
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
            {filteredRuns.length === runs.length
              ? `${runs.length} entries`
              : `${filteredRuns.length} of ${runs.length} entries`}
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

      {filteredRuns.length === 0 && !loading ? (
        <div className="empty-state-box">
          <p className="muted">
            {runs.length === 0
              ? "No runs yet. Chat turns and scheduled job firings will appear here with complete responses and execution audits."
              : "No runs match the selected filters."}
          </p>
        </div>
      ) : null}

      <div className="run-cards-list">
        {filteredRuns.map((run) => {
          // Amber badge only when this run's session (or one of its gated
          // call identifiers) still has an unresolved approval.
          const pendingCount = runPendingApprovals(run, approvals).length;
          return (
            <div className="run-card" key={run.id}>
              <div className="run-card-main">
                <div className="run-card-header">
                  <span className={`status-pill ${run.status}`}>
                    {run.status === "running"
                      ? "IN PROGRESS"
                      : run.status === "awaiting_approval"
                        ? "AWAITING APPROVAL"
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
                  <span className="run-kind-tag">
                    {run.kind === "scheduler" ? "Scheduled Job" : "Chat Turn"}
                  </span>
                  <span className="run-time-muted">
                    {parseRunTimestamp(run.timestamp).toLocaleString()}
                  </span>
                  {run.durationMs != null ? (
                    <span className="run-time-muted">
                      • {run.durationMs >= 1000 ? `${(run.durationMs / 1000).toFixed(2)}s` : `${run.durationMs}ms`}
                    </span>
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
              </div>

              <div className="run-card-action">
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
            <p className="muted" style={{ margin: 0 }}>
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
            <p className="muted" style={{ margin: 0, lineHeight: 1.5 }}>
              You can archive your execution history by downloading an audit export (JSON) before clearing.
              Clearing will permanently delete all {runs.length} stored run entries.
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
    </section>
  );
}
