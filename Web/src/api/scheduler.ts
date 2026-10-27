// Rune Weaver Dashboard — Scheduler jobs, scheduled sends, and event rules.
import { fetchJson } from "./http";
import { isRecord } from "../typeGuards";
import type {
  OrchestratorResponse,
} from "./types";
import { validateTurnResponse } from "./chat";


export type EventWatcherSource = "email" | "messages" | "calendar";
export type GroupChatFilter = "all" | "directOnly" | "groupOnly";

export interface EventRuleCondition {
  senderContains?: string[];
  subjectContains?: string[];
  contentContains?: string[];
  titleContains?: string[];
  // Canonical calendar filter key matching the engine encoding, so rule
  calendarNameContains?: string[];
  locationContains?: string[];
  excludeAllDay?: boolean;
  groupChatFilter?: GroupChatFilter;
  matchAll?: boolean;
}

export type EventRuleAction =
  | { type: "agentPrompt"; prompt: string }
  | { type: "directTool"; toolName: string; argumentsJSON: string };

export interface EventRule {
  id?: string;
  name: string;
  enabled?: boolean;
  condition: EventRuleCondition;
  action: EventRuleAction;
  stopProcessing?: boolean;
}

// Zero-token direct tools permitted on the event fast path. Mirrors the engine
// allowlist so the dashboard can only submit what the worker will execute;
// anything else must run as a scoped agent turn where approval applies.
export const ALLOWED_DIRECT_TOOL_NAMES: readonly string[] = [
  "calendar.create",
  "calendar.delete",
  "email.archive",
  "email.move",
];

// Fail-closed membership check for the fast path: trims before comparing so
// padded input cannot slip past the allowlist, and non-strings reject.
export function isAllowedDirectToolName(value: unknown): boolean {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (!trimmed) return false;
  return (ALLOWED_DIRECT_TOOL_NAMES as readonly string[]).includes(trimmed);
}

// Dashboard lead-time window for calendar watchers. Narrower than the engine
// persistence bound by design, so meeting prep fires close enough to be useful
// without sweeping months of meetings on a typo.
export const CALENDAR_LEAD_TIME_MINUTES_MIN = 5;
export const CALENDAR_LEAD_TIME_MINUTES_MAX = 120;

// Rejects non-actionable lead times before submit so the engine never has to.
export function validateCalendarLeadTimeMinutes(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    return `Meeting Lead Time must be between ${CALENDAR_LEAD_TIME_MINUTES_MIN} and ${CALENDAR_LEAD_TIME_MINUTES_MAX} minutes.`;
  }
  if (
    value < CALENDAR_LEAD_TIME_MINUTES_MIN ||
    value > CALENDAR_LEAD_TIME_MINUTES_MAX
  ) {
    return `Meeting Lead Time must be between ${CALENDAR_LEAD_TIME_MINUTES_MIN} and ${CALENDAR_LEAD_TIME_MINUTES_MAX} minutes.`;
  }
  return null;
}

// Dashboard batch-limit window for email watchers, pinned to EmailPollRule.minLimit...maxLimit
// (Sources/RuneWeaverCore/Scheduler.swift) so the wizard refuses what the engine would silently
// clamp.
export const POLL_LIMIT_MIN = 1;
export const POLL_LIMIT_MAX = 50;

// Rejects out-of-engine batch limits before submit so the stored job always
// carries an actionable fetch size.
export function validatePollLimit(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    return `Batch Limit must be between ${POLL_LIMIT_MIN} and ${POLL_LIMIT_MAX}.`;
  }
  if (value < POLL_LIMIT_MIN || value > POLL_LIMIT_MAX) {
    return `Batch Limit must be between ${POLL_LIMIT_MIN} and ${POLL_LIMIT_MAX}.`;
  }
  return null;
}

