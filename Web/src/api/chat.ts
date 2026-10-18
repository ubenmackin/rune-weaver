// Rune Weaver Dashboard — Chat message models, turn validation, and chat API.
import { fetchJson } from "./http";
import { ApiError } from "./http";
import { isRecord } from "../typeGuards";
import { sanitizeWarnings } from "../warnings";
import type {
  ToolAction,
  OrchestratorResponse,
  CancelChatResponse,
} from "./types";
import { parseRecallDiagnostics } from "./types";

export interface PlaceholderCall {
  toolName: string;
  argumentsJSON: string;
  callID: string;
}

// Trims only spaces and tabs, mirroring the engine remainder/argument trim (`.whitespaces`) rather
// than the full Unicode trim used for outer lines and identifiers.
function trimPlaceholderSpaces(value: string): string {
  return value.replace(/^[ \t]+|[ \t]+$/g, "");
}

// Parses persisted placeholder lines mirroring `ToolInput.parsePlaceholderLine`: validates
// `Calling <tool> <args> [callID]`, normalizes empty args to "{}", and returns null on invalid
// or drifted shapes so callers never treat stray text as tool frames.
export function parsePlaceholderLine(line: string): PlaceholderCall | null {
  if (typeof line !== "string") return null;
  const trimmed = line.trim();
  const prefix = "Calling ";
  if (!trimmed.startsWith(prefix)) return null;
  if (!trimmed.endsWith("]")) return null;
  const bracketStart = trimmed.lastIndexOf("[");
  if (bracketStart === -1) return null;
  if (!(bracketStart > prefix.length)) return null;
  const beforeBracket = trimmed[bracketStart - 1];
  if (beforeBracket !== " " && beforeBracket !== "\t") return null;
  const afterBracket = bracketStart + 1;
  const endIndex = trimmed.length - 1;
  if (!(afterBracket <= endIndex)) return null;
  const callID = trimmed.slice(afterBracket, endIndex).trim();
  if (!callID) return null;
  if (/[ \t[\]]/.test(callID)) return null;
  const remainderStart = prefix.length;
  const remainderEnd = bracketStart - 1;
  if (!(remainderStart < remainderEnd)) return null;
  const remainder = trimPlaceholderSpaces(
    trimmed.slice(remainderStart, remainderEnd),
  );
  if (!remainder) return null;
  const firstSpace = remainder.search(/[ \t]/);
  if (firstSpace !== -1) {
    const name = remainder.slice(0, firstSpace);
    const args = trimPlaceholderSpaces(remainder.slice(firstSpace + 1));
    if (!name || /[ \t]/.test(name)) return null;
    return { toolName: name, argumentsJSON: args ? args : "{}", callID };
  }
  if (/[ \t]/.test(remainder)) return null;
  return { toolName: remainder, argumentsJSON: "{}", callID };
}

// Extracts the call identifier from one persisted placeholder line, mirroring
// the engine placeholder grammar. Returns null for prose, code, or drifted
// shapes so callers never treat a passing mention as an execution record.
export function parsePlaceholderCallID(line: string): string | null {
  const parsed = parsePlaceholderLine(line);
  return parsed ? parsed.callID : null;
}

