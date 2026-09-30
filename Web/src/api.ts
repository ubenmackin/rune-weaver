// Typed client for the engine JSON API.

import { isRecord } from "./typeGuards";
import { formatRelativeAgo, formatRelativeIn } from "./relativeTime";
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
export type ChatThoughtSegment = { kind: "thought"; text: string };
export type ChatSegment = ChatTextSegment | ChatToolsSegment | ChatThoughtSegment;

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
export function relativeProgressCurrent(value: unknown): string | null {
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

// Shared trimmed-identity guard for tool frames: a tool identity without
// non-whitespace characters cannot correlate with its end frame or approval,
// so it must never enter turn state. Single source for progress parsing, live
// start/end validation, and chat turn state so future grammar changes land in
// one place.
export function isValidToolIDs(toolName: unknown, callID: unknown): boolean {
  return (
    typeof toolName === "string" &&
    typeof callID === "string" &&
    toolName.trim().length > 0 &&
    callID.trim().length > 0
  );
}

// Validates one live progress frame before it enters the keyed map. Required
// numeric fields (scanned, matched, elapsedMs) share the engine's non-negative
// integer contract so a drifted or partial payload drops instead of rendering a
// floored or negative tally; the optional relative tail and warning degrade to
// null rather than aborting the update.
export function parseToolProgress(value: unknown): ToolProgress | null {
  if (!isRecord(value)) return null;
  if (!isValidToolIDs(value.toolName, value.callID)) return null;
  if (typeof value.message !== "string") return null;
  const scanned = toNonNegativeInt(value.scanned);
  const matched = toNonNegativeInt(value.matched);
  const elapsedMs = toNonNegativeInt(value.elapsedMs);
  if (scanned === undefined || matched === undefined || elapsedMs === undefined)
    return null;
  const rawWarning = typeof value.warning === "string" ? value.warning.trim() : "";
  // Store trimmed identities so the keyed progress map and the end-frame
  // lookup agree: a padded identity must not key as " foo " while the forget
  // path looks up "foo".
  const callID = (value.callID as string).trim();
  const toolName = (value.toolName as string).trim();
  return {
    callID,
    toolName,
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
  if (!Number.isFinite(elapsedMs) || elapsedMs < 0) return "0s";
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

export type ImpactSeverity = "safe" | "moderate" | "dangerous";

export interface ImpactAssessment {
  severity: ImpactSeverity;
  outcome: string;
  warnings?: string[];
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
  intent?: string | null;
  assessment?: ImpactAssessment | null;
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
  // Linked goal when the run works toward a tracked one. The engine encodes
  // the goal link under the canonical `goalId` spelling (distinct from the
  // `jobID`/`sessionID` families), so goal-scoped run filters compare this
  // field rather than a renamed alias. Absent on untagged runs and older
  // payloads that predate goal linking.
  goalId?: string | null;
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

// Compact run duration shared by every run-history surface: the scheduler
// history, the run log, the run detail modal, and the goal drawer's linked
// runs. Sub-second runs stay in milliseconds while longer runs collapse to one
// decimal second so all four read identically; non-finite and negative values
// render nothing rather than a bogus duration.
export function formatRunDuration(
  durationMs: number | null | undefined,
): string | null {
  if (
    typeof durationMs !== "number" ||
    !Number.isFinite(durationMs) ||
    durationMs < 0
  ) {
    return null;
  }
  return durationMs >= 1000
    ? `${(durationMs / 1000).toFixed(1)}s`
    : `${durationMs}ms`;
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

// Reports whether any run represents actively-running work that a settings save
// would interrupt. Only `running` counts; parked `awaiting_approval` rows wait
// on the inbox and never trigger the guard, so in-flight chat turns, running
// tool calls, and running scheduler runs guard while parked work does not.
// Accepts unknown status shapes so drifted payloads degrade to inactive rather
// than failing the guard check.
export function hasActiveRuns(
  runs: ReadonlyArray<{ status?: unknown } | null | undefined> | undefined | null,
): boolean {
  if (!Array.isArray(runs)) return false;
  for (const run of runs) {
    if (!run) continue;
    const status = (run as { status?: unknown }).status;
    if (isActiveRunStatus(typeof status === "string" ? status : undefined)) return true;
  }
  return false;
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
  // Linked goal when this session pursues a tracked one. The engine emits the
  // goal link under the canonical `goalId` spelling, so the chat header can
  // resolve a session-to-goal chip from the same detail fetch that hydrates
  // history instead of joining against run records. Absent on unlinked
  // sessions and on payloads that predate goal linkage.
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
  // Linked goal when this session pursues a tracked one, carried on the listing
  // payload so clients resolve a session-to-goal badge without querying run
  // history. Absent on unlinked sessions and older payloads.
  goalId?: string | null;
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

// ---------------------------------------------------------------------------
// Single-owner authentication (HttpOnly session cookie + optional bearer)
// ---------------------------------------------------------------------------

// Legacy sessionStorage key naming the single owner-token slot in older versions.
// Retained only to purge any stale tokens previously written to storage.
export const AUTH_TOKEN_STORAGE_KEY = "runeWeaverToken";

// Immediately purge any legacy token left in sessionStorage to prevent XSS exfiltration
if (typeof window !== "undefined") {
  try {
    window.sessionStorage.removeItem(AUTH_TOKEN_STORAGE_KEY);
  } catch {
    // Ignore storage unavailability in sandbox / private browsing mode
  }
}

// In-memory bearer token for headless / script callers that explicitly supply one.
// Normal browser UI authentication uses HttpOnly cookies (`rw_session`) so credentials
// cannot be exfiltrated via XSS.
let authToken: string | null = null;
let sessionAuthenticated = false;

// Listeners awaiting authentication transitions. The boot gate and the shared
// WebSocket subscribe here so a login, logout, rotation, or uniform 401 reaches
// every holder in one pass instead of each polling storage.
type AuthStateListener = (authenticated: boolean) => void;
const authStateListeners = new Set<AuthStateListener>();

// Whether the current session is authenticated via HttpOnly cookie or bearer token.
export function isSessionAuthenticated(): boolean {
  return sessionAuthenticated || authToken !== null;
}

// Notifies auth-state listeners without letting one throwing listener starve the
// others.
function notifyAuthState(): void {
  const authenticated = isSessionAuthenticated();
  for (const listener of authStateListeners) {
    try {
      listener(authenticated);
    } catch {
      // Isolate listener failures.
    }
  }
}

// Returns the live bearer token if explicitly configured (e.g. headless/test usage).
// In normal browser operations with HttpOnly cookies, credentials cannot be read
// by JavaScript to prevent exfiltration, so this returns null.
export function getAuthToken(): string | null {
  return authToken;
}

// Builds request headers for a direct same-origin fetch made outside the shared
// JSON helper (for example a non-JSON lifecycle probe), so those calls carry the
// owner credential too if one is configured. Extra headers are merged
// last so a caller can still set Content-Type.
export function authHeaders(extra?: Record<string, string>): Record<string, string> {
  const token = getAuthToken();
  return {
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(extra ?? {}),
  };
}

// Adopts an explicit bearer token as the live credential (primarily for tests/CLI).
// The token is never stored in persistent or sessionStorage.
export function setAuthToken(token: string): void {
  const trimmed = token.trim();
  if (!trimmed) return;
  authToken = trimmed;
  sessionAuthenticated = true;
  notifyAuthState();
}

// Clears authentication state from memory, purges any legacy session storage,
// and instructs the engine to expire the HttpOnly session cookie via DELETE /auth/session.
export function clearAuthToken(): void {
  const hadAuth = isSessionAuthenticated();
  authToken = null;
  sessionAuthenticated = false;
  if (typeof window !== "undefined") {
    try {
      window.sessionStorage.removeItem(AUTH_TOKEN_STORAGE_KEY);
    } catch {
      // Ignore
    }
    if (hadAuth) {
      try {
        fetch("/auth/session", {
          method: "DELETE",
          credentials: "same-origin",
        }).catch(() => {});
      } catch {
        // Ignore
      }
    }
  }
  if (hadAuth) {
    notifyAuthState();
  }
}

// Subscribes to authentication transitions. The current state is intentionally
// not emitted synchronously so a caller mounting before the boot probe does not
// briefly believe the session is unauthenticated; callers read isSessionAuthenticated()
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
  if (!isSessionAuthenticated()) return;
  authToken = null;
  sessionAuthenticated = false;
  if (typeof window !== "undefined") {
    try {
      window.sessionStorage.removeItem(AUTH_TOKEN_STORAGE_KEY);
    } catch {
      // Ignore
    }
  }
  notifyAuthState();
}

// Outcome of presenting a candidate token at login. Kept as a small union so the
// login view can render one honest message per case without distinguishing a
// missing credential from a wrong one beyond throttle and transport.
export type AuthenticationResult = "ok" | "invalid" | "throttled" | "unreachable";

// Validates a candidate token against POST /auth/session. On success, the engine sets
// a secure, HttpOnly, SameSite=Strict cookie ('rw_session') on the response. The raw token
// is never saved into sessionStorage, localStorage, or client memory, preventing XSS exfiltration.
export async function authenticateWithToken(token: string): Promise<AuthenticationResult> {
  const candidate = token.trim();
  if (!candidate) return "invalid";
  let response: Response;
  try {
    response = await fetch("/auth/session", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ token: candidate }),
      credentials: "same-origin",
    });
  } catch {
    return "unreachable";
  }
  if (response.ok) {
    sessionAuthenticated = true;
    if (typeof window !== "undefined") {
      try {
        window.sessionStorage.removeItem(AUTH_TOKEN_STORAGE_KEY);
      } catch {
        // Ignore
      }
    }
    notifyAuthState();
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

// Rotates the owner bearer through the authenticated route and returns the new token
// for one-time copying by the user. If authenticated via HttpOnly cookie, the engine
// automatically updates the rw_session cookie in the response.
export async function rotateToken(): Promise<string> {
  const response = await fetchJson<RotateTokenResponse>("/auth/rotate", {
    method: "POST",
  });
  const token = typeof response.token === "string" ? response.token.trim() : "";
  if (!token) {
    throw new ApiError("Rotation response did not include a token", 0);
  }
  sessionAuthenticated = true;
  notifyAuthState();
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
      credentials: "same-origin",
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
  if (isAuthenticatedHealth(data)) {
    sessionAuthenticated = true;
  }
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

export function listRuns(
  limit = RUN_LOG_POLL_LIMIT,
  jobID?: string,
  sessionID?: string,
  goalID?: string,
): Promise<RunLogsResponse> {
  const params = new URLSearchParams({ limit: String(limit) });
  if (jobID) params.set("jobID", jobID);
  if (sessionID) params.set("sessionID", sessionID);
  // Goal scoping reuses the one runs endpoint the scheduler history already
  // reads, so a goal detail drawer and a job drawer stay on one bounded list
  // call instead of a parallel route.
  if (goalID) params.set("goalID", goalID);
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

// Response from `POST /runs/:id/cancel`, mirroring the engine's
// `RunCancelResponse`. Treated as a request acknowledgement rather than as
// state: settled badges always come from refetching the runs list, while an
// already-settled run answers 409 (and a pruned row 404) with an honest reason
// that the shared fetchJson surfaces as ApiError. `scope` names what was
// stopped (`"run"` for a whole swarm, `"worker"` for one child whose siblings
// keep running), and `workerCount` is present only on a whole-swarm stop.
export interface CancelRunResponse {
  cancelled: boolean;
  scope: string;
  workerCount?: number;
}

// Stops one in-flight run by row id. The engine owns swarm scope: cancelling a
// fan-out parent stops the whole swarm while cancelling a worker row stops just
// that worker, so the dashboard posts the exact row the operator chose and lets
// the server decide how far the stop reaches instead of re-deriving scope from
// the kind client-side.
//
// The route takes no request body, so none is sent: the shared fetch helper
// only attaches the JSON content type when a body is present, and this handler
// never decodes one.
export function cancelRun(id: string): Promise<CancelRunResponse> {
  return fetchJson<CancelRunResponse>(
    `/runs/${encodeURIComponent(id)}/cancel`,
    {
      method: "POST",
    },
  );
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

// ---------------------------------------------------------------------------
// Long-horizon goals
// ---------------------------------------------------------------------------

// Finished-versus-planned tally nested on one goal row. `done` counts only
// finished steps while `total` is the whole plan, so an empty plan reads 0/0
// instead of a misleading full bar. Mirrors the engine `WSGoalProgress`.
export interface GoalProgress {
  done: number;
  total: number;
}

// One goal row shared by the list, detail, and `goal_updated` push shapes.
// Dates arrive in the engine's dual wire shape (ISO strings from Vapor, Unix
// seconds from SQLite) so callers normalize through parseRunTimestamp; the
// origin session stays nullable because headless and imported goals have no
// owning conversation. The origin key follows the engine's canonical
// `originSessionId` spelling, with the legacy variants accepted by
// parseGoalSnapshot for payloads written before that canonicalization.
export interface Goal {
  id: string;
  title: string;
  statement: string;
  status: string;
  progress: GoalProgress;
  stepIntervalMinutes: number;
  nextDueAt: string | number | null;
  originSessionId: string | null;
  createdAt: string | number;
  updatedAt: string | number;
}

// One ordered step in a goal plan. `status` rides as the engine raw value
// (`pending`, `in_progress`, `done`, `blocked`, `skipped`) so the dashboard
// never invents a case the store cannot round-trip through a PATCH.
export interface GoalStep {
  id: string;
  goalId: string;
  ordinal: number;
  title: string;
  status: string;
  notes: string | null;
  lastRunId: string | null;
  createdAt: string | number;
  updatedAt: string | number;
}

// One append-only audit entry for a goal. `id` is the SQLite rowid so the trail
// stays ordered without a second sequence; `message` is model- or
// operator-authored prose and must render through the sanitized Markdown path.
export interface GoalEvent {
  id: number;
  goalId: string;
  kind: string;
  message: string;
  createdAt: string | number;
}

export interface GoalsListResponse {
  goals: Goal[];
  count: number;
}

// Detail response shared by `GET /goals/:id` and every mutating goal route.
// Steps ride whole because plans stay small by config bound; events ride
// bounded by the caller's limit so a long audit trail never crowds the row.
export interface GoalDetailResponse {
  goal: Goal;
  steps: GoalStep[];
  events: GoalEvent[];
}

// Creation request for `POST /goals`. The cadence hint is optional so an
// omitted value lets the engine apply its configured default.
export interface GoalCreateInput {
  title: string;
  statement: string;
  stepIntervalMinutes?: number;
}

// Edit request for `PATCH /goals/:id`. Every field is optional so one call can
// rename, restate, retime, or flip lifecycle state; absent keys leave their
// columns untouched. A blank title or statement is rejected server-side rather
// than stored, so a partial edit cannot wipe a field with whitespace.
export interface GoalPatchInput {
  status?: string;
  title?: string;
  statement?: string;
  stepIntervalMinutes?: number;
}

// Manual step move for `PATCH /goals/:id/steps/:stepId`. Status is required
// because a move without a destination is a no-op, while the note stays
// optional so terse moves need no annotation.
export interface GoalStepPatchInput {
  status: string;
  note?: string;
}

// Manual-advance receipt for `POST /goals/:id/advance`. Both durable
// identifiers ride along so the dashboard can link the fresh run row and its
// session without a second lookup. Wire spellings match the engine: runs and
// sessions keep their `ID` suffix while the goal link encodes as `goalId`.
export interface GoalAdvanceResponse {
  runID: string;
  sessionID: string;
  goalId: string;
}

// Display label per lifecycle state. An unknown future raw value falls back to
// itself so a newer engine still renders honestly instead of blanking the pill.
export function goalStatusLabel(status: string): string {
  switch (status) {
    case "active":
      return "Active";
    case "paused":
      return "Paused";
    case "needs_input":
    case "needsInput":
      return "Needs input";
    case "achieved":
      return "Achieved";
    case "abandoned":
      return "Abandoned";
    default:
      return status || "Unknown";
  }
}

// Run-status pill tone reused by goal cards so goal and run surfaces share one
// color language: active pursuit reads like a running turn, parked-on-owner
// like a parked approval, achieved like an ok run, abandoned like an error,
// and paused like a skipped row.
export type GoalStatusTone =
  | "ok"
  | "error"
  | "skipped"
  | "running"
  | "awaiting_approval";

export function goalStatusTone(status: string): GoalStatusTone {
  switch (status) {
    case "active":
      return "running";
    case "needs_input":
    case "needsInput":
      return "awaiting_approval";
    case "achieved":
      return "ok";
    case "abandoned":
      return "error";
    case "paused":
      return "skipped";
    default:
      return "skipped";
  }
}

// Reports whether a goal is parked awaiting owner input, the single state the
// attention badge counts; the camelCase alias mirrors the engine's alternate
// REST spelling.
export function goalNeedsInput(status: string | null | undefined): boolean {
  return status === "needs_input" || status === "needsInput";
}

// Display label per audit kind. Unknown kinds fall back to the trimmed raw
// token so a newer engine's event still names itself instead of rendering blank.
export function goalEventKindLabel(kind: string): string {
  switch (kind) {
    case "created":
      return "Created";
    case "plan_ready":
      return "Plan ready";
    case "step_started":
      return "Step started";
    case "step_done":
      return "Step done";
    case "step_blocked":
      return "Step blocked";
    case "needs_input":
      return "Needs input";
    case "completed":
      return "Completed";
    case "resumed":
      return "Resumed";
    case "paused":
      return "Paused";
    case "note":
      return "Note";
    default:
      return kind.trim() || "Update";
  }
}

// Whole-percent completion for the progress bar. An empty plan reads 0 instead
// of dividing by zero, and the value is clamped so a drifted done > total never
// overflows the track; non-finite inputs degrade to 0 rather than rendering NaN.
export function goalProgressPercent(
  progress: GoalProgress | null | undefined,
): number {
  const done = progress?.done;
  const total = progress?.total;
  if (
    typeof done !== "number" ||
    typeof total !== "number" ||
    !Number.isFinite(done) ||
    !Number.isFinite(total) ||
    total <= 0
  ) {
    return 0;
  }
  const percent = (done / total) * 100;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

// Human countdown to the next due advancement. A paused or terminal goal has no
// meaningful next fire, so it renders an em dash instead of a stale countdown;
// a null due date reads as no schedule; a past due reads "due now" so an
// overdue goal never renders a negative "in" value.
export function formatGoalNextAdvance(
  status: string,
  nextDueAt: string | number | null | undefined,
  now: number = Date.now(),
): string {
  if (
    status === "paused" ||
    goalNeedsInput(status) ||
    status === "achieved" ||
    status === "abandoned"
  ) {
    return "—";
  }
  if (nextDueAt == null) return "No schedule";
  const due = parseRunTimestamp(nextDueAt).getTime();
  if (!Number.isFinite(due) || due <= 0) return "No schedule";
  const diff = due - now;
  if (diff <= 0) return "due now";
  return formatRelativeIn(diff);
}

// Parses a goal snapshot carried on a `goal_updated` frame (or a raw REST row)
// before it enters view state. Identity plus the core display fields are
// required; progress and cadence degrade to zeros, the origin session to null,
// and timestamps to the epoch so a partially drifted payload still renders
// instead of dropping an otherwise-usable row. Timestamps are type-checked
// rather than cast so a non-string/non-number value can never reach
// parseRunTimestamp and throw during render.
export function parseGoalSnapshot(value: unknown): Goal | null {
  if (!isRecord(value)) return null;
  const rawID = value.id;
  const id = typeof rawID === "string" ? rawID.trim() : "";
  if (!id) return null;
  // Bind the string fields to locals first so the narrowings survive into the
  // returned object literal without re-reading the index signature.
  const title = value.title;
  const status = value.status;
  if (typeof title !== "string" || typeof status !== "string") {
    return null;
  }
  const statement = typeof value.statement === "string" ? value.statement : "";
  const progressRaw: Record<string, unknown> = isRecord(value.progress)
    ? value.progress
    : {};
  const doneRaw = progressRaw.done;
  const totalRaw = progressRaw.total;
  const done =
    typeof doneRaw === "number" && Number.isFinite(doneRaw)
      ? Math.max(0, Math.floor(doneRaw))
      : 0;
  const total =
    typeof totalRaw === "number" && Number.isFinite(totalRaw)
      ? Math.max(0, Math.floor(totalRaw))
      : 0;
  const intervalRaw = value.stepIntervalMinutes;
  const stepIntervalMinutes =
    typeof intervalRaw === "number" && Number.isFinite(intervalRaw)
      ? Math.max(0, Math.floor(intervalRaw))
      : 0;
  // Canonical `originSessionId` wins when several historical spellings ride
  // together, mirroring the engine's alias-tolerant decoder.
  const originRaw =
    value.originSessionId ?? value.originSessionID ?? value.origin_session_id;
  const originSessionId =
    typeof originRaw === "string" && originRaw.trim() ? originRaw : null;
  // Runtime-validate each timestamp instead of casting: a drifted object or
  // boolean must fall back (null due date, epoch created/updated) rather than
  // flow into parseRunTimestamp, whose string path calls `.trim()`.
  const nextDueRaw = value.nextDueAt;
  const nextDueAt =
    typeof nextDueRaw === "string" || typeof nextDueRaw === "number"
      ? nextDueRaw
      : null;
  const createdRaw = value.createdAt;
  const createdAt =
    typeof createdRaw === "string" || typeof createdRaw === "number"
      ? createdRaw
      : 0;
  const updatedRaw = value.updatedAt;
  const updatedAt =
    typeof updatedRaw === "string" || typeof updatedRaw === "number"
      ? updatedRaw
      : 0;
  return {
    id,
    title,
    statement,
    status,
    progress: { done, total },
    stepIntervalMinutes,
    nextDueAt,
    originSessionId,
    createdAt,
    updatedAt,
  };
}

// Extracts the goal snapshot from a `goal_updated` frame. Returns null for any
// other frame type or a malformed payload so the socket handler refreshes only
// on a real update instead of on unrelated traffic.
export function parseGoalUpdatedFrame(value: unknown): Goal | null {
  if (!isRecord(value) || value.type !== "goal_updated") return null;
  return parseGoalSnapshot(value.goal);
}

// Reports whether a `proactive_message` frame signals a goal awaiting owner
// input. The engine labels the trigger `goalNeedsInput`; normalizing case and
// separators lets both that token and a snake_case `needs_input` variant match
// so the attention badge cannot miss a parking notification over spelling.
export function isGoalNeedsInputProactive(value: unknown): boolean {
  if (!isRecord(value) || value.type !== "proactive_message") return false;
  // Bind to a local so the string narrowing survives the normalization chain.
  const kind = value.kind;
  if (typeof kind !== "string") return false;
  const normalized = kind.trim().toLowerCase().replace(/[_-]/g, "");
  return normalized.includes("needsinput");
}

// Reports whether a `proactive_message` frame announces a freshly proposed
// idea. The engine labels the trigger `idea_proposed`; normalizing case and
// separators lets that token and a camelCase `ideaProposed` variant both match
// so the goals attention badge never misses a suggestion over spelling.
export function isIdeaProposedProactive(value: unknown): boolean {
  if (!isRecord(value) || value.type !== "proactive_message") return false;
  // Bind to a local so the string narrowing survives the normalization chain.
  const kind = value.kind;
  if (typeof kind !== "string") return false;
  const normalized = kind.trim().toLowerCase().replace(/[_-]/g, "");
  return normalized === "ideaproposed";
}

// Lists goals, optionally filtered by lifecycle state. A blank filter is
// omitted so the caller gets every state and can apply its own default hiding.
export function listGoals(status?: string): Promise<GoalsListResponse> {
  const trimmed = status?.trim();
  const query = trimmed ? `?status=${encodeURIComponent(trimmed)}` : "";
  return fetchJson<GoalsListResponse>(`/goals${query}`);
}

// Fetches one goal with its plan and bounded audit history.
export function getGoal(id: string): Promise<GoalDetailResponse> {
  return fetchJson<GoalDetailResponse>(`/goals/${encodeURIComponent(id)}`);
}

// Creates a goal; the engine returns the row immediately and lands the plan on
// a background task, with a later `goal_updated` push carrying the ready plan.
export function createGoal(input: GoalCreateInput): Promise<GoalDetailResponse> {
  return fetchJson<GoalDetailResponse>("/goals", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

// Renames, restates, retimes, or flips the lifecycle state of one goal.
export function patchGoal(
  id: string,
  input: GoalPatchInput,
): Promise<GoalDetailResponse> {
  return fetchJson<GoalDetailResponse>(`/goals/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify(input),
  });
}

// Tombstones a goal by default so history stays joinable; `purge` hard-deletes
// the row and its plan instead. Both paths answer 204 with no body.
export function deleteGoal(id: string, purge = false): Promise<void> {
  const query = purge ? "?purge=true" : "";
  return fetchJson<void>(`/goals/${encodeURIComponent(id)}${query}`, {
    method: "DELETE",
  });
}

// Fires one manual advancement. The engine owns the single-flight lock, so a
// goal already advancing answers 409, which callers surface as already running.
export function advanceGoal(id: string): Promise<GoalAdvanceResponse> {
  return fetchJson<GoalAdvanceResponse>(
    `/goals/${encodeURIComponent(id)}/advance`,
    { method: "POST", body: JSON.stringify({}) },
  );
}

// Moves one plan step and returns the refreshed step row.
export function patchGoalStep(
  goalId: string,
  stepId: string,
  input: GoalStepPatchInput,
): Promise<GoalStep> {
  return fetchJson<GoalStep>(
    `/goals/${encodeURIComponent(goalId)}/steps/${encodeURIComponent(stepId)}`,
    { method: "PATCH", body: JSON.stringify(input) },
  );
}

// One proactive Muse suggestion mirrored from the engine `Idea` snapshot. The
// kind and status ride as the engine raw strings so the dashboard never invents
// a case the store cannot round-trip; the goal link stays optional because tips
// carry no owning goal.
export interface Idea {
  id: string;
  kind: string;
  title: string;
  body: string;
  goalId: string | null;
  status: string;
  createdAt: string | number;
  updatedAt: string | number;
}

export interface IdeasListResponse {
  ideas: Idea[];
  count: number;
}

export interface IdeasSummaryResponse {
  total: number;
  proposed: number;
  accepted: number;
  dismissed: number;
}

// Parses one idea row before it enters view state. Identity plus the core
// display fields are required; the body and goal link degrade to empty/null and
// timestamps to the epoch so a partially drifted payload still renders instead
// of dropping an otherwise-usable suggestion. A blank title rejects the row,
// mirroring the engine's trimmed-empty drop, the store's blank-title skip, and
// the wire decoder's blank-title rejection, instead of rendering an empty card.
// The goal link accepts the canonical `goalId` spelling first, then the legacy
// variants, mirroring the engine's alias-tolerant decoder, and trims padding so
// deep links compare equal.
export function parseIdea(value: unknown): Idea | null {
  if (!isRecord(value)) return null;
  const rawID = value.id;
  const id = typeof rawID === "string" ? rawID.trim() : "";
  if (!id) return null;
  const rawTitle = value.title;
  const kind = value.kind;
  const status = value.status;
  if (
    typeof rawTitle !== "string" ||
    typeof kind !== "string" ||
    typeof status !== "string"
  ) {
    return null;
  }
  const title = rawTitle.trim();
  if (!title) return null;
  const body = typeof value.body === "string" ? value.body : "";
  const goalRaw = value.goalId ?? value.goalID ?? value.goal_id;
  const trimmedGoal = typeof goalRaw === "string" ? goalRaw.trim() : "";
  const goalId = trimmedGoal ? trimmedGoal : null;
  // Type-check timestamps rather than casting so a drifted object or boolean
  // cannot reach parseRunTimestamp, whose string path calls `.trim()`.
  const createdRaw = value.createdAt;
  const createdAt =
    typeof createdRaw === "string" || typeof createdRaw === "number"
      ? createdRaw
      : 0;
  const updatedRaw = value.updatedAt;
  const updatedAt =
    typeof updatedRaw === "string" || typeof updatedRaw === "number"
      ? updatedRaw
      : 0;
  return { id, kind, title, body, goalId, status, createdAt, updatedAt };
}

// Display label per idea family. An unknown future raw value falls back to its
// underscored spelling so a newer engine still renders a readable pill.
export function ideaKindLabel(kind: string): string {
  switch (kind) {
    case "plan_adjustment":
      return "Plan";
    case "new_goal":
      return "New goal";
    case "tip":
      return "Tip";
    default:
      return kind.replace(/_/g, " ").trim() || "Idea";
  }
}

// Lists ideas, optionally filtered by lifecycle state. A blank filter is
// omitted so the caller gets every state and applies its own default hiding.
export function listIdeas(status?: string): Promise<IdeasListResponse> {
  const trimmed = status?.trim();
  const query = trimmed ? `?status=${encodeURIComponent(trimmed)}` : "";
  return fetchJson<IdeasListResponse>(`/ideas${query}`);
}

// Fetches the per-status idea tallies for the attention badge.
export function getIdeasSummary(): Promise<IdeasSummaryResponse> {
  return fetchJson<IdeasSummaryResponse>("/ideas/summary");
}

// Accepts one idea and returns its refreshed row. The engine applies the
// suggestion's change (plan adjustment or new goal) before flipping status, so
// a 400/409 here is the honest reason the change could not be applied.
export function acceptIdea(id: string): Promise<Idea> {
  return fetchJson<Idea>(`/ideas/${encodeURIComponent(id)}/accept`, {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Dismisses one idea and returns its refreshed row. Dismissal never blocks a
// future suggestion with the same title; it only records the owner's "no".
export function dismissIdea(id: string): Promise<Idea> {
  return fetchJson<Idea>(`/ideas/${encodeURIComponent(id)}/dismiss`, {
    method: "POST",
    body: JSON.stringify({}),
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
  // llama.cpp prefix-reuse knobs round-tripped through SettingsResponse providers. Dual snake/camel
  // aliases mirror the existing provider pattern so file-configured values survive a dashboard
  // PUT instead of being stripped to nil. Absent stays unset (server auto-assign / always-on hint).
  slot_count?: number;
  slotCount?: number;
  cache_prompt?: boolean;
  cachePrompt?: boolean;
  supports_vision?: boolean;
  supportsVision?: boolean;
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

// Local background indexer policy mirroring the engine `IndexConfig`
// (Sources/RuneWeaverCore/Config.swift). The indexer is off by default, so a
// fresh install never walks the home directory or reads a mailbox until the
// operator opts in. Only content and derived vectors live behind these knobs;
// no secret ever appears here.
export interface IndexConfigData {
  enabled: boolean;
  files: boolean;
  mail: boolean;
  messages: boolean;
  roots: string[];
  exclude: string[];
  max_file_mb: number;
  mail_vector_window: string;
  icloud_evicted: string;
  describe_images_with_llm: boolean;
  nightly_budget: number;
  db_path: string;
  // Indexing effort preset (`light`, `balanced`, `performance`, or `custom`).
  // Optional for back-compat with older engines that predate the knob; absent
  // degrades to the balanced default instead of failing.
  effort?: string;
  // Custom worker count used only when `effort` is `custom`. Canonical wire
  // key is `workers`, mirroring the engine `IndexConfig.workers`; absent
  // degrades to the default stepper value.
  workers?: number;
  // Whether the run backs off when the machine reports thermal pressure.
  // Optional for back-compat; absent degrades to the default.
  thermal_backoff?: boolean;
  // Whether scheduled and on-demand runs pause while on battery power.
  // Optional for back-compat; absent degrades to the default.
  pause_on_battery?: boolean;
  // Maximum vector chunks stored per document, bounding per-document
  // embedding work; chunks beyond the cap stay keyword-only. Optional for
  // back-compat; absent degrades to the engine default instead of failing.
  max_vector_chunks_per_document?: number;
  // Trash-class mailbox denylist skipped without dialing. Optional for
  // back-compat; absent degrades to the engine default instead of failing.
  mailbox_deny?: string[];
  // Directory and file names the walker always skips, even when absent from
  // `exclude`. Read-only: populated by the engine from the walker's prune list
  // and ignored on write. Optional for back-compat with older engines that
  // predate the field; absent degrades to an empty list instead of failing.
  always_skipped?: string[];
}

// Partial index patch for `PUT /settings`, mirroring the engine
// `IndexSettingsUpdate`. Every field is optional so a request carrying one key
// leaves the rest of the stored `[index]` section untouched; the JSON keys are
// the snake_case names the engine persists.
export interface IndexSettingsUpdate {
  enabled?: boolean;
  files?: boolean;
  mail?: boolean;
  messages?: boolean;
  roots?: string[];
  exclude?: string[];
  max_file_mb?: number;
  mail_vector_window?: string;
  icloud_evicted?: string;
  describe_images_with_llm?: boolean;
  nightly_budget?: number;
  db_path?: string;
  effort?: string;
  workers?: number;
  thermal_backoff?: boolean;
  pause_on_battery?: boolean;
  max_vector_chunks_per_document?: number;
  mailbox_deny?: string[];
}

// Native desktop vision and gated control policy mirroring the engine
// `DesktopConfig` (Sources/RuneWeaverCore/Config.swift). Both desktop tools
// always register so they stay visible in `GET /tools`, but they ship
// disabled until enabled in the tool-state toggles. Only capture knobs and
// the blocklist live here; enablement lives in the tool-state toggles and no
// secret ever appears.
export interface DesktopConfigData {
  max_image_dimension: number;
  jpeg_quality: number;
  blocked_apps: string[];
}

// Partial desktop patch for `PUT /settings`, mirroring the engine
// `DesktopSettingsUpdate`. Every field is optional so a request carrying one
// key leaves the rest of the stored `[desktop]` section untouched; the JSON
// keys are the snake_case names the engine persists.
export interface DesktopSettingsUpdate {
  max_image_dimension?: number;
  jpeg_quality?: number;
  blocked_apps?: string[];
}

// Steady goal pursuit policy mirroring the engine `GoalsConfig`
// (Sources/RuneWeaverCore/Config.swift). Goals stay opt-in so a fresh install
// never spends planning calls until the owner enables them; the cadence hint
// is stored on each new goal and the active cap bounds scheduler fan-out.
export interface GoalsConfigData {
  enabled: boolean;
  step_interval_minutes: number;
  max_active_goals: number;
  max_steps_per_goal: number;
  plan_timeout_seconds: number;
}

// Partial goals patch for `PUT /settings`, mirroring the engine
// `GoalsUpdate`. Every field is optional so a request carrying one key leaves
// the rest of the stored `[goals]` section untouched; the dashboard sends the
// snake_case keys the engine persists while the engine also accepts the
// camelCase aliases, so either spelling writes.
export interface GoalsSettingsUpdate {
  enabled?: boolean;
  step_interval_minutes?: number;
  stepIntervalMinutes?: number;
  max_active_goals?: number;
  maxActiveGoals?: number;
}

// Interruption policy for background scheduler and goal turns, mirroring the
// engine `ProactiveConfig` (Sources/RuneWeaverCore/Config.swift). The gate
// filters notifications and interruption frames only; run history and the
// approvals inbox always record regardless of mode.
export interface ProactiveConfigData {
  mode: string;
  judge_timeout_seconds: number;
}

// Partial proactive patch for `PUT /settings`, mirroring the engine
// `ProactiveUpdate`. Every field is optional so a request carrying one key
// leaves the rest of the stored `[proactive]` section untouched.
export interface ProactiveSettingsUpdate {
  mode?: string;
  judge_timeout_seconds?: number;
  judgeTimeoutSeconds?: number;
}

// Proactive Muse suggestion policy mirroring the engine `IdeasConfig`
// (Sources/RuneWeaverCore/Config.swift). Ideas stay opt-in so a fresh install
// never spends background review calls; the per-cycle cap and review timeout
// stay file-owned planning bounds.
export interface IdeasConfigData {
  enabled: boolean;
  max_per_cycle: number;
  timeout_seconds: number;
}

// Partial ideas patch for `PUT /settings`, mirroring the engine `IdeasUpdate`.
// Only the enable toggle is dashboard-owned; the planning bounds stay file-owned.
export interface IdeasSettingsUpdate {
  enabled?: boolean;
}

// Manual mirror of the IdeasConfig default so a fresh form matches the boundary
// the engine enforces before the first settings fetch.
export const DEFAULT_IDEAS_ENABLED = false;

// Manual mirrors of GoalsConfig defaults so a fresh form matches the boundary
// the engine enforces before the first settings fetch.
export const DEFAULT_GOALS_ENABLED = false;
export const DEFAULT_GOALS_STEP_INTERVAL_MINUTES = 1440;
export const DEFAULT_GOALS_MAX_ACTIVE_GOALS = 10;

// Cadence choices offered by the New Goal form. Every value sits inside the
// engine's 5..20160 bound (GOALS_STEP_INTERVAL_MIN_MINUTES..MAX) so the select
// can never submit a cadence the server would reject, and the daily option
// reuses DEFAULT_GOALS_STEP_INTERVAL_MINUTES so form and settings agree. Kept
// beside the default it derives from so the initializer never reads the
// constant before its declaration.
export const GOAL_CADENCE_OPTIONS: Array<{ value: number; label: string }> = [
  { value: 60, label: "Hourly" },
  { value: 240, label: "Every 4 hours" },
  { value: 720, label: "Every 12 hours" },
  { value: DEFAULT_GOALS_STEP_INTERVAL_MINUTES, label: "Daily" },
  { value: 10080, label: "Weekly" },
];

// Goals cadence bounds mirroring GoalsConfig.minStepIntervalMinutes and
// maxStepIntervalMinutes; the server owns the 5-20160 range and this mirror is
// the single source for the client validator.
export const GOALS_STEP_INTERVAL_MIN_MINUTES = 5;
export const GOALS_STEP_INTERVAL_MAX_MINUTES = 20160;

// Active-goal cap bounds mirroring GoalsConfig.minActiveGoalsBound and
// maxActiveGoalsBound; the server owns the 1-50 range.
export const GOALS_MAX_ACTIVE_MIN = 1;
export const GOALS_MAX_ACTIVE_MAX = 50;

// Closed set of valid proactive surfacing modes, mirroring ProactiveMode on
// the engine. Single source for the client validator and the Proactivity
// select so the two cannot drift.
export const PROACTIVE_MODES = ["all", "milestones", "guarded", "off"] as const;

// Canonical proactive mode spelling carried on the wire and in the select.
export type ProactiveModeName = (typeof PROACTIVE_MODES)[number];

// Normalizes a proactive mode to its canonical lowercase spelling so the
// dashboard accepts the same values the file loader does. The TOML decoder
// trims and lowercases before matching `ProactiveMode`, so `ALL` or padded
// ` Guarded ` load from disk; the client must converge to the same spelling
// before validating or sending instead of rejecting what the file accepts.
export function normalizeProactiveMode(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

// Reports whether a value names a proactive surfacing mode, ignoring case
// and surrounding whitespace to match the file loader. Single source for the
// settings validator and populate path so both agree with the engine.
export function isValidProactiveMode(value: unknown): boolean {
  return (PROACTIVE_MODES as readonly string[]).includes(
    normalizeProactiveMode(value),
  );
}

// Manual mirrors of ProactiveConfig defaults; the server owns `all` plus the
// 15-second judge budget and the contract test pins both ends.
export const DEFAULT_PROACTIVE_MODE = "all";
export const DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS = 15;

// Judge timeout bounds mirroring ProactiveConfig.minJudgeTimeoutSeconds and
// maxJudgeTimeoutSeconds; the server owns the 1-120 range.
export const PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS = 1;
export const PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS = 120;

// Sandboxed shell execution policy mirroring the engine `BashConfig`
// (Sources/RuneWeaverCore/Config.swift). Rules stay ordered top-to-bottom
// last-match-wins; the timeout is bounded 1-3600 seconds. Only policy knobs
// live here; the enabled flag mirrors the stored `[bash]` section.
export interface BashRuleData {
  pattern: string;
  action: string;
}

// Full bash snapshot on `GET /settings`, mirroring the engine `BashConfig`.
// The canonical wire keys are snake_case; the engine also accepts the
// camelCase aliases through the same dual-alias decode as providers, so
// either spelling reads. The dashboard sends snake_case and reads either
// spelling so file-configured values survive a dashboard PUT instead of
// being stripped to nil.
export interface BashConfigData {
  enabled: boolean;
  default_action: string;
  defaultAction?: string;
  rules: BashRuleData[];
  timeout_seconds: number;
  timeoutSeconds?: number;
  allow_network: boolean;
  allowNetwork?: boolean;
}

// Partial bash patch for `PUT /settings`, mirroring the engine
// `BashSettingsUpdate`. Every field is optional so a request carrying one
// key leaves the rest of the stored `[bash]` section untouched. The dashboard
// sends the snake_case keys the engine persists; the engine also accepts the
// camelCase aliases through the dual-alias decode, so either spelling writes.
export interface BashSettingsUpdate {
  enabled?: boolean;
  default_action?: string;
  defaultAction?: string;
  rules?: BashRuleData[];
  timeout_seconds?: number;
  timeoutSeconds?: number;
  allow_network?: boolean;
  allowNetwork?: boolean;
}

// Bash defaults mirror BashConfig in Sources/RuneWeaverCore/Config.swift
// (enabled, defaultAction, defaultRules, defaultTimeoutSeconds,
// allowNetwork). The server owns the values; this mirror seeds the fresh form
// before the first GET /settings fetch and the contract test pins it so drift
// fails loudly. DEFAULT_BASH_CONFIG stays derived from the pieces below so
// the pieces remain the single source.
export const DEFAULT_BASH_ENABLED = true;
export const DEFAULT_BASH_DEFAULT_ACTION = "ask";
export const DEFAULT_BASH_TIMEOUT_SECONDS = 30;
export const DEFAULT_BASH_ALLOW_NETWORK = false;

// Bash timeout bounds mirror BashConfig.minTimeoutSeconds/maxTimeoutSeconds
// in Sources/RuneWeaverCore/Config+Validation.swift and the PUT merge in
// Sources/RuneWeaverServer/ServerBashDTOs.swift. The server owns the 1-3600
// bound; this mirror is the single source for the client validator so the two
// cannot drift. The contract test pins both ends.
export const BASH_TIMEOUT_MIN_SECONDS = 1;
export const BASH_TIMEOUT_MAX_SECONDS = 3600;

// Mirror of BashConfig.defaultRules; update by hand alongside the Swift
// default. The contract test pins the catch-all so drift fails loudly.
export const DEFAULT_BASH_RULES: BashRuleData[] = [
  { pattern: "*", action: "ask" },
];

// Combined bash default mirroring BashConfig. The fresh form seeds from this
// object so the editor matches the boundary the engine enforces before the
// first settings fetch.
export const DEFAULT_BASH_CONFIG: BashConfigData = {
  enabled: DEFAULT_BASH_ENABLED,
  default_action: DEFAULT_BASH_DEFAULT_ACTION,
  rules: DEFAULT_BASH_RULES.map((rule) => ({ ...rule })),
  timeout_seconds: DEFAULT_BASH_TIMEOUT_SECONDS,
  allow_network: DEFAULT_BASH_ALLOW_NETWORK,
};

// Closed set of valid bash permission actions, mirroring BashPermissionAction
// on the engine. Single source for the client validator and the Bash modal
// option lists so the two cannot drift.
export const BASH_PERMISSION_ACTIONS = ["allow", "ask", "deny"] as const;

// Bash textarea codec: one rule per line as `pattern = action` with `allow`,
// `ask`, or `deny` on the right, mirroring the engine
// `BashSecurity.evaluate(command:config:)` contract
// (Sources/RuneWeaverTools/BashSecurity.swift). Rules evaluate top-to-bottom
// and the last matching rule decides, so the catch-all stays first and
// specifics follow. Blank lines are ignored and line order is preserved so
// copy and paste of rule sets works. Owner for parsing is parseBashRulesText
// here; owner for saving is handleSaveBashConfig in SettingsManager.tsx.
export function parseBashRulesText(text: string | undefined | null): BashRuleData[] {
  if (typeof text !== "string") return [];
  const rules: BashRuleData[] = [];
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (!trimmed) continue;
    const lineNumber = index + 1;
    const separator = trimmed.lastIndexOf("=");
    if (separator === -1) {
      throw new Error(
        `Line ${lineNumber}: expected "pattern = action" (missing "=").`,
      );
    }
    const pattern = trimmed.slice(0, separator).trim();
    const rawAction = trimmed.slice(separator + 1).trim();
    const action = rawAction.toLowerCase();
    if (!pattern) {
      throw new Error(`Line ${lineNumber}: pattern must not be blank.`);
    }
    if (!(BASH_PERMISSION_ACTIONS as readonly string[]).includes(action)) {
      throw new Error(
        `Line ${lineNumber}: action must be allow, ask, or deny (got '${rawAction}').`,
      );
    }
    rules.push({ pattern, action });
  }
  return rules;
}

// Formats ordered bash rules for the textarea, one `pattern = action` per
// line, preserving top-to-bottom order so the last matching rule decides.
export function formatBashRulesText(
  rules: BashRuleData[] | undefined | null,
): string {
  if (!Array.isArray(rules)) return "";
  return rules.map((rule) => `${rule.pattern} = ${rule.action}`).join("\n");
}

// Textarea mirror of the bash rule defaults so the shell policy editor starts
// from the same guard boundary without joining inline in every caller.
export const DEFAULT_BASH_RULES_TEXT: string =
  formatBashRulesText(DEFAULT_BASH_RULES);

// Manual mirrors of DesktopConfig defaults in Sources/RuneWeaverCore/Config.swift.
export const DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION = 1280;
export const DEFAULT_DESKTOP_JPEG_QUALITY = 0.75;

// Manual mirror of DesktopConfig.defaultBlockedApps; update by hand alongside
// the Swift default.
export const DEFAULT_DESKTOP_BLOCKED_APPS: string[] = [
  "Terminal",
  "iTerm2",
  "Keychain Access",
  "System Settings",
  "System Preferences",
  "1Password",
  "Bitwarden",
];

// Textarea mirror of the blocked-apps defaults so the desktop editor starts
// from the same guard boundary without joining inline in every caller.
export const DEFAULT_DESKTOP_BLOCKED_APPS_TEXT: string =
  DEFAULT_DESKTOP_BLOCKED_APPS.join("\n");

// Shared line-list codec for multiline editors: one entry per line, trimmed,
// with blank lines dropped so an emptied editor reads as an explicit empty
// list instead of persisting whitespace-only rows. Null input degrades to a
// copy of the caller-supplied fallback so default boundaries stay with the
// wrappers and the server remains the authoritative enforcer.
export function parseLinesToList(
  text: string | undefined | null,
  fallback: string[],
): string[] {
  if (text == null) return [...fallback];
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

// Shared formatter for multiline editors: joins a list for display, falling
// back to the caller-supplied text when an older engine omits the section so
// textarea and array states never diverge on the default boundary.
export function formatListToText(
  list: string[] | undefined | null,
  fallback: string,
): string {
  if (!Array.isArray(list)) return fallback;
  return list.join("\n");
}

// Parses the blocked-apps textarea into the wire shape, defaulting to the
// desktop guard boundary when no text is present.
export function parseBlockedAppsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, DEFAULT_DESKTOP_BLOCKED_APPS);
}

// Formats a blocked-apps array for the multiline editor, falling back to the
// guard defaults when an older engine omits the [desktop] section entirely.
export function formatBlockedAppsText(apps: string[] | undefined | null): string {
  return formatListToText(apps, DEFAULT_DESKTOP_BLOCKED_APPS_TEXT);
}

// Default desktop policy mirroring DesktopConfig so a fresh form matches the
// boundary the engine enforces before the first settings fetch.
export const DEFAULT_DESKTOP_CONFIG: DesktopConfigData = {
  max_image_dimension: DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION,
  jpeg_quality: DEFAULT_DESKTOP_JPEG_QUALITY,
  blocked_apps: [...DEFAULT_DESKTOP_BLOCKED_APPS],
};

// Parallel worker fan-out policy mirroring the engine `FanOutConfig`
// (Sources/RuneWeaverCore/Config.swift). Workers stay on the read-only subset
// unless full_tools widens them to the full registry; the modal owns these
// knobs while tool enablement lives in the tool-state toggles. The dashboard
// defaults below are the modal empty-field fallbacks so a cleared input saves
// an explicit value instead of omitting the key; the engine file defaults may
// differ and the server remains the authoritative enforcer.
export interface FanoutConfigData {
  max_workers: number;
  worker_timeout_seconds: number;
  full_tools: boolean;
}

// Partial fan-out patch for `PUT /settings`, mirroring the engine fan-out
// update shape. Every field is optional so a request carrying one key leaves
// the rest of the stored `[fanout]` section untouched; the JSON keys are the
// snake_case names the engine persists.
export interface FanoutSettingsUpdate {
  max_workers?: number;
  worker_timeout_seconds?: number;
  full_tools?: boolean;
}

// Modal empty-field fallbacks for the fan-out knobs: a cleared Max workers
// input saves the small-swarm default and a cleared timeout saves unlimited
// (0) so local models are never held to a stale budget by accident. Full
// tools stays off so workers keep the read-only subset until explicitly
// widened.
export const DEFAULT_FANOUT_MAX_WORKERS = 2;
export const DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS = 0;
export const DEFAULT_FANOUT_FULL_TOOLS = false;

// Combined fan-out default seeding the fresh form before the first fetch so
// the editor matches the modal empty-field boundary.
export const DEFAULT_FANOUT_CONFIG: FanoutConfigData = {
  max_workers: DEFAULT_FANOUT_MAX_WORKERS,
  worker_timeout_seconds: DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
  full_tools: DEFAULT_FANOUT_FULL_TOOLS,
};

// One source's enablement row on `GET /index/status`. Global enablement gates
// every row server-side, so a source reads as live only when the indexer as a
// whole is on.
export interface IndexSourceStatus {
  kind: string;
  enabled: boolean;
}

// Per-source content counts on `GET /index/status`: real document, chunk, and
// byte totals grouped by origin corpus. Optional because older engines predate
// the aggregates; absent degrades to an empty breakdown instead of failing.
export interface IndexSourceCounts {
  kind: string;
  documents: number;
  chunks: number;
  bytes: number;
}

// Extraction-outcome breakdown row on `GET /index/status`: document counts
// grouped by extraction outcome. Optional for back-compat with older engines.
export interface IndexExtractStatusCounts {
  status: string;
  documents: number;
}

// Display labels for index run triggers. The engine persists the
// machine-readable wire token (`nightly`, `onDemand`, `catchUp`) in run
// messages and the `Trigger:` detail line; the dashboard maps each token to
// plain language here so run notices, the last-run strip, and run-history
// rows agree on one copy without branching per call site.
export const INDEX_RUN_TRIGGER_LABELS: Record<string, string> = {
  nightly: "Nightly Run",
  onDemand: "Manual Run",
  catchUp: "Catch-Up Run",
};

// Maps an index run trigger token to its display label, falling back to the
// trimmed wire token so an unknown future trigger still renders honestly, and
// to a bare index label when no token is present.
export function indexRunTriggerLabel(trigger: string | null | undefined): string {
  if (typeof trigger !== "string") return "Index Run";
  const token = trigger.trim();
  if (!token) return "Index Run";
  return INDEX_RUN_TRIGGER_LABELS[token] ?? token;
}

// Extracts the machine-readable trigger token from an index run log row. The
// start message carries `Index run started (<trigger>)` while the completion
// response carries a `Trigger: <trigger>` detail line; either shape yields the
// token only when anchored to its prefix and matching a known trigger
// (`nightly`, `catchUp`, `onDemand`), and a row carrying neither degrades to
// null instead of guessing.
export function parseIndexRunTrigger(
  run: Pick<RunLogEntry, "message" | "response"> | null | undefined,
): string | null {
  if (!run) return null;
  const message = typeof run.message === "string" ? run.message : "";
  const prefix = "Index run started (";
  const prefixAt = message.indexOf(prefix);
  if (prefixAt !== -1) {
    const rest = message.slice(prefixAt + prefix.length);
    const close = rest.indexOf(")");
    if (close !== -1) {
      const token = rest.slice(0, close).trim();
      if (token === "nightly" || token === "catchUp" || token === "onDemand") {
        return token;
      }
    }
  }
  const response = typeof run.response === "string" ? run.response : "";
  if (response) {
    for (const line of response.split("\n")) {
      const trimmed = line.trim();
      if (/^trigger:/i.test(trimmed)) {
        const token = trimmed.slice(trimmed.indexOf(":") + 1).trim().split(/\s+/, 1)[0];
        if (token === "nightly" || token === "catchUp" || token === "onDemand") {
          return token;
        }
      }
    }
  }
  return null;
}

// Maps an index run log row to its display label, parsing the trigger token
// from the durable message/response first so run-history rows agree with run
// notices even when the status probe predates trigger tracking.
export function indexRunLabelForRun(
  run: Pick<RunLogEntry, "message" | "response"> | null | undefined,
): string {
  return indexRunTriggerLabel(parseIndexRunTrigger(run));
}

// Latest index run outcome on `GET /index/status`, distilled server-side from
// the newest `index`-kind run log row. Counts are nullable because a drifted
// summary line still reports status and finish time; finishedAt keeps the dual
// wire shape (ISO-8601 string or Unix seconds) normalized via parseRunTimestamp.
// The trigger token (`nightly`, `catchUp`, `onDemand`) is optional for
// back-compat with older engines that predate trigger tracking; absent
// degrades to an unlabeled strip instead of failing.
export interface IndexLastRunStatus {
  status: string;
  indexed?: number | null;
  scanned?: number | null;
  errors?: number | null;
  finishedAt?: string | number | null;
  trigger?: string | null;
  // Skip reason for a `skipped` outcome, mirroring `IndexRunResponse.skippedReason`.
  // Optional for back-compat with older engines that predate the field; absent
  // degrades to no reason instead of failing.
  skippedReason?: string | null;
  // Documents retired (deleted or superseded) by the run. Optional for
  // back-compat with older engines that predate retirement tracking; absent
  // degrades to no retired count instead of failing.
  retiredCount?: number | null;
  // Alias some engines emit for the same count. Read via
  // `resolveIndexRetiredCount` so either spelling renders honestly.
  retired?: number | null;
  // Documents where chunks beyond the vector cap stayed keyword-only.
  // Optional for back-compat with older engines that predate truncation
  // tracking; absent degrades to no truncated count instead of failing.
  truncatedCount?: number | null;
  // Alias some engines emit for the same count. Read via
  // `resolveIndexTruncatedCount` so either spelling renders honestly.
  truncated?: number | null;
}

// Live snapshot of an in-flight index run on `GET /index/status`, mirroring
// IndexLiveTotals on the engine. Null when idle; the dashboard renders the
// live block only from this poll snapshot, never from WebSocket frame parsing.
export interface IndexLiveStatus {
  trigger: string;
  phase: string | null;
  stage: string | null;
  scanned: number;
  indexed: number;
  skipped: number;
  errors: number;
  // Engine `live.rate` in docs/s. Optional and nullable for back-compat with
  // older engines that omit the key; absent degrades to no rate instead of
  // failing so callers read `live.rate` directly with a typeof guard.
  rate?: number | null;
  elapsedMs: number;
  current: string | null;
}

// Resolved effort block on `GET /index/status`, mirroring the engine
// `IndexEffortStatus`. Always present on current engines so the dashboard
// renders workers without a second fetch; absent on older engines, which
// degrade to the top-level aliases below or to no effort line.
export interface IndexEffortStatus {
  preset: string;
  resolvedWorkers: number;
  activeProcessors: number;
}

// Status snapshot for `GET /index/status`.
export interface IndexStatusResponse {
  enabled: boolean;
  running: boolean;
  documents: number;
  chunks: number;
  vectorChunks: number;
  keywordChunks: number;
  bytes: number;
  // Watermark of the last successful run, in either wire shape the engine
  // emits (ISO-8601 strings or Unix seconds), or null when never indexed.
  // Kept as a union so callers normalize through parseRunTimestamp.
  indexAsOf?: string | number | null;
  sources: IndexSourceStatus[];
  lastErrors: string[];
  // Per-source content aggregates and extraction-outcome breakdown. Optional
  // because older engines predate the breakdowns; absent means unknown and the
  // charts degrade to an empty state instead of failing.
  bySource?: IndexSourceCounts[];
  byExtractStatus?: IndexExtractStatusCounts[];
  // Latest run outcome, or null when no run has been recorded. Optional for
  // back-compat with older engines that predate the strip.
  lastRun?: IndexLastRunStatus | null;
  // Live snapshot of the run in flight, or null when idle. Optional for
  // back-compat with older engines that predate live polling; absent degrades
  // to no live block instead of failing.
  live?: IndexLiveStatus | null;
  // On-disk database file size in bytes, excluding the write-ahead log.
  // Optional for back-compat; absent degrades to the content `bytes` total so
  // older engines still render an honest size instead of failing.
  dbFileBytes?: number | null;
  // On-disk write-ahead log size in bytes. Optional for back-compat; absent
  // degrades to zero when the file size is present, or to the content total
  // when both are absent.
  walBytes?: number | null;
  // Storage breakdown for the on-disk figure: indexed text, vector, FTS, and
  // free-space bytes. Each optional for back-compat; absent degrades to an
  // omitted breakdown row instead of failing.
  textBytes?: number | null;
  vectorBytes?: number | null;
  ftsBytes?: number | null;
  freeBytes?: number | null;
  // Resolved effort block, always present on current engines.
  effort?: IndexEffortStatus | null;
}

// Outcome of `POST /index/run`.
export interface IndexRunResponse {
  sessionID: string;
  trigger: string;
  status: string;
  documentsIndexed: number;
  vectorChunks: number;
  keywordChunks: number;
  scanned: number;
  skipped: number;
  errors: number;
  warnings: string[];
  startedAt: string | number;
  finishedAt: string | number;
  indexAsOf?: string | number | null;
  skippedReason?: string | null;
  // Documents retired (deleted or superseded) by the run. Optional for
  // back-compat; absent degrades to no retired count instead of failing.
  retiredCount?: number | null;
  retired?: number | null;
  // Documents where chunks beyond the vector cap stayed keyword-only.
  // Optional for back-compat; absent degrades to no truncated count instead
  // of failing.
  truncatedCount?: number | null;
  truncated?: number | null;
}

// Outcome of `POST /index/cancel`.
export interface IndexCancelResponse {
  cancelled: boolean;
}

// Normalized run description shared by the top run notice and the last-run
// strip. Both surfaces render one identical line — status plus the trigger
// display label, outcome counts, and finish age — so a completed run can never
// read differently in the two places. The terminal summary (`IndexRunResponse`)
// and the status strip (`IndexLastRunStatus`) both normalize into this shape.
export interface IndexRunDescription {
  status: string;
  trigger?: string | null;
  indexed?: number | null;
  scanned?: number | null;
  errors?: number | null;
  finishedAt?: string | number | null;
  skippedReason?: string | null;
  retiredCount?: number | null;
  truncatedCount?: number | null;
}

// Resolves the retired count from any run shape, accepting both `retiredCount`
// and the `retired` alias some engines emit. Non-finite, negative, and
// fractional payloads degrade to null so callers omit the count instead of
// rendering a drifted figure.
export function resolveIndexRetiredCount(
  run:
    | Pick<IndexLastRunStatus, "retiredCount" | "retired">
    | Pick<IndexRunResponse, "retiredCount" | "retired">
    | Pick<IndexRunDescription, "retiredCount">
    | null
    | undefined,
): number | null {
  if (!run || typeof run !== "object") return null;
  const candidate =
    (run as { retiredCount?: unknown }).retiredCount ??
    (run as { retired?: unknown }).retired;
  if (typeof candidate !== "number" || !Number.isFinite(candidate)) return null;
  if (candidate < 0) return null;
  return Math.floor(candidate);
}

// Resolves the truncated count from any run shape, accepting both
// `truncatedCount` and the `truncated` alias some engines emit. Non-finite,
// negative, and fractional payloads degrade to null so callers omit the count
// instead of rendering a drifted figure.
export function resolveIndexTruncatedCount(
  run:
    | Pick<IndexLastRunStatus, "truncatedCount" | "truncated">
    | Pick<IndexRunResponse, "truncatedCount" | "truncated">
    | Pick<IndexRunDescription, "truncatedCount">
    | null
    | undefined,
): number | null {
  if (!run || typeof run !== "object") return null;
  const candidate =
    (run as { truncatedCount?: unknown }).truncatedCount ??
    (run as { truncated?: unknown }).truncated;
  if (typeof candidate !== "number" || !Number.isFinite(candidate)) return null;
  if (candidate < 0) return null;
  return Math.floor(candidate);
}

// Normalizes the status strip shape into the shared run description. Null
// degrades to null so callers render the never-ran copy instead of guessing.
export function indexRunDescriptionFromLastRun(
  lastRun:
    | IndexLastRunStatus
    | IndexRunDescription
    | null
    | undefined,
): IndexRunDescription | null {
  if (!lastRun) return null;
  const skippedReason = lastRun.skippedReason ?? null;
  return {
    status: lastRun.status,
    trigger: lastRun.trigger ?? null,
    indexed: lastRun.indexed ?? null,
    scanned: lastRun.scanned ?? null,
    errors: lastRun.errors ?? null,
    finishedAt: lastRun.finishedAt ?? null,
    skippedReason:
      typeof skippedReason === "string" && skippedReason.trim()
        ? skippedReason
        : null,
    retiredCount: resolveIndexRetiredCount(
      lastRun as Pick<IndexLastRunStatus, "retiredCount" | "retired">,
    ),
    truncatedCount: resolveIndexTruncatedCount(
      lastRun as Pick<IndexLastRunStatus, "truncatedCount" | "truncated">,
    ),
  };
}

// Normalizes the terminal run summary into the shared run description. Null
// degrades to null so callers render the never-ran copy instead of guessing.
export function indexRunDescriptionFromSummary(
  summary: IndexRunResponse | null | undefined,
): IndexRunDescription | null {
  if (!summary) return null;
  return {
    status: summary.status,
    trigger: summary.trigger ?? null,
    indexed: summary.documentsIndexed ?? null,
    scanned: summary.scanned ?? null,
    errors: summary.errors ?? null,
    finishedAt: summary.finishedAt ?? null,
    skippedReason:
      typeof summary.skippedReason === "string" && summary.skippedReason.trim()
        ? summary.skippedReason
        : null,
    retiredCount: resolveIndexRetiredCount(summary),
    truncatedCount: resolveIndexTruncatedCount(summary),
  };
}

// Explicit type-guard distinguishing the terminal run summary from the
// status strip and shared description shapes. Checks the summary's own
// `documentsIndexed` plus `vectorChunks` pair so a future strip field
// addition cannot silently flip the branch the way a bare `in` check would.
export function isIndexRunResponse(
  run: IndexRunDescription | IndexLastRunStatus | IndexRunResponse,
): run is IndexRunResponse {
  if (typeof run !== "object" || run === null) return false;
  const candidate = run as unknown as Record<string, unknown>;
  return (
    typeof candidate.documentsIndexed === "number" &&
    typeof candidate.vectorChunks === "number"
  );
}

// Single owner for every integer count on the Index Status page. Floors
// finite numbers so fractional payloads never render decimals, groups en-US
// at and above 10000 so large stores stay scannable, and degrades anything
// non-finite to zero so a drifted payload never renders NaN. Decimals,
// percents, rates, and byte units never pass through here.
export function formatIndexCount(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return "0";
  const floored = Math.floor(value);
  if (floored >= 10000) return floored.toLocaleString("en-US");
  return String(floored);
}

// One-line human summary of an index run shared by the top notice and the
// last-run strip: status plus the trigger display label, outcome counts, and
// run age, omitting any count the payload did not carry so a drifted
// payload still renders its status and time. The trigger label stays
// parenthesized after the status so the `Last run <status>` prefix survives
// verbatim, except an ok run that still recorded errors folds that count into
// the head (`finished with N errors`) so success-with-errors never reads as a
// clean ok plus a duplicated trailing count. A live run names its start
// (`started … ago`) because its row still carries the start instant, while
// every terminal status names its finish (`finished … ago`) from the persisted
// completion instant. A cancelled run appends the
// kept-work copy because committed batches survive the stop and the next run
// resumes from there. A skipped run appends its reason so a skip never reads
// as a silent no-op. Null renders the honest never-ran copy so a fresh store
// never reads as an empty history.
export function describeIndexRun(
  run:
    | IndexRunDescription
    | IndexLastRunStatus
    | IndexRunResponse
    | null
    | undefined,
): string {
  if (!run) return "No runs yet";
  // Single normalization path: the terminal summary and the status strip both
  // flow through the shared normalizers above instead of branching inline.
  const normalized = isIndexRunResponse(
    run as IndexRunDescription | IndexLastRunStatus | IndexRunResponse,
  )
    ? indexRunDescriptionFromSummary(run as IndexRunResponse)
    : indexRunDescriptionFromLastRun(
        run as IndexRunDescription | IndexLastRunStatus,
      );
  if (!normalized) return "No runs yet";
  const status: unknown = normalized.status;
  const trigger: unknown = normalized.trigger;
  const indexed: unknown = normalized.indexed;
  const scanned: unknown = normalized.scanned;
  const errors: unknown = normalized.errors;
  const finishedAt: unknown = normalized.finishedAt;
  const skippedReason: unknown = normalized.skippedReason;
  const retiredCount: unknown = normalized.retiredCount;
  const truncatedCount: unknown = normalized.truncatedCount;
  const normalizedStatus =
    typeof status === "string" && status.trim() ? status.trim() : "unknown";
  // An ok run that still recorded errors folds the count into the head so the
  // line never repeats it: the head names `finished with N errors` and the
  // trailing errors part below stays suppressed for this case only.
  const errorCount =
    typeof errors === "number" && Number.isFinite(errors) ? errors : null;
  const finishedWithErrors =
    normalizedStatus === "ok" && errorCount != null && errorCount > 0;
  const head = finishedWithErrors
    ? typeof trigger === "string" && trigger.trim()
      ? `Last run finished with ${formatIndexCount(errorCount)} errors (${indexRunTriggerLabel(trigger)})`
      : `Last run finished with ${formatIndexCount(errorCount)} errors`
    : typeof trigger === "string" && trigger.trim()
      ? `Last run ${normalizedStatus} (${indexRunTriggerLabel(trigger)})`
      : `Last run ${normalizedStatus}`;
  const parts: string[] = [head];
  if (typeof indexed === "number" && Number.isFinite(indexed)) {
    parts.push(`${formatIndexCount(indexed)} indexed`);
  }
  if (typeof scanned === "number" && Number.isFinite(scanned)) {
    parts.push(`${formatIndexCount(scanned)} scanned`);
  }
  if (
    typeof errors === "number" &&
    Number.isFinite(errors) &&
    !finishedWithErrors
  ) {
    parts.push(`${formatIndexCount(errors)} errors`);
  }
  if (
    typeof retiredCount === "number" &&
    Number.isFinite(retiredCount) &&
    retiredCount > 0
  ) {
    parts.push(`${formatIndexCount(retiredCount)} retired`);
  }
  if (
    typeof truncatedCount === "number" &&
    Number.isFinite(truncatedCount) &&
    truncatedCount > 0
  ) {
    parts.push(`${formatIndexCount(truncatedCount)} truncated`);
  }
  if (finishedAt != null) {
    const ageMs = indexWatermarkAgeMs(
      finishedAt as string | number | null | undefined,
    );
    if (ageMs != null) {
      // A live row still carries its start instant, so it names the start and
      // never the word finished; every settled row carries the completion
      // instant stamped by the reporter, so it keeps the finished copy.
      if (normalizedStatus === "running") {
        parts.push(`started ${formatRelativeAgo(ageMs)}`);
      } else {
        parts.push(`finished ${formatRelativeAgo(ageMs)}`);
      }
    }
  }
  let text = parts.join(" · ");
  if (normalizedStatus === "cancelled") {
    text += " · Committed work is kept and the next run resumes from there.";
  }
  if (
    normalizedStatus === "skipped" &&
    typeof skippedReason === "string" &&
    skippedReason.trim()
  ) {
    text += ` — Index run skipped: ${skippedReason.trim()}`;
  }
  return text;
}

// Outcome of `POST /index/prune`.
export interface IndexPruneResponse {
  removed: number;
  before: string | number;
}

// Outcome of `POST /index/reset`.
export interface IndexResetResponse {
  reset: boolean;
}

// Outcome of `POST /index/reclaim`: compacts the index database and reports
// the on-disk size before and after so the pane can show both figures. All
// three counters are on-disk bytes (database file plus write-ahead log).
export interface IndexReclaimResponse {
  beforeBytes: number;
  afterBytes: number;
  reclaimedBytes: number;
}

// Closed set of valid `mail_vector_window` values, mirroring
// IndexConfig.allowedMailVectorWindows; `all` disables the window.
export const INDEX_MAIL_VECTOR_WINDOWS = ["30d", "6m", "1y", "2y", "all"];

// Closed set of valid `icloud_evicted` policies, mirroring
// IndexConfig.allowedICloudEvictions.
export const INDEX_ICLOUD_EVICTIONS = ["skip", "download"];

// Closed set of valid `effort` preset ids, mirroring
// IndexConfig.allowedEfforts without `custom`. `custom` carries an explicit
// worker count in `workers`; the other three map onto the engine worker
// derivation so the same preset scales from a laptop to a studio machine.
export const INDEX_EFFORT_PRESETS = ["light", "balanced", "performance"] as const;

// Display labels for the effort presets, plus the custom worker mode. Unknown
// future presets fall back to their wire token so the control never renders
// blank.
export const INDEX_EFFORT_PRESET_LABELS: Record<string, string> = {
  light: "Light",
  balanced: "Balanced",
  performance: "Performance",
  custom: "Custom",
};

// Default effort preset: balanced work without saturating the machine.
export const DEFAULT_INDEX_EFFORT = "balanced";
// Default custom worker count used when `effort` is `custom` and no stored
// value exists yet. This is the stepper fallback only; the wire default in
// DEFAULT_INDEX_CONFIG.workers stays 0 (derive from the preset) mirroring
// IndexConfig.defaultWorkers.
export const DEFAULT_INDEX_WORKERS = 4;
// Static ceiling for a `custom` worker count, mirroring
// IndexConfig.maxAllowedWorkers. Validation accepts 1..64 on any machine;
// resolution clamps to the live core count, so a value carried over from a
// larger machine never oversubscribes the current hardware.
export const INDEX_MAX_CUSTOM_WORKERS = 64;
// Default exclude patterns, mirroring IndexConfig.defaultExcludePatterns
// (Sources/RuneWeaverCore/IndexConfig.swift). Single-sourced here so the
// fresh form before the first settings fetch and the back-compat fallback
// cannot drift from the engine walker list.
export const DEFAULT_INDEX_EXCLUDE_PATTERNS: string[] = [
  ".build",
  "*.app",
  "*.log",
  "*.tmp",
  ".DS_Store",
  ".bun",
  ".cocoapods",
  ".npm",
  ".npm-packages",
  ".nvm",
  ".cache",
  ".gradle",
  ".swiftpm",
  ".swiftly",
  ".gem",
  ".rvm",
  ".cpan",
  ".local",
  ".docker",
  ".ollama",
  ".terraform.d",
  ".ipynb_checkpoints",
  ".ipython",
  ".jupyter",
  ".matplotlib",
  ".vscode",
  ".vscode-insiders",
  ".zsh_sessions",
  "gopath",
  "go",
  "nltk_data",
];
// Default per-document vector chunk cap, mirroring
// IndexConfig.defaultMaxVectorChunksPerDocument.
export const DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT = 128;
// Default thermal-backoff toggle: back off when the machine reports pressure.
export const DEFAULT_INDEX_THERMAL_BACKOFF = true;
// Default pause-on-battery toggle: keep indexing on battery unless asked.
export const DEFAULT_INDEX_PAUSE_ON_BATTERY = false;
// Default Trash-class mailbox denylist, mirroring
// IndexConfig.defaultMailboxDeny.
export const DEFAULT_INDEX_MAILBOX_DENY: string[] = [
  "Trash",
  "Junk",
  "Spam",
  "Deleted*",
];
// Textarea mirror of the mailbox denylist so the policy editor starts from
// the same boundary without joining inline in every caller.
export const DEFAULT_INDEX_MAILBOX_DENY_TEXT: string =
  DEFAULT_INDEX_MAILBOX_DENY.join("\n");

// Parses the denied-mailboxes textarea into the wire shape, defaulting to the
// Trash-class boundary when no text is present.
export function parseMailboxDenyText(
  text: string | undefined | null,
): string[] {
  return parseLinesToList(text, DEFAULT_INDEX_MAILBOX_DENY);
}

// Formats a mailbox denylist for the multiline editor, falling back to the
// Trash-class defaults when an older engine omits the section entirely.
export function formatMailboxDenyText(
  deny: string[] | undefined | null,
): string {
  return formatListToText(deny, DEFAULT_INDEX_MAILBOX_DENY_TEXT);
}

// Default index policy values mirroring IndexConfig so a fresh form matches the
// boundary the engine enforces before the first settings fetch. `workers` is
// 0 (derive from the preset) mirroring IndexConfig.defaultWorkers; presets
// require 0 and only `custom` carries an explicit 1..64 count.
export const DEFAULT_INDEX_CONFIG: IndexConfigData = {
  enabled: false,
  files: true,
  mail: false,
  messages: false,
  roots: ["~"],
  exclude: [...DEFAULT_INDEX_EXCLUDE_PATTERNS],
  max_file_mb: 20,
  mail_vector_window: "2y",
  icloud_evicted: "skip",
  describe_images_with_llm: false,
  nightly_budget: 0,
  db_path: "~/.runeweaver/index.db",
  effort: DEFAULT_INDEX_EFFORT,
  workers: 0,
  thermal_backoff: DEFAULT_INDEX_THERMAL_BACKOFF,
  pause_on_battery: DEFAULT_INDEX_PAUSE_ON_BATTERY,
  max_vector_chunks_per_document: DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
  mailbox_deny: [...DEFAULT_INDEX_MAILBOX_DENY],
};

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
  // Local background indexer policy under [index]; optional for back-compat
  // with older engines that predate the section.
  index?: IndexConfigData;
  // Native desktop vision and gated control under [desktop]; optional for
  // back-compat with older engines that predate the section.
  desktop?: DesktopConfigData;
  // Sandboxed shell execution policy under [bash]; optional for back-compat
  // with older engines that predate the section.
  bash?: BashConfigData;
  // Steady goal pursuit policy under [goals]; optional for back-compat with
  // older engines that predate the section.
  goals?: GoalsConfigData;
  // Interruption policy under [proactive]; optional for back-compat with
  // older engines that predate the section.
  proactive?: ProactiveConfigData;
  // Proactive Muse suggestion policy under [ideas]; optional for back-compat
  // with older engines that predate the section.
  ideas?: IdeasConfigData;
  // Parallel worker fan-out policy under [fanout]; optional for back-compat
  // with older engines that predate the section.
  fanout?: FanoutConfigData;
  // HTTP bind from [server]; optional for back-compat with older engines that
  // predate the bind keys. Absent degrades to the loopback defaults so the
  // Network pane never renders blank.
  serverHostname?: string;
  serverPort?: number;
  serverAllowedHosts?: string[];
  configPath: string;
  // Whether the last PUT needs a restart to take effect. True only when the
  // save carried bind-affecting [server] keys; the route never live-reloads
  // the socket or the middleware set. Optional because older engines predate
  // the flag; absent means no restart was advertised.
  requiresRestart?: boolean;
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
  // Partial index patch; an omitted patch preserves the stored [index] section.
  index?: IndexSettingsUpdate;
  // Partial desktop patch; an omitted patch preserves the stored [desktop] section.
  desktop?: DesktopSettingsUpdate;
  // Partial bash patch; an omitted patch preserves the stored [bash] section.
  bash?: BashSettingsUpdate;
  // Partial goals patch; an omitted patch preserves the stored [goals] section.
  goals?: GoalsSettingsUpdate;
  // Partial proactive patch; an omitted patch preserves the stored [proactive] section.
  proactive?: ProactiveSettingsUpdate;
  // Partial ideas patch; an omitted patch preserves the stored [ideas] section.
  ideas?: IdeasSettingsUpdate;
  // Partial fan-out patch; an omitted patch preserves the stored [fanout] section.
  fanout?: FanoutSettingsUpdate;
  // Bind patch for [server]; an omitted patch preserves the stored section.
  // The engine persists these to the file and returns requiresRestart without
  // live-reloading the bind, so the dashboard shows a restart banner.
  serverHostname?: string;
  serverPort?: number;
  serverAllowedHosts?: string[];
}

// Textarea mirror of the empty allowed origins defaults.
export const DEFAULT_BROWSER_ALLOWED_ORIGINS_TEXT = "";

// Parses the allowed-origins textarea into the wire shape, defaulting to an
// empty allowlist when no text is present.
export function parseAllowedOriginsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, []);
}

// Formats an allowed-origins array for the multiline editor.
export function formatAllowedOriginsText(
  origins: string[] | undefined | null
): string {
  return formatListToText(origins, DEFAULT_BROWSER_ALLOWED_ORIGINS_TEXT);
}

// Manual mirrors of ServerEndpointConfig ([server] bind) in
// Sources/RuneWeaverCore/Config.swift so a fresh Network form matches the
// boundary the engine enforces before the first settings fetch.
export const DEFAULT_SERVER_HOSTNAME = "127.0.0.1";
export const DEFAULT_SERVER_PORT = 8082;
export const MAX_SERVER_ALLOWED_HOSTS = 20;
export const MAX_SERVER_ALLOWED_HOST_LENGTH = 253;

// Whether a bind hostname is loopback-only. Non-loopback binds need a
// resolvable owner token and fail closed otherwise, so the Network pane gates
// its save copy on this check before any network write. A trailing FQDN dot
// never counts as loopback, mirroring ServerConfig.isLoopbackHostname:
// validators reject trailing-dot hosts fail-closed, so `localhost.`
// classifies as non-loopback here to agree with the validator instead of
// riding loopback under a spelling that can never be configured.
export function isLoopbackHostname(hostname: string | undefined | null): boolean {
  const trimmed = (hostname ?? "").trim().toLowerCase();
  return (
    trimmed === "127.0.0.1" ||
    trimmed === "localhost" ||
    trimmed === "::1" ||
    trimmed === "[::1]"
  );
}

// Single web source for the restart compare: trimmed plus lowercased, then a
// single outer bracket pair stripped only when the inner text holds a colon
// so `::1` and `[::1]` (or `::` and `[::]`) compare equal while bracketed
// non-IPv6 spellings stay distinct. Matches canonicalRestartHost in
// Sources/RuneWeaverServer/ServerSettingsRoutes.swift; the Host gate stores
// both spellings for IPv6 literals, so without this the compare reports a
// spurious restart when only the bracket spelling moves. SettingsManager
// consumes this helper directly so casing or IPv6 bracket-only spellings the
// gate treats identically never trip a spurious save or restart badge.
export function canonicalRestartHost(value: string): string {
  const candidate = value.trim().toLowerCase();
  if (candidate.length >= 2 && candidate.startsWith("[") && candidate.endsWith("]")) {
    const inner = candidate.slice(1, -1);
    if (inner.includes(":")) return inner;
  }
  return candidate;
}

// Normalizes one allowed_hosts entry to the compared Host form: trimmed,
// lowercased, with a trailing empty or numeric :port stripped so
// Example.COM:8082 stores as example.com. Bracketed IPv6 keeps its brackets
// while a bare IPv6 literal keeps its colons instead of being mistaken for
// host:port. A bracketed literal strips only for an empty suffix or a colon
// plus numeric port (`[::1]`, `[::1]:8082`); any other trailing shape stays
// verbatim so `[::1]evil` never truncates to an allowlisted literal. An
// unbracketed suffix strips only for an empty or numeric port so
// `evil.com:evil` stays verbatim instead of truncating to an allowlisted host.
export function normalizeServerAllowedHost(entry: string): string {
  const trimmed = entry.trim().toLowerCase();
  if (!trimmed) return trimmed;
  if (trimmed.startsWith("[")) {
    const close = trimmed.indexOf("]");
    if (close === -1) return trimmed;
    const after = trimmed.slice(close + 1);
    if (after.length === 0) return trimmed.slice(0, close + 1);
    if (after.startsWith(":")) {
      const portPart = after.slice(1);
      if (portPart.length > 0 && /^[0-9]+$/.test(portPart)) {
        return trimmed.slice(0, close + 1);
      }
    }
    return trimmed;
  }
  const colonCount = (trimmed.match(/:/g) ?? []).length;
  if (colonCount > 1) return trimmed;
  const colon = trimmed.indexOf(":");
  if (colon !== -1) {
    // Preserve the carved fragment for scheme inputs (`http://...` -> `http`)
    // so the pinned parity fixtures stay stable; validation drops these
    // fail-closed before any allowlist stores them.
    if (trimmed.includes("://")) return trimmed.slice(0, colon);
    const portPart = trimmed.slice(colon + 1);
    if (/^[0-9]*$/.test(portPart)) return trimmed.slice(0, colon);
    return trimmed;
  }
  return trimmed;
}

// Single source for IPv6 bracket-shape validation shared by the allowed_hosts
// and hostname validators. Brackets only ever wrap an IPv6 literal, so any
// other bracket shape would never match the Host gate exactly yet would read
// as configured; keeping the shape check here keeps the client agreeing with
// the server 400 when the accepted shape evolves. Takes the trimmed value for
// shape checks but echoes the original entry for repair, matching the
// surrounding validators. Mirrors validateExactHost.
export function validateBracketedHost(trimmed: string, entry: string): string | null {
  // Fail closed on `[` without `]` (and vice versa): an unbalanced bracket
  // would never match exactly yet read as configured.
  if (trimmed.includes("[") !== trimmed.includes("]")) {
    return `must not contain unbalanced brackets (got '${entry}')`;
  }
  // Fail closed on bracketed non-IPv6 and empty brackets: `[example.com]`,
  // `[127.0.0.1]`, or `[]` would never match exactly yet read as configured.
  // A `:port` suffix after `]` strips only for a numeric port, so any other
  // tail stays verbatim garbage and must fail here while numeric tails pass
  // through for the allowlist strip or the hostname port-suffix rejection.
  // Prefixed `[`, single `[`/`]` counts, non-empty inner holding a colon, and
  // an after-bracket that is empty or colon-plus-numeric-port; bracket extras,
  // prefix doubles, bare tails, and non-numeric ports all reject.
  if (trimmed.includes("[") || trimmed.includes("]")) {
    const openCount = (trimmed.match(/\[/g) ?? []).length;
    const closeCount = (trimmed.match(/\]/g) ?? []).length;
    const close = trimmed.indexOf("]");
    if (
      !trimmed.startsWith("[") ||
      openCount !== 1 ||
      closeCount !== 1 ||
      close === -1
    ) {
      return `must not contain bracketed non-IPv6 (got '${entry}'); brackets are only for IPv6 literals`;
    }
    const inner = trimmed.slice(1, close);
    if (!inner) {
      return `must not contain empty brackets (got '${entry}')`;
    }
    if (!inner.includes(":")) {
      return `must not contain bracketed non-IPv6 (got '${entry}'); list the host without brackets instead`;
    }
    const afterBracket = trimmed.slice(close + 1);
    if (afterBracket) {
      if (!afterBracket.startsWith(":")) {
        return `must not contain bracketed non-IPv6 (got '${entry}'); brackets are only for IPv6 literals`;
      }
      const portPart = afterBracket.slice(1);
      if (!portPart || !/^[0-9]+$/.test(portPart)) {
        return `must not contain bracketed non-IPv6 (got '${entry}'); brackets are only for IPv6 literals`;
      }
    }
  }
  return null;
}

// Validates one allowed_hosts entry against the exact-only Host semantics the
// gate enforces. A bare * would allow every host, schemes/wildcards/CIDR would
// never match exactly yet read as configured, unbalanced brackets or brackets
// around a non-IPv6 host would never match yet read as allowed, a trailing
// FQDN dot would never match the stored form, and over-long entries exceed
// the DNS name limit, so each shape fails closed here with the entry echoed
// for repair. Mirrors RuneWeaverConfig.validateAllowedHosts via
// validateExactHost.
export function validateServerAllowedHost(entry: string): string | null {
  const trimmed = entry.trim();
  if (!trimmed) return "must not contain empty strings";
  if (trimmed.length > MAX_SERVER_ALLOWED_HOST_LENGTH) {
    return `must not exceed ${MAX_SERVER_ALLOWED_HOST_LENGTH} characters (got ${trimmed.length})`;
  }
  const lowered = trimmed.toLowerCase();
  if (lowered.includes("://")) {
    return `must not contain a scheme (got '${entry}'); list the host instead`;
  }
  if (lowered === "*") {
    return `must not contain bare "*" (would allow every host)`;
  }
  if (lowered.includes("*")) {
    return `must not contain wildcards (got '${entry}'); list exact hosts instead`;
  }
  if (lowered.includes("/")) {
    return `must not contain CIDR or paths (got '${entry}'); list exact hosts instead`;
  }
  if (trimmed.includes("@")) {
    return `must not contain userinfo (got '${entry}')`;
  }
  if (trimmed.includes("?") || trimmed.includes("#")) {
    return `must be a host without query or fragment (got '${entry}')`;
  }
  if (trimmed.includes(" ") || trimmed.includes("\t")) {
    return `must not contain whitespace (got '${entry}')`;
  }
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001F\u007F]/.test(trimmed)) {
    return `must not contain control characters (got '${entry}')`;
  }
  // Single-sourced bracket shape so a future IPv6 spelling change stays in
  // lockstep with the server 400.
  const bracketProblem = validateBracketedHost(trimmed, entry);
  if (bracketProblem) {
    return bracketProblem;
  }
  // Fail closed on unbracketed `host:suffix` with a non-numeric suffix:
  // normalization strips only an empty or numeric port, so `evil.com:evil`
  // would otherwise persist verbatim garbage. Empty or numeric suffixes pass
  // through for the allowlist strip; IPv6 literals keep their colons above.
  // Mirrors validateExactHost.
  if (!trimmed.startsWith("[")) {
    const colonCount = (trimmed.match(/:/g) ?? []).length;
    if (colonCount === 1) {
      const colon = trimmed.indexOf(":");
      const suffix = trimmed.slice(colon + 1);
      if (!/^[0-9]*$/.test(suffix)) {
        return `must be a host with an optional numeric port (got '${entry}'); list exact hosts instead`;
      }
    }
  }
  // Fail closed on a trailing FQDN dot: the gate compares exact normalized
  // hosts, so `example.com.` would never match `example.com` yet read as
  // allowed. Mirrors validateExactHost.
  if (trimmed.endsWith(".")) {
    return `must not end with '.' (got '${entry}'); list the host without the trailing dot instead`;
  }
  const normalized = normalizeServerAllowedHost(trimmed);
  if (!normalized) {
    return "must not contain empty strings";
  }
  return null;
}

// Validates the full allowed_hosts list: bounded count plus per-entry
// exact-only rules so a bad line points at its editor line with its number.
export function validateServerAllowedHosts(hosts: string[]): string | null {
  if (hosts.length > MAX_SERVER_ALLOWED_HOSTS) {
    return `Allowed hosts must contain at most ${MAX_SERVER_ALLOWED_HOSTS} entries (got ${hosts.length}).`;
  }
  for (let i = 0; i < hosts.length; i += 1) {
    const problem = validateServerAllowedHost(hosts[i]);
    if (problem) {
      return `Line ${i + 1}: ${problem}`;
    }
  }
  return null;
}

// Whether a trimmed hostname carries a `:port` suffix. Bracketed literals keep
// their brackets and only a colon plus numeric port after `]` marks a port,
// while unbracketed values with more than one colon are IPv6 literals that
// keep their colons. Mirrors RuneWeaverConfig.isHostWithPortSuffix so a
// `host:port` spelling fails closed here instead of persisting a hostname the
// Host gate would never match.
function isServerHostnameWithPortSuffix(trimmed: string): boolean {
  if (trimmed.startsWith("[")) {
    const close = trimmed.indexOf("]");
    if (close === -1) return false;
    const after = trimmed.slice(close + 1);
    if (!after.startsWith(":")) return false;
    const portPart = after.slice(1);
    return portPart.length > 0 && /^[0-9]+$/.test(portPart);
  }
  const colonCount = (trimmed.match(/:/g) ?? []).length;
  if (colonCount !== 1) return false;
  const colon = trimmed.indexOf(":");
  const suffix = trimmed.slice(colon + 1);
  if (suffix.length === 0) return true;
  return /^[0-9]+$/.test(suffix);
}

// Validates one server.hostname value against the exact-only Host semantics the
// gate enforces, mirroring RuneWeaverConfig.validateServerHostname so a bad bind
// fails closed in the form before any network write. Shares the allowed_hosts
// widening shapes (scheme, wildcards, CIDR, userinfo, query, whitespace,
// controls, unbalanced brackets, brackets around a non-IPv6 host, trailing
// dot) while hostname wording stays singular and a `:port` suffix is rejected
// because the port lives in server.port.
export function validateServerHostname(entry: string): string | null {
  const trimmed = entry.trim();
  if (!trimmed) return "must not be empty";
  if (trimmed.length > MAX_SERVER_ALLOWED_HOST_LENGTH) {
    return `must not exceed ${MAX_SERVER_ALLOWED_HOST_LENGTH} characters (got ${trimmed.length})`;
  }
  const lowered = trimmed.toLowerCase();
  if (lowered.includes("://")) {
    return `must not contain a scheme (got '${entry}'); list the host instead`;
  }
  if (lowered === "*") {
    return `must not contain bare "*" (would allow every host)`;
  }
  if (lowered.includes("*")) {
    return `must not contain wildcards (got '${entry}'); list the host instead`;
  }
  if (lowered.includes("/")) {
    return `must not contain CIDR or paths (got '${entry}'); list the host instead`;
  }
  if (trimmed.includes("@")) {
    return `must not contain userinfo (got '${entry}')`;
  }
  if (trimmed.includes("?") || trimmed.includes("#")) {
    return `must be a host without query or fragment (got '${entry}')`;
  }
  if (trimmed.includes(" ") || trimmed.includes("\t")) {
    return `must not contain whitespace (got '${entry}')`;
  }
  if ([...trimmed].some((ch) => { const code = ch.charCodeAt(0); return code < 0x20 || code === 0x7f; })) {
    return `must not contain control characters (got '${entry}')`;
  }
  // Single-sourced bracket shape so a future IPv6 spelling change stays in
  // lockstep with the server 400.
  const bracketProblem = validateBracketedHost(trimmed, entry);
  if (bracketProblem) {
    return bracketProblem;
  }
  // Fail closed on unbracketed `host:suffix` with a non-numeric suffix:
  // normalization strips only an empty or numeric port, so `evil.com:evil`
  // would otherwise persist verbatim garbage. Empty or numeric suffixes pass
  // through for the port-suffix rejection below; IPv6 literals keep their
  // colons above. Mirrors validateExactHost.
  if (!trimmed.startsWith("[")) {
    const colonCount = (trimmed.match(/:/g) ?? []).length;
    if (colonCount === 1) {
      const colon = trimmed.indexOf(":");
      const suffix = trimmed.slice(colon + 1);
      if (!/^[0-9]*$/.test(suffix)) {
        return `must be a host without a port (got '${entry}'); configure the port via server.port instead`;
      }
    }
  }
  if (trimmed.endsWith(".")) {
    return `must not end with '.' (got '${entry}'); list the host without the trailing dot instead`;
  }
  if (isServerHostnameWithPortSuffix(trimmed)) {
    return `must be a host without a port (got '${entry}'); configure the port via server.port instead`;
  }
  const normalized = normalizeServerAllowedHost(trimmed);
  if (!normalized) {
    return "must not be empty";
  }
  return null;
}

// Textarea mirror of the empty allowed-hosts defaults so the Network editor
// starts from the same empty allowlist without joining inline in every caller.
export const DEFAULT_SERVER_ALLOWED_HOSTS_TEXT = "";

// Parses the allowed-hosts textarea into the wire shape, one exact host per
// line with blank lines ignored, so an emptied editor reads as an explicit
// empty allowlist instead of persisting whitespace-only rows.
export function parseServerAllowedHostsText(
  text: string | undefined | null,
): string[] {
  return parseLinesToList(text, []);
}

// Formats an allowed-hosts array for the multiline editor, falling back to
// the empty allowlist when an older engine omits the [server] section so the
// textarea and array states never diverge on the default boundary.
export function formatServerAllowedHostsText(
  hosts: string[] | undefined | null,
): string {
  return formatListToText(hosts, DEFAULT_SERVER_ALLOWED_HOSTS_TEXT);
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
  ".git-credentials",
  ".gitcookies",
  ".rclone.conf",
  ".npmrc",
  ".pypirc",
  ".Xauthority",
  ".emulator_console_auth_token",
  ".gnupg/*",
  ".kube/*",
  ".docker/*",
  ".config/gcloud/*",
  ".chia_keys/*",
  "*_history",
  ".zsh_sessions/*",
];

// Manual mirror of FilesConfig.defaultAllowRoots (`~` = home); update by
// hand alongside the Swift default.
export const DEFAULT_FILES_ALLOW_ROOTS: string[] = ["~"];

// Textarea mirror of the deny defaults so the blocked-paths editor starts from the same guard
// boundary without joining inline in every caller.
export const DEFAULT_FILES_DENY_PATTERNS_TEXT: string =
  DEFAULT_FILES_DENY_PATTERNS.join("\n");

// Parses the blocked-paths textarea into the wire shape, defaulting to the
// files guard boundary when no text is present.
export function parseDenyPatternsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, DEFAULT_FILES_DENY_PATTERNS);
}

// Formats a deny array for the multiline editor, falling back to the guard
// defaults when an older engine omits the [files] section entirely.
export function formatDenyPatternsText(
  patterns: string[] | undefined | null
): string {
  return formatListToText(patterns, DEFAULT_FILES_DENY_PATTERNS_TEXT);
}

// Textarea mirror of the allow-roots defaults so the allowed-roots editor starts from the same
// guard boundary without joining inline in every caller.
export const DEFAULT_FILES_ALLOW_ROOTS_TEXT: string =
  DEFAULT_FILES_ALLOW_ROOTS.join("\n");

// Parses the allowed-roots textarea into the wire shape, defaulting to the
// files guard boundary when no text is present.
export function parseAllowRootsText(text: string | undefined | null): string[] {
  return parseLinesToList(text, DEFAULT_FILES_ALLOW_ROOTS);
}

// Formats an allow-roots array for the multiline editor, falling back to the
// guard defaults when an older engine omits the [files] section entirely.
export function formatAllowRootsText(
  roots: string[] | undefined | null
): string {
  return formatListToText(roots, DEFAULT_FILES_ALLOW_ROOTS_TEXT);
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

// Reads the local index status: counts, bytes, per-source enablement, recent
// failures, the last watermark, and live run state. A missing store or
// coordinator reports an honest zeroed snapshot instead of failing, so a stock
// install still renders an empty state.
export function getIndexStatus(): Promise<IndexStatusResponse> {
  return fetchJson<IndexStatusResponse>("/index/status");
}

// Milliseconds elapsed since the last successful index watermark, or null when
// the store has never been indexed. The status dashboard renders this as the
// watermark-age card through the shared relative-time ladder instead of
// re-parsing the wire shape (ISO-8601 string or Unix seconds) per render; a
// future-skewed timestamp clamps to zero so the label reads "just now".
export function indexWatermarkAgeMs(
  value: string | number | null | undefined,
): number | null {
  if (value == null) return null;
  const time = parseRunTimestamp(value).getTime();
  if (Number.isNaN(time) || time <= 0) return null;
  const age = Date.now() - time;
  return age < 0 ? 0 : age;
}

// Starts an on-demand index run and awaits its terminal summary. Progress rides
// the shared `tool_progress` WebSocket frames while the run is in flight.
export function runIndex(): Promise<IndexRunResponse> {
  return fetchJson<IndexRunResponse>("/index/run", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Asks an in-flight run to stop at its next safe point. The boolean reports
// whether a run was actually in flight when cancellation was requested.
export function cancelIndex(): Promise<IndexCancelResponse> {
  return fetchJson<IndexCancelResponse>("/index/cancel", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Removes documents older than the cutoff. The cutoff is required so a bare
// prune cannot silently clear the store; callers must pass an explicit date.
export function pruneIndex(before: string | number): Promise<IndexPruneResponse> {
  return fetchJson<IndexPruneResponse>("/index/prune", {
    method: "POST",
    body: JSON.stringify({ before }),
  });
}

// Clears the index store; the route fails instead of claiming a partial clear.
export function resetIndex(): Promise<IndexResetResponse> {
  return fetchJson<IndexResetResponse>("/index/reset", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Compacts the index database and reports the on-disk size before and after
// so the pane can show both figures. The counters are on-disk bytes
// (database file plus write-ahead log) so the result reads within ~1% of `du`.
export function reclaimIndex(): Promise<IndexReclaimResponse> {
  return fetchJson<IndexReclaimResponse>("/index/reclaim", {
    method: "POST",
    body: JSON.stringify({}),
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
  const safeClientStartMs = Number.isFinite(clientStartMs) ? clientStartMs : 0;
  const safeNowMs = Number.isFinite(nowMs) ? nowMs : 0;
  const baseMs =
    startedAtSeconds != null && Number.isFinite(startedAtSeconds) && startedAtSeconds > 0
      ? startedAtSeconds * 1000
      : safeClientStartMs;
  return Math.max(0, Math.floor((safeNowMs - baseMs) / 1000));
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

export interface SecretStatusResponse {
  status: Record<string, boolean>;
}

export function storeSecret(key: string, secret: string): Promise<void> {
  return fetchJson<void>("/settings/secrets", {
    method: "POST",
    body: JSON.stringify({ key, secret }),
  });
}

export async function checkSecretStatus(
  keys: string[],
): Promise<Record<string, boolean>> {
  if (keys.length === 0) return {};
  const response = await fetchJson<SecretStatusResponse>(
    "/settings/secrets/status",
    {
      method: "POST",
      body: JSON.stringify({ keys }),
    },
  );
  return response?.status ?? {};
}

export function deleteSecret(key: string): Promise<void> {
  return fetchJson<void>(`/settings/secrets/${encodeURIComponent(key)}`, {
    method: "DELETE",
  });
}

export interface StagedFile {
  path: string;
  stagingPath: string;
  diff: string;
  additions: number;
  deletions: number;
  updatedAt?: string;
}

export interface StagedFilesResponse {
  files: StagedFile[];
}

export interface FileActionResponse {
  status: string;
  count?: number;
}

export async function getStagedFiles(path?: string): Promise<StagedFilesResponse> {
  const url = path ? `/files/staged?path=${encodeURIComponent(path)}` : "/files/staged";
  return fetchJson<StagedFilesResponse>(url);
}

// Accepts one staged file (or all when `all` is true). The optional signal
// lets inline review cards bound the request with a client-side timeout so a
// hung engine walk cannot leave the card in a perpetual loading state.
export async function acceptStagedFile(path?: string, all?: boolean, signal?: AbortSignal): Promise<FileActionResponse> {
  return fetchJson<FileActionResponse>("/files/accept", {
    method: "POST",
    body: JSON.stringify({ path, all }),
    signal,
  });
}

// Discards one staged file (or all when `all` is true). Mirrors the accept
// timeout contract above so discard cards share the same abort behavior.
export async function discardStagedFile(path?: string, all?: boolean, signal?: AbortSignal): Promise<FileActionResponse> {
  return fetchJson<FileActionResponse>("/files/discard", {
    method: "POST",
    body: JSON.stringify({ path, all }),
    signal,
  });
}