// Structured poll predicates combine with AND on the worker: Contains scans
// subject/from/body, From/Subject pin headers, UnreadOnly gates UNSEEN, and
// SinceDays bounds recency to SINCE <today-N>.
export type PollPredicateKind =
  | "contains"
  | "from"
  | "subject"
  | "unread"
  | "sinceDays";

export interface PollPredicate {
  kind: PollPredicateKind;
  value?: string;
  days?: number;
}

export const MAX_POLL_PREDICATES = 5;
export const POLL_SINCE_DAYS_MIN = 1;
export const POLL_SINCE_DAYS_MAX = 90;
export const POLL_SINCE_PRESETS: readonly number[] = [1, 7, 30];

export interface PollPredicatePayload {
  pollContains: string | null;
  pollFrom: string | null;
  pollSubject: string | null;
  pollUnreadOnly: boolean;
  pollSinceDays: number | null;
  pollQuery: string | null;
}

// Reads one optional poll string under both camelCase and snake_case keys,
// so durable rows decode even before the engine adopts the new spelling.
function readPollString(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string,
): string | null {
  const raw =
    typeof record[camelKey] === "string"
      ? (record[camelKey] as string)
      : typeof record[snakeKey] === "string"
        ? (record[snakeKey] as string)
        : null;
  if (raw == null) return null;
  const trimmed = raw.trim();
  return trimmed ? trimmed : null;
}

// Builds the editor row list from one stored job. The server stores
// Contains in pollQuery, so pollContains falls back to pollQuery when
// absent; every non-empty predicate combines with AND on the worker.
export function predicatesFromJob(job: SchedulerJob): PollPredicate[] {
  if (!isRecord(job)) return [];
  const record = job as unknown as Record<string, unknown>;
  const structured: PollPredicate[] = [];
  const containsDirect = readPollString(record, "pollContains", "poll_contains");
  const containsLegacy = readPollString(record, "pollQuery", "poll_query");
  const containsValue = containsDirect ?? containsLegacy;
  if (containsValue) structured.push({ kind: "contains", value: containsValue });
  const fromValue = readPollString(record, "pollFrom", "poll_from");
  if (fromValue) structured.push({ kind: "from", value: fromValue });
  const subjectValue = readPollString(record, "pollSubject", "poll_subject");
  if (subjectValue) structured.push({ kind: "subject", value: subjectValue });
  const unreadRaw = record["pollUnreadOnly"] ?? record["poll_unread_only"];
  if (unreadRaw === true) structured.push({ kind: "unread" });
  const sinceRaw = record["pollSinceDays"] ?? record["poll_since_days"];
  if (typeof sinceRaw === "number" && Number.isFinite(sinceRaw)) {
    structured.push({ kind: "sinceDays", days: sinceRaw });
  }
  return structured;
}

// Maps editor rows back to the save payload. The legacy pollQuery mirrors the
// Contains value so older readers keep filtering on the same text.
export function predicatesToPayload(
  predicates: PollPredicate[] | null | undefined,
): PollPredicatePayload {
  let pollContains: string | null = null;
  let pollFrom: string | null = null;
  let pollSubject: string | null = null;
  let pollUnreadOnly = false;
  let pollSinceDays: number | null = null;
  if (Array.isArray(predicates)) {
    for (const predicate of predicates) {
      if (!isRecord(predicate)) continue;
      const kind = (predicate as PollPredicate).kind;
      if (kind === "contains" && pollContains == null) {
        const raw = (predicate as PollPredicate).value;
        if (typeof raw === "string" && raw.trim()) pollContains = raw.trim();
      } else if (kind === "from" && pollFrom == null) {
        const raw = (predicate as PollPredicate).value;
        if (typeof raw === "string" && raw.trim()) pollFrom = raw.trim();
      } else if (kind === "subject" && pollSubject == null) {
        const raw = (predicate as PollPredicate).value;
        if (typeof raw === "string" && raw.trim()) pollSubject = raw.trim();
      } else if (kind === "unread") {
        pollUnreadOnly = true;
      } else if (kind === "sinceDays" && pollSinceDays == null) {
        const days = (predicate as PollPredicate).days;
        if (typeof days === "number" && Number.isFinite(days)) {
          pollSinceDays = days;
        }
      }
    }
  }
  return {
    pollContains,
    pollFrom,
    pollSubject,
    pollUnreadOnly,
    pollSinceDays,
    pollQuery: pollContains,
  };
}