// Shared wire-grammar vectors pinning the engine and dashboard parsers to one shape.
export const PLACEHOLDER_GRAMMAR_VECTORS: Array<{
  line: string;
  expected: PlaceholderCall | null;
}> = [
  {
    line: 'Calling email.search {"limit":1} [call_1]',
    expected: {
      toolName: "email.search",
      argumentsJSON: '{"limit":1}',
      callID: "call_1",
    },
  },
  {
    line: "Calling email.search [call_2]",
    expected: { toolName: "email.search", argumentsJSON: "{}", callID: "call_2" },
  },
  {
    line: "  Calling email.search {} [call_3]  ",
    expected: {
      toolName: "email.search",
      argumentsJSON: "{}",
      callID: "call_3",
    },
  },
  {
    line: "Calling email.search  [call_4]",
    expected: { toolName: "email.search", argumentsJSON: "{}", callID: "call_4" },
  },
  {
    line: "Calling  email.search {} [call_5]",
    expected: {
      toolName: "email.search",
      argumentsJSON: "{}",
      callID: "call_5",
    },
  },
  {
    line: "Calling web.search query/with/slashes [call_6]",
    expected: {
      toolName: "web.search",
      argumentsJSON: "query/with/slashes",
      callID: "call_6",
    },
  },
  {
    line: "Calling web.fetch {\"url\":\"https://example.com/a/b\"} [call_7]",
    expected: {
      toolName: "web.fetch",
      argumentsJSON: '{"url":"https://example.com/a/b"}',
      callID: "call_7",
    },
  },
  {
    line: "Calling tool arg [inner] [call_8]",
    expected: {
      toolName: "tool",
      argumentsJSON: "arg [inner]",
      callID: "call_8",
    },
  },
  {
    line: "Calling tool args [  call_9  ]",
    expected: { toolName: "tool", argumentsJSON: "args", callID: "call_9" },
  },
  {
    line: "Calling tool args   [call_10]   ",
    expected: { toolName: "tool", argumentsJSON: "args", callID: "call_10" },
  },
  { line: "You mentioned [call_1] in prose", expected: null },
  { line: "Calling email.search [bad id]", expected: null },
  { line: "Calling tool[x]", expected: null },
  { line: "Not a placeholder [call_1]", expected: null },
  { line: "", expected: null },
];

