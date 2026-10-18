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
  // payloads round-trip without a silently dropped filter.
  calendarNameContains?: string[];
  // Legacy alias decoded from older stored rows; never encoded on new saves,
  // which always use the canonical key above.
  calendarNames?: string[];
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

// Reads one string list under both dashboard camelCase and durable snake_case
// spellings so older rows still populate the form after a key migration.
function readFilterList(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string,
  legacyCamelKey?: string,
  legacySnakeKey?: string,
): string[] | undefined {
  return (
    normalizeFilterList(record[camelKey]) ??
    normalizeFilterList(record[snakeKey]) ??
    (legacyCamelKey ? normalizeFilterList(record[legacyCamelKey]) : undefined) ??
    (legacySnakeKey ? normalizeFilterList(record[legacySnakeKey]) : undefined)
  );
}

// Normalizes one rule condition to the canonical camelCase shape, folding the
// legacy calendar alias and any snake_case keys so saves always encode the
// engine spelling and reads never lose a filter.
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
      "calendarNames",
      "calendar_names",
    ) ??
    normalizeFilterList(fallback.calendarNameContains) ??
    normalizeFilterList(fallback.calendarNames);
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

// Normalizes one rule action to the canonical camelCase shape, accepting the
// durable snake_case keys and legacy type aliases so older rows still decode.
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

// Normalizes one rule to the canonical wire shape: legacy calendar keys fold
// to the engine spelling and the deprecated alias is dropped on encode.
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
  // The legacy alias is read-only tolerance: canonical saves carry only the
  // engine key so future reads never depend on the deprecated spelling.
  if (
    normalized.condition &&
    typeof normalized.condition === "object" &&
    "calendarNames" in normalized.condition
  ) {
    delete (normalized.condition as { calendarNames?: string[] }).calendarNames;
  }
  return normalized;
}

// Normalizes one stored job so legacy rule spellings render in the current
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
    condition.calendarNameContains ?? condition.calendarNames,
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
  // leaves the field alone, "" clears that poll string to null (blank → null normalization), and
  // clearPoll clears the whole poll trigger (account, query, mailbox, interval, limit) before...
  pollAccount?: string | null;
  pollQuery?: string | null;
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
  // Normalize rule spellings on read so legacy calendar aliases and snake_case
  // keys render in the current form instead of arriving as blank filters.
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