// Fail-closed predicate validator: zero rows means match-all with rule
// routing, so only non-empty lists can fail on blank values or bounds.
export function validatePollPredicates(
  predicates: PollPredicate[] | null | undefined,
): string | null {
  if (predicates == null) return null;
  if (!Array.isArray(predicates)) return "Predicate 1: predicates are malformed.";
  if (predicates.length === 0) return null;
  if (predicates.length > MAX_POLL_PREDICATES) {
    return `Too many predicates: at most ${MAX_POLL_PREDICATES} allowed.`;
  }
  // Each kind maps to one engine field, so duplicates would silently drop
  // in the payload while the preview still shows AND; reject them here.
  const seenKinds = new Set<string>();
  for (let i = 0; i < predicates.length; i++) {
    const label = `Predicate ${i + 1}`;
    const predicate = predicates[i];
    if (!predicate || !isRecord(predicate)) return `${label}: predicate is malformed.`;
    const kind = (predicate as PollPredicate).kind;
    if (kind === "unread") {
      if (seenKinds.has(kind)) {
        return `${label} (Unread-only): duplicate predicate; only one Unread-only allowed.`;
      }
      seenKinds.add(kind);
      continue;
    }
    if (kind === "contains" || kind === "from" || kind === "subject") {
      const name =
        kind === "contains" ? "Contains" : kind === "from" ? "From" : "Subject";
      if (seenKinds.has(kind)) {
        return `${label} (${name}): duplicate predicate; only one ${name} allowed.`;
      }
      seenKinds.add(kind);
      const raw = (predicate as PollPredicate).value;
      if (typeof raw !== "string" || !raw.trim()) {
        return `${label} (${name}): value must not be empty.`;
      }
      continue;
    }
    if (kind === "sinceDays") {
      if (seenKinds.has(kind)) {
        return `${label} (SinceDays): duplicate predicate; only one SinceDays allowed.`;
      }
      seenKinds.add(kind);
      const days = (predicate as PollPredicate).days;
      if (typeof days !== "number" || !Number.isSafeInteger(days)) {
        return `${label} (SinceDays): days must be a whole number between ${POLL_SINCE_DAYS_MIN} and ${POLL_SINCE_DAYS_MAX}.`;
      }
      if (days < POLL_SINCE_DAYS_MIN || days > POLL_SINCE_DAYS_MAX) {
        return `${label} (SinceDays): days must be between ${POLL_SINCE_DAYS_MIN} and ${POLL_SINCE_DAYS_MAX}.`;
      }
      continue;
    }
    return `${label}: unknown predicate kind.`;
  }
  return null;
}

// Renders rows as one AND sentence for the review step, so combined filters
// read as the worker applies them.
export function pollPredicatePreview(
  predicates: PollPredicate[] | null | undefined,
): string {
  if (!Array.isArray(predicates) || predicates.length === 0) {
    return "Match all mail";
  }
  const parts: string[] = [];
  for (const predicate of predicates) {
    if (!isRecord(predicate)) continue;
    const row = predicate as PollPredicate;
    if (row.kind === "contains" && typeof row.value === "string" && row.value.trim()) {
      parts.push(`Contains "${row.value.trim()}"`);
    } else if (row.kind === "from" && typeof row.value === "string" && row.value.trim()) {
      parts.push(`From "${row.value.trim()}"`);
    } else if (row.kind === "subject" && typeof row.value === "string" && row.value.trim()) {
      parts.push(`Subject "${row.value.trim()}"`);
    } else if (row.kind === "unread") {
      parts.push("Unread only");
    } else if (row.kind === "sinceDays" && typeof row.days === "number") {
      parts.push(
        row.days === 1 ? "Within last 1 day" : `Within last ${row.days} days`,
      );
    }
  }
  if (parts.length === 0) return "Match all mail";
  return parts.join(" AND ");
}

