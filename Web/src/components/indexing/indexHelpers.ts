// Rune Weaver Dashboard — Indexing formatting, error parsing, and donut calculation helpers.

import {
  describeIndexRun,
  formatIndexCount,
  formatToolProgressElapsedMs,
  getIndexStorage,
  indexRunTriggerLabel,
  indexWatermarkAgeMs,
  parseIndexRunTrigger,
  parseRunTimestamp,
  resolveIndexSourceAccess,
  type IndexLastRunStatus,
  type IndexLiveQueueLane,
  type IndexLiveStatus,
  type IndexReclaimResponse,
  type IndexSourceCounts,
  type IndexSourceStatus,
  type IndexStatusResponse,
  type IndexStorageResponse,
} from "../../api";
import type { WSToolProgressFrame } from "../../hooks/useSharedWebSocket";
import { formatRelativeAgo } from "../../relativeTime";

export { formatIndexCount, getIndexStorage, type IndexStorageResponse };

// Engine index source kinds in canonical run order, each with its display label.
// The Messages label carries the Full Disk Access hint because reading the chat
// database requires that grant on macOS.
export const INDEX_SOURCES: Array<{ kind: string; label: string; hint?: string }> = [
  { kind: "files", label: "Files" },
  { kind: "mail", label: "Mail" },
  {
    kind: "messages",
    label: "Messages",
    hint: "Requires Full Disk Access (RuneWeaver.app, or your terminal emulator when running rune-weaver serve), then press Run.",
  },
  { kind: "calendars", label: "Calendars" },
  { kind: "reminders", label: "Reminders" },
];

// Display label for a status source kind, falling back to the engine's wire
// token so an unknown future source still renders honestly.
export function sourceLabel(kind: string): string {
  return INDEX_SOURCES.find((source) => source.kind === kind)?.label ?? kind;
}

// Pill tone for one index source as a pure function of enablement plus access: disabled reads grey,
// enabled plus granted reads green, enabled plus anything else reads amber.
export type IndexSourcePillTone = "ok" | "skipped" | "awaiting_approval";

export function indexSourcePillTone(
  source: Pick<IndexSourceStatus, "enabled" | "access"> | null | undefined,
): IndexSourcePillTone {
  if (!source || !source.enabled) return "skipped";
  return resolveIndexSourceAccess(source) === "granted"
    ? "ok"
    : "awaiting_approval";
}

// Explanatory title for one index source pill: null when the pill reads green
// or grey, otherwise the access reason naming the grant that unblocks it, so
// an amber pill always explains itself on hover.
export function indexSourcePillTitle(
  source: Pick<IndexSourceStatus, "kind" | "enabled" | "access"> | null | undefined,
): string | null {
  if (!source || !source.enabled) return null;
  const access = resolveIndexSourceAccess(source);
  if (access === "granted") return null;
  const kind = typeof source.kind === "string" ? source.kind : "";
  const label = sourceLabel(kind);
  if (access === "unavailable") {
    return `${label} is on but access is unavailable on this device.`;
  }
  if (kind === "messages") {
    if (access === "denied") {
      return `${label} is on but the chat database cannot be read. Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then press Run. The pill turns green on the next poll.`;
    }
    return `${label} is on but Messages access has not been granted yet. Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access.`;
  }
  if (kind === "calendars" || kind === "reminders") {
    const pane = kind === "calendars" ? "Calendars" : "Reminders";
    if (access === "denied") {
      return `${label} is on but ${pane} access was denied. Grant access in System Settings > Privacy & Security > ${pane}. The pill turns green on the next poll, no save needed.`;
    }
    return `${label} is on but ${pane} access has not been granted yet. Allow access when prompted, or grant it in System Settings > Privacy & Security > ${pane}.`;
  }
  return `${label} is on but access is ${access}. Grant access. The pill turns green on the next poll.`;
}

