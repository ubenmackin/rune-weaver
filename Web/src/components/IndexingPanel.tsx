// Rune Weaver Dashboard — Local index status dashboard and policy form.
//
// The status dashboard (Memory → Index Status) owns Run/Cancel/Prune/Reclaim/
// Reset, the honest on-disk size with its storage breakdown, the last-run
// strip with retired and truncated counts, and frontend-only SVG/CSS charts computed from
// the GET /index/status fields; the policy form (Settings → Indexing) owns
// the enable/sources/excludes/caps/effort fields with its own Save, so
// neither surface duplicates the other's control set. Status freshness comes
// from the shared WebSocket run broadcasts — there is no manual Refresh
// button — and live progress renders one grep-style block from the polled
// status live snapshot, so the panel never invents a completion fraction the
// engine cannot supply.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_EFFORT,
  DEFAULT_INDEX_MAILBOX_DENY,
  DEFAULT_INDEX_MAILBOX_DENY_TEXT,
  DEFAULT_INDEX_WORKERS,
  DEFAULT_INDEX_PAUSE_ON_BATTERY,
  DEFAULT_INDEX_THERMAL_BACKOFF,
  INDEX_MAX_CUSTOM_WORKERS,
  INDEX_EFFORT_PRESETS,
  INDEX_EFFORT_PRESET_LABELS,
  INDEX_ICLOUD_EVICTIONS,
  INDEX_MAIL_VECTOR_WINDOWS,
  formatListToText,
  formatMailboxDenyText,
  parseLinesToList,
  parseMailboxDenyText,
  cancelIndex,
  describeIndexRun,
  formatIndexCount,
  formatToolProgressElapsedMs,
  getAuthToken,
  getIndexStatus,
  getSettings,
  indexRunTriggerLabel,
  indexWatermarkAgeMs,
  parseIndexRunTrigger,
  parseRunTimestamp,
  pruneIndex,
  reclaimIndex,
  relativeProgressCurrent,
  requestIndexAccess,
  resetIndex,
  resolveIndexRetiredCount,
  resolveIndexSourceAccess,
  resolveIndexSourceSkippedReason,
  resolveIndexTruncatedCount,
  runIndex,
  updateSettings,
  type IndexConfigData,
  type IndexExtractStatusCounts,
  type IndexLastRunStatus,
  type IndexLiveStatus,
  type IndexReclaimResponse,
  type IndexSourceCounts,
  type IndexSourceStatus,
  type IndexStatusResponse,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
  WSToolProgressFrame,
} from "../hooks/useSharedWebSocket";
import { formatRelativeAgo } from "../relativeTime";
import {
  AlertTriangleIcon,
  StopIcon,
  TrashIcon,
} from "./icons";
import Modal from "./Modal";
import MarkdownText from "./MarkdownText";
import { ToastStack } from "./Toast";
import { useToastStack } from "../hooks/useToastStack";

// Engine index source kinds in canonical run order, each with its display label.
// The Messages label carries the Full Disk Access hint because reading the chat
// database requires that grant on macOS.
const INDEX_SOURCES: Array<{ kind: string; label: string; hint?: string }> = [
  { kind: "files", label: "Files" },
  { kind: "mail", label: "Mail" },
  {
    kind: "messages",
    label: "Messages",
    hint: "Requires Full Disk Access — RuneWeaver.app, or your terminal emulator when running rune-weaver serve — then press Run.",
  },
  { kind: "calendars", label: "Calendars" },
  { kind: "reminders", label: "Reminders" },
];

// Display label for a status source kind, falling back to the engine's wire
// token so an unknown future source still renders honestly.
function sourceLabel(kind: string): string {
  return INDEX_SOURCES.find((source) => source.kind === kind)?.label ?? kind;
}

// Pill tone for one index source as a pure function of enablement plus
// access: disabled reads grey, enabled plus granted reads green, enabled
// plus anything else reads amber. Recomputed from the status row on every
// render so color tracks poll truth, never cached UI state.
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
      return `${label} is on but the chat database cannot be read. Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then press Run — the pill turns green on the next poll.`;
    }
    return `${label} is on but Messages access has not been granted yet. Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access.`;
  }
  if (kind === "calendars" || kind === "reminders") {
    const pane = kind === "calendars" ? "Calendars" : "Reminders";
    if (access === "denied") {
      return `${label} is on but ${pane} access was denied. Grant access in System Settings > Privacy & Security > ${pane} — the pill turns green on the next poll, no save needed.`;
    }
    return `${label} is on but ${pane} access has not been granted yet. Allow access when prompted, or grant it in System Settings > Privacy & Security > ${pane}.`;
  }
  return `${label} is on but access is ${access}. Grant access — the pill turns green on the next poll.`;
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
  return `Access denied — open System Settings > Privacy & Security > ${pane} to grant access.`;
}

// Deep link into the Full Disk Access pane. There is no prompt API for this
// grant, so the dashboard can only open Settings and show copy-paste steps
// alongside it. The link must navigate the top frame (anchor or location
// assignment): the system scheme reads as a blocked popup under window.open.
export const FULL_DISK_ACCESS_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

// Whether one status error is the Full Disk Access denial. Matched loosely on
// the shared engine phrase so both the cheap status-probe warning and the
// run-time denial from the run log trigger the same guided onboarding.
export function isFullDiskAccessError(detail: string | null | undefined): boolean {
  if (typeof detail !== "string") return false;
  return /full disk access/i.test(detail);
}

// Whether any status error needs the Full Disk Access guided onboarding.
// Checked over lastErrors so the dashboard surfaces guidance before the next
// wasted run instead of only after one fails. The element narrows by typeof
// so malformed payload entries degrade to no-match instead of relying on a
// cast that would hide non-string values from the type checker.
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

// Display list for the last-errors card: deduped lines with the raw Full Disk
// Access bullet suppressed whenever the guided onboarding renders, since the
// guidance is the formatted form of that same failure and keeping both would
// read as a duplicate. No backend shape change — the engine still sends
// string[] and this stays a frontend-only projection.
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

// Short stable digest for one error line, used for React keys so a
// kilobyte-long failure never becomes a full-text key. Collisions only reuse
// a row element, never drop an entry, because the visible position joins the
// key at the call site.
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

// Elapsed floor before the live rate reads honestly: under half a second one
// document over a few milliseconds renders a triple-digit spike, so the line
// omits the rate until the window is wide enough to mean something. Mirrors
// the engine liveTotals floor that reports 0 below this window.
export const INDEX_MIN_HONEST_RATE_ELAPSED_MS = 500;

// Ceiling above which a rate cannot be real work: guards a handcrafted or
// drifted payload the same way the non-finite check does, so the line omits
// the rate instead of rendering an absurd figure.
export const INDEX_MAX_HONEST_RATE = 1000000;

// Documents-per-second for the live block: the engine `live.rate` (indexed
// documents over elapsed time), labeled explicitly as docs work. Returns null
// when the rate cannot read honestly — absent, non-finite, non-positive,
// absurdly huge, or measured under the honest elapsed floor — so the line
// omits it instead of rendering a jittering zero or an early-run spike.
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

// Chart palette drawn from the dashboard theme tokens: the vector segment uses
// the accent purple, the keyword segment the accent blue, and the tracks reuse
// the border color so both charts read as native surfaces without new CSS.
const CHART_VECTOR_COLOR = "var(--accent-purple)";
const CHART_KEYWORD_COLOR = "var(--accent-blue)";
const CHART_TRACK_COLOR = "var(--border-color)";
// Extraction-outcome bars reuse the keyword blue so the breakdown reads as a
// second member of the same chart family without inventing a new hue per status.
const CHART_EXTRACT_COLOR = "var(--accent-blue)";

// Donut ring geometry in SVG user units: radius 40 inside a 100×100 viewBox
// with a 10-unit stroke leaves an inner hole wide enough for the ring to read
// as a donut rather than a pie.
const DONUT_RADIUS = 40;
const DONUT_SIZE = 100;
const DONUT_STROKE = 10;

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

// On-disk storage breakdown for the honest size figure. The primary figure
// sums the database file plus the write-ahead log so it reads within ~1% of
// `du`; the text/vector/FTS/free rows explain where those bytes live, and the
// content total stays as a secondary detail. Every field degrades to zero so
// a drifted payload never renders NaN, and older engines without the file
// sizes fall back to the content total instead of failing. `hasStorage`
// tracks slow arrival explicitly so an honest empty index hides sizing once
// slow lands instead of gating solely on non-zero breakdown.
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

// Full breakdown for the size card: on-disk primary plus the four storage
// rows and the content secondary. `hasOnDisk` reports whether the file sizes
// were present; `hasBreakdown` reports whether any storage row was non-zero,
// so the card omits the breakdown row for older engines instead of rendering
// a row of zeros. `hasStorage` reports whether the slow phase landed, so the
// sizing copy shows only until slow fields land even for an honest empty index.
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

// Slow storage snapshot for GET /index/storage. Fast status carries counts
// immediately while these byte totals arrive separately, so every key stays
// optional and byte-compatible with older engines that omit the route.
export interface IndexStorageResponse {
  bytes?: number | null;
  textBytes?: number | null;
  vectorBytes?: number | null;
  ftsBytes?: number | null;
  freeBytes?: number | null;
  dbFileBytes?: number | null;
  walBytes?: number | null;
  contentBytes?: number | null;
  bySource?: IndexSourceCounts[] | null;
}

