// Typed client for the engine JSON API.
//
// Same-origin by design: every path below is relative ("/health",
// "/chat", ...) so the dashboard bundle served by the engine needs no
// CORS and no runtime Node server. Do not introduce absolute hosts here.

export type TrustDuration =
  | "thisTime"
  | "fiveMinutes"
  | "oneHour"
  | "oneDay"
  | "forever";

export const trustDurationOptions: Array<{ value: TrustDuration; label: string }> = [
  { value: "thisTime", label: "Only this time" },
  { value: "fiveMinutes", label: "Next 5 minutes" },
  { value: "oneHour", label: "Next hour" },
  { value: "oneDay", label: "Next day" },
  { value: "forever", label: "Forever" },
];

// Single web source for the poll default, pinned to
// EmailPollRule.defaultPollIntervalSeconds
// (Sources/RuneWeaverCore/Scheduler.swift). Used for display placeholders
// only; create/update payloads omit an empty interval so the server default
// applies, keeping both sides pinned without silent resets.
export const DEFAULT_POLL_INTERVAL_SECONDS = 300;

export interface HealthResponse {
  status: string;
  engine: string;
  version: string;
  model?: string;
  contextLength?: number;
}

export interface ToolResult {
  toolCallID: string;
  content: string;
  isError: boolean;
}

export interface ToolAction {
  toolName: string;
  callID: string;
  argumentsJSON: string;
  result?: ToolResult | null;
}

export interface OrchestratorResponse {
  text: string;
  sessionID: string;
  toolActions: ToolAction[];
  totalTokens?: number | null;
  modelName?: string | null;
  contextLength?: number | null;
  sessionTokens?: number | null;
}

export interface CancelChatResponse {
  sessionID: string;
  cancelled: boolean;
}

export interface ApprovalInput {
  toolName: string;
  argumentsJSON: string;
  callID: string;
}

export interface PermissionRequest {
  id: string;
  toolName: string;
  description: string;
  input: ApprovalInput;
  suggestedDurations: TrustDuration[];
}

export interface ApprovalsResponse {
  approvals: PermissionRequest[];
  count: number;
}

export interface ApprovalDecisionResponse {
  id: string;
  approved: boolean;
  duration: TrustDuration;
}

export interface MemoryResult {
  content: string;
  score: number;
  source: "episodic" | "semantic" | "profile";
  metadata: Record<string, string>;
}

export interface MemorySearchResponse {
  query: string;
  count: number;
  memories: MemoryResult[];
}

export interface UserFact {
  id: string;
  content: string;
  confidence: number;
  source: string;
  lastConfirmed: string;
}

export interface Preference {
  key: string;
  value: string;
  confidence: number;
}

export interface FactsResponse {
  facts: UserFact[];
  preferences: Preference[];
  semanticCount: number;
  episodeCount: number;
}

export interface RunLogEntry {
  id: string;
  jobID?: string | null;
  kind: string;
  status: string;
  message: string;
  timestamp: string;
  response?: string | null;
  toolActions?: ToolAction[];
  totalTokens?: number | null;
  durationMs?: number | null;
}

export interface RunLogsResponse {
  runs: RunLogEntry[];
  count: number;
}

export interface ChatMessage {
  id?: string;
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  toolCallID?: string | null;
  isError?: boolean | null;
  createdAt?: string;
}

export interface ConversationSession {
  id: string;
  title?: string | null;
  messages: ChatMessage[];
  summary?: string | null;
  createdAt: string;
  updatedAt: string;
  source?: string | null;
}

export interface SessionSummary {
  id: string;
  title: string;
  messageCount: number;
  summary?: string | null;
  createdAt: string;
  updatedAt: string;
  source?: string | null;
}

export interface SessionsResponse {
  sessions: SessionSummary[];
  count: number;
}

export interface SessionMessageToolActions {
  messageID: string;
  actions: ToolAction[];
}

export interface SessionToolActionsResponse {
  sessionID: string;
  actions: SessionMessageToolActions[];
  count: number;
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
  createdAt: string;
  updatedAt: string;
}

export interface SchedulerJobsResponse {
  jobs: SchedulerJob[];
  count: number;
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
}