// Per-source default for the direct-tool radio. Email and calendar each have a
// dedicated allowlisted mutation; messages has none, so it falls back to the
// first allowlisted entry rather than offering an unexecutable tool.
export function defaultDirectToolForSource(source: EventWatcherSource): string {
  if (source === "email") return "email.move";
  if (source === "calendar") return "calendar.delete";
  return "email.archive";
}

// Trims one free-form filter list the same way the rule form splits CSV text,
// so blank entries never count as a configured filter.
function normalizeFilterList(value: unknown): string[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) return undefined;
  const trimmed = value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  return trimmed;
}

// Reads one string list under both dashboard camelCase and durable snake_case spellings.
function readFilterList(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string,
): string[] | undefined {
  return (
    normalizeFilterList(record[camelKey]) ??
    normalizeFilterList(record[snakeKey])
  );
}

// Normalizes one rule condition to the canonical camelCase shape so saves
// always encode the engine spelling and reads never lose a filter.
export function normalizeEventRuleCondition(
  condition: EventRuleCondition,
): EventRuleCondition {
  if (!isRecord(condition)) return condition;
  const record = condition as unknown as Record<string, unknown>;
  // The Record narrowing widens optional reads to unknown, so keep a typed
  // view for fallbacks to preserve the declared field types.
  const fallback = record as unknown as EventRuleCondition;
  const calendarNameContains =
    readFilterList(
      record,
      "calendarNameContains",
      "calendar_name_contains",
    ) ?? normalizeFilterList(fallback.calendarNameContains);
  return {
    senderContains:
      readFilterList(record, "senderContains", "sender_contains") ??
      fallback.senderContains,
    subjectContains:
      readFilterList(record, "subjectContains", "subject_contains") ??
      fallback.subjectContains,
    contentContains:
      readFilterList(record, "contentContains", "content_contains") ??
      fallback.contentContains,
    titleContains:
      readFilterList(record, "titleContains", "title_contains") ??
      fallback.titleContains,
    calendarNameContains,
    locationContains:
      readFilterList(record, "locationContains", "location_contains") ??
      fallback.locationContains,
    excludeAllDay:
      typeof record["excludeAllDay"] === "boolean"
        ? (record["excludeAllDay"] as boolean)
        : typeof record["exclude_all_day"] === "boolean"
          ? (record["exclude_all_day"] as boolean)
          : fallback.excludeAllDay,
    groupChatFilter:
      record["groupChatFilter"] === "all" ||
      record["groupChatFilter"] === "directOnly" ||
      record["groupChatFilter"] === "groupOnly"
        ? (record["groupChatFilter"] as GroupChatFilter)
        : record["group_chat_filter"] === "all" ||
            record["group_chat_filter"] === "directOnly" ||
            record["group_chat_filter"] === "groupOnly"
          ? (record["group_chat_filter"] as GroupChatFilter)
          : fallback.groupChatFilter,
    matchAll:
      typeof record["matchAll"] === "boolean"
        ? (record["matchAll"] as boolean)
        : typeof record["match_all"] === "boolean"
          ? (record["match_all"] as boolean)
          : fallback.matchAll,
  };
}