/// Reads the slow storage breakdown from GET /index/storage.
/// Ownership: second phase of loadStatus only; never called from render or broadcast handlers directly.
/// Edge cases: non-OK answers throw ApiError so the caller keeps phase-1 state; malformed or non-record JSON degrades to an empty object so the merge stays a no-op; network failure propagates as ApiError.
export async function getIndexStorage(): Promise<IndexStorageResponse> {
  let response: Response;
  try {
    const token = getAuthToken();
    response = await fetch("/index/storage", {
      credentials: "same-origin",
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
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
      if (text) detail = text.slice(0, 500);
    } catch {
      // Keep the status fallback when the body is unreadable.
    }
    throw new ApiError(detail || "Request failed: /index/storage", response.status);
  }
  try {
    const data: unknown = await response.json();
    // Non-record payloads degrade to empty so a drifted body never clears fast counts.
    if (!data || typeof data !== "object" || Array.isArray(data)) return {};
    return data as IndexStorageResponse;
  } catch (error) {
    throw new ApiError(
      error instanceof ApiError ? error.message : "Invalid JSON response: /index/storage",
      response.status,
    );
  }
}

// Effort preset ids in display order: the three scaling presets plus the
// custom worker mode. The scaling presets mirror the engine worker
// derivation; custom carries an explicit worker count from the stepper.
export const INDEX_EFFORT_OPTIONS: Array<{ id: string; label: string }> = [
  ...INDEX_EFFORT_PRESETS.map((id) => ({
    id,
    label: INDEX_EFFORT_PRESET_LABELS[id] ?? id,
  })),
  { id: "custom", label: INDEX_EFFORT_PRESET_LABELS.custom ?? "Custom" },
];

// Normalizes a stored effort token to the canonical preset id, mirroring
// IndexConfig.allowedEfforts (`light`, `balanced`, `performance`, `custom`).
// Legacy tokens from older dashboards and example files (`eco`/`low` for
// light, `standard` for balanced, `fast`/`high`/`max` for performance) map
// onto their canonical successor so an upgraded install keeps its intent
// instead of falling back; unknown, blank, or non-string payloads degrade to
// the balanced default so the control never renders blank.
export function normalizeIndexEffortPreset(value: unknown): string {
  if (typeof value !== "string") return DEFAULT_INDEX_EFFORT;
  const token = value.trim().toLowerCase();
  if (
    token === "light" ||
    token === "balanced" ||
    token === "performance" ||
    token === "custom"
  )
    return token;
  if (token === "eco" || token === "low") return "light";
  if (token === "standard") return "balanced";
  if (token === "fast" || token === "high" || token === "max")
    return "performance";
  return DEFAULT_INDEX_EFFORT;
}

// Display label for an effort preset, falling back to the wire token so an
// unknown future preset still renders honestly.
export function indexEffortLabel(preset: string): string {
  const token = typeof preset === "string" ? preset.trim().toLowerCase() : "";
  if (!token) return INDEX_EFFORT_PRESET_LABELS.balanced ?? "Balanced";
  return INDEX_EFFORT_PRESET_LABELS[token] ?? preset;
}

// Machine core count for the effort mapping: the engine `coreCount` when it
// carries a positive finite value, otherwise the browser
// `hardwareConcurrency`, otherwise null so callers omit the of-N-cores suffix
// instead of guessing.
export function resolveMachineCores(
  statusCores?: number | null | undefined,
): number | null {
  if (
    typeof statusCores === "number" &&
    Number.isFinite(statusCores) &&
    statusCores > 0
  )
    return Math.floor(statusCores);
  if (
    typeof navigator !== "undefined" &&
    typeof navigator.hardwareConcurrency === "number" &&
    Number.isFinite(navigator.hardwareConcurrency) &&
    navigator.hardwareConcurrency > 0
  )
    return Math.floor(navigator.hardwareConcurrency);
  return null;
}

// Resolved worker count for one effort preset against a core count, mirroring
// IndexConfig.resolvedWorkerCount: `light` pins one worker, `balanced` takes
// half the cores up to four, `performance` takes all but one core, and
// `custom` clamps the stepper value into 1..64 and then to the available
// cores. Unknown core counts mirror safeCores=max(1,cores) so every preset
// resolves to 1 instead of guessing, and an invalid custom value falls back
// to the balanced mapping so the line never blanks.
export function resolveEffortWorkers(
  preset: string | null | undefined,
  coreCount: number | null | undefined,
  customWorkers?: number | null | undefined,
): number {
  const normalized = normalizeIndexEffortPreset(preset);
  const cores =
    typeof coreCount === "number" &&
    Number.isFinite(coreCount) &&
    coreCount > 0
      ? Math.floor(coreCount)
      : 0;
  const custom =
    typeof customWorkers === "number" &&
    Number.isFinite(customWorkers) &&
    customWorkers >= 1
      ? Math.min(INDEX_MAX_CUSTOM_WORKERS, Math.floor(customWorkers))
      : null;
  if (cores <= 0) {
    if (normalized === "custom")
      return Math.min(
        INDEX_MAX_CUSTOM_WORKERS,
        custom ?? DEFAULT_INDEX_WORKERS,
      );
    // Unknown cores mirror safeCores=max(1,cores): light pins 1, balanced
    // takes half of one clamped to 1, performance takes all but one clamped
    // to 1, so every preset resolves to 1.
    return 1;
  }
  if (normalized === "light") return 1;
  if (normalized === "balanced") return Math.max(1, Math.min(4, Math.floor(cores / 2)));
  if (normalized === "performance") return Math.max(1, cores - 1);
  // Custom clamps the stepper into the static ceiling and the machine so a
  // stale value from a larger machine never asks for more workers than exist
  // here.
  const fallback = Math.max(1, Math.min(4, Math.floor(cores / 2)));
  const wanted = custom ?? fallback;
  return Math.min(cores, Math.min(INDEX_MAX_CUSTOM_WORKERS, Math.max(1, wanted)));
}

// Reads the custom worker count from an index payload. Non-finite or
// out-of-range values degrade to null so callers apply their own default
// instead of guessing.
export function resolveIndexWorkersValue(
  data: { workers?: unknown } | null | undefined,
): number | null {
  if (!data || typeof data !== "object") return null;
  const candidate =
    typeof data.workers === "number" && Number.isFinite(data.workers)
      ? data.workers
      : null;
  if (candidate == null || candidate < 1) return null;
  return Math.floor(candidate);
}

// Reads the per-document vector chunk cap from an index payload. Non-finite
// or out-of-range values degrade to null so callers apply the engine default
// instead of rendering a drifted figure.
export function resolveIndexVectorCapValue(
  data: { maxVectorChunksPerDocument?: unknown } | null | undefined,
): number | null {
  if (!data || typeof data !== "object") return null;
  const candidate = (data as { maxVectorChunksPerDocument?: unknown })
    .maxVectorChunksPerDocument;
  if (typeof candidate !== "number" || !Number.isFinite(candidate)) return null;
  if (candidate < 1) return null;
  return Math.floor(candidate);
}

// Resolved effort signal from a status payload, reading the canonical nested
// `effort` block (`preset`/`resolvedWorkers`/`activeProcessors`). Null fields
// mean the engine predates the signal so the pane omits the line instead of
// inventing a preset.
export function resolveStatusEffort(status: unknown): {
  preset: string | null;
  resolvedWorkers: number | null;
  coreCount: number | null;
} {
  if (!status || typeof status !== "object") {
    return { preset: null, resolvedWorkers: null, coreCount: null };
  }
  const record = status as {
    effort?: unknown;
  };
  const nested =
    record.effort && typeof record.effort === "object"
      ? (record.effort as {
          preset?: unknown;
          resolvedWorkers?: unknown;
          activeProcessors?: unknown;
        })
      : null;
  const rawPreset =
    typeof nested?.preset === "string" && nested.preset.trim()
      ? nested.preset.trim()
      : null;
  // Preserve unknown future presets verbatim while mapping legacy aliases
  // onto canonical ids so an upgraded engine still renders honestly.
  let preset: string | null = null;
  if (rawPreset != null) {
    const lowered = rawPreset.toLowerCase();
    if (
      lowered === "light" ||
      lowered === "balanced" ||
      lowered === "performance" ||
      lowered === "custom"
    ) {
      preset = lowered;
    } else if (lowered === "eco" || lowered === "low") {
      preset = "light";
    } else if (lowered === "standard") {
      preset = "balanced";
    } else if (lowered === "fast" || lowered === "high" || lowered === "max") {
      preset = "performance";
    } else {
      preset = lowered;
    }
  }
  const nestedResolved =
    typeof nested?.resolvedWorkers === "number" &&
    Number.isFinite(nested.resolvedWorkers) &&
    (nested.resolvedWorkers as number) > 0
      ? Math.floor(nested.resolvedWorkers as number)
      : null;
  const nestedCores =
    typeof nested?.activeProcessors === "number" &&
    Number.isFinite(nested.activeProcessors) &&
    (nested.activeProcessors as number) > 0
      ? Math.floor(nested.activeProcessors as number)
      : null;
  return {
    preset,
    resolvedWorkers: nestedResolved,
    coreCount: nestedCores,
  };
}

// Resolved-reality copy for the effort control: preset label plus the worker
// resolution against the machine (`Balanced - using 4 of 10 cores`). Without
// a core count the line names the worker count alone so it never invents a
// denominator the machine did not report.
export function describeEffortReality(
  preset: string | null | undefined,
  resolvedWorkers: number | null | undefined,
  coreCount: number | null | undefined,
): string {
  const label = indexEffortLabel(normalizeIndexEffortPreset(preset));
  const resolved =
    typeof resolvedWorkers === "number" &&
    Number.isFinite(resolvedWorkers) &&
    resolvedWorkers > 0
      ? Math.floor(resolvedWorkers)
      : null;
  const cores =
    typeof coreCount === "number" &&
    Number.isFinite(coreCount) &&
    coreCount > 0
      ? Math.floor(coreCount)
      : null;
  if (resolved != null && cores != null) {
    const coreNoun = cores === 1 ? "core" : "cores";
    return `${label} - using ${formatIndexCount(resolved)} of ${formatIndexCount(cores)} ${coreNoun}`;
  }
  if (resolved != null) {
    const workerNoun = resolved === 1 ? "worker" : "workers";
    return `${label} - using ${formatIndexCount(resolved)} ${workerNoun}`;
  }
  return label;
}

// Display string for the configured file roots: the home shorthand gains its
// parenthetical so a stock `~` reads as the home directory instead of a bare
// sigil, while custom roots join verbatim so the subtitle names exactly what
// the walker covers. Non-array or empty payloads degrade to honest fallbacks
// instead of rendering a blank scope.
export function formatIndexScopeRoots(roots: unknown): string {
  if (!Array.isArray(roots)) return "~ (your home directory)";
  const cleaned = roots
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (cleaned.length === 0) return "no configured roots";
  return cleaned
    .map((root) => (root === "~" ? "~ (your home directory)" : root))
    .join(", ");
}

// Root-scoped coverage subtitle for the Index Policy panel: names the
// configured roots and states that nothing outside them is ever scanned, so
// the owner sees the walk boundary without opening the config file.
export function describeIndexScope(roots: unknown): string {
  return `Builds a local search index of ${formatIndexScopeRoots(roots)}. Nothing outside the configured roots is ever scanned.`;
}

// Parses the index-roots textarea into the wire shape: one root per line,
// trimmed, with blank lines dropped so an emptied editor reads as an explicit
// empty list instead of persisting whitespace rows. Null input degrades to
// empty so callers apply the empty-reject rule instead of guessing. Delegates
// to the shared line-list codec so index roots stay symmetric with allow roots.
export function parseIndexRootsText(text: string | undefined | null): string[] {
  if (typeof text !== "string") return [];
  return parseLinesToList(text ?? "", []);
}

// Formats an index-roots array for the multiline editor, joining one root per
// line so the textarea and the stored array stay symmetric. Non-array payloads
// degrade to empty so older engines without the field never seed stale text.
// Delegates to the shared formatter so index roots stay symmetric with allow roots.
export function formatIndexRootsText(
  roots: string[] | undefined | null,
): string {
  return formatListToText(roots, "");
}

// Validates the index-roots textarea before any network write: blank lines
// collapse on save, an emptied editor is rejected, and `..` escapes are
// rejected with line numbers so a traversal escape points at its editor row.
// Returns the error copy or null when valid.
export function validateIndexRootsText(
  text: string | undefined | null,
): string | null {
  const raw = typeof text === "string" ? text : "";
  const lines = raw.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (!trimmed) continue;
    if (trimmed.includes("..")) {
      return `Line ${index + 1}: Index root must not contain '..': "${trimmed}".`;
    }
  }
  if (parseIndexRootsText(text).length === 0) {
    return "Index roots cannot be empty.";
  }
  return null;
}

// Normalizes one root for the outside-allow-roots comparison: trims and drops
// trailing slashes so `~/Docs/` and `~/Docs` compare equal without changing
// the stored value. `~` keeps its sigil so home containment reads honestly.
function normalizeIndexRootForCompare(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "~" || trimmed === "/") return trimmed;
  return trimmed.replace(/\/+$/, "");
}

// Reports whether one index root sits inside one files allow root: an exact
// match or a child path under the allow root counts as inside, so
// `~/Docs/Sub` stays inside `~/Docs` and `~` contains every `~/...` entry.
// Absolute paths never match `~` without the sigil prefix, so an
// outside-filesystem root reads as outside instead of guessing home expansion.
export function isIndexRootInsideAllowRoot(
  indexRoot: string,
  allowRoot: string,
): boolean {
  const index = normalizeIndexRootForCompare(indexRoot);
  const allow = normalizeIndexRootForCompare(allowRoot);
  if (!index || !allow) return false;
  if (index === allow) return true;
  if (allow === "~") {
    return index === "~" || index.startsWith("~/");
  }
  return index.startsWith(allow.endsWith("/") ? allow : `${allow}/`);
}

// Lists the index roots sitting outside every loaded files allow root, so the
// policy form can warn that recalled content from there may not be readable
// by live file tools. An absent allow list degrades to no warning instead of
// guessing, and blank entries never count as outside.
export function findOutsideIndexRoots(
  indexRoots: unknown,
  allowRoots: unknown,
): string[] {
  if (!Array.isArray(indexRoots) || !Array.isArray(allowRoots)) return [];
  const cleanedAllow = allowRoots
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (cleanedAllow.length === 0) return [];
  const cleanedIndex = indexRoots
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  return cleanedIndex.filter(
    (root) => !cleanedAllow.some((allow) => isIndexRootInsideAllowRoot(root, allow)),
  );
}

// Always-skipped names from the index settings payload: the engine's
// `alwaysSkipped` array populated from the walker's prune list. Non-string
// entries degrade to skipped so a drifted payload never renders a blank row,
// and a missing field degrades to empty so older engines without the field
// render generic copy without inventing names.
export function resolveAlwaysSkipped(index: unknown): string[] {
  if (!index || typeof index !== "object") return [];
  const raw = (index as { alwaysSkipped?: unknown }).alwaysSkipped;
  if (!Array.isArray(raw)) return [];
  return raw.filter(
    (entry): entry is string =>
      typeof entry === "string" && entry.trim().length > 0,
  );
}

// Human summary of a reclaim pass for the notice and the result block: the
// reclaimed delta plus the before and after on-disk figures so both ends of
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

// Per-source content row joining enablement with real totals: enablement comes
// from the status sources list while documents/chunks/bytes come from the
// additive bySource aggregates. A source missing from either side degrades to
// disabled or zero rather than disappearing, so older engines without the
// aggregates still render the canonical Files/Mail/Messages/Calendars/Reminders rows.
export interface IndexSourceContentRow {
  kind: string;
  enabled: boolean;
  documents: number;
  chunks: number;
  bytes: number;
}

// Resolves the canonical Files/Mail/Messages/Calendars/Reminders rows with real totals, so the
// bars scale by content instead of rendering binary on/off widths.
export function resolveIndexSourceContent(
  status: Pick<IndexStatusResponse, "sources" | "bySource"> | null | undefined,
): IndexSourceContentRow[] {
  const sources = status?.sources ?? [];
  const totals = status?.bySource ?? [];
  const enabledByKind = new Map(sources.map((source) => [source.kind, source.enabled]));
  const totalsByKind = new Map<string, IndexSourceCounts>(
    totals.map((row) => [row.kind, row]),
  );
  return INDEX_SOURCES.map((source) => {
    const totalsRow = totalsByKind.get(source.kind);
    return {
      kind: source.kind,
      enabled: enabledByKind.get(source.kind) ?? false,
      documents: floorPositive(totalsRow?.documents),
      chunks: floorPositive(totalsRow?.chunks),
      bytes: floorPositive(totalsRow?.bytes),
    };
  });
}

// Sanitized share of the total index for one chart row: the true
// documents/total fraction capped to 0..1, degrading malformed, negative, or
// zero inputs to zero so bars and labels never render NaN or Infinity.
// Shared by the width and percent helpers below, whose guard rule is
// identical and must stay in one place.
export function indexShare(documents: number, totalDocuments: number): number {
  const docs = Number.isFinite(documents) && documents > 0 ? documents : 0;
  const total =
    Number.isFinite(totalDocuments) && totalDocuments > 0 ? totalDocuments : 0;
  if (total <= 0 || docs <= 0) return 0;
  return Math.min(1, docs / total);
}

// Visual track width for one chart row scaled by its document share of the
// total index, so every bar reads as its honest fraction of the displayed
// rows instead of competing for the longest slot. Shared by the per-source
// and extraction-outcome charts, whose scaling rule is identical. No
// visibility floor remains: the width equals the rounded percent below, so a
// tiny bucket paints as a sliver while its label stays truthful.
export function indexSourceBarWidth(documents: number, totalDocuments: number): string {
  const share = indexShare(documents, totalDocuments);
  if (share <= 0) return "0%";
  return `${Math.min(100, Math.round(share * 100))}%`;
}

// Honest share-of-index percent label for one chart row: the true rounded
// share of the displayed total, so the label and the track width above always
// agree. Shared by the per-source and extraction-outcome charts alongside
// indexSourceBarWidth.
export function indexSourceBarPercent(documents: number, totalDocuments: number): string {
  const share = indexShare(documents, totalDocuments);
  if (share <= 0) return "0%";
  return `${Math.min(100, Math.round(share * 100))}%`;
}

// Display label for an extraction-outcome token, falling back to the engine's
// wire token so an unknown future status still renders honestly.
export function extractStatusLabel(status: string): string {
  return status && status.trim() ? status.trim() : "unknown";
}

// Last-run strip copy with the never-empty history contract: a fresh store
// with no run ever recorded reads as an honest empty state, a first pass in
// flight names itself instead of reading as empty history, and any completed
// or cancelled run always renders its entry. The active flag covers every
// in-flight signal so the two empty copies can never contradict each other.
export function resolveIndexLastRunText(
  lastRun: IndexLastRunStatus | null | undefined,
  isActive: boolean,
): string {
  if (lastRun == null && isActive) return "First run in progress…";
  return describeIndexRun(lastRun);
}