// Folds CRLF and legacy CR line endings to LF so placeholder coverage matches the engine,
// which strips those shapes before comparing plumbing lines. Single source for every
// placeholder and history path so carriage returns never hide a covered line.
export function normalizeLineEndings(text: string): string {
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

// Collects every placeholder identifier carried in a block of text, one parse
// per line so callers test membership instead of scanning per identifier.
export function placeholderCallIDsInText(text: string): Set<string> {
  const ids = new Set<string>();
  if (typeof text !== "string" || text.length === 0) return ids;
  const normalized = normalizeLineEndings(text);
  for (const rawLine of normalized.split("\n")) {
    const parsed = parsePlaceholderCallID(rawLine);
    if (parsed) ids.add(parsed);
  }
  return ids;
}

// Reports whether a block of text carries the placeholder line for one call,
// identified by the parsed line shape rather than a substring of the bracketed
// token.
export function textContainsPlaceholderForCall(
  text: string,
  callID: string,
): boolean {
  if (typeof text !== "string" || typeof callID !== "string" || !callID)
    return false;
  const trimmedCallID = callID.trim();
  // Same identifier bar as the engine parser (space/tab/bracket): a drifted
  // identifier never matches a parsed line, so mention-only prose stays visible.
  if (!trimmedCallID || /[ \t[\]]/.test(trimmedCallID)) return false;
  const normalized = normalizeLineEndings(text);
  for (const rawLine of normalized.split("\n")) {
    if (parsePlaceholderCallID(rawLine) === trimmedCallID) return true;
  }
  return false;
}

export interface ChatMessage {
  id?: string;
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  reasoning?: string | null;
  toolCallID?: string | null;
  isError?: boolean | null;
  // Creation time in either wire shape the engine emits: ISO-8601 strings from the Vapor API versus
  // Unix seconds as JSON numbers from SQLite persistence.
  createdAt?: string | number;
}

export interface ConversationSession {
  id: string;
  title?: string | null;
  messages: ChatMessage[];
  summary?: string | null;
  createdAt: string;
  updatedAt: string;
  source?: string | null;
  // Session that spawned this one (a fan-out worker's origin).
  parentSessionID?: string | null;
  // Linked goal when this session pursues a tracked one.
  goalId?: string | null;
}

export interface SessionSummary {
  id: string;
  title: string;
  messageCount: number;
  summary?: string | null;
  createdAt: string;
  updatedAt: string;
  source?: string | null;
  // Session that spawned this one, carried on the listing payload so the
  // sidebar can nest fan-out workers under their origin without a second
  // fetch. Absent on top-level sessions and older payloads.
  parentSessionID?: string | null;
  // Linked goal when this session pursues a tracked one, carried on the listing
  // payload so clients resolve a session-to-goal badge without querying run
  // history. Absent on unlinked sessions and older payloads.
  goalId?: string | null;
  isArchived?: boolean;
}

export interface SessionsResponse {
  sessions: SessionSummary[];
  count: number;
}

export interface SessionMessageToolActions {
  messageID: string;
  actions: ToolAction[];
  // Parent message completion time on the server clock, mirroring the persisted
  // ChatMessage.createdAt for the same note.
  completedAt?: string | number | null;
}

export interface SessionToolActionsResponse {
  sessionID: string;
  actions: SessionMessageToolActions[];
  count: number;
}

export function isOrchestratorResponse(value: unknown): value is OrchestratorResponse {
  if (!isRecord(value)) return false;
  if (typeof value.text !== "string") return false;
  if (typeof value.sessionID !== "string") return false;
  if (!Array.isArray(value.toolActions)) return false;
  const parked = value.isParked;
  if (parked !== undefined && parked !== null && typeof parked !== "boolean") return false;
  // Probe the shared sanitizer so malformed shapes degrade to absent without a second inline
  // validator drifting from the banner path; any result still validates the turn.
  sanitizeWarnings(value.warnings);
  // Probe the shared recall parser so a drifted diagnostics block degrades to
  // absent without failing an otherwise complete turn.
  parseRecallDiagnostics(value.recallDiagnostics);
  return true;
}

// Validates one orchestrator turn before it enters typed state so a malformed engine payload
// surfaces as an error instead of rendering a partial reply.
export function validateTurnResponse(
  response: unknown,
  invalidMessage: string,
): OrchestratorResponse {
  if (!isOrchestratorResponse(response)) {
    throw new ApiError(invalidMessage, 0);
  }
  if (response.warnings !== undefined && response.warnings !== null) {
    response.warnings = sanitizeWarnings(response.warnings);
  }
  if (response.recallDiagnostics !== undefined && response.recallDiagnostics !== null) {
    const parsed = parseRecallDiagnostics(response.recallDiagnostics);
    response.recallDiagnostics = parsed;
  }
  return response;
}


export function postChat(
  text: string,
  sessionID?: string,
  source = "dashboard",
): Promise<OrchestratorResponse> {
  return fetchJson<OrchestratorResponse>("/chat", {
    method: "POST",
    body: JSON.stringify({ text, sessionID, source }),
  }).then((response) => validateTurnResponse(response, "Invalid chat response"));
}

export function cancelChat(sessionID: string): Promise<CancelChatResponse> {
  return fetchJson<CancelChatResponse>("/chat/cancel", {
    method: "POST",
    body: JSON.stringify({ sessionID }),
  });
}

export interface ToolCancelResponse {
  sessionID: string;
  callID: string;
  cancelled: boolean;
}

// Cancels one tool call by identity, distinct from the session-wide turn cancel above: a turn
// cancel aborts the whole reply while this stops a single long-running execution and lets the model
// reason about the partial result.
export function toolCancel(
  sessionID: string,
  callID: string,
  reason?: string,
): Promise<ToolCancelResponse> {
  const trimmedReason = reason?.trim();
  return fetchJson<ToolCancelResponse>("/chat/tool_cancel", {
    method: "POST",
    body: JSON.stringify({
      sessionID,
      callID,
      ...(trimmedReason ? { reason: trimmedReason } : {}),
    }),
  });
}

export function listSessions(includeArchived = false): Promise<SessionsResponse> {
  const query = includeArchived ? "?include_archived=true" : "";
  return fetchJson<SessionsResponse>(`/sessions${query}`);
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

export interface LiveTurnResponse {
  active: boolean;
  isRunning?: boolean;
  sessionID: string;
  text: string;
  reasoning: string;
  toolActions: ToolAction[];
  totalTokens?: number | null;
  warnings: string[];
  startedAt?: number | null;
}

export function getLiveTurn(id: string): Promise<LiveTurnResponse> {
  return fetchJson<LiveTurnResponse>(
    `/sessions/${encodeURIComponent(id)}/live-turn`,
  );
}

export function updateSessionTitle(id: string, title: string): Promise<void> {
  return fetchJson<void>(`/sessions/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify({ title }),
  });
}

export function archiveSession(id: string): Promise<void> {
  return fetchJson<void>(`/sessions/${encodeURIComponent(id)}/archive`, {
    method: "POST",
  });
}

export function unarchiveSession(id: string): Promise<void> {
  return fetchJson<void>(`/sessions/${encodeURIComponent(id)}/unarchive`, {
    method: "POST",
  });
}

export function deleteSession(id: string): Promise<void> {
  return fetchJson<void>(`/sessions/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

