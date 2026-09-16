// Typed client for the engine JSON API.

import { isRecord } from "./typeGuards";

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

// Single web source for the poll default, pinned to EmailPollRule.defaultPollIntervalSeconds
// (Sources/RuneWeaverCore/Scheduler.swift).
export const DEFAULT_POLL_INTERVAL_SECONDS = 300;

export interface HealthResponse {
  status: string;
  engine: string;
  version: string;
  model?: string;
  provider?: string;
  contextLength?: number;
  // Search health rides along so the profile menu can render the SearXNG dot without a second round
  // trip. Optional because older engines predate the search service; absent means unknown and
  // renders as Unknown (gray), never as Stopped.
  searchReachable?: boolean;
  searchURL?: string;
  searchStatus?: string;
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
  // Per-turn parked flag mirroring the engine response: true when the turn
  // filed gated approvals and waits on the inbox. Optional for back-compat
  // with older engines; absent or null decodes to not parked.
  isParked?: boolean | null;
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
  // Owning session when the engine tags the prompt; absent on older
  // payloads, so session filtering must treat it as unattributed rather
  // than guessing an owner.
  sessionID?: string | null;
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
  // Owning chat session when the run came from an interactive turn;
  // absent on older payloads, so callers must handle unattributed runs.
  sessionID?: string | null;
  kind: string;
  status: string;
  message: string;
  timestamp: string | number;
  response?: string | null;
  toolActions?: ToolAction[];
  totalTokens?: number | null;
  durationMs?: number | null;
}