export interface UpdateSchedulerJobInput {
  name?: string;
  schedule?: string;
  prompt?: string;
  enabled?: boolean;
  // Poll clear-vs-omit contract (mirrors UpdateSchedulerJob on the engine):
  // omitted (undefined) leaves the field alone, "" clears that poll string
  // to null (blank → null normalization), and clearPoll clears the whole
  // poll trigger (account, query, mailbox, interval, limit) before applying
  // any sibling poll fields. pollIntervalSeconds and pollLimit have no blank
  // form, so clearing them alone requires clearPoll.
  pollAccount?: string | null;
  pollQuery?: string | null;
  pollMailbox?: string | null;
  pollIntervalSeconds?: number | null;
  pollLimit?: number | null;
  clearPoll?: boolean;
}

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  const hasBody = init?.body != null;
  let response: Response;
  try {
    response = await fetch(path, {
      ...init,
      headers: {
        ...(hasBody ? { "Content-Type": "application/json" } : {}),
        ...(init?.headers ?? {}),
      },
    });
  } catch (error) {
    throw new ApiError(
      error instanceof Error ? error.message : "Network request failed",
      0,
    );
  }
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`.trim();
    try {
      const text = await response.text();
      if (text) {
        // Prefer a structured server reason (Vapor `{"reason": ...}`) over a
        // raw JSON blob so callers surface a human-readable message.
        try {
          const parsed = JSON.parse(text) as unknown;
          const reason =
            typeof parsed === "object" && parsed !== null
              ? (parsed as Record<string, unknown>).reason ??
                (parsed as Record<string, unknown>).message ??
                (parsed as Record<string, unknown>).error
              : undefined;
          detail =
            typeof reason === "string" && reason.trim()
              ? reason.trim().slice(0, 500)
              : text.slice(0, 500);
        } catch {
          detail = text.slice(0, 500);
        }
      }
    } catch {
      // Keep the status fallback when the body is unreadable.
    }
    throw new ApiError(detail || `Request failed: ${path}`, response.status);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  const contentType = response.headers?.get("content-type") ?? "";
  if (contentType && !contentType.includes("application/json")) {
    throw new ApiError(`Expected JSON response: ${path}`, response.status);
  }
  try {
    const data = (await response.json()) as unknown;
    if (data === null || data === undefined) {
      throw new Error("Null response body");
    }
    return data as T;
  } catch (err) {
    throw new ApiError(
      err instanceof ApiError ? err.message : `Invalid JSON response: ${path}`,
      response.status,
    );
  }
}

export function newSessionId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export function getHealth(): Promise<HealthResponse> {
  return fetchJson<HealthResponse>("/health");
}

export function postChat(
  text: string,
  sessionID?: string,
  source = "dashboard",
): Promise<OrchestratorResponse> {
  return fetchJson<OrchestratorResponse>("/chat", {
    method: "POST",
    body: JSON.stringify({ text, sessionID, source }),
  });
}

export function cancelChat(sessionID: string): Promise<CancelChatResponse> {
  return fetchJson<CancelChatResponse>("/chat/cancel", {
    method: "POST",
    body: JSON.stringify({ sessionID }),
  });
}

export function listApprovals(limit?: number): Promise<ApprovalsResponse> {
  const query = limit != null && limit > 0 ? `?limit=${encodeURIComponent(limit)}` : "";
  return fetchJson<ApprovalsResponse>(`/approvals${query}`);
}

export function decideApproval(
  id: string,
  approved: boolean,
  duration: TrustDuration = "thisTime",
): Promise<ApprovalDecisionResponse> {
  return fetchJson<ApprovalDecisionResponse>(
    `/approvals/${encodeURIComponent(id)}/decide`,
    {
      method: "POST",
      body: JSON.stringify({ approved, duration }),
    },
  );
}

export function searchMemory(
  query: string,
  limit = 10,
): Promise<MemorySearchResponse> {
  const params = new URLSearchParams({
    q: query,
    limit: String(limit),
  });
  return fetchJson<MemorySearchResponse>(`/memory/search?${params.toString()}`);
}

export function getFacts(): Promise<FactsResponse> {
  return fetchJson<FactsResponse>("/memory/facts");
}

export function storeFact(
  content: string,
  source = "dashboard",
): Promise<UserFact> {
  return fetchJson<UserFact>("/memory/facts", {
    method: "POST",
    body: JSON.stringify({ content, source }),
  });
}

export async function deleteFact(id: string): Promise<void> {
  await fetchJson<void>(`/memory/facts/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function listRuns(limit = 50, jobID?: string): Promise<RunLogsResponse> {
  const params = new URLSearchParams({ limit: String(limit) });
  if (jobID) params.set("jobID", jobID);
  return fetchJson<RunLogsResponse>(`/runs?${params.toString()}`);
}

export function getRun(id: string): Promise<RunLogEntry> {
  return fetchJson<RunLogEntry>(`/runs/${encodeURIComponent(id)}`);
}

export function listSessions(): Promise<SessionsResponse> {
  return fetchJson<SessionsResponse>("/sessions");
}

export function getSession(id: string): Promise<ConversationSession> {
  return fetchJson<ConversationSession>(`/sessions/${encodeURIComponent(id)}`);
}

export function getSessionToolActions(
  id: string,
): Promise<SessionToolActionsResponse> {
  return fetchJson<SessionToolActionsResponse>(
    `/sessions/${encodeURIComponent(id)}/tool-actions`,
  );
}

export function updateSessionTitle(id: string, title: string): Promise<void> {
  return fetchJson<void>(`/sessions/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify({ title }),
  });
}

export function deleteSession(id: string): Promise<void> {
  return fetchJson<void>(`/sessions/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function listJobs(limit?: number): Promise<SchedulerJobsResponse> {
  const query = limit != null && limit > 0 ? `?limit=${encodeURIComponent(limit)}` : "";
  return fetchJson<SchedulerJobsResponse>(`/scheduler/jobs${query}`);
}

export function getJob(id: string): Promise<SchedulerJob> {
  return fetchJson<SchedulerJob>(`/scheduler/jobs/${encodeURIComponent(id)}`);
}

export function createJob(input: NewSchedulerJobInput): Promise<SchedulerJob> {
  return fetchJson<SchedulerJob>("/scheduler/jobs", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

export function updateJob(
  id: string,
  input: UpdateSchedulerJobInput,
): Promise<SchedulerJob> {
  return fetchJson<SchedulerJob>(`/scheduler/jobs/${encodeURIComponent(id)}`, {
    method: "PUT",
    body: JSON.stringify(input),
  });
}

export async function deleteJob(id: string): Promise<void> {
  await fetchJson<void>(`/scheduler/jobs/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function runJobNow(id: string): Promise<OrchestratorResponse> {
  return fetchJson<OrchestratorResponse>(
    `/scheduler/jobs/${encodeURIComponent(id)}/run`,
    { method: "POST", body: JSON.stringify({}) },
  );
}
