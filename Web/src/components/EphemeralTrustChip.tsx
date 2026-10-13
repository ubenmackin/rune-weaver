// Rune Weaver Dashboard — Ephemeral session-trust chip for chat and the approvals inbox.
//
// Purpose: render the live ephemeral trust one session still carries — the
// gate's thisTime, forTask, and forSession grants plus the egress supervisor's
// session and one-shot domain allowances — as one compact line per trust, each
// with its own Revoke.
// Scope: mounts beside an owning session id and refetches on mount, on
// approval-family frames, on access-rule changes, and on a 30-second poll.
// Empty trust renders nothing, so a fresh or unattributed session stays silent.
// Architectural role: the only surface that lists ephemeral grants; durable
// standing rules live in Settings → Access and never enter this chip.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  clearEphemeralTrust,
  isAccessScope,
  sessionTrust,
  trustDurationOptions,
  type AccessScopeDTO,
  type EphemeralGrantDTO,
  type TrustDuration,
} from "../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../hooks/useSharedWebSocket";
import { normalizeSessionID } from "../approvalsSession";

// Refresh cadence between frames: ephemeral trust dies on its own timers, so
// the poll only keeps a long-lived tab honest while the socket is quiet.
const POLL_INTERVAL_MS = 30_000;

// Frame families that can change one session's ephemeral trust: a fresh
// approval request, its decided broadcast, and any durable-rule write, because
// a decision with a dated tier mints a rule while the ephemeral tiers land in
// the session tables this chip reads.
const TRUST_FRAME_TYPES = new Set([
  "approval",
  "approval_decided",
  "access_rules_changed",
]);

// Names a trust by lifetime only. Task grants, session grants, and supervisor
// domain allowances ride the same duration tiers, so the chip cannot tell them
// apart and deliberately does not try: the lifetime is the whole claim.
function lifetimeCopy(duration: TrustDuration): string {
  switch (duration) {
    case "thisTime":
      return "this time only";
    case "forTask":
      return "rest of this task";
    case "forSession":
      return "rest of this session";
    default:
      // Dated and forever tiers mint durable rules rather than ephemeral
      // grants, so a drifted payload borrows the shared tier label instead of
      // this chip inventing a lifetime claim.
      return (
        trustDurationOptions.find((option) => option.value === duration)?.label ??
        "temporarily"
      );
  }
}

// One-line reading of the trusted target, mirroring the scope vocabulary the
// engine already serves. A malformed scope names no target, so it degrades to
// the tool-wide reading rather than rendering a blank line.
function describeGrantScope(scope: AccessScopeDTO | undefined): string {
  if (!scope || !isAccessScope(scope)) return "all targets";
  switch (scope.kind) {
    case "tool":
      return "all targets";
    case "exactTarget":
      return scope.target;
    case "recipientSet":
      return scope.handles.length === 1
        ? scope.handles[0]
        : `${scope.handles.length} recipients`;
    case "domain":
      return scope.host;
  }
}

// Ephemeral grants carry no identity, so the row key is derived from the whole
// scope: two rows can only collide when tool, scope, and lifetime all match,
// which the engine's keyed tables never store twice.
function grantKey(grant: EphemeralGrantDTO): string {
  return `${grant.toolName}|${JSON.stringify(grant.scope)}|${grant.duration}`;
}

export interface EphemeralTrustChipProps {
  // Owning session of the trust being shown. Empty or absent hides the chip
  // entirely, so no mount ever implies trust for an unknown session.
  sessionID?: string | null;
}