// Parses a run timestamp from the engine wire shape into a Date. The engine persists run times as
// Unix seconds (REAL seconds since 1970 in SQLite, encoded as JSON numbers) while older payloads
// carry ISO-8601 strings; very old numeric payloads may carry Unix milliseconds.
export function parseRunTimestamp(value: string | number | undefined | null): Date {
  if (value == null) return new Date(0);
  if (typeof value === "number") {
    // Non-finite and non-positive numbers predate any real run.
    if (!Number.isFinite(value) || value <= 0) return new Date(0);
    // Unix milliseconds versus Unix seconds by magnitude.
    if (value > 1e12) return new Date(value);
    return new Date(value * 1000);
  }
  const trimmed = value.trim();
  if (trimmed === "") return new Date(0);
  const numeric = Number(trimmed);
  // Pure numeric strings (including negatives and exponents) follow the
  // numeric path so "-5" normalizes to the epoch instead of mis-parsing as
  // a date; ISO strings fall through to Date parsing below.
  if (!Number.isNaN(numeric) && /^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(trimmed)) {
    return parseRunTimestamp(numeric);
  }
  const parsed = new Date(trimmed);
  if (Number.isNaN(parsed.getTime())) return new Date(0);
  return parsed;
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
  // Poll clear-vs-omit contract (mirrors UpdateSchedulerJob on the engine): omitted (undefined)
  // leaves the field alone, "" clears that poll string to null (blank → null normalization), and
  // clearPoll clears the whole poll trigger (account, query, mailbox, interval, limit) before...
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

// Validates an orchestrator turn before it enters chat state: the engine always emits text,
// session, and tool actions together, so a partial object must never render as a completed reply.
// The parked flag stays optional for back-compat and defaults to not parked when absent.
function isOrchestratorResponse(value: unknown): value is OrchestratorResponse {
  if (!isRecord(value)) return false;
  if (typeof value.text !== "string") return false;
  if (typeof value.sessionID !== "string") return false;
  if (!Array.isArray(value.toolActions)) return false;
  const parked = value.isParked;
  return parked === undefined || parked === null || typeof parked === "boolean";
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
          const parsed: unknown = JSON.parse(text);
          // Guard with a record check so arrays and primitives cannot leak
          // indexed fields into the error detail.
          const record = isRecord(parsed) ? parsed : null;
          const reason =
            record != null
              ? (record.reason ?? record.message ?? record.error)
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
    const data: unknown = await response.json();
    if (data === null || data === undefined) {
      throw new Error("Null response body");
    }
    // Reject malformed engine payloads before they enter typed state:
    // primitives and arrays cannot satisfy any dashboard response shape.
    if (!isRecord(data)) {
      throw new Error("Non-record response body");
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
  }).then((response) => {
    // Validate required turn fields before typed state so a malformed engine
    // payload surfaces as an error instead of rendering a partial reply.
    if (!isOrchestratorResponse(response)) {
      throw new ApiError("Invalid chat response", 0);
    }
    return response;
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

export function deleteFact(id: string): Promise<void> {
  return fetchJson<void>(`/memory/facts/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function listRuns(limit = 50, jobID?: string, sessionID?: string): Promise<RunLogsResponse> {
  const params = new URLSearchParams({ limit: String(limit) });
  if (jobID) params.set("jobID", jobID);
  if (sessionID) params.set("sessionID", sessionID);
  return fetchJson<RunLogsResponse>(`/runs?${params.toString()}`);
}

export function getRun(id: string): Promise<RunLogEntry> {
  return fetchJson<RunLogEntry>(`/runs/${encodeURIComponent(id)}`);
}

export function clearRuns(): Promise<void> {
  return fetchJson<void>("/runs", {
    method: "DELETE",
  });
}

export function deleteRun(id: string): Promise<void> {
  return fetchJson<void>(`/runs/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
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

export function deleteJob(id: string): Promise<void> {
  return fetchJson<void>(`/scheduler/jobs/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function runJobNow(id: string): Promise<OrchestratorResponse> {
  return fetchJson<OrchestratorResponse>(
    `/scheduler/jobs/${encodeURIComponent(id)}/run`,
    { method: "POST", body: JSON.stringify({}) },
  ).then((response) => {
    // Same turn contract as interactive chat: reject partial payloads before
    // run history renders them as completed executions.
    if (!isOrchestratorResponse(response)) {
      throw new ApiError("Invalid job run response", 0);
    }
    return response;
  });
}

export interface ProviderConfigData {
  enabled: boolean;
  model?: string;
  server_url?: string;
  serverURL?: string;
  api_key_env?: string;
  apiKeyEnv?: string;
  provider_type?: string;
  providerType?: string;
  api_style?: string;
  apiStyle?: string;
  context_length?: number;
  contextLength?: number;
}

export interface EmailAccountData {
  name: string;
  type: string;
  host: string;
  port: number;
  username: string;
  // Optional SMTP overrides persisted as smtp_host/smtp_port/smtp_security.
  // Camel-case aliases mirror the provider pattern so older dashboards keep
  // round-tripping without dropping overrides.
  smtp_host?: string;
  smtpHost?: string;
  smtp_port?: number;
  smtpPort?: number;
  smtp_security?: string;
  smtpSecurity?: string;
}

export interface SettingsResponse {
  engineName: string;
  logLevel: string;
  defaultProvider: string;
  fallbackProvider?: string;
  providers: Record<string, ProviderConfigData>;
  memoryVectorDBPath: string;
  memoryEpisodesDBPath: string;
  memoryEmbeddingModel: string;
  memoryEmbeddingBackend: string;
  voiceSTTProvider: string;
  voiceWhisperModel: string;
  voiceTTSProvider: string;
  // Tier-3 detonation policy persisted under [sandbox]: ephemeral microVMs with immediate reap; the
  // TTL reclaims only crash orphans and the cap gates concurrent detonations. The runtime stays
  // pinned to the Apple Container CLI server-side with no dashboard knob.
  sandboxContainerBaseImage?: string;
  sandboxArchiveSessionTTLMinutes?: number;
  sandboxMaxConcurrentMachines?: number;
  // File access policy persisted under [files]; optional for back-compat
  // with older engines that predate the deny list.
  filesDenyPatterns?: string[];
  filesAllowRoots?: string[];
  filesRequireApprovalOnDeny?: boolean;
  // Web search policy persisted under [browser] (searxng_url, timeout, max_results). The engine
  // encodes both the canonical `browser*` keys and the `search*` aliases with identical values so
  // either contract reads without falling back to defaults; older engines may carry only `browser*`.
  browserSearxngURL?: string;
  browserSearchTimeoutSeconds?: number;
  browserMaxResults?: number;
  searchSearxngURL?: string;
  searchTimeoutSeconds?: number;
  searchMaxResults?: number;
  emailAccounts: EmailAccountData[];
  pluginsDir: string;
  pluginsMarketplaceIndexURL: string;
  pluginsAutoRescan: boolean;
  configPath: string;
}

export interface UpdateSettingsInput {
  engineName?: string;
  logLevel?: string;
  defaultProvider?: string;
  fallbackProvider?: string;
  providers?: Record<string, ProviderConfigData>;
  memoryVectorDBPath?: string;
  memoryEpisodesDBPath?: string;
  memoryEmbeddingModel?: string;
  memoryEmbeddingBackend?: string;
  voiceSTTProvider?: string;
  voiceWhisperModel?: string;
  voiceTTSProvider?: string;
  sandboxContainerBaseImage?: string;
  sandboxArchiveSessionTTLMinutes?: number;
  sandboxMaxConcurrentMachines?: number;
  filesDenyPatterns?: string[];
  filesAllowRoots?: string[];
  filesRequireApprovalOnDeny?: boolean;
  // Dual-write both contracts so old and new engines persist the [browser] values tools dial.
  browserSearxngURL?: string;
  browserSearchTimeoutSeconds?: number;
  browserMaxResults?: number;
  searchSearxngURL?: string;
  searchTimeoutSeconds?: number;
  searchMaxResults?: number;
  emailAccounts?: EmailAccountData[];
  pluginsDir?: string;
  pluginsMarketplaceIndexURL?: string;
  pluginsAutoRescan?: boolean;
}

// Manual mirror of FilesConfig.defaultDenyPatterns in Sources/RuneWeaverCore/Config.swift.
export const DEFAULT_FILES_DENY_PATTERNS: string[] = [
  ".env*",
  ".netrc",
  "secrets.json",
  "config.toml",
  "*.pem",
  "*.key",
  "*keychain*",
  ".ssh/*",
  ".aws/*",
  ".runeweaver/memory/vectors/*",
];

// Manual mirror of FilesConfig.defaultAllowRoots (`~` = home); update by
// hand alongside the Swift default.
export const DEFAULT_FILES_ALLOW_ROOTS: string[] = ["~"];

// Textarea mirror of the deny defaults so the blocked-paths editor starts from the same guard
// boundary without joining inline in every caller.
export const DEFAULT_FILES_DENY_PATTERNS_TEXT: string =
  DEFAULT_FILES_DENY_PATTERNS.join("\n");

// Parses the blocked-paths textarea into the wire shape: one glob per line, trimmed, with blank
// lines dropped. Blank filtering keeps an emptied editor as an explicit allow-all instead of
// persisting whitespace-only rows, and the server-side guard remains the authoritative enforcer.
export function parseDenyPatternsText(text: string | undefined | null): string[] {
  if (text == null) return [...DEFAULT_FILES_DENY_PATTERNS];
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

// Formats a deny array for the multiline editor, falling back to the guard defaults when an older
// engine omits the [files] section entirely. Callers use this for initial display and reset so
// textarea and array states never diverge on the default boundary.
export function formatDenyPatternsText(
  patterns: string[] | undefined | null
): string {
  if (!Array.isArray(patterns)) return DEFAULT_FILES_DENY_PATTERNS_TEXT;
  return patterns.join("\n");
}

// Manual mirrors of SandboxConfig Tier-3 defaults in Sources/RuneWeaverCore/Config.swift.
export const DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE = "alpine:latest";
export const DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES = 10;
export const DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES = 3;

// Manual mirrors of the [browser] defaults (searxng_url, timeout, max_results) pinned to
// BrowserConfig in Sources/RuneWeaverCore/Config.swift (defaultSearxngURL, defaultMaxResults),
// Config/config.toml.example, and CONFIG.md.
export const DEFAULT_SEARCH_SEARXNG_URL = "http://127.0.0.1:8888";
export const DEFAULT_SEARCH_TIMEOUT_SECONDS = 10;
export const DEFAULT_SEARCH_MAX_RESULTS = 10;

export function getSettings(): Promise<SettingsResponse> {
  return fetchJson<SettingsResponse>("/settings");
}

export function updateSettings(
  input: UpdateSettingsInput,
): Promise<SettingsResponse> {
  return fetchJson<SettingsResponse>("/settings", {
    method: "PUT",
    body: JSON.stringify(input),
  });
}

// Web search (SearXNG) lifecycle surfaced by the engine service. The service
// runs SearXNG in an Apple Container machine with no Docker dependency, so
// these routes start and stop that machine rather than proxying queries.
// The ensure path carries the last cascade failure detail (stage, exit,
// capped tail, timeout) in `message` when unreachable so callers render why
// the heal stopped instead of flipping silently.
export interface SearchHealthResponse {
  reachable: boolean;
  url?: string;
  baseURL?: string;
  status?: string | null;
  containerName?: string | null;
  started?: boolean | null;
  stopped?: boolean | null;
  message?: string | null;
}

// Resolves the display URL across the dual `url`/`baseURL` contract so custom
// ports survive regardless of which key the engine encoded.
export function resolveSearchURL(
  response: SearchHealthResponse | null | undefined,
  fallback: string,
): string {
  if (!response) return fallback;
  const candidate =
    (typeof response.url === "string" && response.url.trim()) ||
    (typeof response.baseURL === "string" && response.baseURL.trim()) ||
    "";
  return candidate || fallback;
}

// Single-sourced cascade-detail extraction for the search lifecycle: trims the
// engine `message` (stage, exit, capped tail, timeout) and normalizes blank or
// non-string payloads to null so callers never render whitespace as detail.
export function resolveSearchMessage(
  response: SearchHealthResponse | null | undefined,
): string | null {
  const message = response?.message;
  return typeof message === "string" && message.trim() ? message.trim() : null;
}

// Reads live SearXNG reachability without touching settings: the profile
// menu dot and the Settings search pane both poll this so Start and Stop
// stay honest about the container state.
export function getSearchHealth(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/health");
}

// Starts the SearXNG container (pulls the image on first run) and reports
// the resulting health. Idempotent when already running.
export function ensureSearch(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/ensure", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Stops the SearXNG container and reports the resulting health. Idempotent
// when already stopped.
export function stopSearch(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/stop", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

export interface ToolInfo {
  name: string;
  description: string;
  permissionLevel: string;
  inputSchema: string;
  isEnabled: boolean;
  isBuiltIn: boolean;
  pluginID?: string | null;
  source: string;
  integrityStatus: string;
}

export interface ToolsResponse {
  tools: ToolInfo[];
}

export function getTools(): Promise<ToolsResponse> {
  return fetchJson<ToolsResponse>("/tools");
}

// Toggles one registered tool without touching siblings: the engine persists the flag before
// mutating the live bus, so a builtin and a plugin tool with similar prefixes never share fate and
// per-tool granularity (email.read vs email.attachment) stays intact across restarts.
export function updateToolState(name: string, enabled: boolean): Promise<ToolInfo> {
  return fetchJson<ToolInfo>(`/tools/${encodeURIComponent(name)}/state`, {
    method: "POST",
    body: JSON.stringify({ enabled }),
  });
}

export interface PluginSummary {
  id: string;
  name: string;
  version: string;
  author?: string | null;
  description: string;
  runtime: string;
  source: string;
  status: "discovered" | "enabled" | "disabled" | "tampered";
  isEnabled: boolean;
  integrityHash?: string | null;
  tools: ToolInfo[];
  permissionOverrides: Record<string, string>;
  discoveredAt: string;
  updatedAt: string;
}

export interface PluginsResponse {
  plugins: PluginSummary[];
}

export interface UpdatePluginStateRequest {
  action: "enable" | "disable" | "override_permission" | "clear_override";
  toolName?: string;
  permissionLevel?: "readOnly" | "requiresApproval";
}

export interface MarketplacePluginItem {
  id: string;
  name: string;
  version: string;
  author: string;
  description: string;
  downloadURL: string;
  tags: string[];
  runtime: string;
  declaredTools: string[];
  isInstalled: boolean;
}

export interface MarketplaceResponse {
  items: MarketplacePluginItem[];
}

export interface InstallMarketplacePluginRequest {
  id: string;
  // Optional display provenance carried alongside the install.
  downloadURL?: string;
}

export function getPlugins(): Promise<PluginsResponse> {
  return fetchJson<PluginsResponse>("/plugins");
}

export function getPlugin(id: string): Promise<PluginSummary> {
  return fetchJson<PluginSummary>(`/plugins/${encodeURIComponent(id)}`);
}

export function rescanPlugins(): Promise<PluginsResponse> {
  return fetchJson<PluginsResponse>("/plugins/rescan", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

export function updatePluginState(
  id: string,
  request: UpdatePluginStateRequest,
): Promise<PluginSummary> {
  return fetchJson<PluginSummary>(`/plugins/${encodeURIComponent(id)}/state`, {
    method: "POST",
    body: JSON.stringify(request),
  });
}

export function uninstallPlugin(id: string): Promise<void> {
  return fetchJson<void>(`/plugins/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function getMarketplacePlugins(): Promise<MarketplaceResponse> {
  return fetchJson<MarketplaceResponse>("/marketplace/plugins");
}

export function installMarketplacePlugin(
  request: InstallMarketplacePluginRequest,
): Promise<PluginSummary> {
  return fetchJson<PluginSummary>("/marketplace/install", {
    method: "POST",
    body: JSON.stringify(request),
  });
}