// Whether one source kind supports the explicit access prompt.
export function isPromptableIndexSourceKind(kind: unknown): boolean {
  return kind === "calendars" || kind === "reminders";
}

// Inline Grant affordance shows only for an enabled, amber, undetermined
// calendars/reminders row; denied renders guidance instead so a denial never
// prompts again.
export function shouldShowIndexGrantButton(
  source: Pick<IndexSourceStatus, "kind" | "enabled" | "access"> | null | undefined,
): boolean {
  if (!source || !source.enabled) return false;
  const kind = typeof source.kind === "string" ? source.kind : "";
  if (!isPromptableIndexSourceKind(kind)) return false;
  return resolveIndexSourceAccess(source) === "notDetermined";
}

// Denied guidance replaces the Grant button when the polled status reports
// denied, derived from status truth on every render with no pill-state cache.
export function shouldShowIndexAccessDeniedGuidance(
  source: Pick<IndexSourceStatus, "kind" | "enabled" | "access"> | null | undefined,
): boolean {
  if (!source || !source.enabled) return false;
  const kind = typeof source.kind === "string" ? source.kind : "";
  if (!isPromptableIndexSourceKind(kind)) return false;
  return resolveIndexSourceAccess(source) === "denied";
}

// Settings copy shown in place of the Grant button after a denial.
export function indexAccessDeniedGuidance(kind: string): string {
  const pane = kind === "reminders" ? "Reminders" : "Calendars";
  return `Access denied. Open System Settings > Privacy & Security > ${pane} to grant access.`;
}

// Deep link into the Full Disk Access pane. There is no prompt API for this grant, so the dashboard
// can only open Settings and show copy-paste steps alongside it.
export const FULL_DISK_ACCESS_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

// Whether one status error is the Full Disk Access denial. Matched loosely on
// the shared engine phrase so both the cheap status-probe warning and the
// run-time denial from the run log trigger the same guided onboarding.
export function isFullDiskAccessError(detail: string | null | undefined): boolean {
  if (typeof detail !== "string") return false;
  return /full disk access/i.test(detail);
}

// Whether any status error needs the Full Disk Access guided onboarding. Checked over lastErrors so
// the dashboard surfaces guidance before the next wasted run instead of only after one fails.
export function hasFullDiskAccessError(errors: unknown): boolean {
  if (!Array.isArray(errors)) return false;
  return errors.some((detail) => typeof detail === "string" && isFullDiskAccessError(detail));
}

// Preview budget for one last-error line. Past this length the row renders a
// truncated preview with an expand control so a path-heavy failure cannot
// stretch the status card while the full text stays one click away.
export const INDEX_LAST_ERROR_PREVIEW_CHARS = 180;

// Dedupes the string[] last-errors payload in first-seen order so a repeated
// engine line reads once. Non-string entries degrade to skipped rather than
// rendering a blank row or crashing the slice below.
export function dedupeIndexErrors(errors: unknown): string[] {
  if (!Array.isArray(errors)) return [];
  const seen = new Set<string>();
  const deduped: string[] = [];
  for (const entry of errors) {
    if (typeof entry !== "string") continue;
    if (seen.has(entry)) continue;
    seen.add(entry);
    deduped.push(entry);
  }
  return deduped;
}

// Display list for the last-errors card: deduped lines with the raw Full Disk Access bullet
// suppressed whenever the guided onboarding renders, since the guidance is the formatted form of
// that same failure and keeping both would read as a duplicate.
export function resolveDisplayIndexErrors(errors: unknown): string[] {
  const deduped = dedupeIndexErrors(errors);
  if (hasFullDiskAccessError(deduped)) {
    return deduped.filter((detail) => !isFullDiskAccessError(detail));
  }
  return deduped;
}

// Truncated preview for one long error line, keeping the full text on title
// for hover. Short lines pass through untouched so the common case never
// gains an expand control.
export function truncateIndexError(detail: string): string {
  if (detail.length <= INDEX_LAST_ERROR_PREVIEW_CHARS) return detail;
  return `${detail.slice(0, INDEX_LAST_ERROR_PREVIEW_CHARS)}…`;
}

