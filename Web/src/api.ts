// Typed client for the engine JSON API.

import { isRecord } from "./typeGuards";
import { sanitizeWarnings } from "./warnings";

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
  // Live Start stage plus Start time while an ensure flight runs (resolving, daemon, pulling,
  // starting, waiting). Optional because older engines predate staged progress and because the
  // keys are absent when idle; absent means no Start is in flight.
  searchStage?: string | null;
  searchStartedAt?: number | null;
  // Authoritative turn cap advertised by the engine on GET /health. Optional because older
  // engines predate the advertisement and because getHealth injects it from the response
  // header when the JSON body carries none; absent degrades to MAX_CONCURRENT_CHAT_TURNS.
  maxConcurrentChatTurns?: number | null;
}

export type ToolErrorKind = "invalid_tool" | "invalid_syntax" | "execution_error";

export interface ToolResult {
  toolCallID: string;
  content: string;
  isError: boolean;
  errorKind?: ToolErrorKind | null;
}

export interface ToolAction {
  toolName: string;
  callID: string;
  argumentsJSON: string;
  result?: ToolResult | null;
  // Zero-based LLM round that produced this call, oldest first. Optional because
  // older engines predate round tracking; absent means unordered and callers fall
  // back to stored order, which remains chronological.
  roundIndex?: number | null;
}

// Ordered timeline pieces for one assistant turn. Text and tool batches alternate
// chronologically (text, tools, text, tools, text) so multi-round turns never
// collapse into a single lumped bucket. The flat `text`/`toolActions` on message
// state stay as back-compat summaries while rendering walks this list in order.
export type ChatTextSegment = { kind: "text"; text: string };
export type ChatToolsSegment = { kind: "tools"; actions: ToolAction[] };
export type ChatSegment = ChatTextSegment | ChatToolsSegment;

// Normalizes a round hint to a comparable index: finite numbers floor to an
// integer round, while absent or drifted shapes degrade to undefined so ordering
// falls back to stored order instead of dropping the action.
export function normalizeRoundIndex(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
    return undefined;
  return Math.floor(value);
}

// Single non-negative integer contract shared by live token frames, terminal
// counters, and cached bases so a fractional or negative payload degrades to
// absent instead of rendering a floored value on one path and rejecting on
// another. Mirrors the engine decoder so footers and persistence agree.
export function toNonNegativeInt(value: unknown): number | undefined {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    Number.isInteger(value) &&
    value >= 0
    ? value
    : undefined;
}

// Live progress for one executing tool, mirrored from the engine's throttled
// `tool_progress` frame. Counters are monotonic while a call runs and `current`
// is relative-only on purpose: the engine never streams absolute machine paths,
// so the dashboard can show activity without exposing the local filesystem.
export interface ToolProgress {
  callID: string;
  toolName: string;
  // Human scope copy the engine composes (for example "Find *.txt in ~"). The
  // broad-scope warning travels on its own `warning` field rather than folded
  // into this line, so a pattern containing an em-dash is never misread as a
  // scope-plus-warning pair.
  message: string;
  // Advisory broad-scope warning for `message`, when the engine supplies one.
  // Optional and nullable so older frames and narrow scans degrade to no
  // warning instead of rendering an empty span.
  warning?: string | null;
  scanned: number;
  matched: number;
  elapsedMs: number;
  // Relative path of the item currently being examined; absent when the engine
  // has no meaningful tail to report.
  current?: string | null;
}

// Longest relative tail retained for display, pinned to the engine's
// ToolProgress.maxCurrentLength (Sources/RuneWeaverCore/Tool.swift) so a
// handcrafted frame cannot smuggle in a path the engine would have shortened.
const MAX_TOOL_PROGRESS_CURRENT_LENGTH = 240;

// Normalizes a progress tail the same way the engine's ToolProgress.relativeCurrent
// does: trim, drop blank, refuse anything that could disclose an absolute
// location or climb outside its root, then cap for display. The dashboard mirrors
// this instead of trusting the wire as defense-in-depth, so a handcrafted frame
// ("/etc/passwd", "~/.ssh", "../../secret") can never render a filesystem path
// the engine deliberately keeps private.
function relativeProgressCurrent(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  // A leading slash discloses a filesystem root and a leading tilde a home
  // directory, so neither may survive.
  if (trimmed.startsWith("/") || trimmed.startsWith("~")) return null;
  // A traversal segment reveals as much as an absolute path, and resolving it
  // would require a base the reporter intentionally does not know.
  if (trimmed.split("/").includes("..")) return null;
  return trimmed.slice(0, MAX_TOOL_PROGRESS_CURRENT_LENGTH);
}

// Validates one live progress frame before it enters the keyed map. Required
// numeric fields (scanned, matched, elapsedMs) share the engine's non-negative
// integer contract so a drifted or partial payload drops instead of rendering a
// floored or negative tally; the optional relative tail and warning degrade to
// null rather than aborting the update.
export function parseToolProgress(value: unknown): ToolProgress | null {
  if (!isRecord(value)) return null;
  if (typeof value.callID !== "string" || value.callID.trim().length === 0)
    return null;
  if (typeof value.toolName !== "string" || value.toolName.trim().length === 0)
    return null;
  if (typeof value.message !== "string") return null;
  const scanned = toNonNegativeInt(value.scanned);
  const matched = toNonNegativeInt(value.matched);
  const elapsedMs = toNonNegativeInt(value.elapsedMs);
  if (scanned === undefined || matched === undefined || elapsedMs === undefined)
    return null;
  const rawWarning = typeof value.warning === "string" ? value.warning.trim() : "";
  return {
    callID: value.callID,
    toolName: value.toolName,
    message: value.message,
    warning: rawWarning.length > 0 ? rawWarning : null,
    scanned,
    matched,
    elapsedMs,
    current: relativeProgressCurrent(value.current),
  };
}

