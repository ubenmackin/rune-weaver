// Rune Weaver Dashboard — Approvals and access rules API.
import { fetchJson } from "./http";
import { ApiError } from "./http";
import { isRecord } from "../typeGuards";
import type {
  ApprovalsResponse,
  ApprovalDecisionResponse,
  AccessScopeDTO,
  AccessRule,
  AccessRulesResponse,
  AccessRuleEffect,
  SessionTrustResponse,
  NewAccessRuleInput,
  TrustDuration,
} from "./types";
import { trustDurationOptions, parseRunTimestamp, isAccessScope } from "./types";


export function listApprovals(limit?: number): Promise<ApprovalsResponse> {
  const query = limit != null && limit > 0 ? `?limit=${encodeURIComponent(limit)}` : "";
  return fetchJson<ApprovalsResponse>(`/approvals${query}`);
}

// Single decision path shared by the chat banner, the inbox, the dashboard quick action, and
// WebSocket triage: one POST carrying {approved, duration, scope}.
export async function decideApproval(
  id: string,
  approved: boolean,
  duration: TrustDuration = "thisTime",
  scope?: AccessScopeDTO,
  surface?: string,
): Promise<ApprovalDecisionResponse> {
  if (scope !== undefined && !isAccessScope(scope)) {
    throw new ApiError("Decision scope is malformed", 0);
  }
  // A blank surface tag names no origin, so it stays omitted rather than
  // stored as an empty string the audit trail would have to interpret.
  const trimmedSurface = typeof surface === "string" ? surface.trim() : "";
  return fetchJson<ApprovalDecisionResponse>(
    `/approvals/${encodeURIComponent(id)}/decide`,
    {
      method: "POST",
      body: JSON.stringify({
        approved,
        duration,
        ...(scope !== undefined ? { scope } : {}),
        ...(trimmedSurface ? { surface: trimmedSurface } : {}),
      }),
    },
  );
}

export function respondToQuestion(
  id: string,
  answer?: string,
  cancelled?: boolean,
): Promise<ApprovalDecisionResponse> {
  return fetchJson<ApprovalDecisionResponse>(
    `/approvals/${encodeURIComponent(id)}/respond`,
    {
      method: "POST",
      body: JSON.stringify({ answer, cancelled }),
    },
  );
}

// Decision-surface filter for the audit trail: an allow entry resolved the
// parked call while a deny entry refused it. Kept as action words so the
// query reads as the owner chose rather than as a wire boolean.
export type ApprovalHistoryAction = "allowed" | "denied";

// One resolved decision in the audit trail, mirroring the server DTO: the request identity plus the
// tool, the recorded scope split into kind and data, the verdict, the tier, the deciding surface,
// and the resolution time in either wire shape the engine emits.
export interface ApprovalHistoryEntry {
  id: string;
  toolName: string;
  scopeKind?: string | null;
  scopeData?: string | null;
  allowed: boolean;
  duration: string;
  surface: string;
  sessionID?: string | null;
  displayTarget?: string | null;
  decidedAt: string | number;
}

export interface ApprovalHistoryResponse {
  entries: ApprovalHistoryEntry[];
  count: number;
}

export interface ApprovalHistoryParams {
  limit?: number;
  tool?: string;
  action?: ApprovalHistoryAction;
}

// Lists resolved approval decisions newest first through the shared JSON
// path. Every filter stays optional so the default call reads the recent
// window; a blank tool or an out-of-range limit is omitted rather than sent.
export function listApprovalHistory(
  params?: ApprovalHistoryParams,
): Promise<ApprovalHistoryResponse> {
  const query = new URLSearchParams();
  const limit = params?.limit;
  if (typeof limit === "number" && Number.isFinite(limit) && limit > 0) {
    query.set("limit", String(Math.floor(limit)));
  }
  const tool = params?.tool?.trim();
  if (tool) query.set("tool", tool);
  if (params?.action === "allowed" || params?.action === "denied") {
    query.set("action", params.action);
  }
  const suffix = query.toString();
  return fetchJson<ApprovalHistoryResponse>(
    suffix ? `/approvals/history?${suffix}` : "/approvals/history",
  );
}