// Whether one error line needs the expand control. Kept beside the truncate
// helper so the row and the tests share one length rule.
export function isLongIndexError(detail: string): boolean {
  return typeof detail === "string" && detail.length > INDEX_LAST_ERROR_PREVIEW_CHARS;
}

// Short stable digest for one error line, used for React keys so a kilobyte-long failure never
// becomes a full-text key.
export function hashIndexError(detail: string): string {
  let hash = 5381;
  for (let i = 0; i < detail.length; i += 1) {
    hash = ((hash << 5) + hash + detail.charCodeAt(i)) | 0;
  }
  return (hash >>> 0).toString(16);
}

// Tool identity the engine stamps on index progress frames. Progress is only
// adopted while a run is in flight and carrying this name.
export const INDEX_PROGRESS_TOOL_NAME = "index";

// Elapsed floor before the live rate reads honestly: under half a second one document over a few
// milliseconds renders a triple-digit spike, so the line omits the rate until the window is wide
// enough to mean something.
export const INDEX_MIN_HONEST_RATE_ELAPSED_MS = 500;

// Ceiling above which a rate cannot be real work: guards a handcrafted or
// drifted payload the same way the non-finite check does, so the line omits
// the rate instead of rendering an absurd figure.
export const INDEX_MAX_HONEST_RATE = 1000000;

// Documents-per-second for the live block: the engine `live.rate` (indexed documents over elapsed
// time), labeled explicitly as docs work.
export function formatIndexRate(
  rate: number | null | undefined,
  elapsedMs?: number | null,
): string | null {
  if (typeof rate !== "number" || !Number.isFinite(rate)) return null;
  if (rate <= 0 || rate > INDEX_MAX_HONEST_RATE) return null;
  if (
    typeof elapsedMs === "number" &&
    Number.isFinite(elapsedMs) &&
    elapsedMs < INDEX_MIN_HONEST_RATE_ELAPSED_MS
  )
    return null;
  const rounded = rate >= 10 ? Math.round(rate) : Math.round(rate * 10) / 10;
  return `${rounded} docs/s`;
}

// Lane throughput: active rate, completed Done with frozen rate, queued Queued.
// Empty lanes return null so nothing renders.
export function formatLaneRate(lane: IndexLiveQueueLane): string | null {
  const rateText = formatIndexRate(lane.rate);
  const queued = floorPositive(lane.queued);
  const processed = floorPositive(lane.processed);
  const isDone = queued > 0 && processed >= queued;
  if (isDone) {
    return rateText ? `Done (${rateText})` : "Done";
  }
  if (queued > 0 && processed === 0) {
    return "Queued";
  }
  return rateText;
}

// Chart palette drawn from the dashboard theme tokens: the vector segment uses
// the accent purple, the keyword segment the accent blue, and the tracks reuse
// the border color so both charts read as native surfaces without new CSS.
export const CHART_VECTOR_COLOR = "var(--accent-purple)";
export const CHART_KEYWORD_COLOR = "var(--accent-blue)";
export const CHART_TRACK_COLOR = "var(--border-color)";
// Extraction-outcome bars reuse the keyword blue so the breakdown reads as a
// second member of the same chart family without inventing a new hue per status.
export const CHART_EXTRACT_COLOR = "var(--accent-blue)";

// Donut ring geometry in SVG user units: radius 40 inside a 100×100 viewBox
// with a 10-unit stroke leaves an inner hole wide enough for the ring to read
// as a donut rather than a pie.
export const DONUT_RADIUS = 40;
export const DONUT_SIZE = 100;
export const DONUT_STROKE = 10;

// Human-readable byte size with binary units, bounded to one decimal so a large
// index reads compactly without implying precision the count lacks.
export function formatIndexBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const rounded = unit === 0 ? Math.round(value) : Math.round(value * 10) / 10;
  return `${rounded} ${units[unit]}`;
}