// Formats the elapsed portion of a progress line. Work under ten seconds keeps
// one decimal so fast scans still look alive, while ten seconds and beyond rounds
// to whole seconds to avoid a jittering tenth that implies false precision.
export function formatToolProgressElapsedMs(elapsedMs: number): string {
  const seconds = Math.max(0, elapsedMs) / 1000;
  const rounded = seconds >= 10 ? Math.round(seconds) : Math.round(seconds * 10) / 10;
  return `${rounded}s`;
}

// Single counts line shared by the live row: "N files checked · M matched · Ss".
// Pluralization keys off the scanned count so a one-file scan reads honestly.
export function formatToolProgressCounts(progress: {
  scanned: number;
  matched: number;
  elapsedMs: number;
}): string {
  const files = `${progress.scanned} file${progress.scanned === 1 ? "" : "s"} checked`;
  return `${files} · ${progress.matched} matched · ${formatToolProgressElapsedMs(
    progress.elapsedMs,
  )}`;
}

// Compares two actions chronologically: numbered rounds ascend oldest-first with
// untracked rounds partitioning after tracked so mixed legacy+tracked history
// holds a total order. Untracked pairs keep stored order through sort stability,
// while tracked rounds always meet numerically even across an untracked gap.
export function compareToolActionsByRound(a: ToolAction, b: ToolAction): number {
  const left = normalizeRoundIndex(a.roundIndex);
  const right = normalizeRoundIndex(b.roundIndex);
  if (left === undefined && right === undefined) return 0;
  if (left === undefined) return 1;
  if (right === undefined) return -1;
  return left - right;
}

// Orders one batch of actions oldest-first without mutating the input, keeping
// tracked rounds numeric and untracked rounds after tracked in stored order so
// reloads match live.
export function sortToolActionsByRound(actions: ToolAction[]): ToolAction[] {
  return [...actions].sort(compareToolActionsByRound);
}

// Groups actions into one tools segment per round, oldest round first. Sorts
// internally to the shared untracked-last order so unsorted callers cannot
// place legacy actions ahead of numbered rounds; the single untracked bucket
// always trails because mixed history renders chronologically only when
// untracked legacy actions stay after tracked rounds.
export function groupToolActionsByRound(actions: ToolAction[]): ToolAction[][] {
  if (actions.length === 0) return [];
  const ordered = sortToolActionsByRound(actions);
  const byRound = new Map<number, ToolAction[]>();
  const untracked: ToolAction[] = [];
  for (const action of ordered) {
    const round = normalizeRoundIndex(action.roundIndex);
    if (round === undefined) {
      untracked.push(action);
      continue;
    }
    const list = byRound.get(round);
    if (list) list.push(action);
    else {
      byRound.set(round, [action]);
    }
  }
  // Numbered rounds sort independently of input order, so a late R0 never
  // renders after R1 just because legacy actions interleaved it.
  const orderedRounds = [...byRound.keys()].sort((a, b) => a - b);
  const groups = orderedRounds.map(
    (round) => byRound.get(round) as ToolAction[],
  );
  // Untracked legacy actions trail every numbered round to match the sorted
  // total order; a missing bucket stays absent rather than emitting empties.
  if (untracked.length > 0) {
    groups.push([...untracked]);
  }
  return groups;
}