// Clears the resolved-decision audit trail. Pending approvals stay parked;
// only settled rows drop, so the inbox never loses a decidable entry.
export function clearApprovalHistory(): Promise<void> {
  return fetchJson<void>("/approvals/history", {
    method: "DELETE",
  });
}

// Normalizes a rule expiry into a Date while preserving the forever contract: null stays null so
// callers can branch on "never expires" without sentinel-date comparisons.
export function parseRuleExpiry(
  value: string | number | null | undefined,
): Date | null {
  if (value == null) return null;
  return parseRunTimestamp(value);
}

// Normalizes a rule payload from the engine into the client model. The engine encodes `action`
// ("allow" | "deny") while older client mocks and legacy frames used `effect`; both spellings bridge
// to the two UI keys.
export function normalizeAccessRule(raw: unknown): AccessRule {
  if (!isRecord(raw)) {
    throw new ApiError("Access rule response is malformed", 0);
  }
  const record = raw as Record<string, unknown>;
  const rawEffect = typeof record.action === "string" ? record.action : record.effect;
  if (rawEffect !== "allow" && rawEffect !== "deny") {
    throw new ApiError("Access rule response is malformed", 0);
  }
  const action = rawEffect as AccessRuleEffect;
  const rawTool = typeof record.toolName === "string" ? record.toolName : record.tool;
  if (typeof rawTool !== "string" || rawTool.trim().length === 0) {
    throw new ApiError("Access rule response is malformed", 0);
  }
  const toolName = rawTool.trim();
  let duration: TrustDuration | null | undefined;
  const rawDuration = record.duration;
  if (rawDuration === undefined || rawDuration === null) {
    duration = action === "deny" ? "forever" : ((rawDuration as null | undefined) ?? undefined);
  } else {
    if (!isTrustDurationValue(rawDuration)) {
      throw new ApiError("Access rule response is malformed", 0);
    }
    if (action === "deny" && rawDuration !== "forever") {
      throw new ApiError("Access rule response is malformed", 0);
    }
    duration = rawDuration;
  }
  return {
    ...(record as unknown as AccessRule),
    toolName,
    tool: toolName,
    action,
    effect: action,
    duration: duration as TrustDuration,
  };
}

// Lists durable access rules so the dashboard can show what stays
// auto-approved (or parked, for a deny rule) without re-deriving it from the
// pending approvals inbox.
export async function listRules(): Promise<AccessRulesResponse> {
  const response = await fetchJson<AccessRulesResponse>("/approvals/rules");
  const rawRules = Array.isArray(response?.rules) ? response.rules : [];
  const rules = rawRules.map(normalizeAccessRule);
  const serverCount =
    typeof (response as { count?: unknown } | null | undefined)?.count === "number" &&
    Number.isFinite((response as { count: number }).count)
      ? (response as { count: number }).count
      : rules.length;
  return {
    ...response,
    rules,
    count: serverCount,
  };
}

// Revokes one rule by id. A 404 surfaces as ApiError through the shared fetchJson reason parsing so
// the UI can explain the rule already lapsed; a successful revoke returns 204 with no body, which
// fetchJson maps to void.
export function revokeRule(id: string): Promise<void> {
  return fetchJson<void>(`/approvals/rules/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

// Widens an active rule to a tool-wide scope.
export function widenRule(id: string): Promise<void> {
  return fetchJson<void>(`/approvals/rules/${encodeURIComponent(id)}/widen`, {
    method: "POST",
  });
}

// Re-arms an active rule with a new expiry tier in place.
export function rearmRule(
  id: string,
  duration: TrustDuration,
): Promise<void> {
  return fetchJson<void>(`/approvals/rules/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify({ duration }),
  });
}

