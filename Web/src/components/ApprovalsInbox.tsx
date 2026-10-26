// Rune Weaver Dashboard — Approvals inbox for pending gated tool requests.

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ApiError,
  decideApproval,
  listApprovals,
  listRules,
  listSessions,
  parseRuleExpiry,
  respondToQuestion,
  type AccessRule,
  type AccessScopeDTO,
  type PermissionRequest,
  type TrustDuration,
} from "../api";
import {
  deriveRequestTarget,
  durationOptionsFor,
  isSystemNoticeTool,
  truncateTarget,
  widenableBaseDomain,
} from "../approvalsShared";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { mergeApprovalFrame, normalizeSessionID } from "../approvalsSession";
import { isRecord } from "../typeGuards";
import { BRAKE_TOOL_NAME, buildGroups } from "./approvalsInboxGroups";
import {
  MAX_RECIPIENT_SET_MEMBERS,
  SCOPE_EDITOR_COPY,
  buildCustomScope,
  describeScope,
  effectiveScopeChoice,
  scopeChoicesFor,
  scopeEditorKind,
  scopePrefill,
  scopeToText,
  type ScopeChoice,
  type ScopeDraft,
} from "./approvalsInboxScope";
import InlineQuestionCard from "./InlineQuestionCard";
import SystemNoticeCard from "./SystemNoticeCard";
import ApprovalActiveTrust from "./ApprovalActiveTrust";
import ApprovalHistory from "./ApprovalHistory";
import BashTierLine from "./BashTierLine";
import EphemeralTrustChip from "./EphemeralTrustChip";
import { resolveEgressHost, resolveSandboxSummary } from "./InlineApprovalBanner";
import Modal from "./Modal";
import { ApprovalsIcon, CloseIcon, RefreshIcon } from "./icons";

// Deep link into the Settings → Access pane that owns standing rules.
const STANDING_RULES_HREF = "#settings?access=rules";

// Resolves the scope one decision carries. An empty target names tool-wide
// trust, so a missing egress host plus a missing derived target mints kind tool.
export function decisionScopeFor(
  request: PermissionRequest,
  choice: ScopeChoice,
  custom: AccessScopeDTO | undefined,
): AccessScopeDTO | undefined {
  if (choice === "allTargets") return { kind: "tool" };
  if (choice === "custom") return custom;
  const rawHost = resolveEgressHost(request);
  const host = typeof rawHost === "string" ? rawHost.trim() : "";
  if (choice === "domainSubdomains") {
    const base = widenableBaseDomain(host);
    if (base) return { kind: "domain", host: base, subdomains: true };
  }
  if (host) return { kind: "domain", host };
  if (!deriveRequestTarget(request)) return { kind: "tool" };
  return undefined;
}

interface ApprovalsInboxProps {
  // Session the inbox is filtered to, when one is selected. The ephemeral
  // trust chip renders only for that session, so with no session selected
  // the chip stays hidden instead of implying trust for the whole inbox.
  sessionID?: string;
}