// Formats the last successful watermark, or an honest never-indexed label so a
// fresh store never renders an epoch date.
export function formatIndexAsOf(value: string | number | null | undefined): string {
  if (value == null) return "Never indexed";
  const parsed = parseRunTimestamp(value);
  if (Number.isNaN(parsed.getTime()) || parsed.getTime() <= 0) return "Never indexed";
  return parsed.toLocaleString();
}

// Watermark age in plain language: an honest never-indexed label for a fresh
// store, otherwise the shared relative ladder ("3d ago") so the age card reads
// like every other freshness label in the dashboard.
export function formatIndexAge(value: string | number | null | undefined): string {
  const ageMs = indexWatermarkAgeMs(value);
  if (ageMs == null) return "Never indexed";
  return formatRelativeAgo(ageMs);
}

// Donut geometry for the vector-vs-keyword split: both arc lengths around one
// shared ring, with a zero-chunk store collapsing both arcs so the neutral
// track renders instead of dividing by zero.
export function indexDonutArcs(
  vector: number,
  keyword: number,
  radius: number,
): { circumference: number; vectorDash: number; keywordDash: number } {
  const circumference = 2 * Math.PI * radius;
  const vectorCount = Number.isFinite(vector) && vector > 0 ? vector : 0;
  const keywordCount = Number.isFinite(keyword) && keyword > 0 ? keyword : 0;
  const total = vectorCount + keywordCount;
  const vectorDash = total > 0 ? (vectorCount / total) * circumference : 0;
  const keywordDash = total > 0 ? (keywordCount / total) * circumference : 0;
  return { circumference, vectorDash, keywordDash };
}

// Floors a positive finite count to an integer, degrading anything else to
// zero so status totals never render NaN, Infinity, negatives, or fractions.
export function floorPositive(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0;
}

// On-disk storage breakdown for the honest size figure.
export interface IndexStorageBreakdown {
  onDisk: number;
  dbFile: number;
  wal: number;
  text: number;
  vector: number;
  fts: number;
  free: number;
  content: number;
  hasOnDisk: boolean;
  hasBreakdown: boolean;
  hasStorage: boolean;
}

// Sanitized on-disk total: the database file plus the write-ahead log when
// either is present, otherwise the content total so older engines without the
// file sizes still render an honest size instead of zero.
export function resolveIndexOnDiskBytes(
  status: Pick<
    IndexStatusResponse,
    "bytes" | "dbFileBytes" | "walBytes"
  > | null | undefined,
): number {
  if (!status) return 0;
  const dbFile = floorPositive(
    (status as { dbFileBytes?: unknown }).dbFileBytes,
  );
  const wal = floorPositive((status as { walBytes?: unknown }).walBytes);
  if (dbFile > 0 || wal > 0) return dbFile + wal;
  return floorPositive(status.bytes);
}

// Full breakdown for the size card: on-disk primary plus the four storage rows and the content
// secondary.
export function resolveIndexStorageBreakdown(
  status: Pick<
    IndexStatusResponse,
    | "bytes"
    | "dbFileBytes"
    | "walBytes"
    | "textBytes"
    | "vectorBytes"
    | "ftsBytes"
    | "freeBytes"
  > | null | undefined,
  hasStorage = false,
): IndexStorageBreakdown {
  const content = floorPositive(status?.bytes);
  const dbFile = floorPositive(
    (status as { dbFileBytes?: unknown } | null | undefined)?.dbFileBytes,
  );
  const wal = floorPositive(
    (status as { walBytes?: unknown } | null | undefined)?.walBytes,
  );
  const text = floorPositive(
    (status as { textBytes?: unknown } | null | undefined)?.textBytes,
  );
  const vector = floorPositive(
    (status as { vectorBytes?: unknown } | null | undefined)?.vectorBytes,
  );
  const fts = floorPositive(
    (status as { ftsBytes?: unknown } | null | undefined)?.ftsBytes,
  );
  const free = floorPositive(
    (status as { freeBytes?: unknown } | null | undefined)?.freeBytes,
  );
  const hasOnDisk = dbFile > 0 || wal > 0;
  const hasBreakdown = text > 0 || vector > 0 || fts > 0 || free > 0;
  return {
    onDisk: hasOnDisk ? dbFile + wal : content,
    dbFile,
    wal,
    text,
    vector,
    fts,
    free,
    content,
    hasOnDisk,
    hasBreakdown,
    hasStorage,
  };
}

