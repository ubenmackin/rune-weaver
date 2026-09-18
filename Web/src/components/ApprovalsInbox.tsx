// Rune Weaver Dashboard — Approvals inbox for reviewing and deciding gated tool requests.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  decideApproval,
  listApprovals,
  listTrustGrants,
  parseRunTimestamp,
  parseTrustGrantExpiry,
  revokeTrustGrant,
  trustDurationOptions,
  type PermissionRequest,
  type TrustDuration,
  type TrustGrant,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { mergeApprovalFrame } from "../approvalsSession";
import { formatRelativeAgo, formatRelativeIn } from "../relativeTime";
import Modal from "./Modal";
import { CloseIcon, RefreshIcon } from "./icons";

function isTrustDuration(value: string): value is TrustDuration {
  return trustDurationOptions.some((option) => option.value === value);
}

// Clock tick plus grants poll cadence: relative countdowns roll on the same
// interval that refetches usage counters (record-use emits no WS broadcast,
// so the poll proves a grant is live); expiry eviction derives from the same
// timestamp.
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

// Grant recency routing both tenses through the shared ladders so expiry
// countdowns, last-use recency, and chat footers agree by construction.
// Callers handle their own empty/expired/just-now sentinels.
function formatDuration(diffMs: number, future: boolean): string {
  if (!future) return formatRelativeAgo(diffMs);
  return formatRelativeIn(diffMs);
}

// Relative countdown for a timed grant ("in 5m"); forever grants have no
// expiry date and render "Never expires" instead of a countdown.
function grantRelativeLabel(expiry: Date | null, nowMs: number): string {
  if (!expiry) return "Never expires";
  const diffMs = expiry.getTime() - nowMs;
  if (diffMs <= 0) return "Expired";
  return formatDuration(diffMs, true);
}

function isGrantExpired(grant: TrustGrant, nowMs: number): boolean {
  const expiry = grantExpiryDate(grant);
  if (!expiry) return false;
  return expiry.getTime() <= nowMs;
}

// Normalizes the last-use timestamp through the same dual-shape parser as expiry, so ISO
// strings and Unix seconds converge without the card branching on the wire encoding. A null
// or epoch result means the grant never fired and renders as untouched.
function grantLastUsedDate(grant: TrustGrant): Date | null {
  const raw = grant.lastUsedAt;
  if (raw == null) return null;
  const parsed = parseRunTimestamp(raw);
  if (parsed.getTime() === 0) return null;
  return parsed;
}

// Relative "ago" label sharing the expiry countdown ladder, so elapsed time reads with
// the same granularity as remaining time. Future-skewed stamps and sub-second
// uses collapse to "just now" rather than rendering a negative countdown or
// "0s ago".
function grantLastUsedRelativeLabel(lastUsed: Date | null, nowMs: number): string {
  if (!lastUsed) return "Never";
  return formatRelativeAgo(nowMs - lastUsed.getTime());
}