// Reports whether a value names a tier in the shared duration vocabulary.
// Single source for the rule validator so the client refuses a tier the
// engine would reject.
function isTrustDurationValue(value: unknown): value is TrustDuration {
  return trustDurationOptions.some((option) => option.value === value);
}

// Fail-closed validator for a rule creation request: the tool must name a tool, the effect must be
// allow or deny, the scope must pass isAccessScope, and the tier must be a defined TrustDuration
// with deny always forever.
function isAccessRuleInput(value: unknown): value is NewAccessRuleInput {
  if (!isRecord(value)) return false;
  const tool = typeof value.toolName === "string" ? value.toolName : value.tool;
  if (typeof tool !== "string" || tool.trim().length === 0) return false;
  const effect = typeof value.action === "string" ? value.action : value.effect;
  if (effect !== "allow" && effect !== "deny") return false;
  if (!isAccessScope(value.scope)) return false;
  if (!isTrustDurationValue(value.duration)) return false;
  if (effect === "deny" && value.duration !== "forever") return false;
  return true;
}

// Mints a durable rule directly from the rules surface. The engine broadcasts
// `access_rules_changed` after the write, so every open dashboard refetches the list without a
// manual refresh.
export async function createRule(
  input: NewAccessRuleInput,
): Promise<AccessRule> {
  if (!isAccessRuleInput(input)) {
    throw new ApiError("Access rule request is malformed", 0);
  }
  const toolName = (input.toolName ?? input.tool)!.trim();
  const action = (typeof input.action === "string" ? input.action : input.effect) as AccessRuleEffect;
  const wirePayload: Record<string, unknown> = {
    toolName,
    action,
    tool: toolName,
    effect: action,
    scope: input.scope,
    duration: input.duration,
  };
  if (typeof input.reason === "string" && input.reason.trim().length > 0) {
    wirePayload.reason = input.reason.trim();
  }
  const response = await fetchJson<AccessRule>("/approvals/rules", {
    method: "POST",
    body: JSON.stringify(wirePayload),
  });
  return normalizeAccessRule(response);
}

// Reads the ephemeral trust one session still carries: the thisTime, forTask,
// and forSession grants that expire with their turn, task, or session instead
// of surviving into the durable rule store.
export function sessionTrust(sessionID: string): Promise<SessionTrustResponse> {
  const trimmed = sessionID.trim();
  const query = trimmed ? `?sessionID=${encodeURIComponent(trimmed)}` : "";
  return fetchJson<SessionTrustResponse>(`/approvals/session-trust${query}`);
}

// One revoke request for the ephemeral trust one session carries.
export interface EphemeralClearInput {
  sessionID: string;
  toolName: string;
  scope: AccessScopeDTO;
}

// Revokes the ephemeral trust one session still carries for one tool plus scope: the chip posts the
// owning session, the trusted tool, and the scoped target verbatim so the clear reaches exactly the
// row the owner clicked.
export function clearEphemeralTrust(
  input: EphemeralClearInput,
): Promise<void> {
  if (!isEphemeralClearInput(input)) {
    throw new ApiError("Ephemeral trust clear request is malformed", 0);
  }
  return fetchJson<void>("/approvals/ephemeral/clear", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

// Fail-closed validator for the revoke request: the session and tool must name
// something and the scope must pass isAccessScope, mirroring createRule's
// pre-wire refusal so a half-described clear never reaches the engine.
function isEphemeralClearInput(value: unknown): value is EphemeralClearInput {
  if (!isRecord(value)) return false;
  if (typeof value.sessionID !== "string" || value.sessionID.trim().length === 0) {
    return false;
  }
  if (typeof value.toolName !== "string" || value.toolName.trim().length === 0) {
    return false;
  }
  return isAccessScope(value.scope);
}

