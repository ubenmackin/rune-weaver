// Rune Weaver Dashboard — Approvals inbox for reviewing and deciding gated tool requests.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  decideApproval,
  listApprovals,
  listTrustGrants,
  parseTrustGrantExpiry,
  revokeTrustGrant,
  trustDurationOptions,
  type PermissionRequest,
  type TrustDuration,
  type TrustGrant,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { mergeApprovalFrame } from "../approvalsSession";
import { RefreshIcon } from "./icons";

function isTrustDuration(value: string): value is TrustDuration {
  return trustDurationOptions.some((option) => option.value === value);
}

// Lightweight clock tick so relative countdowns roll without a server
// round-trip; expiry eviction derives from the same timestamp.
const GRANT_CLOCK_POLL_MS = 30_000;

function durationLabelFor(duration: TrustDuration): string {
  return (
    trustDurationOptions.find((option) => option.value === duration)?.label ??
    duration
  );
}

// Turns a tool identifier into sentence prose ("email.send" reads as
// "email sends") so grant scope lines read naturally across tools.
function humanizeGrantTool(toolName: string): string {
  const parts = toolName.split(".");
  if (parts.length === 2 && parts[0] && parts[1]) {
    const verb = parts[1].endsWith("s") ? parts[1] : `${parts[1]}s`;
    return `${parts[0]} ${verb}`;
  }
  return toolName;
}

// Builds the human scope line for a grant card. Tool-wide grants carry an
// empty target by contract, so they must name "all targets" explicitly
// instead of rendering a blank recipient.
function grantScopeLine(grant: TrustGrant): string {
  const target = (grant.target ?? "").trim();
  const tool = humanizeGrantTool(grant.toolName);
  if (!target) return `${tool} to all targets are approved`;
  return `${tool} to ${target} are approved`;
}

function grantExpiryDate(grant: TrustGrant): Date | null {
  return parseTrustGrantExpiry(grant.expiresAt);
}

// Relative countdown for a timed grant ("in 5m"); forever grants have no
// expiry date and render "Never expires" instead of a countdown.
function grantRelativeLabel(expiry: Date | null, nowMs: number): string {
  if (!expiry) return "Never expires";
  const diffMs = expiry.getTime() - nowMs;
  if (diffMs <= 0) return "Expired";
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return `in ${diffSec}s`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `in ${diffMin}m`;
  const diffHour = Math.floor(diffMin / 60);
  if (diffHour < 24) return `in ${diffHour}h`;
  return `in ${Math.floor(diffHour / 24)}d`;
}

function isGrantExpired(grant: TrustGrant, nowMs: number): boolean {
  const expiry = grantExpiryDate(grant);
  if (!expiry) return false;
  return expiry.getTime() <= nowMs;
}

