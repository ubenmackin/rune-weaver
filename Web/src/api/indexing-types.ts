// Rune Weaver Dashboard — Indexing models, status shapes, and run outcome helpers.
import { formatRelativeAgo } from "../relativeTime";
import type { RunLogEntry } from "./types";
import { parseRunTimestamp } from "./types";
import type { IndexConfigData } from "./settings-types";
import { formatListToText, parseLinesToList } from "./settings-sandbox";


// One source's enablement row on `GET /index/status`. Global enablement gates
// every row server-side, so a source reads as live only when the indexer as a
// whole is on.
export type IndexSourceAccess =
  | "granted"
  | "denied"
  | "notDetermined"
  | "unavailable";

export interface IndexSourceStatus {
  kind: string;
  enabled: boolean;
  // Access posture observed server-side with silent reads at status build
  // time. Optional because older engines predate access reporting; absent
  // degrades to granted so older payloads keep today's pill colors.
  access?: IndexSourceAccess | null;
}

// Normalizes any wire access token to the known set: exact known tokens pass
// through, while absent or drifted shapes degrade to granted so older engines
// keep today's green instead of failing the status row.
export function normalizeIndexSourceAccess(value: unknown): IndexSourceAccess {
  if (typeof value !== "string") return "granted";
  const token = value.trim();
  if (
    token === "granted" ||
    token === "denied" ||
    token === "notDetermined" ||
    token === "unavailable"
  ) {
    return token;
  }
  return "granted";
}

// Resolves the effective access posture for one source row: the normalized
// wire token, defaulting to granted when the row or the field is absent so
// payloads built against an older engine stay green.
export function resolveIndexSourceAccess(
  source: Pick<IndexSourceStatus, "access"> | null | undefined,
): IndexSourceAccess {
  if (!source || typeof source !== "object") return "granted";
  return normalizeIndexSourceAccess(
    (source as { access?: unknown }).access,
  );
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

// Display labels for index run triggers.
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

// Extracts the machine-readable trigger token from an index run log row.
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

// Per-source outcome on run-status payloads, mirroring the engine `IndexSourceRunOutcome`. Counts
// degrade to zero and `didRun` degrades to the absence of a skip reason so drifted rows never fail
// the strip.
export interface IndexSourceRunOutcome {
  kind: string;
  didRun?: boolean | null;
  scanned?: number | null;
  indexed?: number | null;
  skippedReason?: string | null;
}

// Resolves the per-source outcome list from any run shape under canonical `sources`.
export function resolveIndexSourceOutcomes(
  run:
    | Pick<IndexLastRunStatus, "sources">
    | Pick<IndexRunResponse, "sources">
    | { sources?: unknown }
    | null
    | undefined,
): IndexSourceRunOutcome[] {
  if (!run || typeof run !== "object") return [];
  const record = run as { sources?: unknown };
  const candidate = Array.isArray(record.sources) ? record.sources : null;
  if (!candidate) return [];
  const cleaned: IndexSourceRunOutcome[] = [];
  for (const entry of candidate) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    const kind = typeof row.kind === "string" ? row.kind.trim() : "";
    if (!kind) continue;
    const rawDidRun =
      typeof row.didRun === "boolean"
        ? row.didRun
        : typeof row.did_run === "boolean"
          ? row.did_run
          : undefined;
    const rawSkipped =
      typeof row.skippedReason === "string"
        ? row.skippedReason
        : typeof row.skipped_reason === "string"
          ? row.skipped_reason
          : null;
    const skippedReason =
      typeof rawSkipped === "string" && rawSkipped.trim()
        ? rawSkipped.trim()
        : null;
    const didRun = rawDidRun ?? (skippedReason == null);
    const scanned =
      typeof row.scanned === "number" && Number.isFinite(row.scanned) && row.scanned >= 0
        ? Math.floor(row.scanned)
        : 0;
    const indexed =
      typeof row.indexed === "number" && Number.isFinite(row.indexed) && row.indexed >= 0
        ? Math.floor(row.indexed)
        : 0;
    cleaned.push({ kind, didRun, scanned, indexed, skippedReason });
  }
  return cleaned;
}

// Finds one source outcome by kind, or null when the run carried none.
export function indexSourceOutcomeForKind(
  run:
    | Pick<IndexLastRunStatus, "sources">
    | Pick<IndexRunResponse, "sources">
    | { sources?: unknown }
    | null
    | undefined,
  kind: string,
): IndexSourceRunOutcome | null {
  if (typeof kind !== "string" || !kind.trim()) return null;
  const wanted = kind.trim().toLowerCase();
  for (const outcome of resolveIndexSourceOutcomes(run)) {
    if (outcome.kind.trim().toLowerCase() === wanted) return outcome;
  }
  return null;
}

