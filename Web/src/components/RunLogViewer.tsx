// Rune Weaver Dashboard — Audit log viewer for inspecting chat turns and scheduler job runs.

import { useCallback, useEffect, useState } from "react";
import { ApiError, listRuns, type RunLogEntry } from "../api";

export default function RunLogViewer() {
  const [runs, setRuns] = useState<RunLogEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<RunLogEntry | null>(null);

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

  function showDetails(run: RunLogEntry) {
    // GET /runs/:id returns the same RunLogEntry shape already in the list
    // (no enriched detail fields), so render the listed row directly with
    // no extra round-trip.
    setSelected(run);
  }

  return (
    <section className="panel" aria-label="Run log viewer">
      <h2>Run log</h2>
      <div className="row">
        <button
          type="button"
          className="ghost"
          onClick={() => void refresh()}
          disabled={loading}
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
        <span className="muted">{runs.length} entries</span>
      </div>
      {error ? <p className="error">{error}</p> : null}
      {runs.length === 0 && !loading ? (
        <p className="muted">
          No runs yet. Chat turns and scheduled job runs appear here with
          their logs.
        </p>
      ) : null}
      {runs.map((run) => (
        <div className="card" key={run.id}>
          <div>
            <strong>{run.kind}</strong> · {run.status}
          </div>
          <div className="muted">
            {new Date(run.timestamp).toLocaleString()}
            {run.jobID ? ` · job ${run.jobID.slice(0, 8)}` : ""}
          </div>
          <div>{run.message}</div>
          <button
            type="button"
            className="ghost"
            onClick={() => showDetails(run)}
          >
            Details
          </button>
        </div>
      ))}
      {selected ? (
        <div className="card" aria-label="Run details">
          <h3>Run details</h3>
          <pre>{JSON.stringify(selected, null, 2)}</pre>
          <button
            type="button"
            className="ghost"
            onClick={() => setSelected(null)}
          >
            Close
          </button>
        </div>
      ) : null}
    </section>
  );
}
