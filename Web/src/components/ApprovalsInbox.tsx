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
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { mergeApprovalFrame } from "../approvalsSession";
import { RefreshIcon } from "./icons";

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

  // Live approval prompts arrive over the shared socket; merge them so the
  // inbox updates without waiting for the next manual refresh.
  const handleWSApproval = useCallback((data: unknown) => {
    const request = mergeApprovalFrame(data);
    if (!request) return;
    setApprovals((previous) =>
      previous.some((item) => item.id === request.id) ? previous : [...previous, request],
    );
  }, []);

  useSharedWebSocket(handleWSApproval);

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
    <section className="panel approvals-panel" aria-label="Approvals inbox">
      <div className="panel-header-row">
        <div>
          <h2>Approvals Inbox</h2>
          <p className="muted text-sm">
            Review and decide gated tool execution requests from scheduled jobs or agents.
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
          <span className="muted text-sm">{approvals.length} pending</span>
        </div>
      </div>

      {error ? <p className="error">{error}</p> : null}
      {approvals.length === 0 && !loading ? (
        <div className="approvals-empty muted">
          <p>No pending approvals.</p>
        </div>
      ) : null}

      <div className="approvals-list">
        {approvals.map((request) => (
          <div className="card approval-card" key={request.id}>
            <div className="approval-card-header">
              <div className="approval-title-group">
                <span className="badge approval-tool-badge">{request.toolName}</span>
                {request.description ? (
                  <span className="approval-desc">{request.description}</span>
                ) : null}
              </div>
            </div>

            {request.input?.argumentsJSON ? (
              <div className="approval-args-wrapper">
                <span className="text-xs muted approval-args-label">Arguments:</span>
                <pre className="approval-args-code">{request.input.argumentsJSON}</pre>
              </div>
            ) : null}

            <div className="approval-actions-bar">
              <label className="approval-duration-label">
                <span className="text-sm muted">Duration:</span>
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

              <div className="approval-decision-buttons">
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
          </div>
        ))}
      </div>
    </section>
  );
}