// Resolves the muted note for one source bar: the verbatim skip reason when
// its last run did not run, otherwise null so all-run passes show no notes.
export function resolveIndexSourceSkippedReason(
  run:
    | Pick<IndexLastRunStatus, "sources">
    | Pick<IndexRunResponse, "sources">
    | { sources?: unknown }
    | null
    | undefined,
  kind: string,
): string | null {
  const outcome = indexSourceOutcomeForKind(run, kind);
  if (!outcome) return null;
  if (outcome.didRun !== false) return null;
  const reason = outcome.skippedReason;
  if (typeof reason !== "string" || !reason.trim()) return null;
  return reason.trim();
}

// Latest index run outcome on `GET /index/status`, distilled server-side from the newest
// `index`-kind run log row.
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
  // Per-source outcomes on the canonical `sources` key. Optional for back-compat; absent degrades
  // to no per-source notes instead of failing.
  sources?: IndexSourceRunOutcome[] | null;
}

export interface IndexLiveSourceStatus {
  kind: string;
  state: "running" | "completed";
  scanned: number;
  indexed: number;
  current?: string | null;
}

export interface IndexLiveQueueLane {
  lane: string;
  label: string;
  queued: number;
  processed: number;
  indexed: number;
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
  vectorChunks?: number | null;
  keywordChunks?: number | null;
  sources?: IndexLiveSourceStatus[] | null;
  queues?: IndexLiveQueueLane[] | null;
}

// Resolved effort block on `GET /index/status`, mirroring the engine `IndexEffortStatus`.
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

// Storage breakdown for `GET /index/storage`: byte-exact totals plus per-source document, chunk,
// and byte rows from the slow aggregate pass.
export interface IndexStorageResponse {
  bytes?: number | null;
  textBytes?: number | null;
  vectorBytes?: number | null;
  ftsBytes?: number | null;
  freeBytes?: number | null;
  dbFileBytes?: number | null;
  walBytes?: number | null;
  contentBytes?: number | null;
  bySource?: IndexSourceCounts[];
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
  // Per-source outcomes on the canonical `sources` key. Optional for back-compat; absent degrades
  // to no per-source notes instead of failing.
  sources?: IndexSourceRunOutcome[] | null;
}

// Outcome of `POST /index/cancel`.
export interface IndexCancelResponse {
  cancelled: boolean;
}

// Normalized run description shared by the top run notice and the last-run strip.
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

// Resolves the retired count from any run shape, accepting both `retiredCount` and the `retired`
// alias some engines emit.
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

// Resolves the truncated count from any run shape, accepting both `truncatedCount` and the
// `truncated` alias some engines emit.
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

// Explicit type-guard distinguishing the terminal run summary from the status strip and shared
// description shapes.
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

// Single owner for every integer count on the Index Status page.
export function formatIndexCount(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return "0";
  const floored = Math.floor(value);
  if (floored >= 10000) return floored.toLocaleString("en-US");
  return String(floored);
}

// One-line human summary of an index run shared by the top notice and the last-run strip: status
// plus the trigger display label, outcome counts, and run age, omitting any count the payload did
// not carry so a drifted payload still renders its status and time.
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

// Closed set of valid `effort` preset ids, mirroring IndexConfig.allowedEfforts without `custom`.
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
// Default custom worker count used when `effort` is `custom` and no stored value exists yet.
export const DEFAULT_INDEX_WORKERS = 4;
// Static ceiling for a `custom` worker count, mirroring IndexConfig.maxAllowedWorkers.
export const INDEX_MAX_CUSTOM_WORKERS = 64;
// Default exclude patterns, mirroring IndexConfig.defaultExcludePatterns
// (Sources/RuneWeaverCore/IndexConfig.swift).
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

// Default index policy values mirroring IndexConfig so a fresh form matches the boundary the engine
// enforces before the first settings fetch.
export const DEFAULT_INDEX_CONFIG: IndexConfigData = {
  enabled: false,
  files: true,
  mail: false,
  messages: false,
  calendars: false,
  reminders: false,
  roots: ["~"],
  exclude: [...DEFAULT_INDEX_EXCLUDE_PATTERNS],
  maxFileMB: 20,
  mailVectorWindow: "2y",
  iCloudEvicted: "skip",
  nightlyBudget: 0,
  dbPath: "~/.runeweaver/index.db",
  effort: DEFAULT_INDEX_EFFORT,
  workers: 0,
  thermalBackoff: DEFAULT_INDEX_THERMAL_BACKOFF,
  pauseOnBattery: DEFAULT_INDEX_PAUSE_ON_BATTERY,
  maxVectorChunksPerDocument: DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
  mailboxDeny: [...DEFAULT_INDEX_MAILBOX_DENY],
};

// Milliseconds elapsed since the last successful index watermark, or null when the store has never
// been indexed.
export function indexWatermarkAgeMs(
  value: string | number | null | undefined,
): number | null {
  if (value == null) return null;
  const time = parseRunTimestamp(value).getTime();
  if (Number.isNaN(time) || time <= 0) return null;
  const age = Date.now() - time;
  return age < 0 ? 0 : age;
}
