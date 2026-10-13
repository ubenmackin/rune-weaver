// Rune Weaver Dashboard — Approvals inbox for pending gated tool requests.
//
// Purpose: render every pending approval as its own decidable card, grouped by
// the owning chat session so a parked turn reads beside the conversation that
// filed it. Standing rules live in Settings → Access; this surface decides
// pending requests only and manages no grants.
// Scope: session grouping with sticky headers titled from GET /sessions,
// severity-ordered groups and cards, the unified decide payload
// ({approved, duration, scope}) on every card, the shared question picker
// card, and the dedicated behavior-brake branch.
// Architectural role: the Approvals tab surface, sharing the ApprovalQueue
// wire contract with the chat inline banner and the dashboard quick actions.

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ApiError,
  decideApproval,
  listApprovals,
  listSessions,
  respondToQuestion,
  trustDurationOptions,
  type AccessScopeDTO,
  type ImpactSeverity,
  type PermissionRequest,
  type TrustDuration,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import {
  approvalSessionID,
  mergeApprovalFrame,
  normalizeSessionID,
} from "../approvalsSession";
import { isRecord } from "../typeGuards";
import InlineQuestionCard from "./InlineQuestionCard";
import BashTierLine from "./BashTierLine";
import EphemeralTrustChip from "./EphemeralTrustChip";
import { resolveEgressHost, resolveSandboxSummary } from "./InlineApprovalBanner";
import Modal from "./Modal";
import { ApprovalsIcon, CloseIcon, RefreshIcon } from "./icons";

// Watchdog brake card identity, mirroring the engine's brake tool name: the
// one card whose complete decision is releasing the parked turns.
const BRAKE_TOOL_NAME = "behavior.brake";

// Group key and header for requests no session claims: the brake card, older
// payloads without a session tag, and headless filings all read here.
const UNATTRIBUTED_KEY = "__unattributed__";
const UNATTRIBUTED_TITLE = "Unattributed";

// Deep link into the Settings → Access pane that owns standing rules.
const STANDING_RULES_HREF = "#settings?access=rules";

// Engine recipient-set bound, mirrored so the editor refuses a set the rule
// store would reject instead of failing at the wire.
const MAX_RECIPIENT_SET_MEMBERS = 50;

// Argument keys the legacy target derivation reads, in the engine's priority
// order, so the preview line names the same thing a stored rule would cover.
const TARGET_ARGUMENT_KEYS = [
  "to",
  "recipient",
  "email",
  "target",
  "path",
  "url",
  "address",
  "destination",
];

// One ordering scale shared by cards and groups: dangerous over moderate over
// safe, so a consequential card never sinks below a quieter one.
function severityRank(severity: ImpactSeverity): number {
  switch (severity) {
    case "dangerous":
      return 3;
    case "moderate":
      return 2;
    default:
      return 1;
  }
}

// A nil assessment is the pending state and sorts as moderate, so an
// unassessed card never outranks a valued dangerous one nor sinks below a
// valued safe one while background enrichment is still in flight.
function requestSeverity(request: PermissionRequest): ImpactSeverity {
  return request.assessment?.severity ?? "moderate";
}

// The egress tier mapping names exactly three durations: thisTime allows the
// host once, forSession allows it for the session, and forever mints the
// durable domain rule. Offering a dated tier the mapping never reads would
// invent a second control language, so a parked-host card carries only these
// three tiers in the shared duration vocabulary.
const EGRESS_DURATIONS: TrustDuration[] = ["thisTime", "forSession", "forever"];

interface DurationOption {
  value: TrustDuration;
  label: string;
}

function durationOptionsFor(request: PermissionRequest): DurationOption[] {
  if (!resolveEgressHost(request)) return trustDurationOptions;
  return EGRESS_DURATIONS.map((value) =>
    trustDurationOptions.find((option) => option.value === value),
  ).filter((option): option is DurationOption => option !== undefined);
}

