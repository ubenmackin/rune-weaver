// Rune Weaver Dashboard — Audit log viewer for inspecting chat turns and scheduler job runs.
// Features filter chips, clear status badges, duration/token metrics, and full detail modal.

import { useCallback, useEffect, useState } from "react";
import { ApiError, listRuns, type RunLogEntry } from "../api";
import RunDetailModal from "./RunDetailModal";
import { RefreshIcon, WrenchIcon } from "./icons";

type FilterKind = "all" | "chat" | "scheduler";

export default function RunLogViewer() {
  const [runs, setRuns] = useState<RunLogEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<RunLogEntry | null>(null);
  const [filter, setFilter] = useState<FilterKind>("all");

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listRuns(50);
      setRuns(response.runs);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Runs failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    listRuns(50)
      .then((response) => {
        if (!cancelled) setRuns(response.runs);
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

  // Poll while any run is running
  useEffect(() => {
    const hasRunning = runs.some((r) => r.status === "running");
    if (!hasRunning) return;

    const interval = setInterval(() => {
      listRuns(50)
        .then((response) => setRuns(response.runs))
        .catch(() => {});
    }, 2500);

    return () => clearInterval(interval);
  }, [runs]);

  // Keep selected modal updated if its run changes while viewing
  useEffect(() => {
    if (!selected) return;
    const updated = runs.find((r) => r.id === selected.id);
    if (updated && (updated.status !== selected.status || updated.response !== selected.response)) {
      setSelected(updated);
    }
  }, [runs, selected]);

  const filteredRuns = runs.filter((run) => {
    if (filter === "chat") return run.kind === "chat";
    if (filter === "scheduler") return run.kind === "scheduler";
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
          <span className="muted text-sm">{runs.length} entries</span>
        </div>
      </div>

      {/* Filter Chips */}
      <div className="filter-chip-row">
        <button
          type="button"
          className={`filter-chip ${filter === "all" ? "active" : ""}`}
          onClick={() => setFilter("all")}
        >
          All Runs ({runs.length})
        </button>
        <button
          type="button"
          className={`filter-chip ${filter === "scheduler" ? "active" : ""}`}
          onClick={() => setFilter("scheduler")}
        >
          Scheduled Jobs ({runs.filter((r) => r.kind === "scheduler").length})
        </button>
        <button
          type="button"
          className={`filter-chip ${filter === "chat" ? "active" : ""}`}
          onClick={() => setFilter("chat")}
        >
          Chat Turns ({runs.filter((r) => r.kind === "chat").length})
        </button>
      </div>

      {error ? <p className="error">{error}</p> : null}

      {filteredRuns.length === 0 && !loading ? (
        <div className="empty-state-box">
          <p className="muted">
            {runs.length === 0
              ? "No runs yet. Chat turns and scheduled job firings will appear here with complete responses and execution audits."
              : "No runs match this filter."}
          </p>
        </div>
      ) : null}

      <div className="run-cards-list">
        {filteredRuns.map((run) => (
          <div className="run-card" key={run.id}>
            <div className="run-card-main">
              <div className="run-card-header">
                <span className={`status-pill ${run.status}`}>
                  {run.status === "running" ? "IN PROGRESS" : run.status.toUpperCase()}
                </span>
                <span className="run-kind-tag">
                  {run.kind === "scheduler" ? "Scheduled Job" : "Chat Turn"}
                </span>
                <span className="run-time-muted">
                  {new Date(run.timestamp).toLocaleString()}
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
            </div>
          </div>
        ))}
      </div>

      {/* Full Run Details Modal */}
      {selected ? (
        <RunDetailModal run={selected} onClose={() => setSelected(null)} />
      ) : null}
    </section>
  );
}