// Hit count tolerating payloads minted before usage tracking, so older grants degrade to
// "not used" instead of rendering NaN or crashing the card.
function grantUseCount(grant: TrustGrant): number {
  const raw = grant.useCount;
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) return 0;
  return Math.floor(raw);
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
  // Staged revoke target renders the shared confirmation modal; the destructive request only
  // fires from the modal so list-row clicks stay non-destructive by default.
  const [pendingRevoke, setPendingRevoke] = useState<TrustGrant | null>(null);
  // Revoke failure stays inside the confirmation dialog because the page-level error renders
  // behind the modal portal backdrop and would be invisible while staged.
  const [revokeError, setRevokeError] = useState<string | null>(null);
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

  // Tick the clock for relative countdowns and poll grants for usage
  // counters on the same cadence. Record-use emits no WS broadcast by
  // contract, so the 30s poll is what proves a grant is live; expiry
  // eviction still derives from the same timestamp.
  useEffect(() => {
    const timer = setInterval(() => {
      setNowMs(Date.now());
      void refreshGrants();
    }, GRANT_CLOCK_POLL_MS);
    return () => {
      clearInterval(timer);
    };
  }, [refreshGrants]);

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

  // Confirms the staged revoke: the server already removed the row on 204, so filtering
  // locally avoids a flash of stale state. Failures keep the modal open with the error
  // surfaced inside the dialog so the user can retry or cancel instead of losing scope.
  async function confirmRevoke() {
    if (!pendingRevoke) return;
    const id = pendingRevoke.id;
    setRevokingId(id);
    setRevokeError(null);
    try {
      await revokeTrustGrant(id);
      // Drop the row without a refetch: the server already removed it, so
      // filtering locally avoids a flash of stale state.
      setGrants((previous) => previous.filter((grant) => grant.id !== id));
      setPendingRevoke(null);
      setRevokeError(null);
    } catch (failure) {
      setRevokeError(
        failure instanceof ApiError ? failure.message : "Revoke failed",
      );
    } finally {
      setRevokingId(null);
    }
  }

  function cancelRevoke() {
    setPendingRevoke(null);
    setRevokeError(null);
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
            // Usage degrades to untouched only when both signals agree the grant never
            // fired, so a partial-migration row with a count but no stamp (or a stamp
            // but no count) still proves exercised trust instead of hiding as unused.
            const useCount = grantUseCount(grant);
            const lastUsed = grantLastUsedDate(grant);
            const isUnused = useCount === 0 && !lastUsed;
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

                <div className="approval-grant-usage text-sm muted">
                  {isUnused ? (
                    <span>Not used yet</span>
                  ) : useCount > 0 && lastUsed ? (
                    <span>
                      Used {useCount}x · Last used{" "}
                      {grantLastUsedRelativeLabel(lastUsed, nowMs)} (
                      {lastUsed.toLocaleString()})
                    </span>
                  ) : useCount > 0 ? (
                    <span>Used {useCount}x</span>
                  ) : lastUsed ? (
                    <span>
                      Last used {grantLastUsedRelativeLabel(lastUsed, nowMs)} (
                      {lastUsed.toLocaleString()})
                    </span>
                  ) : (
                    <span>Not used yet</span>
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
                        {/* Staging lock for confirm-every-revoke: while a revoke is staged
                            (modal open, not yet confirming) every row disables so a
                            second Revoke cannot overwrite pendingRevoke and silently
                            drop the first context. Once confirming, only the
                            revoking row locks so siblings stay actionable. */}
                        <button
                          type="button"
                          className="danger"
                          disabled={
                            revokingId !== null
                              ? revokingId === grant.id
                              : pendingRevoke !== null
                          }
                          onClick={() => {
                            setRevokeError(null);
                            setPendingRevoke(grant);
                          }}
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

      {/* Revoke confirmation via the shared modal so the dialog portals above page
          stacking contexts with Escape support. Staging keeps row clicks
          non-destructive; only the modal confirm issues the DELETE. */}
      {pendingRevoke ? (
        <Modal
          label="Confirm revoke grant"
          onClose={() => {
            if (revokingId === pendingRevoke.id) return;
            cancelRevoke();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Revoke approval?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelRevoke}
              disabled={revokingId === pendingRevoke.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              {grantScopeLine(pendingRevoke)}
            </p>
            <p
              className="muted text-sm"
              style={{ margin: "8px 0 0 0", overflowWrap: "anywhere" }}
            >
              {pendingRevoke.toolName} ·{" "}
              {durationLabelFor(pendingRevoke.duration)}
              {grantExpiryDate(pendingRevoke)
                ? ` · Expires ${grantExpiryDate(pendingRevoke)?.toLocaleString()} (${grantRelativeLabel(grantExpiryDate(pendingRevoke), nowMs)})`
                : " · Never expires"}
            </p>
            <p className="muted" style={{ margin: "8px 0 0 0" }}>
              Future calls will require approval again.
            </p>
            {revokeError ? (
              <p className="error" role="alert" style={{ margin: "8px 0 0 0" }}>
                {revokeError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelRevoke}
              disabled={revokingId === pendingRevoke.id}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmRevoke()}
              disabled={revokingId === pendingRevoke.id}
              aria-label="Confirm revoke grant"
            >
              {revokingId === pendingRevoke.id ? "Revoking…" : "Revoke"}
            </button>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}