// Stage-aware header copy for the live progress line. Vision always describes
// images, embedding vectorizes, extracting reads the named corpus, and the
// phase-only snapshots keep their plain copy; anything unrecognized degrades
// to the generic running copy so the header never sticks on a wire token.
export function resolveIndexLiveTitle(
  phase: string | null | undefined,
  stage: string | null | undefined,
): string {
  if (stage === "vision") return "Describing images…";
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

// Reports whether a live progress frame belongs to an index run. The frame is
// adopted only while a run is in flight and carrying the index tool name, so
// a delayed frame after the run settles never resurrects cleared progress and
// a concurrent tool with an omitted name never triggers a poll storm.
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

// One-line header for the polled live snapshot: trigger label plus stage title
// with cumulative counts, skipped/errors when non-zero, engine rate, and
// elapsed. The trigger label already carries its Run noun, so the em dash
// separates it from the stage without repeating the word. Rate reads the wire
// `live.rate` (docs/s) with the honest elapsed floor and omits itself when
// absent so the line never jitters on zero or spikes early. Returns null
// without live so callers render nothing.
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
  return `${label} — ${stageTitle} · ${formatIndexCount(scanned)} scanned · ${formatIndexCount(indexed)} indexed${skippedPart}${errorsPart}${ratePart} · ${elapsed}`;
}

// Embedded callers (the Memory tab) render their own inner header above the
// pane, so the status dashboard hides its title there; standalone hosts keep
// the same copy inline.
export interface IndexingPanelProps {
  hideHeader?: boolean;
}

// Status dashboard for the Memory → Index Status tab: run controls first, stat
// cards and per-source pills second, frontend-only charts last. Policy editing
// lives in IndexPolicyPanel so this surface owns no Save path.
// Module-scoped last-good status shared across mounts in this tab lifetime.
// Written only by loadStatus on success and read only by the state initializer,
// so a tab switch paints instantly and a failing refresh keeps the last panel.
// The slow content total rides alongside so phase 2 owns slow byte totals.
let cachedIndexStatus: (IndexStatusResponse & IndexStorageResponse) | null = null;
// Module-scoped slow arrival flag mirroring the cached status. Set on the
// successful storage merge and cleared with the cache, so a remount paints
// the honest sizing state without waiting for a fresh slow fetch.
let cachedHasStorage = false;

/// Clears the module-scoped cached index status.
/// Ownership: test isolation only, never called from production paths.
/// Edge cases: safe when the cache is already null; the next mount cold-boots to the skeleton.
export function clearCachedIndexStatusForTesting(): void { cachedIndexStatus = null; cachedHasStorage = false; }