// Normalizes one rule action to the canonical camelCase shape, accepting
// durable snake_case keys so rows still decode.
export function normalizeEventRuleAction(
  action: EventRuleAction,
): EventRuleAction {
  if (!isRecord(action)) return action;
  const record = action as unknown as Record<string, unknown>;
  const rawType =
    typeof record["type"] === "string" ? (record["type"] as string).trim() : "";
  if (
    rawType === "agentPrompt" ||
    rawType === "agent_prompt" ||
    rawType === "prompt"
  ) {
    const prompt =
      typeof record["prompt"] === "string" ? (record["prompt"] as string) : "";
    return { type: "agentPrompt", prompt };
  }
  if (
    rawType === "directTool" ||
    rawType === "direct_tool" ||
    rawType === "tool"
  ) {
    const toolName =
      typeof record["toolName"] === "string"
        ? (record["toolName"] as string)
        : typeof record["tool_name"] === "string"
          ? (record["tool_name"] as string)
          : "";
    const argumentsJSON =
      typeof record["argumentsJSON"] === "string"
        ? (record["argumentsJSON"] as string)
        : typeof record["arguments_json"] === "string"
          ? (record["arguments_json"] as string)
          : "{}";
    return { type: "directTool", toolName, argumentsJSON };
  }
  return action;
}

// Normalizes one rule to the canonical wire shape.
export function normalizeEventRule(rule: EventRule): EventRule {
  if (!isRecord(rule)) return rule;
  const record = rule as unknown as Record<string, unknown>;
  const rawStopProcessing =
    typeof record["stopProcessing"] === "boolean"
      ? (record["stopProcessing"] as boolean)
      : typeof record["stop_processing"] === "boolean"
        ? (record["stop_processing"] as boolean)
        : rule.stopProcessing;
  const normalized: EventRule = {
    ...rule,
    condition: normalizeEventRuleCondition(rule.condition),
    action: normalizeEventRuleAction(rule.action),
    stopProcessing: rawStopProcessing,
  };
  return normalized;
}

// Normalizes one stored job so rule spellings render in the current
// form instead of arriving as blank filters.
export function normalizeSchedulerJob(job: SchedulerJob): SchedulerJob {
  if (!isRecord(job)) return job;
  const rules = Array.isArray(job.rules)
    ? job.rules.map((rule) => normalizeEventRule(rule as EventRule))
    : job.rules;
  return { ...job, rules: rules as SchedulerJob["rules"] };
}

function normalizeSchedulerJobsResponse(
  response: SchedulerJobsResponse,
): SchedulerJobsResponse {
  if (!isRecord(response) || !Array.isArray(response.jobs)) return response;
  return {
    ...response,
    jobs: response.jobs.map((job) => normalizeSchedulerJob(job)),
  };
}

// Reports whether a condition carries no actionable filter: every list is
// absent or blank, so the rule would fire on every event. Group scope and
// match strategy alone never count, since they only narrow a filter.
export function isEventRuleConditionEmpty(
  condition: EventRuleCondition | null | undefined,
): boolean {
  if (!condition || !isRecord(condition)) return true;
  const lists = [
    condition.senderContains,
    condition.subjectContains,
    condition.contentContains,
    condition.titleContains,
    condition.calendarNameContains,
    condition.locationContains,
  ];
  for (const list of lists) {
    if (Array.isArray(list)) {
      if (list.some((entry) => typeof entry === "string" && entry.trim())) {
        return false;
      }
    }
  }
  return true;
}

// Fail-closed single-rule validator mirroring the engine reject set: empty names, blank prompts,
// and off-allowlist tools refuse with a rule-scoped message before any network write.
export function validateEventRule(
  rule: EventRule,
  index: number,
): string | null {
  const label = `Rule ${index + 1}${rule?.name?.trim() ? ` ("${rule.name.trim()}")` : ""}`;
  if (!rule || !isRecord(rule)) return `${label}: rule is malformed.`;
  if (!rule.name || !rule.name.trim()) {
    return `${label}: rule name must not be empty.`;
  }
  const action = rule.action as EventRuleAction;
  if (!action || !isRecord(action)) return `${label}: action is malformed.`;
  if ((action as { type: string }).type === "agentPrompt") {
    const prompt = (action as { prompt?: unknown }).prompt;
    if (typeof prompt !== "string" || !prompt.trim()) {
      return `${label}: prompt must not be empty.`;
    }
    return null;
  }
  if ((action as { type: string }).type === "directTool") {
    const toolName = (action as { toolName?: unknown }).toolName;
    if (typeof toolName !== "string" || !toolName.trim()) {
      return `${label}: tool must be selected.`;
    }
    if (!isAllowedDirectToolName(toolName)) {
      return `${label}: tool '${toolName.trim()}' is not allowed (must be one of ${ALLOWED_DIRECT_TOOL_NAMES.join(", ")}).`;
    }
    return null;
  }
  return `${label}: unknown action type.`;
}

