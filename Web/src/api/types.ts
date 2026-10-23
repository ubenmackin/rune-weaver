// Rune Weaver Dashboard — Shared core types, models, and helpers.
import { isRecord } from "../typeGuards";

export type TrustDuration =
  | "thisTime"
  | "forTask"
  | "forSession"
  | "fiveMinutes"
  | "oneHour"
  | "oneDay"
  | "forever";

export const trustDurationOptions: Array<{ value: TrustDuration; label: string }> = [
  { value: "thisTime", label: "Only this time" },
  { value: "forTask", label: "For rest of this task" },
  { value: "forSession", label: "For rest of this session" },
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
  // Verified system-pulse fields from the engine snapshot. Optional because older engines predate
  // the pulse; absent means unknown and the card falls back to its default reading.
  ledgerTip?: string | null;
  // Last explicit ledger verification as Unix seconds, mirroring searchStartedAt. Absent until
  // an explicit verification is stamped.
  ledgerVerifiedAt?: number | null;
  policyHash?: string | null;
  policyVerified?: boolean;
  // Collapsed probe verdict ("pass", "degraded", or "fail"). Absent before any probe reports.
  probeVerdict?: string | null;
  // Bounded backing reasons for a non-green status, driving the card disclosure.
  degradedReasons?: string[];
  // Bounded info notes that never move the dot, driving the Details disclosure
  // alongside reasons. Optional because older engines predate the countdown;
  // absent means no info to disclose.
  infoNotes?: string[];
  // Mapped recovery for a red pulse ("none", "rebaseline", "openInbox", "openPolicy").
  // Optional because older engines predate the mapping; absent means the card
  // derives it from the reason text under the same priority.
  remediation?: string | null;
  // Authoritative turn cap advertised by the engine on GET /health. Optional because older
  // engines predate the advertisement and because getHealth injects it from the response
  // header when the JSON body carries none; absent degrades to MAX_CONCURRENT_CHAT_TURNS.
  maxConcurrentChatTurns?: number | null;
}

export type ToolErrorKind =
  | "invalid_tool"
  | "invalid_syntax"
  | "execution_error"
  | "uncertain_outcome"
  | "idempotency_blocked";

