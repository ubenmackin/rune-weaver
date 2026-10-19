// Rune Weaver Dashboard — Timed trust mirror for the approvals inbox.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  listRules,
  parseRuleExpiry,
  rearmRule,
  revokeRule,
  type AccessRule,
  type TrustDuration,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { formatRelativeAgo, formatRelativeIn } from "../relativeTime";
import { describeAccessScope } from "./access/accessWording";
import EphemeralTrustChip from "./EphemeralTrustChip";

// Quiet refresh between frames so a long-lived tab stays honest while silent.
const POLL_INTERVAL_MS = 30_000;

// Timed tiers the mirror owns. Standing forever plus deny stay in Settings.
const TIMED_DURATIONS: TrustDuration[] = ["fiveMinutes", "oneHour", "oneDay"];

// Deep link owning standing rules, matching the inbox header target.
const STANDING_RULES_HREF = "#settings?access=rules";

// Whether a rule belongs in the timed mirror: dated allow tiers only.
function isTimedAllow(rule: AccessRule): boolean {
  const effect = rule.effect ?? rule.action;
  if (effect !== "allow") return false;
  return TIMED_DURATIONS.includes(rule.duration as TrustDuration);
}

// Whether a stored rule proves standing trust exists elsewhere.
function isStandingRule(rule: AccessRule): boolean {
  const effect = rule.effect ?? rule.action;
  if (effect === "deny") return true;
  return rule.duration === "forever";
}

// Countdown copy from a cached expiry. Past reads Expired until refetch drops it.
function countdownLabel(expiresAt: Date | null, nowMs: number): string {
  if (expiresAt === null) return "Never";
  const remaining = expiresAt.getTime() - nowMs;
  if (remaining <= 0) return "Expired";
  return formatRelativeIn(remaining);
}

// Last-used copy. Never fired reads Never instead of the epoch.
function lastUsedLabel(rule: AccessRule, nowMs: number): string {
  const usedAt = parseRuleExpiry(rule.lastUsedAt);
  if (usedAt === null) return "Never";
  return formatRelativeAgo(nowMs - usedAt.getTime());
}

export interface ApprovalActiveTrustProps {
  // Filtered session owning ephemeral trust. Empty hides the chip.
  sessionID?: string | null;
}