export interface OrchestratorResponse {
  text: string;
  sessionID: string;
  toolActions: ToolAction[];
  totalTokens?: number | null;
  modelName?: string | null;
  contextLength?: number | null;
  sessionTokens?: number | null;
  // Active context window tokens used in the latest round (KV cache occupancy).
  contextTokens?: number | null;
  // Per-turn parked flag mirroring the engine response: true when the turn
  // filed gated approvals and waits on the inbox. Optional for back-compat
  // with older engines; absent or null decodes to not parked.
  isParked?: boolean | null;
  // Degraded-tool notices for tools omitted this turn. Optional because older
  // engines predate the resilient filter; absent means no tools were skipped
  // and the turn renders without a banner.
  warnings?: string[];
  // Completion time on the server clock for this turn. Optional because older
  // engines predate completion footers; absent degrades to client receipt time
  // so live turns still show a footer until the server timestamp reconciles.
  // Carries the same dual wire shape as run timestamps (Unix seconds from
  // SQLite persistence versus ISO strings), normalized via parseRunTimestamp.
  completedAt?: string | number | null;
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

// Graduated-trust grant minted from an approval decision: one row per tool-plus-target pair
// that stays auto-approved until revoked or expired. A null expiresAt is the forever tier,
// so the dashboard must render it as never expiring rather than as missing data.
export interface TrustGrant {
  id: string;
  toolName: string;
  target: string;
  // Creation time in either wire shape the engine emits: ISO-8601 strings from older payloads
  // or Unix seconds as JSON numbers from SQLite persistence. Kept as a union so callers
  // normalize through parseRunTimestamp instead of assuming one encoding.
  grantedAt: string | number;
  // Expiry in either wire shape, or null for the forever tier which never expires. Null must
  // survive as "forever" through every UI path rather than collapsing to the epoch.
  expiresAt: string | number | null;
  duration: TrustDuration;
  // Auto-approved hit count so the inbox can distinguish untouched grants from exercised
  // trust without re-deriving it from run history. Zero means the grant never fired. Optional
  // because rows minted before usage tracking omit the key; absent degrades to untouched.
  useCount?: number;
  // Last auto-approved use in either wire shape, or null when the grant never fired. Kept as
  // the same ISO-or-Unix-seconds union as grantedAt/expiresAt so callers normalize through
  // parseRunTimestamp instead of branching on the encoding. Optional because legacy payloads
  // omit the key entirely; absent degrades to untouched like an explicit null.
  lastUsedAt?: string | number | null;
}

export interface TrustGrantsResponse {
  grants: TrustGrant[];
  count: number;
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

// Fallback for how many interactive turns may run at once across sessions. The engine owns the
// authoritative cap (ActiveTurnTracker.maxConcurrentTurns) and advertises it on every GET /health
// probe; the dashboard prefers that server value via resolveMaxConcurrentChatTurns and only uses
// this constant for older engines that predate the advertisement. Kept equal to the engine cap so
// client-side refusal agrees with server enforcement instead of admitting turns the engine would
// immediately reject. Local inference degrades sharply past a couple of concurrent evaluations,
// so the dashboard refuses new sends with an honest busy notice instead of stacking turns that
// would starve each other and look hung.
export const MAX_CONCURRENT_CHAT_TURNS = 3;

// Response header carrying the authoritative turn cap on GET /health, mirroring
// ActiveTurnTracker.turnCapHeaderName on the engine. Read case-insensitively through Headers.get;
// the JSON field stays the shared hand-off so header and future body shapes resolve identically.
export const MAX_CONCURRENT_CHAT_TURNS_HEADER = "x-runeweaver-max-concurrent-turns";

// Validates a server-advertised turn cap into a usable limit: finite numbers at least 1 floor to an
// integer cap, while absent, non-numeric, or non-positive shapes degrade to null so callers fall
// back to MAX_CONCURRENT_CHAT_TURNS instead of admitting unbounded turns or refusing everything.
export function parseMaxConcurrentChatTurns(value: unknown): number | null {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value < 1) return null;
    return Math.floor(value);
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return null;
    const numeric = Number(trimmed);
    if (!Number.isFinite(numeric) || numeric < 1) return null;
    return Math.floor(numeric);
  }
  return null;
}

// Resolves the effective turn cap preferring the server advertisement over the fallback constant:
// a valid health value wins so admit and reject agree on one server-owned number, while absent or
// drifted shapes degrade to the fallback instead of blocking the dashboard against older engines.
export function resolveMaxConcurrentChatTurns(
  health: HealthResponse | null | undefined,
): number {
  const parsed = parseMaxConcurrentChatTurns(health?.maxConcurrentChatTurns);
  return parsed ?? MAX_CONCURRENT_CHAT_TURNS;
}

// Honest busy copy shown when every turn slot is occupied. Shares the engine
// refusal wording so client-side, REST, and socket refusals read as one
// outcome regardless of which layer enforced the cap.
export function concurrentTurnsBusyMessage(limit: number = MAX_CONCURRENT_CHAT_TURNS): string {
  return `Already running ${limit} chat turns — wait for one to finish or cancel it, then retry.`;
}

// Single web source for the chat text bound, pinned to the engine
// ChatRequest.maxTextLength (which delegates to MemoryEngine.maxContentLength).
// Chat input, steering guards, and pre-send checks share this instead of
// mirroring the magic number per call site so client refusal agrees with
// server enforcement instead of drifting when the engine bound moves.
export const MAX_CHAT_TEXT_LENGTH = 10000;

// Single source for run-log polling so live badges and history views agree on
// page size and cadence instead of drifting per call site. The shared
// `useRunningRuns` hook owns the one interval at this cadence for the chat
// view plus the sidebar, so two mounted views never double the run-log QPS;
// live `run_started`/`run_completed` broadcasts stay the immediate path while
// this poll covers reloads, missed sockets, and cross-tab turns.
export const RUN_LOG_POLL_LIMIT = 50;
export const RUN_POLL_INTERVAL_MS = 2500;

// Reports whether a run row represents an in-flight turn that should keep a
// session badge lit. Single active contract shared by live broadcasts and
// polled runs: only `running` counts. Parked `awaiting_approval` turns arrive
// as completed on the hub and surface through the approvals badge, so counting
// them here would double-badge one blocked turn and flicker after reload.
export function isActiveRunStatus(status: string | null | undefined): boolean {
  return status === "running";
}