/// Renders the index status dashboard with instant hydration from the module cache.
/// Ownership: initial paint reads the cache via the state initializer; refreshes revalidate via loadStatus without resetting to null.
/// Edge cases: null cache cold-boots to the skeleton; a cache hit paints instantly then updates silently on fetch.
export default function IndexingPanel({ hideHeader = false }: IndexingPanelProps) {
  // Initial paint owns the cache read so a prior successful load renders
  // synchronously before the background revalidation resolves.
  const [status, setStatus] = useState<(IndexStatusResponse & IndexStorageResponse) | null>(() => cachedIndexStatus);
  // Slow arrival flag for the sizing gate. False until the storage merge
  // lands so `Sizing storage…` shows only while slow is pending, even for an
  // honest empty index whose breakdown stays all zeros.
  const [hasStorage, setHasStorage] = useState(() => cachedHasStorage);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // One in-flight slot names the action so Run, Prune, Reset, and Reclaim stay
  // mutually exclusive while a request is pending. Cancel rides a separate
  // flag so it can run concurrent with Run: a local run holds `action="run"`
  // for the whole pass, and Cancel must still reach the engine during it.
  const [action, setAction] = useState<"run" | "prune" | "reset" | "reclaim" | null>(null);
  const actionBusy = action !== null;
  const [cancelBusy, setCancelBusy] = useState(false);
  // Last reclaim outcome for the before/after block. Kept separate from the
  // top notice so both figures stay visible after the status reload replaces
  // the size card, instead of scrolling away with the transient notice.
  const [reclaimResult, setReclaimResult] = useState<IndexReclaimResponse | null>(null);
  // Synchronous guard for the run flight: state commits asynchronously, so a
  // double-click before re-render would otherwise start two runs. The ref flips
  // immediately and the state mirrors it for rendering.
  const runActiveRef = useRef(false);
  const [runActive, setRunActive] = useState(false);
  // Cancelling window after a successful cancel request: the engine has been
  // asked to stop but the run has not settled yet. The ref flips immediately
  // so broadcast handlers observe it without waiting for a re-render, while
  // the state drives the Cancelling pill, header, and disabled buttons.
  const cancellingRef = useRef(false);
  const [cancelling, setCancelling] = useState(false);
  // Non-blocking destructive confirmations: prune and reset each render a
  // true modal so stored memory is never cleared by an accidental click. Each
  // modal carries its own description, so the button row stays label-only.
  const [pendingPrune, setPendingPrune] = useState(false);
  const [pendingRebuild, setPendingRebuild] = useState(false);
  // Explicit prune cutoff chosen in the confirm modal. Kept as the raw date
  // input value so an empty choice blocks the request instead of falling back
  // to now and silently clearing the store.
  const [pruneBefore, setPruneBefore] = useState<string>("");
  const [pruneError, setPruneError] = useState<string | null>(null);
  // Reset refusal surfaced inside the confirm modal, mirroring the prune
  // error slot so a confirm blocked by an in-flight run explains itself
  // instead of landing as a dead click.
  const [resetError, setResetError] = useState<string | null>(null);
  // Last-errors display state: the block stays collapsed behind its header
  // toggle so a noisy pass never pushes surrounding content, plus per-row
  // expansion for long lines. The expanded set is pruned to the
  // current display list on every status change so stale full-text entries
  // cannot accumulate unbounded across polls.
  const [errorsExpanded, setErrorsExpanded] = useState(false);
  const [expandedErrors, setExpandedErrors] = useState<Set<string>>(
    () => new Set<string>(),
  );
  // Freeze-then-jump: committed stat cards hold the last settled snapshot
  // mid-run and jump atomically at completion, so there is no committed-growth
  // flash. Only the live block stays live via the polled liveTotals snapshot.
  // Generation counter for two-phase loads so overlapping polls keep only the
  // newest storage merge. Phase 1 paints fast unconditionally while phase 2
  // checks this before merging, so a slow storage answer never overwrites a
  // newer fast snapshot.
  const loadGenerationRef = useRef(0);
  const [accessBusy, setAccessBusy] = useState<Record<string, boolean>>({});

  // True whenever the engine reports a run in flight or this panel started one,
  // so the in-run poll stays active and Run stays disabled during a real run.
  // The Status pill below stays the authoritative running source; this flag
  // only gates polling and buttons, never the live block.
  const progressActive = runActive || status?.running === true;
  const indexingEnabled = status?.enabled === true;
  // Mirrors the engine running flag for the broadcast consumer without
  // re-subscribing the shared socket on every status poll.
  const statusRunningRef = useRef(false);
  useEffect(() => {
    statusRunningRef.current = status?.running === true;
  }, [status?.running]);
  // Polled live snapshot for the grep-style block. Null when idle; the block
  // mounts only from this, never from frame parsing, and unmounts on settle
  // when the engine clears it. The Status pill owns the Running indicator.
  const live: IndexLiveStatus | null = status?.live ?? null;
  // Sanitized relative tail for the single file line. Defense-in-depth mirrors
  // the ToolProgress contract so a handcrafted payload can never render an
  // absolute path the engine keeps private.
  const liveCurrent = live ? relativeProgressCurrent(live.current) : null;

  const vectorChunks = status?.vectorChunks ?? 0;
  const keywordChunks = status?.keywordChunks ?? 0;
  const donut = indexDonutArcs(vectorChunks, keywordChunks, DONUT_RADIUS);
  // Real per-source totals for the bars, in canonical Files/Mail/Messages/Calendars/Reminders
  // order; older engines without the aggregates degrade to zeroed rows.
  const sourceContent = resolveIndexSourceContent(status);
  // Displayed-total denominator for the source chart: every visible row shares
  // this sum so each bar reads as its honest fraction of the index.
  const sourceTotalDocuments = sourceContent.reduce((sum, row) => sum + row.documents, 0);
  // Extraction-outcome breakdown for the second chart, largest bucket first so
  // the dominant outcome leads the list while every bar still scales by the
  // displayed total. Document counts are sanitized through floorPositive
  // before sort, matching resolveIndexSourceContent, so
  // malformed/negative/NaN payloads degrade to zero instead of misordering
  // the rows or yielding NaN.
  const extractRows: IndexExtractStatusCounts[] = [...(status?.byExtractStatus ?? [])]
    .map((row) => ({ ...row, documents: floorPositive(row.documents) }))
    .sort((left, right) => right.documents - left.documents);
  // Displayed-total denominator for the extraction chart: the sum across the
  // outcome rows above, so labels and widths agree with the source chart rule.
  const extractTotalDocuments = extractRows.reduce((sum, row) => sum + row.documents, 0);
  // Honest on-disk storage: the database file plus the write-ahead log as the
  // primary figure, the text/vector/FTS/free rows as the breakdown, and the
  // content total as the secondary detail. Older engines without the file
  // sizes fall back to the content total with no breakdown row. The explicit
  // arrival flag keeps sizing honest for an empty index whose breakdown stays
  // all zeros after slow lands.
  const storage = resolveIndexStorageBreakdown(status, hasStorage);
  // Retired documents from the last run, accepting both wire spellings.
  // Null when the engine predates retirement tracking so the strip omits it
  // instead of rendering a zero.
  const lastRunRetired = resolveIndexRetiredCount(status?.lastRun ?? null);
  // Truncated documents from the last run, accepting both wire spellings.
  // Null when the engine predates truncation tracking so the strip omits it
  // instead of rendering a zero.
  const lastRunTruncated = resolveIndexTruncatedCount(status?.lastRun ?? null);
  // Resolved effort reality for the status pane: the canonical nested `effort`
  // block when present, otherwise the local mapping against the machine cores so the
  // line still reflects the hardware. Hidden for older engines without any
  // effort signal so the pane never invents a preset.
  const statusEffort = resolveStatusEffort(status);
  const statusEffortPreset = statusEffort.preset;
  const statusCoreCount = resolveMachineCores(statusEffort.coreCount);
  const statusResolvedWorkers =
    statusEffort.resolvedWorkers ??
    (statusEffortPreset && statusCoreCount != null
      ? resolveEffortWorkers(statusEffortPreset, statusCoreCount, null)
      : null);
  const hasStatusEffort =
    statusEffortPreset != null ||
    statusEffort.resolvedWorkers != null ||
    statusEffort.coreCount != null;
  const statusEffortReality = hasStatusEffort
    ? describeEffortReality(
        statusEffortPreset ?? DEFAULT_INDEX_EFFORT,
        statusResolvedWorkers,
        statusCoreCount,
      )
    : null;
  // Reclaim result copy for the dedicated before/after block, kept beside the
  // transient notice so both figures survive the post-reclaim status reload.
  const reclaimSummary = formatIndexReclaimResult(reclaimResult);

  /// Reloads index status in two phases and commits the last-good snapshot to the module cache.
  /// Ownership: sole owner of fetch plus cache commit; phase 1 owns fast counts, phase 2 owns slow byte totals.
  /// Edge cases: fast success caches and paints before slow resolves; slow merge keeps fast counts and never clears them while in flight; slow failure leaves phase-1 state plus the error slot untouched and never nulls status; overlapping polls keep only the newest merge via the generation counter.
  const loadStatus = useCallback(async () => {
    const generation = loadGenerationRef.current + 1;
    loadGenerationRef.current = generation;
    setError(null);
    let fast: IndexStatusResponse | null = null;
    try {
      const response = await getIndexStatus();
      fast = response;
      cachedIndexStatus = response;
      // Fast resets the slow arrival gate so sizing shows until the fresh
      // storage merge lands for this generation.
      cachedHasStorage = false;
      setStatus(response);
      setHasStorage(false);
    } catch (failure) {
      // Only the newest poll owns the error slot so a stale rejection never
      // clears a newer panel that already painted.
      if (loadGenerationRef.current !== generation) return null;
      setError(
        failure instanceof ApiError ? failure.message : "Failed to load index status",
      );
      return null;
    }
    // Phase 2 fires without awaiting paint so the cold mount paints counts,
    // pills, and the last-run strip immediately. The generation guard keeps
    // only the newest storage answer when polls overlap.
    void (async () => {
      try {
        const s = await getIndexStorage();
        if (loadGenerationRef.current !== generation) return;
        setStatus((prev) => {
          if (prev == null) return prev;
          const merged: IndexStatusResponse & IndexStorageResponse = {
            ...prev,
            bytes: s.bytes ?? prev.bytes,
            textBytes: s.textBytes ?? prev.textBytes,
            vectorBytes: s.vectorBytes ?? prev.vectorBytes,
            ftsBytes: s.ftsBytes ?? prev.ftsBytes,
            freeBytes: s.freeBytes ?? prev.freeBytes,
            dbFileBytes: s.dbFileBytes ?? prev.dbFileBytes,
            walBytes: s.walBytes ?? prev.walBytes,
            contentBytes: s.contentBytes ?? prev.contentBytes,
            bySource: s.bySource != null && s.bySource.length > 0 ? s.bySource : prev.bySource,
          };
          // Recommit the module cache so a tab switch paints merged sizes instantly.
          cachedIndexStatus = merged;
          return merged;
        });
        // Slow arrival flips the sizing gate so an honest empty index hides
        // the sizing copy once slow lands instead of gating on non-zero.
        cachedHasStorage = true;
        setHasStorage(true);
      } catch {
        // Storage failure leaves phase-1 state plus the existing error slot
        // untouched and never nulls status.
      }
    })();
    return fast;
  }, []);

  // Live-only poll while a run is in flight: fetches status but adopts only
  // the live snapshot plus the running flag, holding every committed card
  // frozen on the last settled snapshot. The cards jump atomically on the
  // run_completed reload below, never mid-run.
  const loadLiveOnly = useCallback(async () => {
    try {
      const fresh = await getIndexStatus();
      setStatus((prev) => {
        if (prev == null) {
          cachedIndexStatus = fresh;
          return fresh;
        }
        const merged: IndexStatusResponse & IndexStorageResponse = {
          ...prev,
          running: fresh.running,
          live: fresh.live,
        };
        cachedIndexStatus = merged;
        return merged;
      });
    } catch {
      // Live-only failure leaves the frozen cards plus the existing error
      // slot untouched and never nulls status.
    }
  }, []);

  useEffect(() => {
    void loadStatus();
  }, [loadStatus]);

  // Live broadcast consumer: run_completed jumps the frozen cards atomically
  // via a full reload with no manual Refresh control, while `tool_progress`
  // and run_started only refresh the live snapshot — numbers always come from
  // the polled status live snapshot, never from frame parsing. A
  // launch-triggered nightly or catch-up pass this panel did not start also
  // raises an auto-start notice naming the trigger display label explicitly.
  const handleIndexBroadcast = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as WSGenericFrame).type;
      if (frameType === "run_started" || frameType === "run_completed") {
        const nested = (frame as WSGenericFrame).run as
          | { kind?: unknown; message?: unknown; response?: unknown }
          | undefined;
        const isIndexKind =
          typeof nested?.kind === "string" && nested.kind === "index";
        if (frameType === "run_started" && isIndexKind) {
          if (!runActiveRef.current && !cancellingRef.current) {
            const notice = describeAutoStartNotice({
              message: nested.message,
              response: nested.response,
            });
            if (notice) {
              setNotice(notice);
            }
          }
        }
        if (frameType === "run_completed" && isIndexKind) {
          if (cancellingRef.current) {
            // The cancelling window ends on the terminal broadcast. A run this
            // panel started still resolves through its awaiting run request with
            // full counts, so only a remote run refreshes its kept-work notice
            // from the reloaded strip entry; the status reload below settles
            // the pill either way and unmounts the live block on settle.
            const wasLocal = runActiveRef.current;
            cancellingRef.current = false;
            setCancelling(false);
            if (!wasLocal) {
              void loadStatus().then((fresh) => {
                if (fresh?.lastRun) {
                  setNotice(describeIndexRun(fresh.lastRun));
                } else {
                  setNotice(
                    "Last run cancelled · Committed work is kept and the next run resumes from there.",
                  );
                }
              });
              return;
            }
          }
          void loadStatus();
          return;
        }
        // Freeze-then-jump: a run_started frame only refreshes the live
        // snapshot so the committed cards stay frozen; the atomic jump lands
        // on run_completed below.
        if (isIndexKind) {
          void loadLiveOnly();
        }
        return;
      }
      if (frameType !== "tool_progress") return;
      const progress = frame as WSToolProgressFrame;
      if (
        !isIndexProgressFrame(
          progress,
          runActiveRef.current || cancellingRef.current || statusRunningRef.current,
        )
      )
        return;
      // Poll-now trigger only for the live block: the live numbers render from
      // status live, so a frame refreshes only live while committed cards stay
      // frozen instead of distilling counters locally.
      void loadLiveOnly();
    },
    [loadStatus, loadLiveOnly],
  );

  useSharedWebSocket(handleIndexBroadcast);

  // Clears the local run flight once the engine reports no run in flight, so a
  // run started from another tab still settles the panel's busy state. The
  // cancelling window settles the same way when the broadcast is missed: the
  // status probe is authoritative, so a remote cancel still reaches its shared
  // kept-work notice from the strip entry and re-enables Run without a
  // separate Stopped variant. The live block unmounts through the cleared
  // status live snapshot, so a missed broadcast never strands stale content
  // on screen.
  useEffect(() => {
    if (status?.running !== false) return;
    // Capture locality before clearing: a run this panel started resolves
    // through its awaiting request with full counts, so only a remote run
    // refreshes its notice here from the shared strip entry.
    const wasLocalRun = runActiveRef.current;
    if (wasLocalRun) {
      runActiveRef.current = false;
      setRunActive(false);
    }
    if (!cancellingRef.current) return;
    if (!wasLocalRun) {
      if (status?.lastRun) {
        setNotice(describeIndexRun(status.lastRun));
      } else {
        setNotice(
          "Last run cancelled · Committed work is kept and the next run resumes from there.",
        );
      }
    }
    cancellingRef.current = false;
    setCancelling(false);
  }, [status?.running, status?.lastRun]);

  // Freeze-then-jump live poll while a run is in flight: polls only the live
  // snapshot about every two seconds while progress is active or the
  // cancelling window is open, so the live block stays live while the
  // committed cards hold the last settled snapshot frozen with no reload and
  // no flash. Pauses while the tab is hidden and clears on settle through the
  // effect deps. Mount, broadcast run_completed, and after-action loads perform
  // the atomic jump, and a missed broadcast still settles promptly.
  useEffect(() => {
    if (!progressActive && !cancelling) return;
    const timer = setInterval(() => {
      if (typeof document !== "undefined" && document.hidden) return;
      void loadLiveOnly();
    }, 2000);
    return () => clearInterval(timer);
  }, [progressActive, cancelling, loadLiveOnly]);

  // Starts an on-demand run and awaits its terminal summary. The polled live
  // snapshot keeps the live block honest while the request is in flight; the
  // summary fills the notice through the shared run formatter so the notice
  // and the reloaded strip read identically. A locally cancelled run settles
  // here with its full counts, clearing the cancelling window without
  // overwriting the detailed summary. The live block unmounts on settle when
  // the engine clears the snapshot, with no persistence.
  const handleRun = async () => {
    if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) return;
    runActiveRef.current = true;
    setRunActive(true);
    setAction("run");
    setError(null);
    setNotice(null);
    try {
      const summary = await runIndex();
      setNotice(describeIndexRun(summary));
      // The run reached its terminal summary, so any cancelling window opened
      // by a concurrent cancel request is over; the detailed summary above
      // already carries the kept-work copy for the cancelled case.
      if (cancellingRef.current) {
        cancellingRef.current = false;
        setCancelling(false);
      }
      await loadStatus();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Index run failed");
    } finally {
      runActiveRef.current = false;
      setRunActive(false);
      setAction(null);
    }
  };

  // Asks the engine to stop an in-flight run, then holds the cancelling window
  // until the terminal broadcast or the status probe reports a settled run.
  // Committed work survives, so a cancelled run simply resumes from the first
  // unfinished item on the next run. Cancel rides its own busy flag so it can
  // run concurrent with Run instead of multiplexing one shared action slot.
  const handleCancel = async () => {
    if (cancelBusy || cancellingRef.current) return;
    if (action === "prune" || action === "reset" || action === "reclaim") return;
    setCancelBusy(true);
    setError(null);
    try {
      const response = await cancelIndex();
      if (response?.cancelled) {
        // Enter the cancelling window: the pill flips to Cancelling, both Run
        // and Cancel stay disabled, and the kept-work notice lands only once
        // the run actually settles instead of on the request itself.
        cancellingRef.current = true;
        setCancelling(true);
      } else {
        setNotice("No index run was in flight.");
      }
      await loadStatus();
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Failed to cancel index run",
      );
    } finally {
      setCancelBusy(false);
    }
  };

  // Compacts the index database, then shows the before and after on-disk
  // figures so the reclaimed delta reads without reopening the size card.
  // Blocked while a run is in flight like prune and reset, since compaction
  // races the writer.
  const handleGrantAccess = async (kind: string) => {
    if (accessBusy[kind]) return;
    setAccessBusy((prev) => ({ ...prev, [kind]: true }));
    try {
      await requestIndexAccess(kind);
      await loadStatus();
    } catch {
      // Keep the Grant affordance so the owner can retry explicitly.
    } finally {
      setAccessBusy((prev) => ({ ...prev, [kind]: false }));
    }
  };

  const handleReclaim = async () => {
    if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) return;
    setAction("reclaim");
    setError(null);
    setNotice(null);
    try {
      const response = await reclaimIndex();
      setReclaimResult(response);
      const summary = formatIndexReclaimResult(response);
      if (summary) setNotice(summary);
      await loadStatus();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to reclaim index space");
    } finally {
      setAction(null);
    }
  };

  const handleConfirmPrune = async () => {
    if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) {
      setPruneError("An index run is in flight — wait for it to settle before pruning.");
      return;
    }
    const trimmed = pruneBefore.trim();
    if (!trimmed) {
      setPruneError("Choose a cutoff date before pruning.");
      return;
    }
    // The date input yields a calendar day with no zone; build local midnight
    // from its parts so toISOString ships the operator's day instead of a
    // UTC-midnight value shifted by the timezone offset.
    const dateParts = trimmed.split("-").map(Number);
    let cutoff: Date;
    if (
      dateParts.length === 3 &&
      dateParts.every((part) => Number.isFinite(part)) &&
      Number.isInteger(dateParts[0]) &&
      Number.isInteger(dateParts[1]) &&
      Number.isInteger(dateParts[2])
    ) {
      const [year, month, day] = dateParts as [number, number, number];
      cutoff = new Date(year, month - 1, day);
      if (
        Number.isNaN(cutoff.getTime()) ||
        cutoff.getFullYear() !== year ||
        cutoff.getMonth() !== month - 1 ||
        cutoff.getDate() !== day
      ) {
        setPruneError("Choose a valid cutoff date before pruning.");
        return;
      }
    } else {
      cutoff = new Date(trimmed);
      if (Number.isNaN(cutoff.getTime())) {
        setPruneError("Choose a valid cutoff date before pruning.");
        return;
      }
    }
    setPruneError(null);
    setPendingPrune(false);
    setAction("prune");
    setError(null);
    setNotice(null);
    try {
      const response = await pruneIndex(cutoff.toISOString());
      setNotice(
        `Pruned ${formatIndexCount(response?.removed ?? 0)} document${response?.removed === 1 ? "" : "s"} indexed before ${formatIndexAsOf(response?.before)}.`,
      );
      await loadStatus();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to prune the index");
    } finally {
      setAction(null);
    }
  };

  const handleConfirmRebuild = async () => {
    if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) {
      setResetError("An index run is in flight — wait for it to settle before resetting.");
      return;
    }
    setResetError(null);
    setPendingRebuild(false);
    setAction("reset");
    setError(null);
    setNotice(null);
    try {
      await resetIndex();
      setNotice("Index cleared. Run Rebuild to re-index from scratch.");
      await loadStatus();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to reset the index");
    } finally {
      setAction(null);
    }
  };

  // The grep-style live block mounts only from the polled live snapshot — or
  // during the cancelling window — and unmounts fully on settle with no
  // persistence. Without live data it renders nothing; the Status pill below
  // owns the Running indicator so the block never duplicates it.
  const showLiveBlock = live != null || cancelling;
  // Line 1 without any pill: trigger label plus stage-aware title with counts,
  // rate, and elapsed while the snapshot is present, and Cancelling… during
  // the stop window. Never renders a Running fallback.
  // Honest rate for the cancelling branch, shared with the live header so both
  // surfaces omit early-run spikes and absurd wire values identically.
  const cancellingRate = live
    ? formatIndexRate(
        typeof live.rate === "number" ? live.rate : null,
        typeof live.elapsedMs === "number" ? live.elapsedMs : 0,
      )
    : null;
  const cancellingRatePart = cancellingRate ? ` · ${cancellingRate}` : "";
  const liveHeaderText = cancelling
    ? live
      ? `Cancelling… ${formatIndexCount(live.scanned)} scanned · ${formatIndexCount(live.indexed)} indexed${cancellingRatePart} · ${formatToolProgressElapsedMs(typeof live.elapsedMs === "number" ? live.elapsedMs : 0)}`
      : "Cancelling…"
    : (formatIndexLiveHeader(live) ?? "");
  // Fresh stores have no last run yet: while the first pass is in flight the
  // live block already proves liveness, so the last-run line names it instead
  // of reading as an empty history. The shared resolver keeps the two empty
  // copies from ever contradicting each other.
  const lastRunText = resolveIndexLastRunText(
    status?.lastRun ?? null,
    progressActive || showLiveBlock || cancelling,
  );
  // Last-errors card projection: deduped lines with the raw Full Disk Access
  // bullet suppressed whenever the guided onboarding renders, since the
  // guidance is the formatted form of that failure. The guidance flag reads
  // the raw payload so it still fires when every line is a denial and the
  // visible list collapses to guidance-only. The header count stays
  // guidance-inclusive over the deduped raw payload so a guidance-only denial
  // still reads as Last errors (1) instead of (0).
  const displayErrors = resolveDisplayIndexErrors(status?.lastErrors);
  const showFdaGuidance = hasFullDiskAccessError(status?.lastErrors);
  const totalErrorCount = dedupeIndexErrors(status?.lastErrors).length;
  const hasErrorBlock = displayErrors.length > 0 || showFdaGuidance;
  // Prunes the expanded set to the current display list so a failure that
  // ages out of lastErrors cannot keep its full text alive in state, bounding
  // the set to the visible rows instead of every error ever seen.
  useEffect(() => {
    const allowed = new Set(resolveDisplayIndexErrors(status?.lastErrors));
    setExpandedErrors((previous) => {
      if (previous.size === 0) return previous;
      let pruned = false;
      for (const entry of previous) {
        if (!allowed.has(entry)) {
          pruned = true;
          break;
        }
      }
      if (!pruned) return previous;
      const next = new Set<string>();
      for (const entry of previous) {
        if (allowed.has(entry)) next.add(entry);
      }
      return next;
    });
  }, [status?.lastErrors]);

  return (
    <section className="panel indexing-panel" aria-label="Index Status">
      {hideHeader ? null : (
        <div className="panel-header-row">
          <div>
            <h2>Index Status</h2>
            <p className="muted text-sm">
              Monitor the local file, mail, and Messages index.
            </p>
          </div>
        </div>
      )}

      {error ? <p className="error">{error}</p> : null}
      {notice ? <p className="muted text-sm">{notice}</p> : null}

      {/* Run controls top: start, stop, prune, reclaim, and reset sit above
          the numbers they act on. Each destructive action opens its own modal
          carrying the description, so no helper text repeats under the row.
          Reclaim compacts without deleting content, so it needs no modal. */}
      <div className="index-actions-section">
        <h3>Run</h3>
        <div className="row">
          <button
            type="button"
            className="primary icon-text-btn"
            onClick={() => void handleRun()}
            disabled={actionBusy || cancelBusy || cancelling || !indexingEnabled || progressActive}
            title={
              indexingEnabled
                ? "Run an on-demand index pass"
                : "Enable indexing to run a pass"
            }
          >
            <span>
              {action === "run" ? "Indexing…" : "Run"}
            </span>
          </button>

          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void handleCancel()}
            disabled={cancelBusy || cancelling || !progressActive || action === "prune" || action === "reset" || action === "reclaim"}
          >
            <StopIcon size={14} />
            <span>{cancelBusy || cancelling ? "Cancelling…" : "Cancel"}</span>
          </button>

          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => {
              setPruneBefore("");
              setPruneError(null);
              setPendingPrune(true);
            }}
            disabled={actionBusy || cancelBusy || progressActive || cancelling}
          >
            <TrashIcon size={14} />
            <span>{action === "prune" ? "Pruning…" : "Prune"}</span>
          </button>

          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void handleReclaim()}
            disabled={actionBusy || cancelBusy || progressActive || cancelling}
            title="Compact the index database to reclaim free space"
          >
            <span>{action === "reclaim" ? "Reclaiming…" : "Reclaim space"}</span>
          </button>

          <button
            type="button"
            className="danger icon-text-btn"
            onClick={() => {
              setResetError(null);
              setPendingRebuild(true);
            }}
            disabled={actionBusy || cancelBusy || progressActive || cancelling}
          >
            <TrashIcon size={14} />
            <span>{action === "reset" ? "Clearing…" : "Reset Index"}</span>
          </button>
        </div>
        {/* Disabled-index hint under the Run row; prune/reclaim/reset stay
            independent of the enabled flag. */}
        {status?.enabled === false ? (
          <p className="muted text-sm">
            Indexing is off — turn it on in Settings → Indexing to run a pass.
          </p>
        ) : null}
        {/* Reclaim outcome keeps both on-disk figures visible after the size
            card reloads, so the compaction delta never scrolls away with the
            transient notice. */}
        {reclaimSummary ? (
          <p
            className="muted text-sm"
            data-testid="index-reclaim-result"
            style={{ marginTop: 8 }}
          >
            {reclaimSummary}
          </p>
        ) : null}
      </div>

      {/* Grep-style live block under Run while the polled snapshot is present:
          line 1 trigger plus stage-aware counts, line 2 single truncated
          relative file with full-path title, line 3 indeterminate activity bar
          reusing the ToolProgress activity style (activity only, never
          percent). Unmounts fully on settle; without live data it renders
          nothing and the Status pill owns Running. */}
      {showLiveBlock && (
        <div className="index-live-progress" data-testid="index-live-progress">
          <div
            className="index-live-header muted text-xs"
            data-testid="index-live-header"
          >
            {liveHeaderText}
          </div>
          {liveCurrent ? (
            <div
              className="tool-progress-current index-live-current"
              data-testid="index-live-current"
              title={liveCurrent}
            >
              {liveCurrent}
            </div>
          ) : null}
          <div
            className="tool-progress-shimmer index-live-activity"
            data-testid="index-live-activity"
            role="progressbar"
            aria-label="Index run in progress"
            aria-valuetext="In progress"
          />
        </div>
      )}

      {/* Stat cards middle: frozen committed size, counts with the
          vector/keyword split, prominent watermark age, per-source pills,
          last-run strip, and recent failures. Freeze-then-jump: cards hold the
          last settled snapshot mid-run and jump atomically at completion while
          only the live block above stays live. */}
      <div className="index-status-section">
        <h3>Status</h3>
        <div className="index-status-line">
          {cancelling ? (
            <span className="status-pill running">Cancelling</span>
          ) : status?.running || runActive ? (
            <span className="status-pill running">Running</span>
          ) : status?.enabled ? (
            <span className="status-pill ok">Enabled</span>
          ) : (
            <span className="status-pill skipped">Disabled</span>
          )}
        </div>

        {status ? (
          <>
            {/* Last-run strip distilled from the newest index-kind run log row:
                status plus indexed/scanned/errors/retired/truncated and the
                finish time, so the latest outcome reads without opening run
                history. A first run in flight names itself instead of reading
                as empty history. The retired and truncated badges mirror the
                shared formatter so the counts read identically in the notice
                and the strip. */}
            <div
              className="index-last-run"
              data-testid="index-last-run"
              style={{ marginTop: 12 }}
            >
              <span className="muted text-sm">{lastRunText}</span>
              {lastRunRetired != null && lastRunRetired > 0 ? (
                <span
                  className="muted text-sm"
                  data-testid="index-last-run-retired"
                  style={{ marginLeft: 8 }}
                >
                  {formatIndexCount(lastRunRetired)} retired
                </span>
              ) : null}
              {lastRunTruncated != null && lastRunTruncated > 0 ? (
                <span
                  className="muted text-sm"
                  data-testid="index-last-run-truncated"
                  style={{ marginLeft: 8 }}
                >
                  {formatIndexCount(lastRunTruncated)} truncated
                </span>
              ) : null}
            </div>
            {/* Resolved effort reality for the status pane: the engine preset
                plus the worker resolution against the machine cores. Rendered
                only when the engine carries an effort signal so older engines
                never invent a preset. The editable control lives in Settings →
                Indexing; this line is the read-only mirror. */}
            {statusEffortReality ? (
              <p
                className="muted text-sm"
                data-testid="index-effort-status"
                style={{ marginTop: 8, marginBottom: 0 }}
              >
                {statusEffortReality}
              </p>
            ) : null}
            <div
              className="index-stat-cards"
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))",
                gap: 12,
                marginTop: 12,
              }}
            >
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Size on disk</div>
                {/* Freeze-then-jump: committed cards hold the last settled snapshot
                    mid-run with no flash; only the live block above stays live. */}
                <div
                  className="index-stat-value"
                  data-testid="index-stat-size-value"
                  style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}
                >
                  <span data-testid="index-stat-size-figure">
                    {formatIndexBytes(storage.onDisk)}
                  </span>
                  {/* Explicit sizing state while slow storage is pending:
                      inline copy beside the figure with no spinner so the card
                      never shifts layout when exact sizes fill in. Gated on
                      slow arrival so an honest empty index hides it once slow
                      lands instead of gating on non-zero breakdown. */}
                  {storage.hasStorage ? null : (
                    <span
                      className="muted text-xs"
                      data-testid="index-size-sizing"
                      style={{ marginLeft: 8, fontWeight: 400, fontSize: 12 }}
                    >
                      Sizing storage…
                    </span>
                  )}
                </div>
                {/* Breakdown row for the on-disk figure: text, vectors, FTS,
                    and free space. Omitted for older engines without the
                    storage rows so the card never renders a row of zeros. */}
                {storage.hasBreakdown ? (
                  <div
                    className="muted text-xs"
                    data-testid="index-size-breakdown"
                    style={{ marginTop: 4 }}
                  >
                    <span data-testid="index-size-text">
                      Text {formatIndexBytes(storage.text)}
                    </span>
                    {" · "}
                    <span data-testid="index-size-vectors">
                      Vectors {formatIndexBytes(storage.vector)}
                    </span>
                    {" · "}
                    <span data-testid="index-size-fts">
                      FTS {formatIndexBytes(storage.fts)}
                    </span>
                    {" · "}
                    <span data-testid="index-size-free">
                      Free {formatIndexBytes(storage.free)}
                    </span>
                  </div>
                ) : null}
                {/* On-disk file detail: database file plus write-ahead log, the
                    two addends behind the primary figure. Omitted for older
                    engines without the file sizes. */}
                {storage.hasOnDisk ? (
                  <div
                    className="muted text-xs"
                    data-testid="index-size-files"
                    style={{ marginTop: 2 }}
                  >
                    DB {formatIndexBytes(storage.dbFile)} · WAL{" "}
                    {formatIndexBytes(storage.wal)}
                  </div>
                ) : null}
                {/* Content bytes stay as the secondary detail so the pane never
                    loses the pre-existing figure while the primary moves to
                    the honest on-disk total. */}
                <div
                  className="muted text-xs"
                  data-testid="index-size-content"
                  style={{ marginTop: 2 }}
                >
                  Content {formatIndexBytes(storage.content)}
                </div>
              </div>
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Documents</div>
                <div
                  className="index-stat-value"
                  data-testid="index-stat-documents-value"
                  style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}
                >
                  {formatIndexCount(status.documents)}
                </div>
              </div>
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Chunks</div>
                <div
                  className="index-stat-value"
                  data-testid="index-stat-chunks-value"
                  style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}
                >
                  {formatIndexCount(status.chunks)}
                </div>
                <div className="muted text-xs" style={{ marginTop: 2 }}>
                  {formatIndexCount(status.vectorChunks)} vector · {formatIndexCount(status.keywordChunks)} keyword
                </div>
              </div>
              <div
                className="card index-stat-card index-watermark-card"
                data-testid="index-watermark-card"
                style={{
                  padding: 12,
                  marginBottom: 0,
                  borderWidth: 2,
                  borderStyle: "solid",
                }}
              >
                <div className="muted text-xs">Last indexed</div>
                <div style={{ fontSize: 22, fontWeight: 800, marginTop: 2 }}>
                  {formatIndexAge(status.indexAsOf)}
                </div>
                <div className="muted text-xs" style={{ marginTop: 2 }}>
                  {formatIndexAsOf(status.indexAsOf)}
                </div>
              </div>
            </div>

            {status.sources.length > 0 ? (
              <div
                className="index-source-pills"
                style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 12 }}
              >
                {status.sources.map((source) => {
                  const tone = indexSourcePillTone(source);
                  const title = indexSourcePillTitle(source);
                  const showGrant = shouldShowIndexGrantButton(source);
                  const showDenied = shouldShowIndexAccessDeniedGuidance(source);
                  return (
                    <span
                      key={source.kind}
                      className={`status-pill ${tone}`}
                      title={title ?? undefined}
                    >
                      {sourceLabel(source.kind)} · {source.enabled ? "On" : "Off"}
                      {showGrant ? (
                        <button
                          type="button"
                          className="ghost"
                          aria-label={`Grant ${sourceLabel(source.kind)} access`}
                          disabled={!!accessBusy[source.kind]}
                          onClick={() => void handleGrantAccess(source.kind)}
                          style={{ marginLeft: 8 }}
                        >
                          {accessBusy[source.kind] ? "Requesting…" : "Grant"}
                        </button>
                      ) : null}
                      {showDenied ? (
                        <span
                          className="muted text-xs"
                          style={{ marginLeft: 8 }}
                        >
                          {indexAccessDeniedGuidance(source.kind)}
                        </span>
                      ) : null}
                    </span>
                  );
                })}
              </div>
            ) : null}
          </>
        ) : (
          <div className="index-status-skeleton" data-testid="index-status-skeleton" role="status" aria-busy="true" aria-label="Loading index status">
            {/* Cold-boot skeleton: same card and pill geometry as the loaded panel
                so the first paint reserves space without the old text paragraph. */}
            <div
              className="index-stat-cards"
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))",
                gap: 12,
                marginTop: 12,
              }}
            >
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Size on disk</div>
                <div className="index-stat-value muted text-sm">Loading…</div>
              </div>
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Documents</div>
                <div className="index-stat-value muted text-sm">Loading…</div>
              </div>
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Chunks</div>
                <div className="index-stat-value muted text-sm">Loading…</div>
              </div>
              <div
                className="card index-stat-card index-watermark-card"
                style={{
                  padding: 12,
                  marginBottom: 0,
                  borderWidth: 2,
                  borderStyle: "solid",
                }}
              >
                <div className="muted text-xs">Last indexed</div>
                <div className="index-stat-value muted text-sm">Loading…</div>
              </div>
            </div>
            <div
              className="index-source-pills"
              style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 12 }}
            >
              <span className="status-pill skipped">Loading…</span>
              <span className="status-pill skipped">Loading…</span>
              <span className="status-pill skipped">Loading…</span>
            </div>
          </div>
        )}
      </div>

      {/* Charts bottom: frontend-only SVG donut (vector vs keyword), CSS bars
          for real per-source content (documents/chunks/bytes by source), and
          bars for the extraction-outcome breakdown — plain markup computed
          from the status payload, no chart dependency and no extra route. */}
      {status ? (
        <div className="index-charts-section">
          <h3>Charts</h3>
          <div
            style={{
              display: "flex",
              flexWrap: "wrap",
              gap: 24,
              alignItems: "flex-start",
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
              <svg
                width={DONUT_SIZE}
                height={DONUT_SIZE}
                viewBox={`0 0 ${DONUT_SIZE} ${DONUT_SIZE}`}
                role="img"
                aria-label={`${formatIndexCount(vectorChunks)} vector chunks, ${formatIndexCount(keywordChunks)} keyword chunks`}
                data-testid="index-donut-chart"
              >
                <circle
                  cx={DONUT_SIZE / 2}
                  cy={DONUT_SIZE / 2}
                  r={DONUT_RADIUS}
                  fill="none"
                  stroke={CHART_TRACK_COLOR}
                  strokeWidth={DONUT_STROKE}
                />
                <circle
                  cx={DONUT_SIZE / 2}
                  cy={DONUT_SIZE / 2}
                  r={DONUT_RADIUS}
                  fill="none"
                  stroke={CHART_VECTOR_COLOR}
                  strokeWidth={DONUT_STROKE}
                  strokeDasharray={`${donut.vectorDash} ${donut.circumference - donut.vectorDash}`}
                  transform={`rotate(-90 ${DONUT_SIZE / 2} ${DONUT_SIZE / 2})`}
                />
                <circle
                  cx={DONUT_SIZE / 2}
                  cy={DONUT_SIZE / 2}
                  r={DONUT_RADIUS}
                  fill="none"
                  stroke={CHART_KEYWORD_COLOR}
                  strokeWidth={DONUT_STROKE}
                  strokeDasharray={`${donut.keywordDash} ${donut.circumference - donut.keywordDash}`}
                  strokeDashoffset={-donut.vectorDash}
                  transform={`rotate(-90 ${DONUT_SIZE / 2} ${DONUT_SIZE / 2})`}
                />
              </svg>
              <div
                style={{ display: "flex", flexDirection: "column", gap: 6 }}
                className="text-sm"
              >
                <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                  <span
                    style={{
                      width: 10,
                      height: 10,
                      borderRadius: 2,
                      display: "inline-block",
                      background: CHART_VECTOR_COLOR,
                    }}
                  />
                  Vector <strong>{formatIndexCount(vectorChunks)}</strong>
                </span>
                <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                  <span
                    style={{
                      width: 10,
                      height: 10,
                      borderRadius: 2,
                      display: "inline-block",
                      background: CHART_KEYWORD_COLOR,
                    }}
                  />
                  Keyword <strong>{formatIndexCount(keywordChunks)}</strong>
                </span>
              </div>
            </div>

            <div
              data-testid="index-source-bars"
              style={{
                flex: "1 1 240px",
                minWidth: 200,
                display: "flex",
                flexDirection: "column",
                gap: 8,
              }}
            >
              {/* Share-of-index heading keeps the scaling honest: every bar
                  below is a fraction of the displayed total, so small buckets
                  read as slivers rather than competing for the longest slot. */}
              <h4 className="text-xs muted" style={{ margin: 0, fontWeight: 600 }}>
                Documents by source — share of index
              </h4>
              {sourceContent.map((source) => {
                // Width equals the rounded share with no visibility floor, so a
                // tiny bucket paints as a sliver while its label stays
                // truthful. Zero-document rows skip the track entirely so an
                // empty bar never reads as missing paint.
                const barWidth = indexSourceBarWidth(
                  source.documents,
                  sourceTotalDocuments,
                );
                const barLabel = indexSourceBarPercent(
                  source.documents,
                  sourceTotalDocuments,
                );
                const isEmpty = source.documents <= 0;
                // Stacked row keeps every track on its own full-width line so
                // label length and trailing counts can never shift the bar
                // origin: line one pairs the name with its share, line two
                // paints the full-width track, line three carries the totals.
                // A skipped source adds a muted fourth line with its verbatim
                // reason so it never renders as healthy silence.
                const skippedReason = resolveIndexSourceSkippedReason(
                  status?.lastRun ?? null,
                  source.kind,
                );
                return (
                  <div
                    key={source.kind}
                    style={{ display: "flex", flexDirection: "column", gap: 4 }}
                  >
                    <div
                      style={{
                        display: "flex",
                        justifyContent: "space-between",
                        alignItems: "baseline",
                        gap: 8,
                      }}
                    >
                      <span className="text-xs muted">
                        {sourceLabel(source.kind)}
                      </span>
                      {isEmpty ? null : (
                        <span
                          className="text-xs muted"
                          data-testid={`index-bar-pct-${source.kind}`}
                          style={{ textAlign: "right" }}
                        >
                          {barLabel}
                        </span>
                      )}
                    </div>
                    {isEmpty ? (
                      <span
                        className="text-xs muted"
                        data-testid={`index-bar-empty-${source.kind}`}
                      >
                        No data yet
                      </span>
                    ) : (
                      <div
                        style={{
                          width: "100%",
                          height: 10,
                          borderRadius: 5,
                          background: CHART_TRACK_COLOR,
                          overflow: "hidden",
                        }}
                      >
                        <div
                          data-testid={`index-bar-${source.kind}`}
                          aria-label={`${sourceLabel(source.kind)} ${formatIndexCount(source.documents)} documents`}
                          style={{
                            width: barWidth,
                            height: "100%",
                            borderRadius: 5,
                            background: CHART_VECTOR_COLOR,
                          }}
                        />
                      </div>
                    )}
                    <span className="text-xs muted">
                      {formatIndexCount(source.documents)} docs · {formatIndexCount(source.chunks)} chunks · {formatIndexBytes(source.bytes)}
                    </span>
                    {skippedReason ? (
                      <span
                        className="muted text-xs"
                        data-testid={`index-source-note-${source.kind}`}
                      >
                        {skippedReason}
                      </span>
                    ) : null}
                  </div>
                );
              })}
            </div>

            <div
              data-testid="index-extract-bars"
              style={{
                flex: "1 1 240px",
                minWidth: 200,
                display: "flex",
                flexDirection: "column",
                gap: 8,
              }}
            >
              {/* Same share-of-index contract as the source bars so both
                  breakdowns read as proportions of their own displayed total. */}
              <h4 className="text-xs muted" style={{ margin: 0, fontWeight: 600 }}>
                Extraction outcomes — share of index
              </h4>
              {extractRows.length > 0 ? (
                extractRows.map((row) => {
                  // Width equals the rounded share like the source bars above,
                  // so the paint and the label never disagree.
                  const barWidth = indexSourceBarWidth(
                    row.documents,
                    extractTotalDocuments,
                  );
                  const barLabel = indexSourceBarPercent(
                    row.documents,
                    extractTotalDocuments,
                  );
                  const isEmpty = row.documents <= 0;
                  // Same stacked contract as the source chart so both groups
                  // share one row geometry: label plus share on line one, a
                  // full-width track on line two, totals on line three.
                  return (
                    <div
                      key={row.status}
                      style={{ display: "flex", flexDirection: "column", gap: 4 }}
                    >
                      <div
                        style={{
                          display: "flex",
                          justifyContent: "space-between",
                          alignItems: "baseline",
                          gap: 8,
                        }}
                      >
                        <span className="text-xs muted">
                          {extractStatusLabel(row.status)}
                        </span>
                        {isEmpty ? null : (
                          <span
                            className="text-xs muted"
                            data-testid={`index-extract-pct-${row.status}`}
                            style={{ textAlign: "right" }}
                          >
                            {barLabel}
                          </span>
                        )}
                      </div>
                      {isEmpty ? (
                        <span
                          className="text-xs muted"
                          data-testid={`index-extract-empty-${row.status}`}
                        >
                          No data yet
                        </span>
                      ) : (
                        <div
                          style={{
                            width: "100%",
                            height: 10,
                            borderRadius: 5,
                            background: CHART_TRACK_COLOR,
                            overflow: "hidden",
                          }}
                        >
                          <div
                            data-testid={`index-extract-bar-${row.status}`}
                            aria-label={`${extractStatusLabel(row.status)} ${formatIndexCount(row.documents)} documents`}
                            style={{
                              width: barWidth,
                              height: "100%",
                              borderRadius: 5,
                              background: CHART_EXTRACT_COLOR,
                            }}
                          />
                        </div>
                      )}
                      <span className="text-xs muted">
                        {formatIndexCount(row.documents)} docs
                      </span>
                    </div>
                  );
                })
              ) : (
                <span className="text-xs muted" data-testid="index-extract-empty">
                  No data yet
                </span>
              )}
            </div>
          </div>
        </div>
      ) : null}

      {/* Last errors below the charts: rows stay collapsed behind their header
          toggle so a noisy pass never pushes the charts, with the full list
          in a fixed inset scroll once expanded. The Full Disk Access guidance
          stays visible even while collapsed so the actionable onboarding never
          hides behind Show. When the display list is empty (guidance-only
          denial) the header renders a static count with no toggle, so the
          Show/Hide affordance never flips with zero visible change. Row
          markup, test ids, per-row expand controls, and the guided onboarding
          stay owned here. */}
      {hasErrorBlock ? (
        <div
          className="index-errors"
          aria-label="Last index errors"
          data-testid="index-last-errors"
        >
          {displayErrors.length > 0 ? (
            <button
              type="button"
              className="ghost index-errors-header-toggle muted text-xs"
              data-testid="index-errors-header-toggle"
              aria-expanded={errorsExpanded}
              onClick={() => setErrorsExpanded((previous) => !previous)}
            >
              <span>Last errors ({formatIndexCount(totalErrorCount)})</span>
              <span>{errorsExpanded ? "Hide" : "Show"}</span>
            </button>
          ) : (
            <span
              className="index-errors-header-count muted text-xs"
              data-testid="index-errors-header-count"
            >
              <span>Last errors ({formatIndexCount(totalErrorCount)})</span>
            </span>
          )}
          {errorsExpanded && displayErrors.length > 0 ? (
                <div className="index-errors-scroll">
                  {/* Raw error rows own this list so guidance steps below never
                      read as raw rows when scoped by test id or assistive tech. */}
                  <ul data-testid="index-error-list" className="muted text-xs">
                    {displayErrors.map((detail, index) => {
                      // Per-row expansion looks up the full error text so the
                      // toggle survives status polls, while the React key stays
                      // a short hash plus position so kilobyte-long failures
                      // never become full-text keys. The test id uses the
                      // visible position so it stays O(1) and stable.
                      const expanded = expandedErrors.has(detail);
                      const long = isLongIndexError(detail);
                      const visibleText = expanded ? detail : truncateIndexError(detail);
                      // Truncated previews render as plain text: slicing raw
                      // markdown at the preview budget can split emphasis,
                      // code, or link syntax and misrender through MarkdownText,
                      // so only the expanded full text keeps markdown.
                      const showPlainPreview = long && !expanded;
                      return (
                        <li
                          key={`index-error-${index}-${hashIndexError(detail)}`}
                          data-testid={`index-last-error-${index}`}
                          className="index-error-row"
                        >
                          <span className="index-error-icon" aria-hidden="true">
                            <AlertTriangleIcon size={14} />
                          </span>
                          <span
                            className="index-error-text-wrap"
                            title={long && !expanded ? detail : undefined}
                          >
                            {showPlainPreview ? (
                              <span className="index-error-text">{visibleText}</span>
                            ) : (
                              <MarkdownText
                                text={visibleText}
                                className="index-error-text"
                              />
                            )}
                          </span>
                          {long ? (
                            <button
                              type="button"
                              className="ghost index-error-expand"
                              aria-expanded={expanded}
                              onClick={() => {
                                setExpandedErrors((previous) => {
                                  const next = new Set(previous);
                                  if (next.has(detail)) {
                                    next.delete(detail);
                                  } else {
                                    next.add(detail);
                                  }
                                  return next;
                                });
                              }}
                            >
                              <span>{expanded ? "Show less" : "Show more"}</span>
                            </button>
                          ) : null}
                        </li>
                      );
                    })}
                  </ul>
                </div>
              ) : null}
              {/* Guided onboarding for the Full Disk Access denial, always visible
                  even while the rows stay collapsed: macOS
                  offers no prompt API, so the denial only surfaces at
                  run time. The button navigates the top frame to the exact
                  Settings pane, where window.open would be treated as a
                  blocked popup for this system scheme. The steps name both
                  grants because macOS attributes the read to the host
                  process: RuneWeaver.app for the app, the terminal emulator
                  for rune-weaver serve. The raw denial bullet stays hidden
                  while this renders — the guidance is its formatted form. */}
              {showFdaGuidance ? (
                <div
                  className="index-fda-guidance"
                  data-testid="index-fda-guidance"
                  style={{ marginTop: 8 }}
                >
                  <p className="muted text-sm" style={{ marginBottom: 8 }}>
                    Messages indexing needs Full Disk Access. Grant it to
                    RuneWeaver.app — or to your terminal emulator (for example
                    Terminal.app or iTerm2) when you run rune-weaver serve —
                     then restart and press Run.
                  </p>
                  <button
                    type="button"
                    className="ghost icon-text-btn"
                    onClick={() => {
                      window.location.href = FULL_DISK_ACCESS_SETTINGS_URL;
                    }}
                  >
                    <span>Open Full Disk Access Settings</span>
                  </button>
                  <ol className="muted text-sm" style={{ marginTop: 8, paddingLeft: 20 }}>
                    <li>Open System Settings &gt; Privacy &amp; Security &gt; Full Disk Access.</li>
                    <li>Click + and add RuneWeaver.app — or your terminal emulator (for example Terminal.app or iTerm2) when you run rune-weaver serve.</li>
                    <li>Toggle the added entry ON and authenticate when prompted.</li>
                    <li>Quit and restart the app or terminal, then press Run.</li>
                  </ol>
                </div>
              ) : null}
        </div>
      ) : null}

      {pendingPrune ? (
        <Modal
          label="Confirm prune index"
          onClose={() => {
            if (action === "prune") return;
            setPendingPrune(false);
          }}
          containerClassName="modal-container index-prune-modal"
        >
          <div className="modal-header">
            <h3>Prune the index?</h3>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This removes documents indexed before the cutoff date you choose.
              Stored chunks for those documents are deleted and cannot be
              recovered. Intact documents are untouched.
            </p>
            <div className="form-group" style={{ marginTop: 12 }}>
              <label htmlFor="index-prune-before">Cutoff date</label>
              <input
                id="index-prune-before"
                type="date"
                className="input-field"
                value={pruneBefore}
                onChange={(event) => {
                  setPruneBefore(event.target.value);
                  if (pruneError) setPruneError(null);
                }}
              />
              {pruneError ? <p className="error">{pruneError}</p> : null}
            </div>
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={() => setPendingPrune(false)}>
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              aria-label="Confirm prune index"
              onClick={() => void handleConfirmPrune()}
            >
              Prune
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingRebuild ? (
        <Modal
          label="Confirm reset index"
          onClose={() => {
            if (action === "reset") return;
            setPendingRebuild(false);
          }}
          containerClassName="modal-container index-reset-modal"
        >
          <div className="modal-header">
            <h3>Reset the index?</h3>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This clears every indexed document and chunk. The next run rebuilds
              the index from scratch. This cannot be undone.
            </p>
            {resetError ? <p className="error">{resetError}</p> : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setPendingRebuild(false)}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              aria-label="Confirm reset index"
              onClick={() => void handleConfirmRebuild()}
            >
              Reset
            </button>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}

// Index policy form for the Settings → Indexing tab: master enablement,
// per-source toggles, exclude globs, caps, effort presets with thermal and
// power toggles, and the vision describe toggle, persisted only through this
// form's own Save. Status cards, charts, and run controls stay on the Memory
// tab so one surface never duplicates the other's control set.
export function IndexPolicyPanel() {
  const [config, setConfig] = useState<IndexConfigData>(DEFAULT_INDEX_CONFIG);
  const [excludeText, setExcludeText] = useState<string>(
    DEFAULT_INDEX_CONFIG.exclude.join("\n"),
  );
  const [mailboxDenyText, setMailboxDenyText] = useState<string>(
    DEFAULT_INDEX_MAILBOX_DENY_TEXT,
  );
  // Index roots textarea state, seeded from the loaded `config.roots` so the
  // walk boundary edits without TOML hand-edits. One root per line, trimmed
  // with blanks dropped on save; validation rejects empties and `..` before
  // any network write.
  const [rootsText, setRootsText] = useState<string>(
    DEFAULT_INDEX_CONFIG.roots.join("\n"),
  );
  // Loaded files allow roots from GET /settings for the outside-roots
  // informational warning. Null until the settings fetch settles so the
  // warning never fires on a default guess before the engine answers.
  const [filesAllowRoots, setFilesAllowRoots] = useState<string[] | null>(
    null,
  );
  const [saving, setSaving] = useState(false);
  // Engine core count from GET /index/status for the effort reality line.
  // Null until the status fetch settles so resolveMachineCores falls back to
  // the browser hardwareConcurrency instead of guessing.
  const [policyCoreCount, setPolicyCoreCount] = useState<number | null>(null);
  // Transient save feedback in a top-right stack so the confirmation never
  // blocks the form. Distinct notices stack with independent timers; an
  // identical copy replaces its sibling so repeat saves refresh one notice
  // instead of duplicating, matching the Settings save pattern.
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast } =
    useToastStack();
  // Save-and-restart inputs come from the fresh post-PUT status read in
  // handleSave, never from a cached flag, so a run started between boot and
  // save still counts and a disable-then-save never restarts. No running refs
  // are kept here (the dead runActiveRef was removed): the dashboard owns its
  // runActive/statusRunning guards for live polling, while this form only
  // needs the effort core count plus the fresh decision read. The loadStatus
  // and notice duplication with the dashboard stays local — different owners
  // with different lifecycles — to avoid a shared-hook refactor risk.
  // Restart outcome line rendered under the toast stack: the shared run
  // formatter keeps it identical to the status strip so the fresh run reads
  // the same in both places.
  const [notice, setNotice] = useState<string | null>(null);
  // Mounted guard for the save-and-restart chain: persist, status reads, the
  // cancel/poll/run sequence, and the toasts all settle after awaits, so an
  // unmount mid-save must skip every state update instead of writing into a
  // retired tree.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);
  const lastSavedSourcesRef = useRef<{ calendars: boolean; reminders: boolean } | null>(null);

  // Fresh status read shared by the boot load and the save-and-restart flow:
  // the saved policy stays enabled-aware while the running flag settles, so
  // the restart decision always observes the engine rather than a stale flag.
  // Only the effort core count is cached; running/enabled come from the fresh
  // response in handleSave.
  const loadStatus = useCallback(async () => {
    try {
      const response = await getIndexStatus();
      if (!mountedRef.current) return response;
      setPolicyCoreCount(resolveStatusEffort(response).coreCount);
      return response;
    } catch {
      return null;
    }
  }, []);

  // Loads the [index] section through the shared settings read so the editable
  // form starts from the stored policy. An older engine without the section
  // leaves the local defaults in place instead of blanking the form. Effort
  // knobs degrade to their defaults when the engine predates them so the
  // control never renders blank.
  const loadConfig = useCallback(async () => {
    try {
      const settings = await getSettings();
      const index = settings?.index;
      // Loaded files allow roots for the outside-roots warning: kept when the
      // engine sends an array so the warning compares live roots against the
      // live guard, otherwise cleared so no warning fires on a guess.
      const allowRoots = (settings as { filesAllowRoots?: unknown })
        ?.filesAllowRoots;
      if (mountedRef.current) {
        if (Array.isArray(allowRoots)) {
          setFilesAllowRoots(
            allowRoots
              .filter((entry): entry is string => typeof entry === "string")
              .map((entry) => entry.trim())
              .filter(Boolean),
          );
        } else {
          setFilesAllowRoots(null);
        }
      }
      if (index) {
        const merged: IndexConfigData = {
          ...DEFAULT_INDEX_CONFIG,
          ...index,
          roots: Array.isArray(index.roots) ? index.roots : DEFAULT_INDEX_CONFIG.roots,
          exclude: Array.isArray(index.exclude)
            ? index.exclude
            : DEFAULT_INDEX_CONFIG.exclude,
          mailboxDeny: Array.isArray(
            (index as IndexConfigData).mailboxDeny,
          )
            ? ((index as IndexConfigData).mailboxDeny as string[])
            : [...DEFAULT_INDEX_MAILBOX_DENY],
          // Read-only walker list: kept when the engine sends an array so the
          // detail block names exactly what the next run will skip, otherwise
          // left absent so older engines render generic copy without names.
          alwaysSkipped: Array.isArray(
            (index as IndexConfigData).alwaysSkipped,
          )
            ? (index as IndexConfigData).alwaysSkipped
            : undefined,
          effort: normalizeIndexEffortPreset(
            (index as IndexConfigData).effort ?? DEFAULT_INDEX_CONFIG.effort,
          ),
          // Worker count with fallback to DEFAULT_INDEX_WORKERS (not the 0 wire
          // default) so a custom preset with no stored value still opens on a
          // valid stepper count; preset saves send 0 regardless.
          workers:
            resolveIndexWorkersValue(index as IndexConfigData) ??
            DEFAULT_INDEX_WORKERS,
          thermalBackoff:
            typeof (index as IndexConfigData).thermalBackoff === "boolean"
              ? (index as IndexConfigData).thermalBackoff
              : DEFAULT_INDEX_CONFIG.thermalBackoff,
          pauseOnBattery:
            typeof (index as IndexConfigData).pauseOnBattery === "boolean"
              ? (index as IndexConfigData).pauseOnBattery
              : DEFAULT_INDEX_CONFIG.pauseOnBattery,
          maxVectorChunksPerDocument:
            resolveIndexVectorCapValue(index as IndexConfigData) ??
            (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number),
        };
        setConfig(merged);
        setExcludeText(merged.exclude.join("\n"));
        setMailboxDenyText(
          formatMailboxDenyText(merged.mailboxDeny),
        );
        // Seed the roots textarea from the loaded `config.roots` so edits
        // start from stored truth and reload without TOML hand-edits.
        setRootsText(formatIndexRootsText(merged.roots));
        lastSavedSourcesRef.current = {
          calendars: !!merged.calendars,
          reminders: !!merged.reminders,
        };
      }
    } catch {
      // A settings read failure leaves the local defaults; the save path
      // surfaces transport errors so the form stays usable.
    }
    // Status snapshot for the effort reality line and the save-and-restart
    // decision: the shared loader keeps the running flag fresh while a status
    // failure leaves the browser fallback in place.
    await loadStatus();
  }, [loadStatus]);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  // Persists the [index] patch and returns the saved enabled flag from the
  // PUT response (falling back to the pre-save closure only when the engine
  // omits the section), so handleSave restarts solely from post-save truth.
  // Throws on transport failure; the caller surfaces it as a save error.
  const persistConfig = useCallback(async (): Promise<boolean> => {
    const exclude = excludeText
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    // Denied mailboxes mirror the excludes editor: one glob per line,
    // trimmed, blanks dropped so an emptied editor opts every mailbox back
    // in instead of persisting whitespace rows.
    const mailboxDeny = parseMailboxDenyText(mailboxDenyText);
    // Index roots mirror the excludes editor: one root per line, trimmed with
    // blanks dropped, saved through the existing `roots` key with no API
    // shape change. Validation rejects empties and `..` in handleSave before
    // this runs, so this stays a pure parse.
    const roots = parseIndexRootsText(rootsText);
    const effort = normalizeIndexEffortPreset(config.effort);
    // Presets derive workers on the engine so they must save 0; only custom
    // carries an explicit 1..64 count. The stepper fallback stays
    // DEFAULT_INDEX_WORKERS (not the 0 wire default) so a custom preset with
    // no stored value still saves a valid count.
    const customWorkers =
      resolveIndexWorkersValue(config) ?? DEFAULT_INDEX_WORKERS;
    const workers = effort === "custom" ? customWorkers : 0;
    const vectorCap =
      resolveIndexVectorCapValue(config) ??
      (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number);
    const saved = await updateSettings({
      index: {
        enabled: config.enabled,
        files: config.files,
        mail: config.mail,
        messages: config.messages,
        calendars: config.calendars,
        reminders: config.reminders,
        roots,
        exclude,
        maxFileMB: config.maxFileMB,
        mailVectorWindow: config.mailVectorWindow,
        iCloudEvicted: config.iCloudEvicted,
        nightlyBudget: config.nightlyBudget,
        dbPath: config.dbPath.trim(),
        effort,
        workers,
        thermalBackoff: config.thermalBackoff ?? DEFAULT_INDEX_THERMAL_BACKOFF,
        pauseOnBattery:
          config.pauseOnBattery ?? DEFAULT_INDEX_PAUSE_ON_BATTERY,
        maxVectorChunksPerDocument: vectorCap,
        mailboxDeny: mailboxDeny,
      },
    });
    const index = saved?.index;
    if (index) {
      const merged: IndexConfigData = {
        ...DEFAULT_INDEX_CONFIG,
        ...index,
        roots: Array.isArray(index.roots) ? index.roots : DEFAULT_INDEX_CONFIG.roots,
        exclude: Array.isArray(index.exclude)
          ? index.exclude
          : DEFAULT_INDEX_CONFIG.exclude,
        mailboxDeny: Array.isArray(
          (index as IndexConfigData).mailboxDeny,
        )
          ? ((index as IndexConfigData).mailboxDeny as string[])
          : [...DEFAULT_INDEX_MAILBOX_DENY],
        alwaysSkipped: Array.isArray(
          (index as IndexConfigData).alwaysSkipped,
        )
          ? (index as IndexConfigData).alwaysSkipped
          : undefined,
      };
      if (mountedRef.current) {
        setConfig(merged);
        setExcludeText(merged.exclude.join("\n"));
        setMailboxDenyText(
          formatMailboxDenyText(merged.mailboxDeny),
        );
        // Keep the textarea synced to the saved echo so save-plus-reload
        // stays honest without TOML hand-edits.
        setRootsText(formatIndexRootsText(merged.roots));
      }
    }
    // Saved enabled truth for the restart gate: the engine echo wins so a
    // disable-then-save never restarts from a stale pre-save closure.
    return typeof index?.enabled === "boolean" ? index.enabled : config.enabled;
  }, [config, excludeText, mailboxDenyText, rootsText]);

  // Sole owner of save-and-restart: the settings patch never auto-starts a
  // run, so a policy saved mid-scan must stop the old generation and start a
  // fresh one with the new roots/excludes/caps. An idle save or a save with
  // the master switch off keeps the save-only path and starts nothing, while
  // a restart failure still leaves the saved policy in place. Order stays
  // persist -> cancel -> poll -> run -> load; both decision inputs come from
  // post-PUT truth (saved enabled plus the fresh status read) so a run that
  // started between boot and save is not missed and a disable never restarts.
  // The restart line clears at save start and on every idle/error path so a
  // stale outcome never lingers under a fresh toast; every post-await update
  // bails when the panel unmounts mid-save.
  const handleSave = async () => {
    if (saving) return;
    setSaving(true);
    // A stale restart line must never survive a new save: an idle save would
    // otherwise keep rendering the previous run under the fresh toast.
    setNotice(null);
    try {
      // Roots validate before any network write: an emptied editor and `..`
      // escapes fail closed here with line numbers, mirroring the files guard,
      // so a bad walk boundary never persists to config.toml.
      const rootsValidationError = validateIndexRootsText(rootsText);
      if (rootsValidationError) {
        if (!mountedRef.current) return;
        setNotice(null);
        pushErrorToast(rootsValidationError);
        return;
      }
      const savedEnabled = await persistConfig();
      if (!mountedRef.current) return;
      const editedCalendars = config.calendars;
      const editedReminders = config.reminders;
      const prevSources = lastSavedSourcesRef.current;
      lastSavedSourcesRef.current = {
        calendars: !!editedCalendars,
        reminders: !!editedReminders,
      };
      const fresh = await loadStatus();
      if (!mountedRef.current) return;
      {
        const newlyEnabled: string[] = [];
        if (savedEnabled) {
          // A save before the first loadConfig settles leaves prev null; treat
          // it as disabled so a newly-enabled toggle still prompts once.
          const prevCalendars = prevSources?.calendars ?? false;
          const prevReminders = prevSources?.reminders ?? false;
          if (!prevCalendars && editedCalendars) newlyEnabled.push("calendars");
          if (!prevReminders && editedReminders) newlyEnabled.push("reminders");
        }
        for (const kind of newlyEnabled) {
          const row = fresh?.sources?.find((entry) => entry.kind === kind);
          if (!row || resolveIndexSourceAccess(row) !== "notDetermined") continue;
          if (!mountedRef.current) return;
          try {
            await requestIndexAccess(kind);
          } catch {
            // Save stays successful; pills surface the current posture on poll.
          }
          if (!mountedRef.current) return;
        }
        if (newlyEnabled.length > 0) {
          await loadStatus();
          if (!mountedRef.current) return;
        }
      }
      const wasRunning = fresh?.running === true;
      if (wasRunning && savedEnabled) {
        try {
          // Explicit cancel outcome: 404 means no run to stop so the restart
          // continues; any other failure aborts before polling instead of
          // silently continuing over a half-stopped generation.
          try {
            await cancelIndex();
          } catch (failure) {
            if (!(failure instanceof ApiError && failure.status === 404)) {
              throw failure;
            }
          }
          if (!mountedRef.current) return;
          let settled = false;
          for (let attempt = 0; attempt < 10; attempt += 1) {
            const polled = await getIndexStatus();
            if (!mountedRef.current) return;
            if (polled?.running === false) {
              settled = true;
              break;
            }
            if (attempt < 9) {
              await new Promise((resolve) => setTimeout(resolve, 500));
              if (!mountedRef.current) return;
            }
          }
          // Single-flight guard: never start a second generation over a
          // still-running one (the engine answers 409); abort honestly with
          // an error toast instead of dialing.
          if (!settled) {
            if (!mountedRef.current) return;
            setNotice(null);
            pushErrorToast(
              "Failed to restart index run: previous scan is still running.",
            );
            return;
          }
          const summary = await runIndex();
          if (!mountedRef.current) return;
          setNotice(describeIndexRun(summary));
          await loadStatus();
          if (!mountedRef.current) return;
          pushSuccessToast(
            "Index settings saved. Restarted the running scan so new settings apply.",
          );
        } catch (failure) {
          if (!mountedRef.current) return;
          setNotice(null);
          pushErrorToast(
            failure instanceof ApiError ? failure.message : "Failed to restart index run",
          );
        }
      } else {
        if (!mountedRef.current) return;
        setNotice(null);
        pushSuccessToast("Index settings saved.");
      }
    } catch (failure) {
      if (!mountedRef.current) return;
      setNotice(null);
      pushErrorToast(
        failure instanceof ApiError ? failure.message : "Failed to save index settings",
      );
    } finally {
      if (mountedRef.current) setSaving(false);
    }
  };

  // Flips one toggle in local state; the change persists only on Save so a
  // stray click never writes policy without review.
  const updateConfig = (patch: Partial<IndexConfigData>) => {
    setConfig((previous) => ({ ...previous, ...patch }));
  };

  // Effort control state: the preset plus the custom stepper and the two
  // thermal/power toggles. The resolved reality below maps the preset onto
  // the machine's core count so the same preset scales from a laptop to a
  // studio machine without inventing a worker count the hardware cannot meet.
  // The engine core count from GET /index/status wins when present so a
  // remote dashboard (phone browser vs Mac engine) resolves against the
  // engine hardware; otherwise the browser hardwareConcurrency applies.
  const effortPreset = normalizeIndexEffortPreset(config.effort);
  const machineCores = resolveMachineCores(policyCoreCount);
  // Stepper fallback stays DEFAULT_INDEX_WORKERS (not the 0 wire default)
  // so custom opens on a valid count before the first fetch.
  const customWorkers =
    resolveIndexWorkersValue(config) ?? DEFAULT_INDEX_WORKERS;
  const resolvedEffortWorkers = resolveEffortWorkers(
    effortPreset,
    machineCores,
    customWorkers,
  );
  const effortReality = describeEffortReality(
    effortPreset,
    resolvedEffortWorkers,
    machineCores,
  );
  // Static ceiling shared with the engine validation bound; the live core
  // count narrows it further so the stepper never offers more workers than
  // the machine can meet.
  const customMax =
    machineCores != null && machineCores > 0
      ? Math.min(machineCores, INDEX_MAX_CUSTOM_WORKERS)
      : INDEX_MAX_CUSTOM_WORKERS;
  // Per-document vector chunk cap: bounds embedding work so one text-dense
  // document cannot fan an outsized batch; chunks beyond the cap stay
  // keyword-only. Clamped into the engine 1..4096 range so a hand-typed value
  // never fails the save.
  const vectorCap =
    resolveIndexVectorCapValue(config) ??
    (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number);
  const vectorCapMax = 4096;
  // Root-scoped coverage plus the walker prune list: the subtitle reads the
  // live roots textarea so it names exactly what the next run will cover with
  // no hardcoded home names, while the prune list stays read from the loaded
  // [index] payload. The credential deny list stays out of the rendered names
  // and is described generically in the detail block.
  const liveRoots = parseIndexRootsText(rootsText);
  const scopeSubtitle = describeIndexScope(liveRoots);
  const alwaysSkipped = resolveAlwaysSkipped(config);
  // Informational outside-allow-roots warning: any live index root outside the
  // loaded files allow roots means recalled content from there may not be
  // readable by live file tools. Null allow roots (not yet loaded or older
  // engines) degrade to no warning instead of guessing.
  const outsideRoots = findOutsideIndexRoots(liveRoots, filesAllowRoots);

  return (
    <section className="panel indexing-panel" aria-label="Index Policy">
      <div className="panel-header-row">
        <div>
          <h2>Index Policy</h2>
          <p className="muted text-sm" data-testid="index-scope-subtitle">
            {scopeSubtitle}
          </p>
          <div
            className="muted text-xs"
            data-testid="index-always-skipped-block"
          >
            {/* Walker prune list renders solely from the `alwaysSkipped`
                payload so the copy cannot drift from
                FilesIndexer.alwaysSkippedPatterns. The file-access deny list
                stays generic and never enumerates patterns here. */}
            {alwaysSkipped.length > 0 ? (
              <>
                <p style={{ marginTop: 4, marginBottom: 0 }}>
                  Always skipped, even when they are not in the Exclude
                  patterns list:
                </p>
                <p
                  data-testid="index-always-skipped"
                  style={{ marginTop: 4, marginBottom: 0 }}
                >
                  {alwaysSkipped.join(", ")}
                </p>
              </>
            ) : (
              <p style={{ marginTop: 4, marginBottom: 0 }}>
                The walker also skips its built-in prune list, even when
                entries are not in the Exclude patterns list.
              </p>
            )}
            <p style={{ marginTop: 4, marginBottom: 0 }}>
              Credential and key files blocked by your file access rules are
              never indexed either. Paths denied under Security Files and
              Access are never indexed.
            </p>
          </div>
        </div>
      </div>

      <ToastStack toasts={toasts} onDismiss={dismissToast} />
      {notice ? <p className="muted text-sm">{notice}</p> : null}

      <div className="index-policy-section">
        <h3>Policy</h3>

        <label className="toggle-label">
          <input
            type="checkbox"
            checked={config.enabled}
            onChange={(event) => updateConfig({ enabled: event.target.checked })}
          />
          <span>Enable background indexing</span>
        </label>

        <fieldset className="index-sources-fieldset">
          <legend>Sources</legend>
          {INDEX_SOURCES.map((source) => {
            const checkedByKind: Record<string, boolean> = {
              files: config.files,
              mail: config.mail,
              messages: config.messages,
              calendars: config.calendars,
              reminders: config.reminders,
            };
            const checked = checkedByKind[source.kind] ?? false;
            const keyByKind: Record<string, string> = {
              files: "files",
              mail: "mail",
              messages: "messages",
              calendars: "calendars",
              reminders: "reminders",
            };
            const key = keyByKind[source.kind] ?? source.kind;
            return (
              <div
                key={source.kind}
                className="index-source-row"
                style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}
              >
                <label className="toggle-label">
                  <input
                    type="checkbox"
                    checked={checked}
                    disabled={!config.enabled}
                    aria-label={`Index ${source.label}`}
                    onChange={(event) =>
                      updateConfig({ [key]: event.target.checked } as Partial<IndexConfigData>)
                    }
                  />
                  <span>{source.label}</span>
                </label>
                {source.hint ? (
                  <span
                    className="muted text-xs index-source-hint"
                    style={{ marginLeft: 4 }}
                  >
                    <AlertTriangleIcon size={12} /> {source.hint}
                  </span>
                ) : null}
              </div>
            );
          })}
        </fieldset>

        {/* Index roots editor: the file-walk boundary over IndexConfig.roots.
            One root per line, trimmed with blanks dropped on save; an emptied
            editor and `..` escapes fail closed with line numbers in handleSave.
            Saved through the existing `roots` key with no API shape change.
            The deny filter honors deny patterns only and ignores allow roots,
            while paths denied under Security Files and Access are never
            indexed. */}
        <div className="form-group">
          <label htmlFor="index-roots">Index roots (one per line)</label>
          <textarea
            id="index-roots"
            aria-label="Index roots"
            rows={3}
            value={rootsText}
            onChange={(event) => setRootsText(event.target.value)}
          />
          <p className="muted text-xs">
            Folders the file walk covers. One root per line. Blank lines are
            ignored. Paths denied under Security Files and Access are never
            indexed.
          </p>
          {/* Informational outside-allow-roots warning: renders exactly when a
              live index root sits outside the loaded files allow roots, since
              recalled content from there may not be readable by live file
              tools. Informational only — the save still persists. */}
          {outsideRoots.length > 0 ? (
            <p
              className="muted text-xs"
              data-testid="index-roots-outside-warning"
              style={{ marginTop: 4, marginBottom: 0 }}
            >
              An index root sits outside your Files allow roots — recalled
              content from there may not be readable by live file tools. Keep
              index roots inside Security Files and Access allow roots, or
              broaden those allow roots.
            </p>
          ) : null}
        </div>

        {/* Effort control: the three scaling presets plus a custom worker
            stepper, with the resolved reality against the machine's core count
            on top and the thermal/power toggles below. Persisted only on Save
            like every other policy knob. */}
        <fieldset className="index-effort-fieldset">
          <legend>Effort</legend>
          <p
            className="muted text-sm"
            data-testid="index-effort-reality"
            style={{ marginTop: 0 }}
          >
            {effortReality}
          </p>
          <div role="radiogroup" aria-label="Indexing effort">
            {INDEX_EFFORT_OPTIONS.map((option) => (
              <label key={option.id} className="toggle-label">
                <input
                  type="radio"
                  name="index-effort"
                  value={option.id}
                  checked={effortPreset === option.id}
                  onChange={() => updateConfig({ effort: option.id })}
                />
                <span>{option.label}</span>
              </label>
            ))}
          </div>
          {effortPreset === "custom" ? (
            <div className="form-group" style={{ marginTop: 8 }}>
              <label htmlFor="index-custom-workers">Custom workers</label>
              <div className="row index-stepper">
                <button
                  type="button"
                  className="ghost"
                  aria-label="Decrease workers"
                  disabled={customWorkers <= 1}
                  onClick={() =>
                    updateConfig({ workers: Math.max(1, customWorkers - 1) })
                  }
                >
                  <span aria-hidden="true">−</span>
                </button>
                <input
                  id="index-custom-workers"
                  type="number"
                  className="input-field index-stepper-input"
                  inputMode="numeric"
                  min={1}
                  max={customMax}
                  value={customWorkers}
                  onChange={(event) => {
                    const parsed = Number(event.target.value);
                    if (!Number.isFinite(parsed)) return;
                    updateConfig({
                      workers: Math.min(
                        customMax,
                        Math.max(1, Math.floor(parsed)),
                      ),
                    });
                  }}
                />
                <button
                  type="button"
                  className="ghost"
                  aria-label="Increase workers"
                  disabled={customWorkers >= customMax}
                  onClick={() =>
                    updateConfig({
                      workers: Math.min(customMax, customWorkers + 1),
                    })
                  }
                >
                  <span aria-hidden="true">+</span>
                </button>
              </div>
              <p className="muted text-xs">
                Workers used when the Custom preset is selected.
              </p>
            </div>
          ) : null}
          <label className="toggle-label">
            <input
              type="checkbox"
              checked={config.thermalBackoff ?? DEFAULT_INDEX_THERMAL_BACKOFF}
              onChange={(event) =>
                updateConfig({ thermalBackoff: event.target.checked })
              }
            />
            <span>Thermal backoff</span>
          </label>
          <label className="toggle-label">
            <input
              type="checkbox"
              checked={config.pauseOnBattery ?? DEFAULT_INDEX_PAUSE_ON_BATTERY}
              onChange={(event) =>
                updateConfig({ pauseOnBattery: event.target.checked })
              }
            />
            <span>Pause on battery</span>
          </label>
        </fieldset>

        {/* Per-document vector chunk cap: bounds embedding work so one
            text-dense document cannot fan an outsized batch. Chunks beyond the
            cap stay keyword-searchable, so a capped document is still fully
            findable by keyword. Persisted only on Save like every other knob. */}
        <div className="form-group" style={{ marginTop: 12 }}>
          <label htmlFor="index-vector-cap">
            Max vector chunks per document
          </label>
          <div className="row">
            <button
              type="button"
              className="ghost"
              aria-label="Decrease vector cap"
              disabled={vectorCap <= 1}
              onClick={() =>
                updateConfig({
                  maxVectorChunksPerDocument: Math.max(1, vectorCap - 1),
                })
              }
            >
              <span aria-hidden="true">−</span>
            </button>
            <input
              id="index-vector-cap"
              type="number"
              className="input-field"
              min={1}
              max={vectorCapMax}
              value={vectorCap}
              onChange={(event) => {
                const parsed = Number(event.target.value);
                if (!Number.isFinite(parsed)) return;
                updateConfig({
                  maxVectorChunksPerDocument: Math.min(
                    vectorCapMax,
                    Math.max(1, Math.floor(parsed)),
                  ),
                });
              }}
            />
            <button
              type="button"
              className="ghost"
              aria-label="Increase vector cap"
              disabled={vectorCap >= vectorCapMax}
              onClick={() =>
                updateConfig({
                  maxVectorChunksPerDocument: Math.min(
                    vectorCapMax,
                    vectorCap + 1,
                  ),
                })
              }
            >
              <span aria-hidden="true">+</span>
            </button>
          </div>
          <p className="muted text-xs">
            Chunks beyond the cap stay keyword-only (1–4096).
          </p>
        </div>

        <div className="form-group">
          <label htmlFor="index-excludes">Exclude patterns (one glob per line)</label>
          <textarea
            id="index-excludes"
            aria-label="Exclude patterns"
            rows={6}
            value={excludeText}
            onChange={(event) => setExcludeText(event.target.value)}
          />
          <p className="muted text-xs">
            Directories and patterns skipped during a file scan.
          </p>
        </div>

        <div className="form-group">
          <label htmlFor="index-mailbox-deny">Denied mailboxes (one glob per line)</label>
          <textarea
            id="index-mailbox-deny"
            aria-label="Denied mailboxes"
            rows={4}
            value={mailboxDenyText}
            onChange={(event) => setMailboxDenyText(event.target.value)}
          />
          <p className="muted text-xs">
            Trash-class mailboxes skipped without dialing. Denied mail retires
            on the next complete run; clearing a name re-indexes it from scratch.
          </p>
        </div>

        <div className="form-row">
          <div className="form-group flex-1">
            <label htmlFor="index-mail-window">Mail vector window</label>
            <select
              id="index-mail-window"
              className="input-field"
              value={config.mailVectorWindow}
              onChange={(event) =>
                updateConfig({ mailVectorWindow: event.target.value })
              }
            >
              {INDEX_MAIL_VECTOR_WINDOWS.map((window) => (
                <option key={window} value={window}>
                  {window === "all" ? "All mail" : window}
                </option>
              ))}
            </select>
          </div>

          <div className="form-group flex-1">
            <label htmlFor="index-icloud">iCloud files with evicted bytes</label>
            <select
              id="index-icloud"
              className="input-field"
              value={config.iCloudEvicted}
              onChange={(event) =>
                updateConfig({ iCloudEvicted: event.target.value })
              }
            >
              {INDEX_ICLOUD_EVICTIONS.map((policy) => (
                <option key={policy} value={policy}>
                  {policy === "skip" ? "Skip (never download)" : "Download"}
                </option>
              ))}
            </select>
          </div>
        </div>

        <p className="muted text-sm index-attachment-cap">
          Attachment / file size cap: {config.maxFileMB} MB per file.
        </p>

        <div className="settings-footer">
          <button
            type="button"
            className="primary-button save-button"
            onClick={() => void handleSave()}
            disabled={saving}
          >
            {saving ? "Saving…" : "Save Index Settings"}
          </button>
        </div>
      </div>
    </section>
  );
}

// Auto-start notice for a run broadcast that this panel did not initiate:
// a launch-triggered nightly or catch-up pass announces itself by display
// label so a missed nightly window names the catch-up explicitly instead of
// reading as a generic index run.
export function describeAutoStartNotice(
  run: { message?: unknown; response?: unknown } | null | undefined,
): string | null {
  if (!run) return null;
  const message = typeof run.message === "string" ? run.message : undefined;
  const response = typeof run.response === "string" ? run.response : undefined;
  const trigger = parseIndexRunTrigger({ message: message ?? "", response: response ?? null });
  const label = indexRunTriggerLabel(trigger);
  if (trigger === "catchUp") {
    return `${label} started — catching up on missed nightly indexing.`;
  }
  return `${label} started.`;
}