// Best-effort preview of the request's own target for the scope line. The
// engine's descriptor derivation stays authoritative — "this target" omits the
// scope so the server resolves it — this copy only names what the owner is
// about to trust. Unreadable arguments degrade to no preview rather than a
// misleading one.
function previewRequestTarget(request: PermissionRequest): string | null {
  const host = resolveEgressHost(request);
  if (host) return host;
  let parsed: unknown;
  try {
    parsed = JSON.parse(request.input?.argumentsJSON ?? "");
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  for (const key of TARGET_ARGUMENT_KEYS) {
    const value = parsed[key];
    if (typeof value !== "string") continue;
    const trimmed = value.trim();
    if (trimmed) return trimmed;
  }
  return null;
}

// Editor shape a custom scope takes, keyed to what the wire scope vocabulary
// can carry for the tool: a recipient set for the send tools, one host for an
// egress-parked request, and a single exact-target string for path, pattern,
// and generic calls.
type ScopeEditorKind = "recipients" | "hosts" | "paths" | "pattern";

const SCOPE_EDITOR_COPY: Record<
  ScopeEditorKind,
  { label: string; hint: string }
> = {
  recipients: {
    label: "Recipients",
    hint: "One canonical recipient per line. Every listed recipient is covered.",
  },
  hosts: {
    label: "Hosts / domains",
    hint: "One host or domain per line. The first entry becomes the rule's host.",
  },
  paths: {
    label: "Paths",
    hint: "One path per line. The first entry becomes the rule's target.",
  },
  pattern: {
    label: "Pattern",
    hint: "One pattern or exact target per line. The first entry becomes the rule's target.",
  },
};

function scopeEditorKind(request: PermissionRequest): ScopeEditorKind {
  if (resolveEgressHost(request)) return "hosts";
  if (request.toolName === "messages.send" || request.toolName === "email.send") {
    return "recipients";
  }
  if (request.toolName === "bash.exec") return "pattern";
  if (request.toolName.startsWith("files.")) return "paths";
  return "pattern";
}

// Editor prefill: the request's own target for the kind that can carry it, so
// narrowing starts from what is about to run. Everything else opens blank.
function scopePrefill(request: PermissionRequest): string {
  switch (scopeEditorKind(request)) {
    case "hosts":
      return resolveEgressHost(request) ?? "";
    default:
      return previewRequestTarget(request) ?? "";
  }
}

// Splits editor text into deduplicated, non-blank entries. The
// case-insensitive dedupe matches the recipient normalization the rule store
// applies, so a repeated spelling never reads as two members.
function splitScopeEntries(text: string): string[] {
  const seen = new Set<string>();
  const entries: string[] = [];
  for (const rawLine of text.split("\n")) {
    const trimmed = rawLine.trim();
    if (!trimmed) continue;
    const key = trimmed.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    entries.push(trimmed);
  }
  return entries;
}

// Builds the wire scope from editor text. The recipient set travels whole;
// every single-value kind names its first entry, because one decision carries
// one scope and the wire vocabulary holds one host or one target per rule.
// Returns null for an all-blank editor so the caller refuses the save.
function buildCustomScope(
  kind: ScopeEditorKind,
  text: string,
): AccessScopeDTO | null {
  const entries = splitScopeEntries(text);
  if (entries.length === 0) return null;
  switch (kind) {
    case "recipients":
      return { kind: "recipientSet", handles: entries };
    case "hosts":
      return { kind: "domain", host: entries[0] };
    default:
      return { kind: "exactTarget", target: entries[0] };
  }
}

// Editor text for a staged scope, so reopening the modal shows exactly what
// the next decision would ship.
function scopeToText(scope: AccessScopeDTO): string {
  switch (scope.kind) {
    case "tool":
      return "";
    case "exactTarget":
      return scope.target;
    case "recipientSet":
      return scope.handles.join("\n");
    case "domain":
      return scope.host;
  }
}

// One-line reading of a staged scope for the card summary.
function describeScope(scope: AccessScopeDTO): string {
  switch (scope.kind) {
    case "tool":
      return "all targets";
    case "exactTarget":
      return scope.target;
    case "recipientSet":
      return `${scope.handles.length} recipients`;
    case "domain":
      return scope.host;
  }
}

type ScopeChoice = "thisTarget" | "allTargets" | "custom";

// Resolves the scope one decision carries. "All targets" names the tool-wide
// scope, "custom" ships the staged editor scope, and "this target" derives
// the domain scope for an egress-parked request — otherwise the scope stays
// omitted so the engine resolves the request's own target instead of the
// dashboard second-guessing it.
function decisionScopeFor(
  request: PermissionRequest,
  choice: ScopeChoice,
  custom: AccessScopeDTO | undefined,
): AccessScopeDTO | undefined {
  if (choice === "allTargets") return { kind: "tool" };
  if (choice === "custom") return custom;
  const host = resolveEgressHost(request);
  return host ? { kind: "domain", host } : undefined;
}

interface ApprovalGroup {
  key: string;
  title: string;
  requests: PermissionRequest[];
  // Newest filing position inside the group, kept as the stable tiebreak
  // between groups of equal maximum severity.
  newestIndex: number;
}

// The brake card parks every running turn rather than one session's call, so
// it always reads under Unattributed even when the watchdog tagged a session.
function groupKeyFor(request: PermissionRequest): string {
  if (request.toolName === BRAKE_TOOL_NAME) return UNATTRIBUTED_KEY;
  return normalizeSessionID(approvalSessionID(request)) || UNATTRIBUTED_KEY;
}

// The wire carries no filing timestamp, so payload position is the filing
// signal: the engine lists pending entries oldest-first, which makes a later
// position the more recent filing. Cards order by severity descending then by
// that position descending; groups order by their maximum card severity with
// the same newest-filing tiebreak, so the ordering is total and stable.
function buildGroups(
  approvals: PermissionRequest[],
  titles: Map<string, string>,
): ApprovalGroup[] {
  const buckets = new Map<
    string,
    {
      rawID: string;
      entries: Array<{ request: PermissionRequest; index: number }>;
    }
  >();
  approvals.forEach((request, index) => {
    const key = groupKeyFor(request);
    const bucket = buckets.get(key);
    if (bucket) {
      bucket.entries.push({ request, index });
      if (!bucket.rawID) bucket.rawID = (approvalSessionID(request) ?? "").trim();
      return;
    }
    buckets.set(key, {
      rawID: (approvalSessionID(request) ?? "").trim(),
      entries: [{ request, index }],
    });
  });

  const groups: ApprovalGroup[] = [];
  for (const [key, bucket] of buckets) {
    const ordered = [...bucket.entries].sort((a, b) => {
      const bySeverity =
        severityRank(requestSeverity(b.request)) -
        severityRank(requestSeverity(a.request));
      return bySeverity !== 0 ? bySeverity : b.index - a.index;
    });
    const titled = titles.get(key);
    groups.push({
      key,
      title:
        key === UNATTRIBUTED_KEY
          ? UNATTRIBUTED_TITLE
          : titled || bucket.rawID || UNATTRIBUTED_TITLE,
      requests: ordered.map((entry) => entry.request),
      newestIndex: Math.max(...bucket.entries.map((entry) => entry.index)),
    });
  }

  return groups.sort((a, b) => {
    const bySeverity =
      maxSeverityRank(b.requests) - maxSeverityRank(a.requests);
    return bySeverity !== 0 ? bySeverity : b.newestIndex - a.newestIndex;
  });
}

function maxSeverityRank(requests: PermissionRequest[]): number {
  return requests.reduce(
    (highest, request) =>
      Math.max(highest, severityRank(requestSeverity(request))),
    0,
  );
}

interface ScopeDraft {
  id: string;
  kind: ScopeEditorKind;
  text: string;
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

  // Live approval prompts arrive over the shared socket; same-id frames merge
  // in place so enrichment swaps the pending badge for the valued one without
  // remounting the card. Decision frames evict promptly so a cross-tab or
  // menu-bar decision disappears immediately. The rules-change frame drops
  // here: standing rules live in Settings → Access, so nothing
  // grants-related remains for this surface to refresh.
  const handleWSApproval = useCallback((data: unknown) => {
    if (isRecord(data)) {
      const frame = data as Record<string, unknown>;
      if (frame.type === "access_rules_changed") return;
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
  }, []);

  useSharedWebSocket(handleWSApproval);

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

  // Single decision path: every card, including the brake, leaves through
  // POST /approvals/:id/decide with the unified {approved, duration, scope}
  // payload.
  async function submitDecision(
    id: string,
    approved: boolean,
    duration: TrustDuration,
    scope?: AccessScopeDTO,
  ) {
    setDecidingState({ id, action: approved ? "allowing" : "denying" });
    setError(null);
    try {
      await decideApproval(id, approved, duration, scope);
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
    const choice = scopeChoices[request.id] ?? "thisTarget";
    void submitDecision(
      request.id,
      approved,
      effectiveDurationFor(request),
      decisionScopeFor(request, choice, customScopes[request.id]),
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
    const choice = scopeChoices[id] ?? "thisTarget";
    const customScope = customScopes[id];
    // A custom choice without a staged scope names no target, so the decision
    // controls hold until the editor saves one instead of shipping a
    // half-described payload.
    const scopeReady = choice !== "custom" || customScope !== undefined;
    const egressHost = resolveEgressHost(request);
    const targetPreview = previewRequestTarget(request);

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
                  {egressHost
                    ? "This host"
                    : request.toolName === "messages.send" ||
                        request.toolName === "email.send"
                      ? "This recipient"
                      : "This target"}
                  {targetPreview ? (
                    <>
                      {" "}
                      <code className="approval-scope-target">
                        {targetPreview}
                      </code>
                    </>
                  ) : null}
                </span>
              </label>
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
              <label className="approval-scope-option">
                <input
                  type="radio"
                  name={`approval-scope-${id}`}
                  checked={choice === "custom"}
                  disabled={isDeciding}
                  onChange={() => selectScopeChoice(request, "custom")}
                />
                <span>Custom scope</span>
              </label>
            </div>
            <button
              type="button"
              className="ghost"
              disabled={isDeciding}
              onClick={() => openScopeDraft(request)}
            >
              Edit scope
            </button>
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
            {`Tiers map to ${egressHost}: once, for this session, or a durable rule.`}
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
                      : "Pick a custom scope first — Edit scope opens the editor."
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
                      : "Pick a custom scope first — Edit scope opens the editor."
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

        <div className="row">
          <a
            className="ghost icon-text-btn"
            href={STANDING_RULES_HREF}
            title="Standing rules live in Settings → Access"
          >
            <ApprovalsIcon size={14} />
            <span>Manage standing rules</span>
          </a>
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
            <p className="muted text-sm" style={{ margin: 0 }}>
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
              <p className="error" role="alert" style={{ margin: "8px 0 0 0" }}>
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