// Compaction result formatted copy for the reclaim banner and status line. Keeps both figures so
// the compaction read without reopening the size card.
export function formatIndexReclaimResult(
  result: Pick<
    IndexReclaimResponse,
    "beforeBytes" | "afterBytes" | "reclaimedBytes"
  > | null | undefined,
): string | null {
  if (!result) return null;
  const before = floorPositive(result.beforeBytes);
  const after = floorPositive(result.afterBytes);
  let reclaimed = floorPositive(result.reclaimedBytes);
  if (before > 0 && after >= 0 && reclaimed <= 0 && before >= after) {
    reclaimed = before - after;
  }
  return `Reclaimed ${formatIndexBytes(reclaimed)} (before ${formatIndexBytes(before)} → after ${formatIndexBytes(after)})`;
}

// Per-source content row joining enablement with real totals: enablement comes from the status
// sources list while documents/chunks/bytes come from the additive bySource aggregates.
export interface IndexSourceContentRow {
  kind: string;
  enabled: boolean;
  documents: number;
  chunks: number;
  bytes: number;
}

// Effort preset ids in display order: the three scaling presets plus the
// custom worker mode. The scaling presets mirror the engine worker
// derivation; custom carries an explicit worker count from the stepper.

export function resolveIndexSourceContent(
  status: Pick<IndexStatusResponse, "sources" | "bySource"> | null | undefined,
  live?: IndexLiveStatus | null,
): IndexSourceContentRow[] {
  const sources = status?.sources ?? [];
  const totals = status?.bySource ?? [];
  const enabledByKind = new Map(sources.map((source) => [source.kind, source.enabled]));
  const totalsByKind = new Map<string, IndexSourceCounts>(
    totals.map((row) => [row.kind, row]),
  );
  const liveByKind = new Map<string, number>();
  if (Array.isArray(live?.sources) && live.sources.length > 0) {
    for (const entry of live.sources) {
      if (entry && typeof entry.kind === "string") {
        liveByKind.set(entry.kind, floorPositive(entry.indexed));
      }
    }
  } else if (
    live &&
    typeof live.stage === "string" &&
    live.stage &&
    // Cumulative fallback: `live.indexed` spans the whole run, so it maps onto one row
    // only when that stage is the run's sole enabled source; otherwise other sources'
    // work totals would inflate the active stage's row.
    sources.filter((source) => source.enabled).length === 1 &&
    enabledByKind.get(live.stage) === true
  ) {
    liveByKind.set(live.stage, floorPositive(live.indexed));
  }
  return INDEX_SOURCES.map((source) => {
    const totalsRow = totalsByKind.get(source.kind);
    const liveDelta = liveByKind.get(source.kind) ?? 0;
    return {
      kind: source.kind,
      enabled: enabledByKind.get(source.kind) ?? false,
      documents: floorPositive(totalsRow?.documents) + liveDelta,
      chunks: floorPositive(totalsRow?.chunks),
      bytes: floorPositive(totalsRow?.bytes),
    };
  });
}

// Pipeline stage node descriptor for the animated 4-stage live flow track.
export interface IndexPipelineStep {
  id: "discovering" | "queues" | "embedding" | "committing";
  label: string;
  state: "pending" | "active" | "done";
  metric?: string;
}