export default function ApprovalsInbox({
  sessionID,
}: ApprovalsInboxProps = {}) {
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [durations, setDurations] = useState<Record<string, TrustDuration>>({});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [decidingState, setDecidingState] = useState<{
    id: string;
    action: "allowing" | "denying";
  } | null>(null);
  const [sessionTitles, setSessionTitles] = useState<Map<string, string>>(
    () => new Map(),
  );
  const [scopeChoices, setScopeChoices] = useState<Record<string, ScopeChoice>>(
    {},
  );
  const [customScopes, setCustomScopes] = useState<
    Record<string, AccessScopeDTO>
  >({});
  // Staged scope edit renders through the shared modal; only the modal save
  // commits a scope, so a half-typed list can never reach a decision.
  const [scopeDraft, setScopeDraft] = useState<ScopeDraft | null>(null);
  const [scopeDraftError, setScopeDraftError] = useState<string | null>(null);
  // Three panes sharing one header row. Pending stays the default so the inbox
  // keeps opening on the decidable queue; Active-timed mirrors dated trust and
  // History swaps the groups for the durable decision log.
  const [view, setView] = useState<"pending" | "active-timed" | "history">("pending");
  // Timed count for the Active-timed tab label, settled from the rules route.
  const [activeTimedCount, setActiveTimedCount] = useState<number | null>(null);

  // Session titles name the group headers. Best-effort: a sessions outage
  // keeps the prior map, and a header without a title falls back to the raw
  // session id rather than hiding the group.
  const refreshSessions = useCallback(async () => {
    try {
      const response = await listSessions();
      const titles = new Map<string, string>();
      for (const session of response.sessions ?? []) {
        const key = normalizeSessionID(session.id);
        if (!key) continue;
        const title = typeof session.title === "string" ? session.title.trim() : "";
        if (title) titles.set(key, title);
      }
      setSessionTitles(titles);
    } catch {
      // Keep prior titles on transient failure; headers fall back to raw ids.
    }
  }, []);

  // Timed tally for the Active-timed tab. Failures keep the last count so a
  // transient read never blanks the label.
  const refreshActiveCount = useCallback(async () => {
    try {
      const response = await listRules();
      const nowMs = Date.now();
      const timed = (response.rules ?? []).filter((rule: AccessRule) => {
        const effect = rule.effect ?? rule.action;
        if (effect !== "allow") return false;
        if (
          rule.duration !== "fiveMinutes" &&
          rule.duration !== "oneHour" &&
          rule.duration !== "oneDay"
        ) {
          return false;
        }
        const expiresAt = parseRuleExpiry(rule.expiresAt);
        return expiresAt !== null && expiresAt.getTime() > nowMs;
      });
      setActiveTimedCount(timed.length);
    } catch {
      // Keep prior tally; the poll and frames re-probe.
    }
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [response] = await Promise.all([listApprovals(), refreshSessions()]);
      setApprovals(response.approvals);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Approvals failed",
      );
    } finally {
      setLoading(false);
    }
  }, [refreshSessions]);

  // Tab tally settles on mount plus the rule and decision broadcasts below.
  useEffect(() => {
    void refreshActiveCount();
  }, [refreshActiveCount]);

  useEffect(() => {
    const timer = setInterval(() => {
      void refreshActiveCount();
    }, 30_000);
    return () => clearInterval(timer);
  }, [refreshActiveCount]);

  useEffect(() => {
    function handleCountVisibility() {
      if (document.visibilityState === "visible") {
        void refreshActiveCount();
      }
    }
    document.addEventListener("visibilitychange", handleCountVisibility);
    return () =>
      document.removeEventListener("visibilitychange", handleCountVisibility);
  }, [refreshActiveCount]);

  // Initial load: pending approvals plus the session titles that name the
  // group headers. Both stay best-effort so a sessions outage never clears
  // the pending list.
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
    void refreshSessions();
    return () => {
      cancelled = true;
    };
  }, [refreshSessions]);

  // Live approval prompts arrive over the shared socket; same-id frames merge in place so
  // enrichment swaps the pending badge for the valued one without remounting the card. Socket
  // reopen resyncs the whole list, so a notice decided while offline still settles here.
  // Rule broadcasts only retouch the Active-timed tally here; the mirror owns its rows.
  const handleWSApproval = useCallback((data: unknown) => {
    if (isRecord(data)) {
      const frame = data as Record<string, unknown>;
      if (frame.type === "access_rules_changed") {
        void refreshActiveCount();
        return;
      }
      if (
        frame.type === "approval_decided" ||
        frame.type === "approval_resolved"
      ) {
        const decidedID = [frame.id, frame.approvalID, frame.approvalId].find(
          (candidate): candidate is string =>
            typeof candidate === "string" && candidate.trim().length > 0,
        );
        if (decidedID) {
          setApprovals((previous) =>
            previous.filter((item) => item.id !== decidedID),
          );
        }
        void refreshActiveCount();
        return;
      }
    }
    const request = mergeApprovalFrame(data);
    if (!request) return;
    setApprovals((previous) =>
      previous.some((item) => item.id === request.id)
        ? previous.map((item) => (item.id === request.id ? request : item))
        : [...previous, request],
    );
  }, [refreshActiveCount]);

  useSharedWebSocket(handleWSApproval, undefined, refresh);

  // Visibility resync: returning to the tab refetches the pending list so
  // decisions and settlements made elsewhere appear without waiting for the
  // next live frame.
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        void refresh();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () =>
      document.removeEventListener("visibilitychange", handleVisibility);
  }, [refresh]);

  const groups = useMemo(
    () => buildGroups(approvals, sessionTitles),
    [approvals, sessionTitles],
  );

  function durationFor(id: string): TrustDuration {
    return durations[id] ?? "thisTime";
  }

  // An enrichment upsert can add an egress host to a card whose picker held a
  // dated tier, so the effective duration always falls back into the options
  // the card actually offers instead of rendering an unselectable value.
  function effectiveDurationFor(request: PermissionRequest): TrustDuration {
    const current = durationFor(request.id);
    return durationOptionsFor(request).some((option) => option.value === current)
      ? current
      : "thisTime";
  }

  // Single decision path: every card, including the brake, leaves through POST
  // /approvals/:id/decide with the unified {approved, duration, scope} payload plus the "inbox"
  // surface tag naming this card as the deciding origin for the audit trail.
  async function submitDecision(
    id: string,
    approved: boolean,
    duration: TrustDuration,
    scope?: AccessScopeDTO,
  ) {
    setDecidingState({ id, action: approved ? "allowing" : "denying" });
    setError(null);
    try {
      await decideApproval(id, approved, duration, scope, "inbox");
      setApprovals((previous) => previous.filter((item) => item.id !== id));
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Decision failed",
      );
    } finally {
      setDecidingState(null);
    }
  }

  function decideFromCard(request: PermissionRequest, approved: boolean) {
    // Deny stays exact-host on egress: no scope rides a refusal, so the
    // engine resolves the dialed host exactly even when widening is checked.
    const scope = !approved && resolveEgressHost(request) ? undefined : decisionScopeFor(
      request,
      effectiveScopeChoice(request, scopeChoices[request.id]),
      customScopes[request.id],
    );
    void submitDecision(
      request.id,
      approved,
      effectiveDurationFor(request),
      scope,
    );
  }

  // The brake's complete decision is releasing or holding the park, so it
  // sends the one-shot tier with no scope: neither choice can mint a rule.
  function decideBrake(request: PermissionRequest, approved: boolean) {
    void submitDecision(request.id, approved, "thisTime");
  }

  async function handleQuestionResponse(
    id: string,
    answer?: string,
    cancelled?: boolean,
  ) {
    setDecidingState({ id, action: cancelled ? "denying" : "allowing" });
    setError(null);
    try {
      await respondToQuestion(id, answer, cancelled);
      setApprovals((previous) => previous.filter((item) => item.id !== id));
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Response failed",
      );
    } finally {
      setDecidingState(null);
    }
  }

  function selectScopeChoice(request: PermissionRequest, choice: ScopeChoice) {
    setScopeChoices((previous) => ({ ...previous, [request.id]: choice }));
    // Picking custom with nothing staged opens the editor immediately so a
    // decision can never ship a half-described scope.
    if (choice === "custom" && !customScopes[request.id]) {
      openScopeDraft(request);
    }
  }

  function openScopeDraft(request: PermissionRequest) {
    setScopeDraftError(null);
    const staged = customScopes[request.id];
    setScopeDraft({
      id: request.id,
      kind: scopeEditorKind(request),
      text: staged ? scopeToText(staged) : scopePrefill(request),
    });
  }

  function saveScopeDraft() {
    if (!scopeDraft) return;
    const scope = buildCustomScope(scopeDraft.kind, scopeDraft.text);
    if (!scope) {
      setScopeDraftError("Enter at least one entry.");
      return;
    }
    if (
      scope.kind === "recipientSet" &&
      scope.handles.length > MAX_RECIPIENT_SET_MEMBERS
    ) {
      setScopeDraftError(
        `Keep the recipient list to ${MAX_RECIPIENT_SET_MEMBERS} or fewer entries.`,
      );
      return;
    }
    setCustomScopes((previous) => ({ ...previous, [scopeDraft.id]: scope }));
    setScopeChoices((previous) => ({ ...previous, [scopeDraft.id]: "custom" }));
    setScopeDraft(null);
    setScopeDraftError(null);
  }

  function cancelScopeDraft() {
    setScopeDraft(null);
    setScopeDraftError(null);
  }

  function decidingLabel(
    request: PermissionRequest,
    action: "allowing" | "denying",
  ): string {
    if (request.toolName === BRAKE_TOOL_NAME) {
      return action === "allowing" ? "Resuming…" : "Keeping paused…";
    }
    return action === "allowing" ? "Allowing & resuming…" : "Denying…";
  }

  function renderSeverityBadge(request: PermissionRequest) {
    const id = request.id;
    if (request.assessment) {
      // Fail-closed on unknown tiers: only engine-known severities render a
      // badge rather than guessing a tier color.
      if (
        request.assessment.severity === "safe" ||
        request.assessment.severity === "moderate" ||
        request.assessment.severity === "dangerous"
      ) {
        return (
          <span
            className={`badge approval-severity-badge severity-${request.assessment.severity}`}
            data-testid={`approval-severity-${id}`}
          >
            {request.assessment.severity === "safe" && "🟢 Safe"}
            {request.assessment.severity === "moderate" && "🟡 State Change"}
            {request.assessment.severity === "dangerous" && "🔴 Dangerous"}
          </span>
        );
      }
      return null;
    }
    // Nil assessment is the pending state: spinner badge with the shared
    // pending copy, hiding outcome and warnings while keeping Allow/Deny
    // enabled.
    return (
      <span
        className="badge approval-severity-badge severity-pending"
        data-testid={`approval-assessment-pending-${id}`}
      >
        <span
          className="approval-assessment-pending approval-assessment-pending-spinner"
          aria-hidden="true"
        />
        Checking safety…
      </span>
    );
  }

  function renderCard(request: PermissionRequest) {
    if (request.toolName === "question.ask") {
      return (
        <InlineQuestionCard
          key={request.id}
          request={request}
          deciding={decidingState?.id === request.id}
          variant="inbox"
          onRespond={(id, answer, cancelled) =>
            void handleQuestionResponse(id, answer, cancelled)
          }
        />
      );
    }

    // System notices are surfacing-only: the shared card renders the mapped
    // remedy, and a settled notice drops through the owner refetch plus the
    // approval_decided frame, never through an approve/deny decision.
    if (isSystemNoticeTool(request.toolName)) {
      return (
        <SystemNoticeCard
          key={request.id}
          request={request}
          variant="inbox"
          onRemedy={() => void refresh()}
        />
      );
    }

    if (request.toolName === BRAKE_TOOL_NAME) {
      const isDeciding = decidingState?.id === request.id;
      return (
        <div
          className="card approval-card approval-brake-card"
          key={request.id}
          data-testid={`approval-card-${request.id}`}
        >
          <div className="approval-card-header">
            <div className="approval-title-group">
              <span className="badge approval-tool-badge">
                {BRAKE_TOOL_NAME}
              </span>
              <span
                className="badge approval-severity-badge severity-dangerous"
                data-testid={`approval-severity-${request.id}`}
              >
                🔴 Dangerous
              </span>
            </div>
          </div>

          <div className="approval-narrative approval-intent">
            {request.description ||
              "The behavior brake parked the running turns after an anomaly in trusted-tool outcomes."}
          </div>

          <div className="approval-actions-bar">
            <div className="approval-decision-buttons">
              {isDeciding ? (
                <span className="text-xs muted approval-resuming-label">
                  <RefreshIcon size={12} className="spin" />
                  <span>
                    {decidingLabel(
                      request,
                      decidingState?.action ?? "allowing",
                    )}
                  </span>
                </span>
              ) : (
                <>
                  <button
                    type="button"
                    className="primary"
                    disabled={isDeciding}
                    onClick={() => decideBrake(request, true)}
                  >
                    Resume
                  </button>
                  <button
                    type="button"
                    className="danger"
                    disabled={isDeciding}
                    onClick={() => decideBrake(request, false)}
                  >
                    Keep paused
                  </button>
                </>
              )}
            </div>
          </div>
        </div>
      );
    }

    const id = request.id;
    const isDeciding = decidingState?.id === id;
    // An enrichment can re-badge a card as egress after a choice was picked,
    // so the checked radio always resolves through what this card may offer.
    const choice = effectiveScopeChoice(request, scopeChoices[id]);
    const customScope = customScopes[id];
    // A custom choice without a staged scope names no target, so the decision
    // controls hold until the editor saves one instead of shipping a
    // half-described payload.
    const scopeReady = choice !== "custom" || customScope !== undefined;
    const egressHost = resolveEgressHost(request);
    const widenableBase = widenableBaseDomain(egressHost);
    // The radios render exactly the choices the selector offers, so no card
    // can show a stranded tool-wide or custom option the engine would refuse.
    const choices = scopeChoicesFor(request);
    const derivedTarget = deriveRequestTarget(request);

    return (
      <div
        className="card approval-card"
        key={id}
        data-testid={`approval-card-${id}`}
      >
        <div className="approval-card-header">
          <div className="approval-title-group">
            <span className="badge approval-tool-badge">{request.toolName}</span>
            {egressHost ? (
              <span
                className="badge approval-egress-badge"
                data-testid={`approval-egress-${id}`}
              >
                🌐 {egressHost}
              </span>
            ) : null}
            {renderSeverityBadge(request)}
          </div>
        </div>

        {request.intent ? (
          <div className="approval-narrative approval-intent">
            <span className="approval-section-label">Why:</span> {request.intent}
          </div>
        ) : request.description && !request.assessment ? (
          <div className="approval-narrative approval-intent">
            {request.description}
          </div>
        ) : null}

        {request.assessment?.outcome ? (
          <div className="approval-narrative approval-outcome">
            <span className="approval-section-label">Expected outcome:</span>{" "}
            {request.assessment.outcome}
          </div>
        ) : null}

        <BashTierLine summary={resolveSandboxSummary(request)} />

        {request.assessment?.warnings && request.assessment.warnings.length > 0 ? (
          <ul className="approval-warnings">
            {request.assessment.warnings.map((w, idx) => (
              <li key={idx} className="approval-warning-item">
                ⚠️ {w}
              </li>
            ))}
          </ul>
        ) : null}

        {request.input?.argumentsJSON ? (
          <details className="approval-args-details">
            <summary className="approval-args-summary">View arguments</summary>
            <div className="approval-args-wrapper">
              <pre className="approval-args-code">{request.input.argumentsJSON}</pre>
            </div>
          </details>
        ) : null}

        <div className="approval-scope-line" data-testid={`approval-scope-${id}`}>
          <span className="approval-section-label">Scope:</span>
          <div className="approval-scope-options">
            <div
              role="radiogroup"
              aria-label={`Decision scope for ${request.toolName}`}
              className="approval-scope-radios"
            >
              <label className="approval-scope-option">
                <input
                  type="radio"
                  name={`approval-scope-${id}`}
                  checked={choice === "thisTarget"}
                  disabled={isDeciding}
                  onChange={() => selectScopeChoice(request, "thisTarget")}
                />
                <span>
                  {derivedTarget ? (
                    <>
                      {egressHost && egressHost.trim()
                        ? "This host"
                        : request.toolName === "messages.send" ||
                            request.toolName === "email.send"
                          ? "This recipient"
                          : "This target"}{" "}
                      <code
                        className="approval-scope-target"
                        title={derivedTarget}
                      >
                        {truncateTarget(derivedTarget)}
                      </code>
                    </>
                  ) : (
                    `All calls to ${request.toolName}`
                  )}
                </span>
              </label>
              {widenableBase ? (
                <label className="approval-scope-option">
                  <input
                    type="radio"
                    name={`approval-scope-${id}`}
                    checked={choice === "domainSubdomains"}
                    disabled={isDeciding}
                    onChange={() =>
                      selectScopeChoice(request, "domainSubdomains")
                    }
                  />
                  <span>
                    Include subdomains{" "}
                    <code className="approval-scope-target">
                      *.{widenableBase}
                    </code>
                  </span>
                </label>
              ) : null}
              {choices.includes("allTargets") ? (
                <label className="approval-scope-option">
                  <input
                    type="radio"
                    name={`approval-scope-${id}`}
                    checked={choice === "allTargets"}
                    disabled={isDeciding}
                    onChange={() => selectScopeChoice(request, "allTargets")}
                  />
                  <span>All targets</span>
                </label>
              ) : null}
              {choices.includes("custom") ? (
                <label className="approval-scope-option">
                  <input
                    type="radio"
                    name={`approval-scope-${id}`}
                    checked={choice === "custom"}
                    disabled={isDeciding}
                    onChange={() => selectScopeChoice(request, "custom")}
                    onClick={() => {
                      // Re-clicking the already-checked Custom radio fires no onChange, so the click
                      // itself reopens the editor while custom is selected with nothing staged — the
                      // radio is the sole custom-scope entry point.
                      if (choice === "custom" && !customScopes[id]) {
                        openScopeDraft(request);
                      }
                    }}
                  />
                  <span>Custom scope</span>
                </label>
              ) : null}
            </div>
            {choice === "custom" && customScope ? (
              <span
                className="muted text-sm approval-scope-summary"
                data-testid={`approval-scope-summary-${id}`}
              >
                {describeScope(customScope)}
              </span>
            ) : null}
          </div>
        </div>

        {egressHost ? (
          <p className="muted text-sm approval-scope-hint">
            {`Every tier maps to ${egressHost}: once, rest of this task, rest of this session, timed rules, or a durable rule.`}
          </p>
        ) : null}

        <div className="approval-actions-bar">
          <label className="approval-duration-label">
            <span className="text-sm muted">Duration:</span>
            <select
              aria-label={`Duration for ${request.toolName}`}
              value={effectiveDurationFor(request)}
              disabled={isDeciding}
              onChange={(event) => {
                const val = event.target.value;
                const duration: TrustDuration = durationOptionsFor(
                  request,
                ).some((option) => option.value === val)
                  ? (val as TrustDuration)
                  : "thisTime";
                setDurations((previous) => ({
                  ...previous,
                  [id]: duration,
                }));
              }}
            >
              {durationOptionsFor(request).map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>

          <div className="approval-decision-buttons">
            {isDeciding ? (
              <span className="text-xs muted approval-resuming-label">
                <RefreshIcon size={12} className="spin" />
                <span>
                  {decidingLabel(request, decidingState?.action ?? "allowing")}
                </span>
              </span>
            ) : (
              <>
                {/* Per-row locking: only the deciding row disables so
                    independent approvals stay actionable while one decision
                    (and its parked resume) is in flight. */}
                <button
                  type="button"
                  className="primary"
                  disabled={!scopeReady}
                  title={
                    scopeReady
                      ? undefined
                      : "Pick a custom scope first. Select the Custom scope radio to open the editor."
                  }
                  onClick={() => decideFromCard(request, true)}
                >
                  Allow
                </button>
                <button
                  type="button"
                  className="danger"
                  disabled={!scopeReady}
                  title={
                    scopeReady
                      ? undefined
                      : "Pick a custom scope first. Select the Custom scope radio to open the editor."
                  }
                  onClick={() => decideFromCard(request, false)}
                >
                  Deny
                </button>
              </>
            )}
          </div>
        </div>
      </div>
    );
  }

  return (
    <section className="panel approvals-panel" aria-label="Approvals inbox">
      <div className="panel-header-row">
        <div>
          <h2>Inbox</h2>
          <p className="muted text-sm">
            Review and decide gated tool execution requests and operator
            questions.
          </p>
        </div>
        <a
          className="ghost icon-text-btn"
          href={STANDING_RULES_HREF}
          title="Standing rules live in Settings → Access"
        >
          <ApprovalsIcon size={14} />
          <span>Manage standing rules</span>
        </a>
      </div>
      <div className="approvals-view-nav">
        <div
          role="tablist"
          aria-label="Inbox views"
          className="approvals-view-toggle"
        >
          <button
            type="button"
            role="tab"
            id="inbox-tab-pending"
            data-testid="inbox-view-pending"
            aria-selected={view === "pending"}
            aria-pressed={view === "pending"}
            aria-controls="inbox-panel-pending"
            onClick={() => setView("pending")}
          >
            {`Pending (${approvals.length})`}
          </button>
          <button
            type="button"
            role="tab"
            id="inbox-tab-active-timed"
            data-testid="inbox-view-active-timed"
            aria-selected={view === "active-timed"}
            aria-pressed={view === "active-timed"}
            aria-controls="inbox-panel-active-timed"
            onClick={() => setView("active-timed")}
          >
            {activeTimedCount !== null
              ? `Active-timed (${activeTimedCount})`
              : "Active-timed"}
          </button>
          <button
            type="button"
            role="tab"
            id="inbox-tab-history"
            data-testid="inbox-view-history"
            aria-selected={view === "history"}
            aria-pressed={view === "history"}
            aria-controls="inbox-panel-history"
            onClick={() => setView("history")}
          >
            History
          </button>
        </div>
      </div>

      {view === "pending" ? (
        <div
          id="inbox-panel-pending"
          role="tabpanel"
          aria-labelledby="inbox-tab-pending"
          aria-label="Pending"
        >
          {/* Ephemeral session trust for the filtered session, above the pending
              groups: it lists what stays auto-approved for that conversation with
              a per-line revoke. Nothing renders while no session is filtered. */}
          <EphemeralTrustChip sessionID={sessionID} />

          {error ? <p className="error">{error}</p> : null}
          {approvals.length === 0 && !loading ? (
            <div className="approvals-empty muted">
              <p>No pending approvals.</p>
            </div>
          ) : null}

          <div className="approvals-groups">
            {groups.map((group) => (
              <div
                className="approvals-group"
                key={group.key}
                data-testid={`approvals-group-${group.key}`}
              >
                {/* Sticky session header: every card renders beneath it with no
                    collapse, so no group can hide a pending decision. */}
                <h3 className="approvals-group-header">{group.title}</h3>
                <div className="approvals-list">
                  {group.requests.map((request) => renderCard(request))}
                </div>
              </div>
            ))}
          </div>
        </div>
      ) : null}
      {view === "active-timed" ? (
        <div
          id="inbox-panel-active-timed"
          role="tabpanel"
          aria-labelledby="inbox-tab-active-timed"
          aria-label="Active-timed"
        >
          <ApprovalActiveTrust sessionID={sessionID} />
        </div>
      ) : null}
      {view === "history" ? (
        <div
          id="inbox-panel-history"
          role="tabpanel"
          aria-labelledby="inbox-tab-history"
          aria-label="History"
        >
          <ApprovalHistory />
        </div>
      ) : null}

      {/* Scope editor through the shared modal so the dialog portals above
          page stacking contexts with Escape support; only the modal save
          commits a scope to the card's next decision. */}
      {scopeDraft ? (
        <Modal
          label="Edit decision scope"
          onClose={cancelScopeDraft}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Edit scope</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelScopeDraft}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted text-sm m-0">
              {SCOPE_EDITOR_COPY[scopeDraft.kind].hint}
            </p>
            <label className="muted text-sm" htmlFor="approval-scope-editor">
              {SCOPE_EDITOR_COPY[scopeDraft.kind].label}
            </label>
            <textarea
              id="approval-scope-editor"
              className="approval-scope-editor"
              rows={6}
              value={scopeDraft.text}
              onChange={(event) =>
                setScopeDraft((previous) =>
                  previous ? { ...previous, text: event.target.value } : previous,
                )
              }
            />
            {scopeDraftError ? (
              <p className="error mt-2" role="alert">
                {scopeDraftError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={cancelScopeDraft}>
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={saveScopeDraft}
            >
              Save scope
            </button>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}
