// Rune Weaver Dashboard — Rules section of the owner access configuration surface.
//
// Purpose: Lists every durable access rule as one row per tool-plus-scope and
// lets the owner revoke, widen, re-arm, or deny without touching a parked
// approval. A plain-English header, derived from the active allow rules grouped
// by tool, states what the agent may still do on its own; the table underneath
// carries the durable allow and deny rules with their scope, tier, expiry, and
// usage counters.
// Scope: Reading the rule list, the four row actions (revoke, widen to all
// targets, change duration, and minting a deny rule), live refresh on the
// access_rules_changed frame plus a quiet poll, and the deep-link highlight.
// Whether a rule matches a call and the deny-outranks decision order stay with
// the engine's permission gate; this section only renders and edits owner
// intent, and never re-implements scope comparison.
// Architectural role: the landing section of the Access pane; it reuses the
// shared access-wording helpers so its scope lines and header read exactly like
// the approvals inbox and session-trust chip, and refetches on the same 30s
// cadence the counters surface uses.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  createRule,
  listRules,
  parseRuleExpiry,
  rearmRule,
  revokeRule,
  widenRule,
  type AccessRule,
  type AccessScopeDTO,
  type NewAccessRuleInput,
  type TrustDuration,
} from "../../api";
import { useSharedWebSocket } from "../../hooks/useSharedWebSocket";
import { formatRelativeAgo, formatRelativeIn } from "../../relativeTime";
import {
  accessRulesHeaderSentence,
  describeAccessScope,
  formatRuleDurationLabel,
} from "./accessWording";
import Modal from "../Modal";
import { AlertTriangleIcon, CloseIcon, PlusIcon, RefreshIcon } from "../icons";

// The durable tiers a standing allow rule can carry: the three dated spans plus
// forever. The ephemeral thisTime/forTask/forSession tiers mint no durable
// rule, so the change-duration radio set never offers them.
const DURABLE_DURATION_TIERS: TrustDuration[] = [
  "fiveMinutes",
  "oneHour",
  "oneDay",
  "forever",
];

// Quiet refresh cadence between frames, matching the counters surface so a
// long-lived tab stays honest while the socket is quiet.
const POLL_INTERVAL_MS = 30_000;

// Human expiry reading for one rule. A null expiry is the forever tier; a
// future expiry counts down; a past expiry reads lapsed so an owner can tell an
// expired rule from a standing one without comparing clocks.
function expiryLabel(rule: AccessRule, nowMs: number): string {
  const expiresAt = parseRuleExpiry(rule.expiresAt);
  if (expiresAt === null) return "Never";
  const remaining = expiresAt.getTime() - nowMs;
  if (remaining <= 0) return "Expired";
  return formatRelativeIn(remaining);
}

// Human last-used reading for one rule. An absent or null clock means the rule
// never fired, so it reads "Never" instead of the epoch.
function lastUsedLabel(rule: AccessRule, nowMs: number): string {
  const usedAt = parseRuleExpiry(rule.lastUsedAt);
  if (usedAt === null) return "Never";
  return formatRelativeAgo(nowMs - usedAt.getTime());
}

// Splits a deny target into a scope. Blank opens a tool-wide deny (refuse every
// call to the tool); a value narrows the deny to that one exact target.
function denyScopeFromTarget(target: string): AccessScopeDTO {
  const trimmed = target.trim();
  return trimmed ? { kind: "exactTarget", target: trimmed } : { kind: "tool" };
}

export interface AccessRulesSectionProps {
  // Rule id a deep link asked to preselect and highlight, or null. The matching
  // row is marked so an owner following a link lands on the exact rule.
  highlightRuleId?: string | null;
}