// Collects the owning sessions behind in-flight runs, normalized for
// case-insensitive comparison since the engine formats UUIDs uppercase while
// the dashboard mints lowercase. Unattributed rows carry no owner and stay out
// so one untagged scheduler run never lights every session. Accepts a frozen
// snapshot because the shared poller hands out read-only rows it never mutates.
export function runningSessionIDsFromRuns(
  runs:
    | ReadonlyArray<Readonly<Pick<RunLogEntry, "status" | "sessionID">>>
    | undefined
    | null,
): string[] {
  if (!Array.isArray(runs)) return [];
  const seen = new Set<string>();
  for (const run of runs) {
    if (!run || !isActiveRunStatus(run.status)) continue;
    const raw = run.sessionID;
    if (typeof raw !== "string" || raw.trim().length === 0) continue;
    seen.add(raw.trim().toLowerCase());
  }
  return [...seen];
}

// Narration placeholder shape persisted by the engine for tool rounds
// ("Calling <tool> <args> [callID]"). Substring checks for "[callID]" elsewhere
// in prose over-match identifiers merely mentioned in passing, so coverage and
// eviction parse the line shape instead of searching for the bracketed token.

// Structured placeholder record mirroring the engine ToolInput triple. The
// arguments keep the engine empty-to-"{}" normalization so coverage and
// history filters agree on which lines count as plumbing even when the model
// narrates a bare tool with no arguments.
export interface PlaceholderCall {
  toolName: string;
  argumentsJSON: string;
  callID: string;
}

// Trims only spaces and tabs, mirroring the engine remainder/argument trim
// (`.whitespaces`) rather than the full Unicode trim used for outer lines and
// identifiers. Wire lines are single-line after ending normalization, so the
// narrower trim keeps engine and dashboard agreement on interior spacing.
function trimPlaceholderSpaces(value: string): string {
  return value.replace(/^[ \t]+|[ \t]+$/g, "");
}

// Parses one persisted placeholder line exactly like the engine
// (`ToolInput.parsePlaceholderLine`): last "[" wins, the char before it must
// be a space or tab, the bracketed identifier trims and must hold no
// space/tab/bracket, and the head splits into tool plus optional arguments
// with empty arguments normalizing to "{}". Returns null for prose, code, or
// drifted shapes so callers never treat a passing mention as an execution
// record. This manual walk is the sole classifier because a greedy capture
// cannot express inside-bracket trimming or the double-space head the engine
// accepts.
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
  if (/[ \t\[\]]/.test(callID)) return null;
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

// Shared wire-grammar vectors pinning the engine and dashboard parsers to one
// shape. Each entry pairs a raw line with its expected triple (or null for
// non-plumbing); the engine doc comment carries the same table so a grammar
// change must update both sides together instead of drifting silently. Cases
// cover the historic divergences: double-space heads, tab separators,
// slash/bracket arguments via last-bracket wins, inside-bracket trimming, and
// trailing-space tolerance.
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
  if (!trimmedCallID || /[ \t\[\]]/.test(trimmedCallID)) return false;
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
  toolCallID?: string | null;
  isError?: boolean | null;
  // Creation time in either wire shape the engine emits: ISO-8601 strings from
  // the Vapor API versus Unix seconds as JSON numbers from SQLite persistence.
  // Kept as a union so callers normalize through parseRunTimestamp instead of
  // assuming one encoding.
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
  // Parent message completion time on the server clock, mirroring the
  // persisted ChatMessage.createdAt for the same note. Optional because older
  // engines predate completion footers; absent degrades to the sibling history
  // timestamp for the same message so reloads still show a footer.
  completedAt?: string | number | null;
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
// Degraded-tool notices stay optional the same way: missing or malformed warnings degrade to
// absent via the shared sanitizer so an older or drifted payload never fails a complete turn.
function isOrchestratorResponse(value: unknown): value is OrchestratorResponse {
  if (!isRecord(value)) return false;
  if (typeof value.text !== "string") return false;
  if (typeof value.sessionID !== "string") return false;
  if (!Array.isArray(value.toolActions)) return false;
  const parked = value.isParked;
  if (parked !== undefined && parked !== null && typeof parked !== "boolean") return false;
  // Probe the shared sanitizer so malformed shapes degrade to absent without a second inline
  // validator drifting from the banner path; any result still validates the turn.
  sanitizeWarnings(value.warnings);
  return true;
}

// Validates one orchestrator turn before it enters typed state so a malformed
// engine payload surfaces as an error instead of rendering a partial reply.
// Warning shapes normalize through the shared sanitizer on the same pass so
// chat and scheduler paths degrade drifted notices to absent identically.
function validateTurnResponse(
  response: unknown,
  invalidMessage: string,
): OrchestratorResponse {
  if (!isOrchestratorResponse(response)) {
    throw new ApiError(invalidMessage, 0);
  }
  if (response.warnings !== undefined && response.warnings !== null) {
    response.warnings = sanitizeWarnings(response.warnings);
  }
  return response;
}

// ---------------------------------------------------------------------------
// Single-owner bearer authentication
// ---------------------------------------------------------------------------

// sessionStorage key naming the single owner-token slot. The engine serves the
// dashboard bundle publicly, so the in-bundle login gate and the running
// authenticated session share this one slot instead of competing stores; the key
// is never written to persistent storage.
export const AUTH_TOKEN_STORAGE_KEY = "runeWeaverToken";

// The live token lives in memory; sessionStorage is a same-tab mirror only.
// Memory is authoritative because every request and socket dial must read the
// credential synchronously, and a storage-only read would leave a window where a
// cleared slot still authenticates. The mirror survives a reload without ever
// writing the credential to persistent storage.
let authToken: string | null = null;

