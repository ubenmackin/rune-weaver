// Rune Weaver Dashboard — Approvals inbox for reviewing and deciding gated tool requests.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  decideApproval,
  listApprovals,
  trustDurationOptions,
  type PermissionRequest,
  type TrustDuration,
} from "../api";

function isTrustDuration(value: string): value is TrustDuration {
  return trustDurationOptions.some((option) => option.value === value);
}

export default function ApprovalsInbox() {
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [durations, setDurations] = useState<Record<string, TrustDuration>>({});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [deciding, setDeciding] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listApprovals();
      setApprovals(response.approvals);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Approvals failed",
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    listApprovals()
      .then((response) => {
        if (!cancelled) setApprovals(response.approvals);
      })
      .catch((failure) => {
        if (!cancelled) {
          setError(
            failure instanceof ApiError ? failure.message : "Approvals failed",
          );
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function durationFor(id: string): TrustDuration {
    return durations[id] ?? "thisTime";
  }

  async function decide(id: string, approved: boolean) {
    setDeciding(id);
    setError(null);
    try {
      await decideApproval(id, approved, durationFor(id));
      setApprovals((previous) => previous.filter((item) => item.id !== id));
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Decision failed",
      );
    } finally {
      setDeciding(null);
    }
  }

  return (
    <section className="panel" aria-label="Approvals inbox">
      <h2>Approvals inbox</h2>
      <p className="muted">
        Scheduled runs that need permission appear here. Allow with a duration
        or deny without touching config files.
      </p>
      <div className="row">
        <button
          type="button"
          className="ghost"
          onClick={() => void refresh()}
          disabled={loading}
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
        <span className="muted">{approvals.length} pending</span>
      </div>
      {error ? <p className="error">{error}</p> : null}
      {approvals.length === 0 && !loading ? (
        <p className="muted">No pending approvals.</p>
      ) : null}
      {approvals.map((request) => (
        <div className="card" key={request.id}>
          <div>
            <strong>{request.toolName}</strong>
          </div>
          <div className="muted">{request.description}</div>
          <pre>{request.input.argumentsJSON}</pre>
          <div className="row">
            <label>
              Duration{" "}
              <select
                aria-label={`Duration for ${request.toolName}`}
                value={durationFor(request.id)}
                onChange={(event) => {
                  const val = event.target.value;
                  const duration: TrustDuration = isTrustDuration(val) ? val : "thisTime";
                  setDurations((previous) => ({
                    ...previous,
                    [request.id]: duration,
                  }));
                }}
              >
                {trustDurationOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              className="primary"
              disabled={deciding === request.id}
              onClick={() => void decide(request.id, true)}
            >
              Allow
            </button>
            <button
              type="button"
              className="danger"
              disabled={deciding === request.id}
              onClick={() => void decide(request.id, false)}
            >
              Deny
            </button>
          </div>
        </div>
      ))}
    </section>
  );
}