// Returns the first rule failure in order, so the wizard surfaces one
// actionable message instead of a stacked list.
export function validateEventRules(
  rules: EventRule[] | null | undefined,
): string | null {
  if (!Array.isArray(rules) || rules.length === 0) return null;
  for (let i = 0; i < rules.length; i++) {
    const failure = validateEventRule(rules[i], i);
    if (failure) return failure;
  }
  return null;
}

export interface SchedulerJob {
  id: string;
  name: string;
  schedule: string;
  prompt: string;
  enabled: boolean;
  pollAccount?: string | null;
  pollQuery?: string | null;
  pollContains?: string | null;
  pollFrom?: string | null;
  pollSubject?: string | null;
  pollUnreadOnly?: boolean | null;
  pollSinceDays?: number | null;
  pollMailbox?: string | null;
  pollIntervalSeconds?: number | null;
  pollLimit?: number | null;
  maxToolIterations?: number | null;
  onToolLimit?: string | null;
  watcherSource?: EventWatcherSource | null;
  rules?: EventRule[] | null;
  calendarLeadTimeMinutes?: number | null;
  calendarNames?: string[] | null;
  createdAt: string;
  updatedAt: string;
}

export interface SchedulerJobsResponse {
  jobs: SchedulerJob[];
  count: number;
}

// Booked delayed send row mirrored from the engine `ScheduledSend` contract:
// the stored bytes, recipient, and fire time are immutable once booked, and
// the fire worker replays them exactly once with re-validation.
export interface ScheduledSend {
  id: string;
  channel: "email" | "messages";
  status: "queued" | "sending" | "sent" | "cancelled" | "failed";
  account?: string | null;
  recipient: string;
  subject?: string | null;
  bodyText?: string | null;
  bodyHtml?: string | null;
  fireAt: string;
  createdAt: string;
  updatedAt: string;
  settledAt?: string | null;
  failureReason?: string | null;
}

export interface ScheduledSendsResponse {
  sends: ScheduledSend[];
  count: number;
}

export interface NewScheduledSendInput {
  channel: "email" | "messages";
  account?: string | null;
  recipient: string;
  subject?: string | null;
  bodyText?: string | null;
  bodyHtml?: string | null;
  // Approved fire time as epoch seconds; the engine minute-aligns it within
  // its lead-time and horizon bounds.
  fireAt: number;
}

export interface NewSchedulerJobInput {
  name: string;
  schedule: string;
  prompt: string;
  enabled?: boolean;
  pollAccount?: string | null;
  pollQuery?: string | null;
  pollContains?: string | null;
  pollFrom?: string | null;
  pollSubject?: string | null;
  pollUnreadOnly?: boolean | null;
  pollSinceDays?: number | null;
  pollMailbox?: string | null;
  pollIntervalSeconds?: number | null;
  pollLimit?: number | null;
  maxToolIterations?: number | null;
  onToolLimit?: string | null;
  watcherSource?: EventWatcherSource | null;
  rules?: EventRule[] | null;
  calendarLeadTimeMinutes?: number | null;
  calendarNames?: string[] | null;
}