// Resolves the 4 pipeline stages from the polled live snapshot so the user can see items flow
// from discovery through modality queues, cross-file batch embedding, and SQLite commits.
export function resolveIndexPipelineSteps(
  live: IndexLiveStatus | null | undefined,
  cancelling = false,
): IndexPipelineStep[] {
  const phase = live?.phase ?? null;
  const scanned = floorPositive(live?.scanned);
  const indexed = floorPositive(live?.indexed);
  const vectors = floorPositive(live?.vectorChunks);
  const queues = Array.isArray(live?.queues) ? live.queues : [];
  const totalQueued = queues.reduce((sum, lane) => sum + floorPositive(lane.queued), 0);
  const totalProcessed = queues.reduce((sum, lane) => sum + floorPositive(lane.processed), 0);
  const hasQueues = totalQueued > 0;
  const liveRateText = formatIndexRate(live?.rate, live?.elapsedMs);
  const isDiscovering = phase === "discovering" && !hasQueues && indexed === 0;
  const isCommitting = phase === "committing";
  const discoveringRatePart = isDiscovering && liveRateText ? ` · ${liveRateText.replace("docs/s", "files/s")}` : "";
  const discoveringMetric = scanned > 0 ? `${formatIndexCount(scanned)} scanned${discoveringRatePart}` : undefined;
  const queuesRatePart = !isDiscovering && !isCommitting && liveRateText ? ` · ${liveRateText}` : "";
  const queuesMetric =
    totalQueued > 0
      ? `${formatIndexCount(totalProcessed)} / ${formatIndexCount(totalQueued)}${queuesRatePart}`
      : undefined;
  const embeddingMetric = vectors > 0 ? `${formatIndexCount(vectors)} vectors` : undefined;
  const committingMetric = indexed > 0 ? `${formatIndexCount(indexed)} indexed` : undefined;
  if (cancelling) {
    return [
      { id: "discovering", label: "Walk & Classify", state: "done", metric: discoveringMetric },
      { id: "queues", label: "Modality Queues", state: "active", metric: queuesMetric },
      {
        id: "embedding",
        label: "Batch Embed",
        state: vectors > 0 ? "done" : "pending",
        metric: embeddingMetric,
      },
      {
        id: "committing",
        label: "SQLite Commit",
        state: indexed > 0 ? "done" : "pending",
        metric: committingMetric,
      },
    ];
  }
  const isEmbedding =
    phase === "embedding" || (!isDiscovering && !isCommitting && vectors > 0);
  return [
    {
      id: "discovering",
      label: "Walk & Classify",
      state: isDiscovering ? "active" : "done",
      metric: discoveringMetric,
    },
    {
      id: "queues",
      label: "Modality Queues",
      state: isDiscovering ? "pending" : isCommitting ? "done" : "active",
      metric: queuesMetric,
    },
    {
      id: "embedding",
      label: "Batch Embed",
      state: isCommitting ? "done" : isEmbedding ? "active" : "pending",
      metric: embeddingMetric,
    },
    {
      id: "committing",
      label: "SQLite Commit",
      state: isCommitting || indexed > 0 ? "active" : "pending",
      metric: committingMetric,
    },
  ];
}

// Sanitized share of the total index for one chart row: the true documents/total fraction capped to
// 0..1, degrading malformed, negative, or zero inputs to zero so bars and labels never render NaN or
// Infinity.
export function indexShare(documents: number, totalDocuments: number): number {
  const docs = Number.isFinite(documents) && documents > 0 ? documents : 0;
  const total =
    Number.isFinite(totalDocuments) && totalDocuments > 0 ? totalDocuments : 0;
  if (total <= 0 || docs <= 0) return 0;
  return Math.min(1, docs / total);
}

// Visual track width for one chart row scaled by its document share of the total index, so every
// bar reads as its honest fraction of the displayed rows instead of competing for the longest slot.
export function indexSourceBarWidth(documents: number, totalDocuments: number): string {
  const share = indexShare(documents, totalDocuments);
  if (share <= 0) return "0%";
  return `${Math.min(100, Math.round(share * 100))}%`;
}