// Rules section of the access pane: the durable allow and deny rules with the
// four row actions and the deny-creation form, or null while another rail
// section is selected.
export function AccessRulesSection({
  highlightRuleId = null,
}: AccessRulesSectionProps) {
  const [rules, setRules] = useState<AccessRule[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  // Row-action modal state. Each action holds its own pending rule plus its own
  // error so a refusal surfaces inside that action's modal and never leaks to a
  // sibling. busyRuleId locks only the row whose action is in flight.
  const [pendingRevoke, setPendingRevoke] = useState<AccessRule | null>(null);
  const [revokeError, setRevokeError] = useState<string | null>(null);
  const [pendingWiden, setPendingWiden] = useState<AccessRule | null>(null);
  const [widenError, setWidenError] = useState<string | null>(null);
  const [pendingDuration, setPendingDuration] = useState<AccessRule | null>(null);
  const [durationChoice, setDurationChoice] = useState<TrustDuration>("forever");
  const [durationError, setDurationError] = useState<string | null>(null);
  const [busyRuleId, setBusyRuleId] = useState<string | null>(null);

  // Deny-rule form state, kept separate from the row actions so an inline
  // validation failure never collides with a modal error.
  const [denyTool, setDenyTool] = useState<string>("");
  const [denyTarget, setDenyTarget] = useState<string>("");
  const [denyReason, setDenyReason] = useState<string>("");
  const [denyError, setDenyError] = useState<string | null>(null);
  const [denySubmitting, setDenySubmitting] = useState<boolean>(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const response = await listRules();
      setRules(Array.isArray(response.rules) ? response.rules : []);
    } catch (err: unknown) {
      setLoadError(err instanceof ApiError ? err.message : "Failed to load access rules.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Frame plus poll: any rule write broadcasts access_rules_changed so every
  // open dashboard refetches, and the quiet poll keeps the counters honest when
  // the socket is silent. Both call the same refresh so there is one read path.
  const handleFrame = useCallback(
    (frame: unknown) => {
      if ((frame as { type?: string }).type === "access_rules_changed") {
        void refresh();
      }
    },
    [refresh],
  );

  useSharedWebSocket(handleFrame);

  useEffect(() => {
    const interval = setInterval(() => {
      void refresh();
    }, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [refresh]);

  // Rows list the durable allows first and then the durable denies, keeping the
  // server order stable inside each group so a refresh never reshuffles rows.
  const allowRules = rules.filter((rule) => rule.effect === "allow");
  const denyRules = rules.filter((rule) => rule.effect === "deny");
  const orderedRules = [...allowRules, ...denyRules];
  const nowMs = Date.now();

  function openRevoke(rule: AccessRule) {
    setRevokeError(null);
    setPendingRevoke(rule);
  }

  function cancelRevoke() {
    if (busyRuleId && pendingRevoke && busyRuleId === pendingRevoke.id) return;
    setPendingRevoke(null);
    setRevokeError(null);
  }

  async function confirmRevoke() {
    if (!pendingRevoke) return;
    const id = pendingRevoke.id;
    setBusyRuleId(id);
    setRevokeError(null);
    try {
      await revokeRule(id);
      // Re-prove rather than optimistically drop: the refetch confirms exactly
      // which rows survived so a failed read leaves the list until proven.
      await refresh();
      setPendingRevoke(null);
    } catch (err: unknown) {
      setRevokeError(err instanceof ApiError ? err.message : "Failed to revoke the rule.");
    } finally {
      setBusyRuleId(null);
    }
  }

  function openWiden(rule: AccessRule) {
    setWidenError(null);
    setPendingWiden(rule);
  }

  function cancelWiden() {
    if (busyRuleId && pendingWiden && busyRuleId === pendingWiden.id) return;
    setPendingWiden(null);
    setWidenError(null);
  }

  // Widening a send scope is refused server-side (a recipient set must never
  // widen to auto-approve every recipient), and that reason lands here so the
  // owner sees why the widen did not happen without closing the confirm.
  async function confirmWiden() {
    if (!pendingWiden) return;
    const id = pendingWiden.id;
    setBusyRuleId(id);
    setWidenError(null);
    try {
      await widenRule(id);
      await refresh();
      setPendingWiden(null);
    } catch (err: unknown) {
      setWidenError(err instanceof ApiError ? err.message : "Failed to widen the rule.");
    } finally {
      setBusyRuleId(null);
    }
  }

  function openDuration(rule: AccessRule) {
    setDurationError(null);
    setDurationChoice(rule.duration);
    setPendingDuration(rule);
  }

  function cancelDuration() {
    if (busyRuleId && pendingDuration && busyRuleId === pendingDuration.id) return;
    setPendingDuration(null);
    setDurationError(null);
  }

  async function confirmDuration() {
    if (!pendingDuration) return;
    const id = pendingDuration.id;
    setBusyRuleId(id);
    setDurationError(null);
    try {
      await rearmRule(id, durationChoice);
      await refresh();
      setPendingDuration(null);
    } catch (err: unknown) {
      setDurationError(
        err instanceof ApiError ? err.message : "Failed to change the rule duration.",
      );
    } finally {
      setBusyRuleId(null);
    }
  }

  // Mints a deny rule from the form. The tier is forced to forever because a
  // deny rule never expires (deny-outranks), and the reason rides along to the
  // create helper, which forwards the extra field to the same POST /approvals/
  // rules write an approval uses rather than opening a second write path.
  async function submitDeny() {
    const tool = denyTool.trim();
    if (!tool) {
      setDenyError("Enter a tool name.");
      return;
    }
    const scope = denyScopeFromTarget(denyTarget);
    const reason = denyReason.trim();
    const denyPayload: NewAccessRuleInput & { reason?: string } = {
      tool,
      effect: "deny",
      scope,
      duration: "forever",
      ...(reason ? { reason } : {}),
    };
    setDenySubmitting(true);
    setDenyError(null);
    try {
      await createRule(denyPayload);
      setDenyTool("");
      setDenyTarget("");
      setDenyReason("");
      await refresh();
    } catch (err: unknown) {
      setDenyError(err instanceof ApiError ? err.message : "Failed to add the deny rule.");
    } finally {
      setDenySubmitting(false);
    }
  }

  const headerSentence = accessRulesHeaderSentence(rules, nowMs);

  return (
    <section
      className="panel access-rules-section"
      aria-label="Access rules"
      data-testid="access-rules-section"
    >
      <div className="panel-header-row">
        <div>
          <h2>Rules</h2>
          <p className="muted text-sm">
            Standing rules that persist across turns. An allow rule auto-approves a
            matching call; a deny rule parks it every time and never expires.
          </p>
        </div>
        <button
          type="button"
          className="ghost icon-text-btn"
          data-testid="access-rules-refresh"
          onClick={() => void refresh()}
          disabled={loading}
        >
          <RefreshIcon size={14} className={loading ? "spin" : ""} />
          <span>{loading ? "Refreshing…" : "Refresh"}</span>
        </button>
      </div>

      <p
        className="access-rules-header-sentence"
        data-testid="access-rules-header"
        aria-live="polite"
      >
        {headerSentence}
      </p>

      {loadError ? (
        <div
          className="error-banner"
          data-testid="access-rules-load-error"
          style={{ marginBottom: "12px" }}
        >
          <AlertTriangleIcon size={16} />
          <span>{loadError}</span>
        </div>
      ) : null}

      {rules.length === 0 && !loading && !loadError ? (
        <p className="muted text-sm" data-testid="access-rules-empty">
          No standing rules yet. Approve a call with a dated or Forever tier to
          mint one, or add a deny rule below.
        </p>
      ) : null}

      {orderedRules.length > 0 ? (
        <div className="access-rules-table-wrapper">
          <table className="access-rules-table" data-testid="access-rules-table">
            <thead>
              <tr>
                <th>Tool</th>
                <th>Scope</th>
                <th>Duration</th>
                <th>Expires</th>
                <th>Used</th>
                <th>Last used</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {orderedRules.map((rule) => {
                const highlighted = highlightRuleId === rule.id;
                const busy = busyRuleId === rule.id;
                return (
                  <tr
                    key={rule.id}
                    className={`access-rule-row${highlighted ? " highlighted" : ""}`}
                    data-testid={`access-rule-row-${rule.id}`}
                    data-highlighted={highlighted ? "true" : undefined}
                  >
                    <td>
                      <span className="badge access-rule-tool-badge">{rule.toolName}</span>
                      <span
                        className={`badge access-rule-effect-badge effect-${rule.effect}`}
                      >
                        {rule.effect === "allow" ? "Allow" : "Deny"}
                      </span>
                    </td>
                    <td className="access-rule-scope">
                      {describeAccessScope(rule.scope)}
                    </td>
                    <td>{formatRuleDurationLabel(rule.duration)}</td>
                    <td>{expiryLabel(rule, nowMs)}</td>
                    <td>{rule.useCount ?? 0}</td>
                    <td>{lastUsedLabel(rule, nowMs)}</td>
                    <td className="access-rule-actions">
                      <button
                        type="button"
                        className="danger icon-text-btn"
                        data-testid={`access-rule-revoke-${rule.id}`}
                        disabled={busy}
                        onClick={() => openRevoke(rule)}
                      >
                        <span>Revoke</span>
                      </button>
                      {rule.effect === "allow" ? (
                        <>
                          <button
                            type="button"
                            className="ghost icon-text-btn"
                            data-testid={`access-rule-widen-${rule.id}`}
                            disabled={busy}
                            onClick={() => openWiden(rule)}
                          >
                            <span>Widen</span>
                          </button>
                          <button
                            type="button"
                            className="ghost icon-text-btn"
                            data-testid={`access-rule-duration-${rule.id}`}
                            disabled={busy}
                            onClick={() => openDuration(rule)}
                          >
                            <span>Duration</span>
                          </button>
                        </>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : null}

      <div className="access-deny-form" data-testid="access-deny-form">
        <h4>Add deny rule</h4>
        <p className="muted text-sm">
          A deny rule parks every matching call until you revoke it. It never
          expires and outranks any allow rule for the same scope.
        </p>
        <div className="form-group">
          <label htmlFor="access-deny-tool" style={{ fontSize: "0.82rem" }}>
            Tool
          </label>
          <input
            id="access-deny-tool"
            className="input-field"
            data-testid="access-deny-tool"
            value={denyTool}
            onChange={(event) => setDenyTool(event.target.value)}
            placeholder="email.send"
          />
        </div>
        <div className="form-group">
          <label htmlFor="access-deny-target" style={{ fontSize: "0.82rem" }}>
            Target (optional)
          </label>
          <input
            id="access-deny-target"
            className="input-field"
            data-testid="access-deny-target"
            value={denyTarget}
            onChange={(event) => setDenyTarget(event.target.value)}
            placeholder="someone@example.com"
          />
          <span className="form-group-hint">
            Blank denies every target for the tool; a value denies only that one
            target.
          </span>
        </div>
        <div className="form-group">
          <label htmlFor="access-deny-reason" style={{ fontSize: "0.82rem" }}>
            Reason (optional)
          </label>
          <input
            id="access-deny-reason"
            className="input-field"
            data-testid="access-deny-reason"
            value={denyReason}
            onChange={(event) => setDenyReason(event.target.value)}
            placeholder="Why this is denied"
          />
        </div>
        {denyError ? (
          <p className="error" role="alert" data-testid="access-deny-error">
            {denyError}
          </p>
        ) : null}
        <button
          type="button"
          className="primary icon-text-btn"
          data-testid="access-deny-submit"
          disabled={denySubmitting}
          onClick={() => void submitDeny()}
        >
          <PlusIcon size={14} />
          <span>{denySubmitting ? "Adding…" : "Add deny rule"}</span>
        </button>
      </div>

      {pendingRevoke ? (
        <Modal label="Revoke rule" onClose={cancelRevoke}>
          <div className="modal-header">
            <h3>Revoke rule</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelRevoke}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted text-sm" style={{ margin: 0 }}>
              Revoke the {pendingRevoke.effect === "allow" ? "allow" : "deny"} rule
              for <code>{pendingRevoke.toolName}</code> (
              {describeAccessScope(pendingRevoke.scope)})? Revocation stops future
              matches only — calls already allowed stay in history.
            </p>
            {revokeError ? (
              <p className="error" role="alert" data-testid="access-revoke-error">
                {revokeError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelRevoke}
              disabled={busyRuleId === pendingRevoke.id}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              data-testid="access-revoke-confirm"
              onClick={() => void confirmRevoke()}
              disabled={busyRuleId === pendingRevoke.id}
            >
              {busyRuleId === pendingRevoke.id ? "Revoking…" : "Revoke"}
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingWiden ? (
        <Modal label="Widen rule to all targets" onClose={cancelWiden}>
          <div className="modal-header">
            <h3>Widen to all targets</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelWiden}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted text-sm" style={{ margin: 0 }}>
              Widen <code>{pendingWiden.toolName}</code> from{" "}
              {describeAccessScope(pendingWiden.scope)} to every target? Future calls
              to {pendingWiden.toolName} will be auto-approved without asking.
            </p>
            {widenError ? (
              <p className="error" role="alert" data-testid="access-widen-error">
                {widenError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelWiden}
              disabled={busyRuleId === pendingWiden.id}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              data-testid="access-widen-confirm"
              onClick={() => void confirmWiden()}
              disabled={busyRuleId === pendingWiden.id}
            >
              {busyRuleId === pendingWiden.id ? "Widening…" : "Widen"}
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingDuration ? (
        <Modal label="Change rule duration" onClose={cancelDuration}>
          <div className="modal-header">
            <h3>Change duration</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDuration}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted text-sm" style={{ margin: 0 }}>
              Choose how long the allow rule for{" "}
              <code>{pendingDuration.toolName}</code> (
              {describeAccessScope(pendingDuration.scope)}) stays in force.
            </p>
            <div
              role="radiogroup"
              aria-label="Duration"
              className="access-duration-radios"
            >
              {DURABLE_DURATION_TIERS.map((tier) => (
                <label key={tier} className="access-duration-option">
                  <input
                    type="radio"
                    name="access-rule-duration"
                    value={tier}
                    checked={durationChoice === tier}
                    disabled={busyRuleId === pendingDuration.id}
                    onChange={() => setDurationChoice(tier)}
                  />
                  <span>{formatRuleDurationLabel(tier)}</span>
                </label>
              ))}
            </div>
            {durationError ? (
              <p className="error" role="alert" data-testid="access-duration-error">
                {durationError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDuration}
              disabled={busyRuleId === pendingDuration.id}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              data-testid="access-duration-confirm"
              onClick={() => void confirmDuration()}
              disabled={busyRuleId === pendingDuration.id}
            >
              {busyRuleId === pendingDuration.id ? "Saving…" : "Change duration"}
            </button>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}

export default AccessRulesSection;