export interface ToolResult {
  toolCallID: string;
  content: string;
  isError: boolean;
  errorKind?: ToolErrorKind | null;
  exitCode?: number | null;
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

// Ordered timeline pieces for one assistant turn. Text and tool batches alternate chronologically
// (text, tools, text, tools, text) so multi-round turns never collapse into a single lumped bucket.
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

// Single non-negative integer contract shared by live token frames, terminal counters, and cached
// bases so a fractional or negative payload degrades to absent instead of rendering a floored value
// on one path and rejecting on another.
export function toNonNegativeInt(value: unknown): number | undefined {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    Number.isInteger(value) &&
    value >= 0
    ? value
    : undefined;
}

// Live progress for one executing tool, mirrored from the engine's throttled `tool_progress` frame.
export interface ToolProgress {
  callID: string;
  toolName: string;
  // Human scope copy the engine composes (for example "Find *.txt in ~").
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

// Normalizes a progress tail the same way the engine's ToolProgress.relativeCurrent does: trim,
// drop blank, refuse anything that could disclose an absolute location or climb outside its root,
// then cap for display.
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

// Shared trimmed-identity guard for tool frames: a tool identity without non-whitespace characters
// cannot correlate with its end frame or approval, so it must never enter turn state.
export function isValidToolIDs(toolName: unknown, callID: unknown): boolean {
  return (
    typeof toolName === "string" &&
    typeof callID === "string" &&
    toolName.trim().length > 0 &&
    callID.trim().length > 0
  );
}

// Validates one live progress frame before it enters the keyed map.
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

// Compares two actions chronologically: numbered rounds ascend oldest-first with untracked rounds
// partitioning after tracked so mixed untracked+tracked history holds a total order.
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

// Groups actions into one tools segment per round, oldest round first.
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
  // renders after R1 just because untracked actions interleaved it.
  const orderedRounds = [...byRound.keys()].sort((a, b) => a - b);
  const groups = orderedRounds.map(
    (round) => byRound.get(round) as ToolAction[],
  );
  // Untracked actions trail every numbered round to match the sorted
  // total order; a missing bucket stays absent rather than emitting empties.
  if (untracked.length > 0) {
    groups.push([...untracked]);
  }
  return groups;
}

export interface RecallDiagnostics {
  // Per-hit source names in rank order, never hit content.
  sources: string[];
  // True when the document index was skipped for this pass.
  skippedDocIndex: boolean;
  // Total injected hits, always equal to sources.length on encode.
  hitCount: number;
  // Per-tier tallies derived from sources.
  countsBySource: Record<string, number>;
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
  // Completion time on the server clock for this turn.
  completedAt?: string | number | null;
  // Content-free recall counts plus source names plus skip flag for the chip.
  // Optional because older engines predate the chip; absent renders no chip.
  recallDiagnostics?: RecallDiagnostics | null;
}

// Maximum per-hit sources accepted from the wire, pinned to the engine's
// RecallBudgets limit bounds (1...50) so a handcrafted frame cannot smuggle
// an unbounded list into the chip.
const MAX_RECALL_SOURCES = 50;

// Maximum source label length retained for display, keeping a handcrafted
// tier name from smuggling hit text into the chip.
const MAX_RECALL_SOURCE_LENGTH = 32;

// Normalizes one recall source label: trims, drops blanks, and caps length
// so a drifted or handcrafted value degrades to absent rather than rendering
// hit text smuggled through the tier slot.
function normalizeRecallSource(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.slice(0, MAX_RECALL_SOURCE_LENGTH);
}

// Tallies one count per source value so collapsed and expanded copies agree
// without a second derivation drifting.
function talliedRecallCounts(sources: string[]): Record<string, number> {
  const tallied: Record<string, number> = {};
  for (const source of sources) {
    tallied[source] = (tallied[source] ?? 0) + 1;
  }
  return tallied;
}

// Validates one recall diagnostics block before it enters turn state. Absent blocks degrade to null
// so older engines render no chip, while drifted shapes degrade the same way instead of failing the
// turn.
export function parseRecallDiagnostics(value: unknown): RecallDiagnostics | null {
  if (value === undefined || value === null) return null;
  if (!isRecord(value)) return null;
  const rawSources = value.sources;
  if (!Array.isArray(rawSources)) return null;
  const sources: string[] = [];
  for (const entry of rawSources) {
    const normalized = normalizeRecallSource(entry);
    if (normalized) sources.push(normalized);
    if (sources.length >= MAX_RECALL_SOURCES) break;
  }
  const rawSkipped = value.skippedDocIndex;
  if (rawSkipped !== undefined && rawSkipped !== null && typeof rawSkipped !== "boolean") return null;
  const skippedDocIndex = rawSkipped === true;
  const rawHitCount = toNonNegativeInt(value.hitCount);
  const hitCount = rawHitCount ?? sources.length;
  const rawCounts = value.countsBySource;
  let countsBySource: Record<string, number>;
  if (rawCounts === undefined || rawCounts === null) {
    countsBySource = talliedRecallCounts(sources);
  } else {
    if (!isRecord(rawCounts)) return null;
    countsBySource = {};
    for (const [key, count] of Object.entries(rawCounts)) {
      const normalizedKey = normalizeRecallSource(key);
      const normalizedCount = toNonNegativeInt(count);
      if (!normalizedKey || normalizedCount === undefined) return null;
      countsBySource[normalizedKey] = normalizedCount;
    }
  }
  return { sources, skippedDocIndex, hitCount, countsBySource };
}

// Reports whether a diagnostics block deserves a chip: any injected hit or a
// skipped index. Zero-hit unskipped turns and absent blocks render nothing so
// older engines and silent recalls cause no layout shift.
export function isRecallDiagnosticsVisible(
  diagnostics: RecallDiagnostics | null | undefined,
): boolean {
  if (!diagnostics) return false;
  if (diagnostics.skippedDocIndex) return true;
  return diagnostics.sources.length > 0 || diagnostics.hitCount > 0;
}

// Collapsed chip copy: recalled counts per source plus skipped state.
export function formatRecallCollapsed(
  diagnostics: RecallDiagnostics,
): string {
  const tallied =
    Object.keys(diagnostics.countsBySource).length > 0
      ? diagnostics.countsBySource
      : talliedRecallCounts(diagnostics.sources);
  const entries = Object.entries(tallied).sort(([a], [b]) => a.localeCompare(b));
  const total = diagnostics.hitCount ?? diagnostics.sources.length;
  if (entries.length === 0) {
    const base = total > 0 ? `Recalled ${total}` : "Recalled 0";
    return diagnostics.skippedDocIndex ? `${base} · index skipped` : base;
  }
  const parts = entries.map(([source, count]) => `${count} ${source}`);
  const base = `Recalled ${parts.join(" · ")}`;
  return diagnostics.skippedDocIndex ? `${base} · index skipped` : base;
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
  egressHost?: string | null;
  // Engine-derived display target naming what "this target" covers. Optional
  // because payloads written before the field carry no key; absent degrades to
  // the fallback argument scan in approvalsShared.
  displayTarget?: string | null;
  sandboxSummary?: string | null;
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

// Scope one durable rule or one decision covers: the discriminator plus only the per-kind fields
// that name what trust reaches.
export type AccessScopeDTO =
  | { kind: "tool" }
  | { kind: "exactTarget"; target: string }
  | { kind: "recipientSet"; handles: string[] }
  | { kind: "domain"; host: string; subdomains?: boolean };

// Shared scope-text check: a scope field must carry visible characters, so a
// blank or whitespace-only value names no target and fails the guard.
function isScopeText(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

// Reports whether a value is a well-formed scope DTO: a known kind plus the per-kind fields that
// kind requires.
export function isAccessScope(value: unknown): value is AccessScopeDTO {
  if (!isRecord(value)) return false;
  const kind = value.kind;
  if (typeof kind !== "string") return false;
  switch (kind) {
    case "tool":
      return true;
    case "exactTarget":
      return isScopeText(value.target);
    case "recipientSet":
      return (
        Array.isArray(value.handles) &&
        value.handles.length > 0 &&
        value.handles.every((handle) => isScopeText(handle))
      );
    case "domain":
      return (
        isScopeText(value.host) &&
        (value.subdomains === undefined || typeof value.subdomains === "boolean")
      );
    default:
      return false;
  }
}

// Effect a durable access rule carries: an allow rule keeps a matching call auto-approved until it
// expires or is revoked, while a deny rule parks the matching call every time.
export type AccessRuleEffect = "allow" | "deny";

// Durable access rule minted from a non-thisTime decision or from the rules surface: one row per
// tool-plus-scope pair that stays auto-approved (or parked, for a deny rule) until revoked or
// expired.
export interface AccessRule {
  id: string;
  toolName: string;
  tool?: string;
  scope: AccessScopeDTO;
  effect: AccessRuleEffect;
  action?: AccessRuleEffect;
  // Creation time in either wire shape the engine emits: ISO-8601 strings from older payloads
  // or Unix seconds as JSON numbers from SQLite persistence. Kept as a union so callers
  // normalize through parseRunTimestamp instead of assuming one encoding.
  grantedAt: string | number;
  // Expiry in either wire shape, or null for the forever tier which never expires. Null must
  // survive as "forever" through every UI path rather than collapsing to the epoch.
  expiresAt: string | number | null;
  duration?: TrustDuration | null;
  // Auto-approved hit count so the inbox can distinguish untouched rules from exercised
  // trust without re-deriving it from run history. Zero means the rule never fired. Optional
  // because rows minted before usage tracking omit the key; absent degrades to untouched.
  useCount?: number;
  // Last auto-approved use in either wire shape, or null when the rule never fired.
  lastUsedAt?: string | number | null;
  reason?: string | null;
  displayScope?: string;
}

export interface AccessRulesResponse {
  rules: AccessRule[];
  count: number;
}

// One ephemeral (never-persisted) grant a session still carries: the thisTime, forTask, and
// forSession tiers that expire with their turn, task, or session instead of surviving into the
// durable rule store.
export interface EphemeralGrantDTO {
  toolName: string;
  scope: AccessScopeDTO;
  duration: TrustDuration;
  grantedAt: string | number;
  // Expiry in the same dual wire shape as a durable rule, or null when the
  // tier runs to the end of its task or session rather than to a clock time.
  expiresAt: string | number | null;
  // Hit counters ride the same optional contract as a durable rule so the
  // session view proves an exercised grant without a second derivation.
  useCount?: number;
  lastUsedAt?: string | number | null;
}

// Session trust view: the ephemeral grants one session still carries, listed so
// the dashboard can show what stays auto-approved for the rest of the session
// without re-deriving it from run history.
export interface SessionTrustResponse {
  sessionID: string;
  grants: EphemeralGrantDTO[];
  count: number;
}

// Creation request for the rules surface. The tool plus effect plus scope plus
// tier fully describe the rule, so the client validates the whole shape before
// the wire instead of asking the engine to store a half-described rule.
export interface NewAccessRuleInput {
  tool?: string;
  toolName?: string;
  effect?: AccessRuleEffect;
  action?: AccessRuleEffect;
  scope: AccessScopeDTO;
  duration?: TrustDuration;
  reason?: string;
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

export interface RunLogEntry {
  id: string;
  jobID?: string | null;
  // Owning chat session when the run came from an interactive turn;
  // absent on older payloads, so callers must handle unattributed runs.
  sessionID?: string | null;
  // Linked goal when the run works toward a tracked one.
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

// Compact run duration shared by every run-history surface: the scheduler history, the run log, the
// run detail modal, and the goal drawer's linked runs.
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

// Fallback for how many interactive turns may run at once across sessions.
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
  return `Already running ${limit} chat turns. Wait for one to finish or cancel it, then retry.`;
}

// Single web source for the chat text bound, pinned to the engine ChatRequest.maxTextLength (which
// delegates to MemoryEngine.maxContentLength).
export const MAX_CHAT_TEXT_LENGTH = 10000;

// Single source for run-log polling so live badges and history views agree on page size and cadence
// instead of drifting per call site.
export const RUN_LOG_POLL_LIMIT = 50;
export const RUN_POLL_INTERVAL_MS = 2500;

// Reports whether a run row represents an in-flight turn that should keep a session badge lit.
// Single active contract shared by live broadcasts and polled runs: only `running` counts.
export function isActiveRunStatus(status: string | null | undefined): boolean {
  return status === "running";
}

// Collects the owning sessions behind in-flight runs, normalized for case-insensitive comparison
// since the engine formats UUIDs uppercase while the dashboard mints lowercase.
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

// Reports whether any run represents actively-running work that a settings save would interrupt.
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

// Narration placeholder shape persisted by the engine for tool rounds ("Calling <tool> <args>
// [callID]").

// Structured placeholder record mirroring the engine ToolInput triple.