// Honest share-of-index percent label for one chart row: the true rounded share of the displayed
// total, so the label and the track width above always agree.
export function indexSourceBarPercent(documents: number, totalDocuments: number): string {
  const share = indexShare(documents, totalDocuments);
  if (share <= 0) return "0%";
  return `${Math.min(100, Math.round(share * 100))}%`;
}

// Rounded 0..100 share percent for meter segment widths, flowing through indexShare so a
// malformed or zero total degrades to zero instead of NaN.
export function percentOf(part: number, total: number): number {
  return Math.round(indexShare(part, total) * 100);
}

// Display label for an extraction-outcome token, falling back to the engine's
// wire token so an unknown future status still renders honestly.
export function extractStatusLabel(status: string): string {
  return status && status.trim() ? status.trim() : "unknown";
}

// Last-run strip copy with the never-empty history contract: a fresh store with no run ever
// recorded reads as an honest empty state, a first pass in flight names itself instead of reading as
// empty history, and any completed or cancelled run always renders its entry.
export function resolveIndexLastRunText(
  lastRun: IndexLastRunStatus | null | undefined,
  isActive: boolean,
): string {
  if (lastRun == null && isActive) return "First run in progress…";
  return describeIndexRun(lastRun);
}

// Stage-aware header copy for the live progress line.
export function resolveIndexLiveTitle(
  phase: string | null | undefined,
  stage: string | null | undefined,
): string {
  if (phase === "embedding") return "Vectorizing…";
  if (phase === "extracting") {
    if (stage === "files") return "Reading files…";
    if (stage === "mail") return "Reading mail…";
    if (stage === "messages") return "Reading messages…";
    if (stage === "calendars") return "Reading calendars…";
    if (stage === "reminders") return "Reading reminders…";
    return "Reading…";
  }
  if (phase === "discovering") return "Discovering…";
  if (phase === "committing") return "Committing…";
  if (stage === "files") return "Reading files…";
  if (stage === "mail") return "Reading mail…";
  if (stage === "messages") return "Reading messages…";
  if (stage === "calendars") return "Reading calendars…";
  if (stage === "reminders") return "Reading reminders…";
  return "Running…";
}

// Reports whether a live progress frame belongs to an index run.
export function isIndexProgressFrame(
  frame: Pick<WSToolProgressFrame, "toolName">,
  runActive: boolean,
): boolean {
  const name = typeof frame.toolName === "string" ? frame.toolName.trim().toLowerCase() : "";
  return name === INDEX_PROGRESS_TOOL_NAME && runActive;
}

// Stage title for the grep-style live line. Reuses the polled snapshot copy
// but never returns the generic running fallback so the live block never
// duplicates the Status pill's Running text.
export function resolveIndexLiveStageTitle(
  phase: string | null | undefined,
  stage: string | null | undefined,
  current?: string | null | undefined,
): string {
  if (typeof current === "string" && (current.startsWith("Downloading") || current.startsWith("Starting local"))) {
    return current.endsWith("…") ? current : `${current}…`;
  }
  const title = resolveIndexLiveTitle(phase, stage);
  return title === "Running…" ? "Indexing…" : title;
}