// Whether the in-memory value has been hydrated from the session mirror yet.
let authTokenHydrated = false;

// Listeners awaiting authentication transitions. The boot gate and the shared
// WebSocket subscribe here so a login, logout, rotation, or uniform 401 reaches
// every holder in one pass instead of each polling storage.
type AuthStateListener = (authenticated: boolean) => void;
const authStateListeners = new Set<AuthStateListener>();

// Reads the session mirror, treating an unreadable or blank slot as absent so a
// privacy-mode storage failure degrades to "no token" instead of throwing on
// every request.
function readStoredAuthToken(): string | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.sessionStorage.getItem(AUTH_TOKEN_STORAGE_KEY);
    return raw && raw.trim() ? raw.trim() : null;
  } catch {
    return null;
  }
}

// Mirrors the in-memory token to sessionStorage. A storage failure keeps the
// in-memory credential (the safe direction is to stay authenticated for this
// page) and only forfeits reload recovery.
function writeStoredAuthToken(token: string | null): void {
  if (typeof window === "undefined") return;
  try {
    if (token) {
      window.sessionStorage.setItem(AUTH_TOKEN_STORAGE_KEY, token);
    } else {
      window.sessionStorage.removeItem(AUTH_TOKEN_STORAGE_KEY);
    }
  } catch {
    // Ignore: the in-memory value remains authoritative for this page.
  }
}

// Notifies auth-state listeners without letting one throwing listener starve the
// others.
function notifyAuthState(): void {
  const authenticated = authToken !== null;
  for (const listener of authStateListeners) {
    try {
      listener(authenticated);
    } catch {
      // Isolate listener failures.
    }
  }
}

// Returns the live token, hydrating from the session mirror on first read so a
// reload re-adopts the tab session without a network round trip.
export function getAuthToken(): string | null {
  if (!authTokenHydrated) {
    authToken = readStoredAuthToken();
    authTokenHydrated = true;
  }
  return authToken;
}

// Builds request headers for a direct same-origin fetch made outside the shared
// JSON helper (for example a non-JSON lifecycle probe), so those calls carry the
// owner credential too instead of bypassing the gate. Extra headers are merged
// last so a caller can still set Content-Type.
export function authHeaders(extra?: Record<string, string>): Record<string, string> {
  const token = getAuthToken();
  return {
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(extra ?? {}),
  };
}

// Adopts a token as the live credential and mirrors it to the tab session.
// Called on login and after rotation; blank input is ignored so an empty form can
// never clear a working session.
export function setAuthToken(token: string): void {
  const trimmed = token.trim();
  if (!trimmed) return;
  authToken = trimmed;
  authTokenHydrated = true;
  writeStoredAuthToken(trimmed);
  notifyAuthState();
}

// Clears the live token from memory and the session mirror together so a logout
// cannot leave a reload-recoverable credential behind. A transition is reported
// only when a credential was actually present: the loopback no-auth posture has
// no token to clear, so a stray logout there must not flip the gate to a login
// form the engine would accept any value for. When it fires, the transition
// drives the login gate and closes the shared socket.
export function clearAuthToken(): void {
  // Hydrate first so a stored token is seen even if this is the first auth call.
  const hadToken = getAuthToken() !== null;
  authToken = null;
  authTokenHydrated = true;
  writeStoredAuthToken(null);
  if (hadToken) {
    notifyAuthState();
  }
}

// Subscribes to authentication transitions. The current state is intentionally
// not emitted synchronously so a caller mounting before the boot probe does not
// briefly believe the session is unauthenticated; callers read getAuthToken()
// for the present value and this only reports changes.
export function subscribeAuthState(listener: AuthStateListener): () => void {
  authStateListeners.add(listener);
  return () => {
    authStateListeners.delete(listener);
  };
}

// Retires a credential the engine rejected. The token is dropped and holders are
// told to fall back to login; the value is never logged, echoed in an error, or
// included in the notification, so a rejected credential stays unobserved.
function handleUnauthorized(): void {
  if (authToken === null) return;
  authToken = null;
  authTokenHydrated = true;
  writeStoredAuthToken(null);
  notifyAuthState();
}

// Outcome of presenting a candidate token at login. Kept as a small union so the
// login view can render one honest message per case without distinguishing a
// missing credential from a wrong one beyond throttle and transport.
export type AuthenticationResult = "ok" | "invalid" | "throttled" | "unreachable";

// Validates a candidate token against a protected route and adopts it only on
// success. The probe deliberately reads no body: the engine's uniform 401 is the
// proof, and parsing the response would tempt logging payload detail that must
// never carry the credential. `/settings` is the same protected probe the engine
// uses for its own token check, so the gate accepts exactly the tokens the
// engine accepts.
export async function authenticateWithToken(token: string): Promise<AuthenticationResult> {
  const candidate = token.trim();
  if (!candidate) return "invalid";
  let response: Response;
  try {
    response = await fetch("/settings", {
      headers: { Authorization: `Bearer ${candidate}` },
    });
  } catch {
    return "unreachable";
  }
  if (response.ok) {
    setAuthToken(candidate);
    return "ok";
  }
  if (response.status === 429) return "throttled";
  // 401 is the uniform rejection; any other status cannot be trusted as a
  // successful login either, so it degrades to the same invalid outcome.
  if (response.status === 401) return "invalid";
  return "unreachable";
}