export interface UpdateSchedulerJobInput {
  name?: string;
  schedule?: string;
  prompt?: string;
  enabled?: boolean;
  // Poll clear-vs-omit contract (mirrors UpdateSchedulerJob on the engine): omitted (undefined)
  // or null leaves the field alone, "" clears that poll string to null (blank → null normalization),
  // and clearPoll clears the whole poll trigger before re-applying non-nil fields in the same payload.
  pollAccount?: string | null;
  pollQuery?: string | null;
  pollContains?: string | null;
  pollFrom?: string | null;
  pollSubject?: string | null;
  pollUnreadOnly?: boolean | null;
  pollSinceDays?: number | null;
  pollMailbox?: string | null;
  pollIntervalSeconds?: number | null;
  pollLimit?: number | null;
  clearPoll?: boolean;
  // Tool-budget clear-vs-omit contract (mirrors UpdateSchedulerJob on the engine): omitted (undefined)
  // leaves the budget alone; use clearToolBudget:true to clear it to inherit (nil) before applying
  // any non-nil budget fields in the same payload.
  maxToolIterations?: number | null;
  // New action on tool limit ("fail" or "park"), if changed. Omitted (undefined) leaves the policy
  // alone; "" clears to nil, or use clearToolBudget:true to clear it to inherit (nil).
  onToolLimit?: string | null;
  // When true, clears the whole tool budget to nil (inherit) before applying any non-nil budget
  // fields in the same payload.
  clearToolBudget?: boolean;
  watcherSource?: EventWatcherSource | null;
  rules?: EventRule[] | null;
  calendarLeadTimeMinutes?: number | null;
  calendarNames?: string[] | null;
  clearWatcher?: boolean;
  clearRules?: boolean;
}


export function listJobs(limit?: number): Promise<SchedulerJobsResponse> {
  const query = limit != null && limit > 0 ? `?limit=${encodeURIComponent(limit)}` : "";
  // Normalize rule spellings on read so snake_case keys render in the current
  // form instead of arriving as blank filters.
  return fetchJson<SchedulerJobsResponse>(`/scheduler/jobs${query}`).then(
    normalizeSchedulerJobsResponse,
  );
}

export function getJob(id: string): Promise<SchedulerJob> {
  return fetchJson<SchedulerJob>(
    `/scheduler/jobs/${encodeURIComponent(id)}`,
  ).then(normalizeSchedulerJob);
}

export function createJob(input: NewSchedulerJobInput): Promise<SchedulerJob> {
  return fetchJson<SchedulerJob>("/scheduler/jobs", {
    method: "POST",
    body: JSON.stringify(input),
  }).then(normalizeSchedulerJob);
}

export function updateJob(
  id: string,
  input: UpdateSchedulerJobInput,
): Promise<SchedulerJob> {
  return fetchJson<SchedulerJob>(`/scheduler/jobs/${encodeURIComponent(id)}`, {
    method: "PUT",
    body: JSON.stringify(input),
  }).then(normalizeSchedulerJob);
}

export function deleteJob(id: string): Promise<void> {
  return fetchJson<void>(`/scheduler/jobs/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function runJobNow(id: string): Promise<OrchestratorResponse> {
  return fetchJson<OrchestratorResponse>(
    `/scheduler/jobs/${encodeURIComponent(id)}/run`,
    { method: "POST", body: JSON.stringify({}) },
  ).then((response) => validateTurnResponse(response, "Invalid job run response"));
}

// ---------------------------------------------------------------------------
// Scheduled sends (Schedules surface)
// ---------------------------------------------------------------------------

// Booked delayed sends mirror the engine byte-immutable contract: booking
// stores the exact bytes, recipient, and fire time at the approval moment,
// and the fire worker replays them exactly once with re-validation.
export function listScheduledSends(): Promise<ScheduledSendsResponse> {
  return fetchJson<ScheduledSendsResponse>(`/scheduler/sends`);
}

export function bookScheduledSend(
  input: NewScheduledSendInput,
): Promise<ScheduledSend> {
  return fetchJson<ScheduledSend>("/scheduler/sends", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

export function cancelScheduledSend(id: string): Promise<ScheduledSend> {
  return fetchJson<ScheduledSend>(`/scheduler/sends/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