// One-line header for the polled live snapshot: trigger label plus stage title with cumulative
// counts, skipped/errors when non-zero, engine rate, and elapsed.
export function formatIndexLiveHeader(
  live: IndexLiveStatus | null | undefined,
): string | null {
  if (!live) return null;
  const scanned =
    typeof live.scanned === "number" && Number.isFinite(live.scanned) && live.scanned > 0
      ? Math.floor(live.scanned)
      : 0;
  const indexed =
    typeof live.indexed === "number" && Number.isFinite(live.indexed) && live.indexed > 0
      ? Math.floor(live.indexed)
      : 0;
  const skipped =
    typeof live.skipped === "number" && Number.isFinite(live.skipped) && live.skipped > 0
      ? Math.floor(live.skipped)
      : 0;
  const errors =
    typeof live.errors === "number" && Number.isFinite(live.errors) && live.errors > 0
      ? Math.floor(live.errors)
      : 0;
  const elapsedMs =
    typeof live.elapsedMs === "number" && Number.isFinite(live.elapsedMs) && live.elapsedMs >= 0
      ? live.elapsedMs
      : 0;
  const label = indexRunTriggerLabel(live.trigger);
  const stageTitle = resolveIndexLiveStageTitle(live.phase, live.stage, live.current);
  const rate = formatIndexRate(
    typeof live.rate === "number" ? live.rate : null,
    elapsedMs,
  );
  const elapsed = formatToolProgressElapsedMs(elapsedMs);
  const skippedPart = skipped > 0 ? ` · ${formatIndexCount(skipped)} skipped` : "";
  const errorsPart = errors > 0 ? ` · ${formatIndexCount(errors)} errors` : "";
  const ratePart = rate ? ` · ${rate}` : "";
  return `${label}: ${stageTitle} · ${formatIndexCount(scanned)} scanned · ${formatIndexCount(indexed)} indexed${skippedPart}${errorsPart}${ratePart} · ${elapsed}`;
}

// Embedded callers (the Memory tab) render their own inner header above the
// pane, so the status dashboard hides its title there; standalone hosts keep
// the same copy inline.
export interface IndexingPanelProps {
  hideHeader?: boolean;
  highlightRun?: boolean;
  onRunStarted?: () => void;
}

// Status dashboard for the Memory → Index Status tab: run controls first, stat cards and per-source
// pills second, frontend-only charts last. Policy editing lives in IndexPolicyPanel so this surface
// owns no Save path.
export let cachedIndexStatus: (IndexStatusResponse & IndexStorageResponse) | null = null;
// Module-scoped slow arrival flag mirroring the cached status. Set on the
// successful storage merge and cleared with the cache, so a remount paints
// the honest sizing state without waiting for a fresh slow fetch.
export let cachedHasStorage = false;
// Module-scoped adoption parity for the cached baseline: true when the cached
// snapshot was adopted during an in-flight run, so its counts already contain
// that run's committed work and live deltas must not project on top.
export let cachedIndexAdoptedMidRun = false;

export function setCachedIndexStatus(val: (IndexStatusResponse & IndexStorageResponse) | null): void {
  cachedIndexStatus = val;
}
export function setCachedHasStorage(val: boolean): void {
  cachedHasStorage = val;
}
export function setCachedIndexAdoptedMidRun(val: boolean): void {
  cachedIndexAdoptedMidRun = val;
}

/// Clears the module-scoped cached index status.
/// Ownership: test isolation only, never called from production paths.
/// Edge cases: safe when the cache is already null; the next mount cold-boots to the skeleton.
export function clearCachedIndexStatusForTesting(): void {
  cachedIndexStatus = null;
  cachedHasStorage = false;
  cachedIndexAdoptedMidRun = false;
}

// Auto-start notice for a run broadcast that this panel did not initiate: a launch-triggered
// nightly or catch-up pass announces itself by display label so a missed nightly window names the
// catch-up explicitly instead of reading as a generic index run.
export function describeAutoStartNotice(
  run: { message?: unknown; response?: unknown } | null | undefined,
): string | null {
  if (!run) return null;
  const message = typeof run.message === "string" ? run.message : undefined;
  const response = typeof run.response === "string" ? run.response : undefined;
  const trigger = parseIndexRunTrigger({ message: message ?? "", response: response ?? null });
  const label = indexRunTriggerLabel(trigger);
  if (trigger === "catchUp") {
    return `${label} started: catching up on missed nightly indexing.`;
  }
  return `${label} started.`;
}