export default function ApprovalsInbox() {
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [durations, setDurations] = useState<Record<string, TrustDuration>>({});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [decidingState, setDecidingState] = useState<{
    id: string;
    action: "allowing" | "denying";
  } | null>(null);
  const [grants, setGrants] = useState<TrustGrant[]>([]);
  const [revokingId, setRevokingId] = useState<string | null>(null);
  const [nowMs, setNowMs] = useState(() => Date.now());

  // Grants fetch stays best-effort so a grants outage never clears the
  // pending inbox; malformed shapes (e.g. approval payloads in tests)
  // resolve to empty rather than crashing the section.
  const refreshGrants = useCallback(async () => {
    try {
      const response = await listTrustGrants();
      const next = (response as unknown as { grants?: unknown }).grants;
      if (Array.isArray(next)) {
        setGrants(next as TrustGrant[]);
      }
    } catch {
      // Keep stale grants visible; revoke failures surface separately.
    }
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listApprovals();
      setApprovals(response.approvals);
      await refreshGrants();
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Approvals failed",
      );
    } finally {
      setLoading(false);
    }
  }, [refreshGrants]);

  // Live approval prompts arrive over the shared socket; merge them so the
  // inbox updates without waiting for the next manual refresh. Decision frames
  // evict promptly so cross-tab or menu-bar decisions disappear immediately.
  // Grant frames refetch instead of merging payloads so duration grants
  // appear through one path whether filed locally or in another tab.
  const handleWSApproval = useCallback(
    (data: unknown) => {
      if (typeof data === "object" && data !== null) {
        const frame = data as Record<string, unknown>;
        if (frame.type === "trust_grants_changed") {
          void refreshGrants();
          return;
        }
        if (
          (frame.type === "approval_decided" ||
            frame.type === "approval_resolved") &&
          typeof frame.id === "string"
        ) {
          const decidedID = frame.id;
          setApprovals((previous) =>
            previous.filter((item) => item.id !== decidedID),
          );
          // A duration decision mints a grant server-side while a one-time
          // decision records nothing; refetching covers both without the
          // inbox guessing which tier was chosen.
          void refreshGrants();
          return;
        }
      }
      const request = mergeApprovalFrame(data);
      if (!request) return;
      setApprovals((previous) =>
        previous.some((item) => item.id === request.id)
          ? previous
          : [...previous, request],
      );
    },
    [refreshGrants],
  );

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
    listTrustGrants()
      .then((response) => {
        if (cancelled) return;
        const next = (response as unknown as { grants?: unknown }).grants;
        if (Array.isArray(next)) setGrants(next as TrustGrant[]);
      })
      .catch(() => {
        // Grants stay empty when the endpoint is unavailable; pending still renders.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Roll relative countdowns and evict expiries client-side on a light
  // cadence; expired rows hide without a server round-trip.
  useEffect(() => {
    const timer = setInterval(() => {
      setNowMs(Date.now());
    }, GRANT_CLOCK_POLL_MS);
    return () => {
      clearInterval(timer);
    };
  }, []);

  function durationFor(id: string): TrustDuration {
    return durations[id] ?? "thisTime";
  }

  async function decide(id: string, approved: boolean) {
    setDecidingState({ id, action: approved ? "allowing" : "denying" });
    setError(null);
    try {
      await decideApproval(id, approved, durationFor(id));
      setApprovals((previous) => previous.filter((item) => item.id !== id));
      // Duration decisions mint a grant server-side; refetch so the Active
      // section reflects it. One-time decisions record nothing, so the
      // refetch resolves to the same list and no grant row appears.
      await refreshGrants();
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Decision failed",
      );
    } finally {
      setDecidingState(null);
    }
  }

  async function revoke(id: string) {
    setRevokingId(id);
    setError(null);
    try {
      await revokeTrustGrant(id);
      // Drop the row without a refetch: the server already removed it, so
      // filtering locally avoids a flash of stale state.
      setGrants((previous) => previous.filter((grant) => grant.id !== id));
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Revoke failed",
      );
    } finally {
      setRevokingId(null);
    }
  }

  // Expired-by-clock rows hide locally so a lapsed grant never lingers
  // until the next server poll.
  const visibleGrants = grants.filter(
    (grant) => !isGrantExpired(grant, nowMs),
  );

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
                {decidingState?.id === request.id ? (
                  <span className="text-xs muted approval-resuming-label">
                    <RefreshIcon size={12} className="spin" />
                    <span>
                      {decidingState.action === "allowing"
                        ? "Allowing & resuming…"
                        : "Denying…"}
                    </span>
                  </span>
                ) : (
                  <>
                    {/* Per-row locking: only the deciding row disables so
                        independent approvals stay actionable while one
                        decision (and its parked resume) is in flight. */}
                    <button
                      type="button"
                      className="primary"
                      disabled={decidingState?.id === request.id}
                      onClick={() => void decide(request.id, true)}
                    >
                      Allow
                    </button>
                    <button
                      type="button"
                      className="danger"
                      disabled={decidingState?.id === request.id}
                      onClick={() => void decide(request.id, false)}
                    >
                      Deny
                    </button>
                  </>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      <div className="active-approvals-section">
        <div className="panel-header-row">
          <div>
            <h3>Active approvals</h3>
            <p className="muted text-sm">
              Trusted tools that stay auto-approved until revoked or expired.
            </p>
          </div>
          <span className="muted text-sm">{visibleGrants.length} active</span>
        </div>

        {visibleGrants.length === 0 ? (
          <div className="approvals-empty muted">
            <p>No active approvals.</p>
          </div>
        ) : null}

        <div className="approvals-list">
          {visibleGrants.map((grant) => {
            const expiry = grantExpiryDate(grant);
            const relative = grantRelativeLabel(expiry, nowMs);
            return (
              <div className="card approval-card" key={grant.id}>
                <div className="approval-card-header">
                  <div className="approval-title-group">
                    <span className="badge approval-tool-badge">
                      {grant.toolName}
                    </span>
                    <span className="approval-desc">
                      {grantScopeLine(grant)}
                    </span>
                  </div>
                </div>

                <div className="approval-grant-meta text-sm muted">
                  <span>{durationLabelFor(grant.duration)}</span>
                  {expiry ? (
                    <span>
                      Expires {expiry.toLocaleString()} ({relative})
                    </span>
                  ) : (
                    <span>Never expires</span>
                  )}
                </div>

                <div className="approval-actions-bar">
                  <div className="approval-decision-buttons">
                    {revokingId === grant.id ? (
                      // Disabled in-flight control keeps the row locked while
                      // surfacing progress, mirroring the pending inbox
                      // per-row spinner without freeing the button early.
                      <button
                        type="button"
                        className="danger"
                        disabled
                      >
                        <RefreshIcon size={12} className="spin" />
                        <span>Revoking…</span>
                      </button>
                    ) : (
                      <>
                        {/* Per-row locking mirrors the pending inbox: only
                            the revoking row locks so independent grants stay
                            revocable while one revoke is in flight. */}
                        <button
                          type="button"
                          className="danger"
                          disabled={revokingId === grant.id}
                          onClick={() => void revoke(grant.id)}
                        >
                          Revoke
                        </button>
                      </>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