export default function EphemeralTrustChip({
  sessionID,
}: EphemeralTrustChipProps) {
  const [grants, setGrants] = useState<EphemeralGrantDTO[]>([]);
  // Keys with a clear in flight, so only the revoking row locks while sibling
  // rows stay actionable.
  const [revokingKeys, setRevokingKeys] = useState<Set<string>>(
    () => new Set<string>(),
  );
  // Request sequence so a fast session switch cannot let an older read land
  // over a newer one's list.
  const requestSeq = useRef(0);

  const trimmedSessionID = (sessionID ?? "").trim();

  const refresh = useCallback(async () => {
    if (!trimmedSessionID) {
      setGrants([]);
      return;
    }
    const seq = ++requestSeq.current;
    try {
      const response = await sessionTrust(trimmedSessionID);
      if (seq !== requestSeq.current) return;
      const loaded = Array.isArray(response?.grants) ? response.grants : [];
      // A drifted row with a blank tool names no trust at all, so it drops
      // instead of rendering an unlabeled line.
      setGrants(
        loaded.filter(
          (grant) =>
            typeof grant.toolName === "string" &&
            grant.toolName.trim().length > 0,
        ),
      );
    } catch {
      // A failed read keeps the last proven list: the poll and the frames
      // re-probe, and dropping the list would hide trust that may still be
      // live. Clearing never hides a wrong line behind an error.
    }
  }, [trimmedSessionID]);

  // Initial read plus every session switch.
  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Poll keeps a quiet socket honest; an empty session has nothing to poll.
  useEffect(() => {
    if (!trimmedSessionID) return;
    const interval = setInterval(() => {
      void refresh();
    }, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [trimmedSessionID, refresh]);

  const handleFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const type = (frame as { type?: string }).type;
      if (!type || !TRUST_FRAME_TYPES.has(type)) return;
      // A frame tagged for another conversation cannot change this session's
      // trust; untagged broadcasts always refresh.
      const tag = (frame as { sessionID?: unknown }).sessionID;
      if (
        typeof tag === "string" &&
        tag.trim().length > 0 &&
        normalizeSessionID(tag) !== normalizeSessionID(trimmedSessionID)
      ) {
        return;
      }
      void refresh();
    },
    [refresh, trimmedSessionID],
  );

  // No session means no socket interest, so an inbox view with nothing
  // filtered never pins the shared connection.
  useSharedWebSocket(trimmedSessionID ? handleFrame : undefined);

  async function revoke(grant: EphemeralGrantDTO) {
    const key = grantKey(grant);
    setRevokingKeys((previous) => new Set(previous).add(key));
    try {
      await clearEphemeralTrust({
        sessionID: trimmedSessionID,
        toolName: grant.toolName,
        scope: grant.scope,
      });
      // Re-prove rather than optimistically drop: the refetch is the
      // confirmation that exactly the scoped trust cleared and the line is
      // gone, so a failed read leaves the row until proven cleared.
      await refresh();
    } catch {
      // The clear never reached the engine; the row stays and the next frame
      // or poll re-proves the grant is still live.
    } finally {
      setRevokingKeys((previous) => {
        const next = new Set(previous);
        next.delete(key);
        return next;
      });
    }
  }

  if (!trimmedSessionID || grants.length === 0) return null;

  return (
    <div
      className="ephemeral-trust-chip"
      data-testid="ephemeral-trust-chip"
      aria-label="Ephemeral session trust"
    >
      <span className="ephemeral-trust-heading">Session trust</span>
      <ul className="ephemeral-trust-list">
        {grants.map((grant) => {
          const key = grantKey(grant);
          const revoking = revokingKeys.has(key);
          return (
            <li
              className="ephemeral-trust-row"
              key={key}
              data-testid="ephemeral-trust-row"
            >
              <span className="ephemeral-trust-line">
                <code className="ephemeral-trust-tool">{grant.toolName}</code>
                {" to "}
                {describeGrantScope(grant.scope)} —{" "}
                {lifetimeCopy(grant.duration)}
              </span>
              <button
                type="button"
                className="ghost ephemeral-trust-revoke"
                disabled={revoking}
                onClick={() => void revoke(grant)}
              >
                {revoking ? "Revoking…" : "Revoke"}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