// One-time rotation response carrying the freshly minted owner token.
export interface RotateTokenResponse {
  token: string;
}

// Rotates the owner bearer through the authenticated route and adopts the
// returned token before handing it back for the one-time reveal. The old token is
// invalid the instant rotation returns, so the swap happens here rather than
// after the owner acknowledges saving: delaying it would strand every background
// poll on a dead credential. A refused rotation leaves the current token
// untouched so the session never lands on a value that was not persisted. The
// token is never logged.
export async function rotateToken(): Promise<string> {
  const response = await fetchJson<RotateTokenResponse>("/auth/rotate", {
    method: "POST",
  });
  const token = typeof response.token === "string" ? response.token.trim() : "";
  if (!token) {
    throw new ApiError("Rotation response did not include a token", 0);
  }
  setAuthToken(token);
  return token;
}

// Whether a health payload proves the request cleared the owner gate. With auth
// active the unauthenticated shape is the minimal liveness object, so a missing
// engine label means the probe never reached the full route; with auth inactive
// every probe carries the full shape.
export function isAuthenticatedHealth(health: HealthResponse | null | undefined): boolean {
  if (!health) return false;
  return typeof health.engine === "string" && health.engine.length > 0;
}

async function fetchJsonWithHeaders<T>(
  path: string,
  init?: RequestInit,
): Promise<{ data: T; headers: Headers }> {
  const hasBody = init?.body != null;
  // The owner token rides every request because auth is enforced uniformly
  // across the engine surface: without it a protected route answers the same
  // uniform 401 as a wrong one. Caller-supplied headers stay last so a probe can
  // present a candidate credential without adopting it first.
  const token = getAuthToken();
  let response: Response;
  try {
    response = await fetch(path, {
      ...init,
      headers: {
        ...(hasBody ? { "Content-Type": "application/json" } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
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
    if (response.status === 401) {
      // Uniform 401: retire the rejected credential and route the session back
      // to the login gate. The token value never appears in the error body, a
      // log line, or the transition notification, so a rejected credential
      // stays unobserved.
      handleUnauthorized();
    }
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
    return { data: undefined as T, headers: response.headers };
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
    return { data: data as T, headers: response.headers };
  } catch (err) {
    throw new ApiError(
      err instanceof ApiError ? err.message : `Invalid JSON response: ${path}`,
      response.status,
    );
  }
}

async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  // Single JSON path shared with the header-aware variant so error wording,
  // content-type checks, and record validation cannot drift per call site.
  const { data } = await fetchJsonWithHeaders<T>(path, init);
  return data;
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

export async function getHealth(): Promise<HealthResponse> {
  // Single health path prefers the server-advertised cap so admit and reject agree: the JSON
  // field wins when valid for future body-carried caps, otherwise the probe header fills it in,
  // and older engines with neither degrade to the fallback constant via the resolver.
  const { data, headers } = await fetchJsonWithHeaders<HealthResponse>("/health");
  const fromBody = parseMaxConcurrentChatTurns(data.maxConcurrentChatTurns as unknown);
  if (fromBody != null) {
    data.maxConcurrentChatTurns = fromBody;
    return data;
  }
  const fromHeader = parseMaxConcurrentChatTurns(
    headers?.get(MAX_CONCURRENT_CHAT_TURNS_HEADER),
  );
  if (fromHeader != null) {
    data.maxConcurrentChatTurns = fromHeader;
  }
  return data;
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

// Cancels one tool call by identity, distinct from the session-wide turn cancel
// above: a turn cancel aborts the whole reply while this stops a single
// long-running execution and lets the model reason about the partial result.
// The optional reason travels with the audit record; blank input is omitted so
// the engine stores absence rather than an empty string.
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

export function listApprovals(limit?: number): Promise<ApprovalsResponse> {
  const query = limit != null && limit > 0 ? `?limit=${encodeURIComponent(limit)}` : "";
  return fetchJson<ApprovalsResponse>(`/approvals${query}`);
}

export function decideApproval(
  id: string,
  approved: boolean,
  duration: TrustDuration = "thisTime",
  widen?: boolean,
): Promise<ApprovalDecisionResponse> {
  return fetchJson<ApprovalDecisionResponse>(
    `/approvals/${encodeURIComponent(id)}/decide`,
    {
      method: "POST",
      body: JSON.stringify({ approved, duration, widen }),
    },
  );
}

// Normalizes a grant expiry into a Date while preserving the forever contract: null stays
// null so callers can branch on "never expires" without sentinel-date comparisons. Non-null
// values delegate to parseRunTimestamp because the engine emits the same dual wire shape as
// run timestamps (Unix seconds from SQLite versus ISO strings from older payloads).
export function parseTrustGrantExpiry(
  value: string | number | null | undefined,
): Date | null {
  if (value == null) return null;
  return parseRunTimestamp(value);
}

// Lists active graduated-trust grants so the dashboard can show what stays auto-approved
// without re-deriving it from the pending approvals inbox.
export function listTrustGrants(): Promise<TrustGrantsResponse> {
  return fetchJson<TrustGrantsResponse>("/approvals/grants");
}

// Widens an active grant to all targets (empty target).
export function widenTrustGrant(id: string): Promise<void> {
  return fetchJson<void>(
    `/approvals/grants/${encodeURIComponent(id)}/widen`,
    {
      method: "POST",
    },
  );
}

// Revokes one grant by id. A 404 surfaces as ApiError through the shared fetchJson reason
// parsing so the UI can explain the grant already lapsed; a successful revoke returns 204
// with no body, which fetchJson maps to void.
export function revokeTrustGrant(id: string): Promise<void> {
  return fetchJson<void>(`/approvals/grants/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
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

export function listRuns(limit = RUN_LOG_POLL_LIMIT, jobID?: string, sessionID?: string): Promise<RunLogsResponse> {
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
  ).then((response) => validateTurnResponse(response, "Invalid job run response"));
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
  // llama.cpp prefix-reuse knobs round-tripped through SettingsResponse providers. Dual snake/camel
  // aliases mirror the existing provider pattern so file-configured values survive a dashboard
  // PUT instead of being stripped to nil. Absent stays unset (server auto-assign / always-on hint).
  slot_count?: number;
  slotCount?: number;
  cache_prompt?: boolean;
  cachePrompt?: boolean;
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

// One self-hosted Arr instance (Sonarr for TV, Radarr for movies). Both
// services share the same five-field shape mirroring the engine
// ArrInstanceConfig, so a single interface backs both sections and keeps the
// dashboard DTO from drifting out of lockstep when one side gains a knob.
// Only env-var names persist; key values resolve via SecretsManager at
// execution time and never enter TOML, logs, or model output.
export interface ArrServiceConfigData {
  enabled: boolean;
  url?: string;
  api_key_env?: string;
  apiKeyEnv?: string;
  default_quality_profile?: string;
  defaultQualityProfile?: string;
  default_root_folder?: string;
  defaultRootFolder?: string;
}

// Sonarr (TV) section of [media]; an alias so call sites keep the service
// name while sharing the single Arr shape above.
export type SonarrConfigData = ArrServiceConfigData;

// Radarr (movies) section of [media]; same shared shape as Sonarr.
export type RadarrConfigData = ArrServiceConfigData;

export interface MediaConfigData {
  sonarr: SonarrConfigData;
  radarr: RadarrConfigData;
}

export interface SettingsResponse {
  engineName: string;
  logLevel: string;
  compactionThresholdPercent?: number;
  maxToolIterations?: number;
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
  browserAllowedOrigins?: string[];
  searchSearxngURL?: string;
  searchTimeoutSeconds?: number;
  searchMaxResults?: number;
  emailAccounts: EmailAccountData[];
  pluginsDir: string;
  pluginsMarketplaceIndexURL: string;
  pluginsAutoRescan: boolean;
  media?: MediaConfigData;
  configPath: string;
}

export interface UpdateSettingsInput {
  engineName?: string;
  logLevel?: string;
  compactionThresholdPercent?: number;
  maxToolIterations?: number;
  defaultProvider?: string;
  fallbackProvider?: string;
  // Provider entries carry the prefix-reuse knobs (slot_count/slotCount/cache_prompt/cachePrompt)
  // through ProviderConfigData so a dashboard PUT preserves file-configured values instead of
  // stripping them to unset.
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
  browserAllowedOrigins?: string[];
  searchSearxngURL?: string;
  searchTimeoutSeconds?: number;
  searchMaxResults?: number;
  emailAccounts?: EmailAccountData[];
  pluginsDir?: string;
  pluginsMarketplaceIndexURL?: string;
  pluginsAutoRescan?: boolean;
  media?: MediaConfigData;
}

// Textarea mirror of the empty allowed origins defaults.
export const DEFAULT_BROWSER_ALLOWED_ORIGINS_TEXT = "";

// Parses the allowed-origins textarea into the wire shape: one pattern per line, trimmed, with blank
// lines dropped. Blank filtering avoids persisting whitespace-only rows.
export function parseAllowedOriginsText(text: string | undefined | null): string[] {
  if (text == null) return [];
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

// Formats an allowed-origins array for the multiline editor. Callers use this for display and reset
// so textarea and array states never diverge.
export function formatAllowedOriginsText(
  origins: string[] | undefined | null
): string {
  if (!Array.isArray(origins)) return "";
  return origins.join("\n");
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
// The ensure path carries a trimmed banner (terminal cause plus one
// `scripts/searxng-up.sh` remediation) in `message` and the chained per-stage
// detail (stage, exit, capped tail, timeout) in `diagnostics` when unreachable.
// Inline slots render `message` once; the Settings pane optionally exposes
// `diagnostics` in a collapsed element while warn logs keep the full chain.
export interface SearchHealthResponse {
  reachable: boolean;
  url?: string;
  baseURL?: string;
  status?: string | null;
  containerName?: string | null;
  started?: boolean | null;
  stopped?: boolean | null;
  // Whether the managed entry is gone after a remove. Optional because health,
  // ensure, and stop payloads predate removal; absent degrades to the honest
  // reachable probe instead of assuming deleted.
  removed?: boolean | null;
  message?: string | null;
  diagnostics?: string | null;
  // Live Start stage plus Start time while an ensure flight runs (resolving, daemon, pulling,
  // starting, waiting). Optional because older engines predate staged progress and because the
  // keys are absent when idle; absent means no Start is in flight.
  stage?: string | null;
  // Unix seconds when the in-flight Start began. Mirrors the engine shape (a number, never a
  // Date string) so elapsed math stays a subtraction; null or absent means unknown.
  startedAt?: number | null;
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

// Single-sourced banner extraction for the search lifecycle: trims the engine
// `message` (terminal cause plus one remediation) and normalizes blank or
// non-string payloads to null so callers never render whitespace as a banner.
// Per-stage detail lives in `diagnostics`, never in this slot, so install,
// daemon, pull, and timeout banners each render once without nesting.
export function resolveSearchMessage(
  response: SearchHealthResponse | null | undefined,
): string | null {
  const message = response?.message;
  return typeof message === "string" && message.trim() ? message.trim() : null;
}

// Single-sourced diagnostics extraction for the search lifecycle: trims the
// engine `diagnostics` (chained stage, exit, capped tail, timeout) and
// normalizes blank or non-string payloads to null so the collapsed Settings
// element only renders when real per-stage detail exists.
export function resolveSearchDiagnostics(
  response: SearchHealthResponse | null | undefined,
): string | null {
  const diagnostics = response?.diagnostics;
  return typeof diagnostics === "string" && diagnostics.trim()
    ? diagnostics.trim()
    : null;
}

// Staged Start progress: while a Start is in flight the engine publishes the current step plus
// the Start time on health payloads, and the dashboard polls about 1s so the amber Starting
// line tracks the cascade instead of sitting static. The client cap (~6 min) bounds a hung
// Start past the minutes-budget image pull plus the cached cascade: past it the UI stops the
// stage line and re-probes the dot while keeping the toggle locked, and the cap suspends while
// the stage reports pulling so a first-run pull never trips it early.
export const SEARCH_START_POLL_INTERVAL_MS = 1000;
export const SEARCH_START_CAP_MS = 360_000;

// Single-sourced user copy per Start stage, mirroring StartStage.userCopy on the engine. Unknown
// or drifted stages fall back to a bare Starting label via searchStageCopy so a new engine step
// never renders blank.
export const SEARCH_START_STAGE_COPY: Record<string, string> = {
  resolving: "Checking container runtime",
  daemon: "Waking container service",
  pulling: "Pulling search image",
  starting: "Starting search container",
  waiting: "Waiting for search to respond",
};

// Payloads carrying staged progress: /search/health uses stage/startedAt while /health nests the
// same values under searchStage/searchStartedAt. One shape keeps both poll sites honest.
export interface SearchStartProgressPayload {
  stage?: string | null;
  searchStage?: string | null;
  startedAt?: number | null;
  searchStartedAt?: number | null;
}

// Extracts the live Start stage across both health contracts, normalizing blank or non-string
// payloads to null so the Starting line only renders for a real in-flight step.
export function resolveStartStage(
  response: SearchStartProgressPayload | null | undefined,
): string | null {
  if (!response) return null;
  const raw =
    (typeof response.stage === "string" && response.stage.trim()) ||
    (typeof response.searchStage === "string" && response.searchStage.trim()) ||
    "";
  return raw || null;
}

// Extracts the in-flight Start time (Unix seconds) across both health contracts, normalizing
// missing, non-finite, or non-positive payloads to null so elapsed math falls back to the
// client-side Start instant instead of rendering from a garbage epoch.
export function resolveStartStartedAt(
  response: SearchStartProgressPayload | null | undefined,
): number | null {
  if (!response) return null;
  const raw =
    typeof response.startedAt === "number"
      ? response.startedAt
      : typeof response.searchStartedAt === "number"
        ? response.searchStartedAt
        : null;
  return raw != null && Number.isFinite(raw) && raw > 0 ? raw : null;
}

// Maps a stage to its user copy, degrading unknown stages to a bare Starting label so engine
// drift never blanks the in-flight line.
export function searchStageCopy(stage: string | null | undefined): string {
  if (stage && SEARCH_START_STAGE_COPY[stage]) return SEARCH_START_STAGE_COPY[stage];
  return "Starting";
}

// Reports whether the live Start stage is the minutes-budget image pull, during which the client
// cap suspends so a first-run pull never trips the hung-Start path early. Single-sourced so the
// shared progress hook and any future poll sites agree on the suspend condition.
export function isSearchStartPullingStage(stage: string | null | undefined): boolean {
  return stage === "pulling";
}

// Elapsed whole seconds since the Start began, preferring the engine Start time and falling back
// to the client-side Start instant when the payload carries none. Clamped at zero so clock skew
// never renders a negative count.
export function startElapsedSeconds(
  startedAtSeconds: number | null | undefined,
  clientStartMs: number,
  nowMs: number = Date.now(),
): number {
  const baseMs =
    startedAtSeconds != null && Number.isFinite(startedAtSeconds) && startedAtSeconds > 0
      ? startedAtSeconds * 1000
      : clientStartMs;
  return Math.max(0, Math.floor((nowMs - baseMs) / 1000));
}

// Reads live SearXNG reachability without touching settings: the profile
// menu dot and the Settings Web pane both poll this so Start and Stop
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

// Deletes the SearXNG container entry and reports the resulting health. The
// server stops a running entry first rather than half-deleting, and the image
// cache survives so the next Start recreates the entry from cache. Idempotent
// when already absent: an unknown-never-started host reports unreachable with
// removed true, while a still-reachable engine refuses with guidance.
export function removeSearch(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/remove", {
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
  hasConfig?: boolean;
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