export default function ApprovalActiveTrust({
  sessionID,
}: ApprovalActiveTrustProps = {}) {
  const [rules, setRules] = useState<AccessRule[]>([]);
  const [fetchedAt, setFetchedAt] = useState<number>(() => Date.now());
  const [nowMs, setNowMs] = useState<number>(() => Date.now());
  const [error, setError] = useState<string | null>(null);
  const [busyRuleId, setBusyRuleId] = useState<string | null>(null);
  const [rearmChoices, setRearmChoices] = useState<Record<string, TrustDuration>>({});
  const [rearmError, setRearmError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const response = await listRules();
      setRules(Array.isArray(response.rules) ? response.rules : []);
      setFetchedAt(Date.now());
      setError(null);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Timed trust failed");
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Ticking clock drives countdown text from the cached expiry alone.
  useEffect(() => {
    const timer = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  // Quiet poll keeps a silent tab honest between broadcasts.
  useEffect(() => {
    const timer = setInterval(() => {
      void refresh();
    }, POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [refresh]);

  const handleFrame = useCallback(
    (frame: unknown) => {
      const type = (frame as { type?: string }).type;
      if (
        type === "access_rules_changed" ||
        type === "approval_decided" ||
        type === "approval_resolved"
      ) {
        void refresh();
      }
    },
    [refresh],
  );

  useSharedWebSocket(handleFrame, undefined, refresh);

  // Visibility resync so returning to the tab drops lapsed rows.
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        void refresh();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [refresh]);

  // Future at fetch stays visible (Expired after lapse) until the next fetch
  // re-proves the list; initially past rows never enter.
  const timedRules = rules
    .filter(isTimedAllow)
    .filter((rule) => {
      const expiresAt = parseRuleExpiry(rule.expiresAt);
      return expiresAt !== null && expiresAt.getTime() > fetchedAt;
    })
    .sort((a, b) => {
      const left = parseRuleExpiry(a.expiresAt)?.getTime() ?? 0;
      const right = parseRuleExpiry(b.expiresAt)?.getTime() ?? 0;
      return left - right;
    });

  const hasStanding = rules.some(isStandingRule);

  async function handleRevoke(rule: AccessRule) {
    setBusyRuleId(rule.id);
    setRearmError(null);
    try {
      await revokeRule(rule.id);
      await refresh();
    } catch (failure) {
      setRearmError(failure instanceof ApiError ? failure.message : "Revoke failed");
    } finally {
      setBusyRuleId(null);
    }
  }

  async function handleRearm(rule: AccessRule) {
    const duration = rearmChoices[rule.id] ?? (rule.duration as TrustDuration) ?? "oneHour";
    if (!TIMED_DURATIONS.includes(duration)) return;
    setBusyRuleId(rule.id);
    setRearmError(null);
    try {
      await rearmRule(rule.id, duration);
      await refresh();
    } catch (failure) {
      setRearmError(failure instanceof ApiError ? failure.message : "Rearm failed");
    } finally {
      setBusyRuleId(null);
    }
  }

  return (
    <div data-testid="approval-active-trust" aria-label="Active timed trust">
      <EphemeralTrustChip sessionID={sessionID} />
      {hasStanding ? (
        <p className="muted text-sm" data-testid="active-trust-standing-banner">
          Forever and deny rules stay in{" "}
          <a href={STANDING_RULES_HREF}>standing rules</a>.
        </p>
      ) : null}
      {error ? <p className="error">{error}</p> : null}
      {rearmError ? (
        <p className="error" role="alert">
          {rearmError}
        </p>
      ) : null}
      {timedRules.length === 0 ? (
        <div className="approvals-empty muted">
          <p>No active timed trust.</p>
        </div>
      ) : (
        <ul className="approvals-list">
          {timedRules.map((rule) => {
            const expiresAt = parseRuleExpiry(rule.expiresAt);
            const busy = busyRuleId === rule.id;
            const rearmValue =
              rearmChoices[rule.id] ?? (rule.duration as TrustDuration) ?? "oneHour";
            return (
              <li
                key={rule.id}
                className="card approval-card"
                data-testid={`active-trust-row-${rule.id}`}
              >
                <div className="approval-card-header">
                  <div className="approval-title-group">
                    <span className="badge approval-tool-badge">{rule.toolName}</span>
                    <span
                      className="badge approval-severity-badge severity-moderate"
                      data-testid={`active-trust-countdown-${rule.id}`}
                    >
                      {countdownLabel(expiresAt, nowMs)}
                    </span>
                  </div>
                </div>
                <div className="approval-narrative">
                  <span className="approval-section-label">Scope:</span>{" "}
                  {describeAccessScope(rule.scope)}
                </div>
                <div className="muted text-sm">
                  <span data-testid={`active-trust-used-${rule.id}`}>
                    Used {rule.useCount ?? 0} times
                  </span>{" "}
                  <span data-testid={`active-trust-last-used-${rule.id}`}>
                    Last used {lastUsedLabel(rule, nowMs)}
                  </span>
                </div>
                <div className="approval-actions-bar">
                  <label className="approval-duration-label">
                    <span className="text-sm muted">Rearm to:</span>
                    <select
                      aria-label={`Rearm duration for ${rule.toolName}`}
                      data-testid={`active-trust-rearm-select-${rule.id}`}
                      value={rearmValue}
                      disabled={busy}
                      onChange={(event) =>
                        setRearmChoices((previous) => ({
                          ...previous,
                          [rule.id]: event.target.value as TrustDuration,
                        }))
                      }
                    >
                      <option value="fiveMinutes">Next 5 minutes</option>
                      <option value="oneHour">Next hour</option>
                      <option value="oneDay">Next day</option>
                    </select>
                  </label>
                  <div className="approval-decision-buttons">
                    <button
                      type="button"
                      className="primary"
                      data-testid={`active-trust-rearm-${rule.id}`}
                      disabled={busy}
                      onClick={() => void handleRearm(rule)}
                    >
                      {busy ? "Rearming…" : "Rearm"}
                    </button>
                    <button
                      type="button"
                      className="danger"
                      data-testid={`active-trust-revoke-${rule.id}`}
                      disabled={busy}
                      onClick={() => void handleRevoke(rule)}
                    >
                      {busy ? "Revoking…" : "Revoke"}
                    </button>
                    <a
                      className="ghost icon-text-btn"
                      href={`#settings?access=${rule.id}`}
                      title="Open this rule in Settings → Access"
                    >
                      <span>Open in Settings</span>
                    </a>
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
