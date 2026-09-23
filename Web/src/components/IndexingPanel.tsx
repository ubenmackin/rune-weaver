// Rune Weaver Dashboard — Local index status dashboard and policy form.
//
// The status dashboard (Memory → Index Status) owns Run/Cancel/Prune/Reset,
// the stat cards, the last-run strip, and frontend-only SVG/CSS charts computed
// from the GET /index/status fields; the policy form (Settings → Indexing)
// owns the enable/sources/excludes/caps fields with its own Save, so neither
// surface duplicates the other's control set. Status freshness comes from the
// shared WebSocket run broadcasts — there is no manual Refresh button — and
// live progress rides the `tool_progress` frames, so the panel never invents a
// completion fraction the engine cannot supply.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_CONFIG,
  INDEX_ICLOUD_EVICTIONS,
  INDEX_MAIL_VECTOR_WINDOWS,
  cancelIndex,
  formatToolProgressElapsedMs,
  getIndexStatus,
  getSettings,
  indexRunTriggerLabel,
  indexWatermarkAgeMs,
  parseIndexRunTrigger,
  parseRunTimestamp,
  pruneIndex,
  relativeProgressCurrent,
  resetIndex,
  runIndex,
  updateSettings,
  type IndexConfigData,
  type IndexExtractStatusCounts,
  type IndexLastRunStatus,
  type IndexRunResponse,
  type IndexSourceCounts,
  type IndexStatusResponse,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
  WSToolProgressFrame,
} from "../hooks/useSharedWebSocket";
import { formatRelativeAgo } from "../relativeTime";
import { AlertTriangleIcon, StopIcon, TrashIcon } from "./icons";
import Modal from "./Modal";
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
    hint: "Requires Full Disk Access — RuneWeaver.app, or your terminal emulator when running rune-weaver serve — then run Rebuild / Run Now.",
  },
];

// Display label for a status source kind, falling back to the engine's wire
// token so an unknown future source still renders honestly.
function sourceLabel(kind: string): string {
  return INDEX_SOURCES.find((source) => source.kind === kind)?.label ?? kind;
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

// Ordered index phases, mirroring IndexPhase on the engine. The live progress
// line names the current step by matching the phase token in the frame message.
const INDEX_PHASES = ["discovering", "extracting", "embedding", "committing"] as const;

// Ordered index stages, mirroring IndexSourceKind on the engine. The live
// header names the active corpus by matching the stage token in the frame
// message ("Indexing extracting files: …"); discovering and committing frames
// carry no stage so the header falls back to the phase copy there.
export const INDEX_STAGES = ["files", "mail", "messages", "vision"] as const;

// Tool identity the engine stamps on index progress frames. Progress is only
// adopted while a run is in flight and either carries this name or, on older
// engines that omit it, arrives during any run in flight.
export const INDEX_PROGRESS_TOOL_NAME = "index";

// User copy per phase so the step list renders plain language rather than the
// engine's wire token.
const INDEX_PHASE_COPY: Record<string, string> = {
  discovering: "Discovering",
  extracting: "Reading",
  embedding: "Vectorizing",
  committing: "Committing",
};

// Explained phase steps for the live list, in display order. Vision is its own
// step even though the engine reports it as a stage token: it stays active
// whenever the stage is vision, regardless of the phase token in the message.
// Labels reuse the phase copy so the wire-token wording stays in one place.
export const INDEX_STEPS: Array<{ id: string; label: string; title: string }> = [
  { id: "discovering", label: INDEX_PHASE_COPY.discovering, title: "Finding candidates to index" },
  { id: "extracting", label: INDEX_PHASE_COPY.extracting, title: "Extracting text from documents" },
  { id: "embedding", label: INDEX_PHASE_COPY.embedding, title: "Building embeddings for search" },
  { id: "vision", label: "Describing images", title: "Describing images with LLM" },
  { id: "committing", label: INDEX_PHASE_COPY.committing, title: "Saving to the index" },
];

// Maps a live frame's phase and stage tokens onto one explained step. Vision
// wins over any phase token so image description never reads as vectorizing.
export function resolveIndexStep(
  phase: string | null | undefined,
  stage: string | null | undefined,
): string | null {
  if (stage === "vision") return "vision";
  if (
    typeof phase === "string" &&
    (INDEX_PHASES as readonly string[]).includes(phase)
  ) {
    return phase;
  }
  return null;
}

// Step ids a single frame marks as visited. A vision frame marks both its
// phase and the vision step so vectorizing reads done while describing stays
// active; any other frame marks only its phase step.
export function indexStepsForFrame(
  phase: string | null | undefined,
  stage: string | null | undefined,
): string[] {
  const steps: string[] = [];
  if (
    typeof phase === "string" &&
    (INDEX_PHASES as readonly string[]).includes(phase)
  ) {
    steps.push(phase);
  }
  if (stage === "vision" && !steps.includes("vision")) {
    steps.push("vision");
  }
  return steps;
}

// Done/active/pending state for one explained step: the live step stays
// active, every other visited step reads done, and the rest stay pending. The
// completed summary reuses the same rule with no active step, so every visited
// step renders checked and the rest stay pending.
export function resolveIndexStepStatus(
  stepID: string,
  activeStep: string | null | undefined,
  visited: Set<string> | string[] | null | undefined,
): "done" | "active" | "pending" {
  if (activeStep != null && stepID === activeStep) return "active";
  const has =
    visited instanceof Set ? visited.has(stepID) : Array.isArray(visited) ? visited.includes(stepID) : false;
  return has ? "done" : "pending";
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

// Per-source content row joining enablement with real totals: enablement comes
// from the status sources list while documents/chunks/bytes come from the
// additive bySource aggregates. A source missing from either side degrades to
// disabled or zero rather than disappearing, so older engines without the
// aggregates still render the canonical Files/Mail/Messages rows.
export interface IndexSourceContentRow {
  kind: string;
  enabled: boolean;
  documents: number;
  chunks: number;
  bytes: number;
}

// Resolves the canonical Files/Mail/Messages rows with real totals, so the
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

// Bar width for one chart row scaled by its document share of the largest
// bucket, so the longest bar always fills the track and the rest read as real
// proportions instead of binary on/off fills. Shared by the per-source and
// extraction-outcome charts, whose scaling rule is identical, keeping
// single-document buckets visible next to large ones.
export function indexSourceBarWidth(documents: number, maxDocuments: number): string {
  const docs = Number.isFinite(documents) && documents > 0 ? documents : 0;
  const max = Number.isFinite(maxDocuments) && maxDocuments > 0 ? maxDocuments : 0;
  if (max <= 0 || docs <= 0) return "0%";
  return `${Math.min(100, Math.max(4, Math.round((docs / max) * 100)))}%`;
}

// Display label for an extraction-outcome token, falling back to the engine's
// wire token so an unknown future status still renders honestly.
export function extractStatusLabel(status: string): string {
  return status && status.trim() ? status.trim() : "unknown";
}

// One-line human summary of the last index run for the strip: status plus the
// trigger label, outcome counts, and finish time, omitting any count the
// summary line did not carry so a drifted payload still renders its status
// and time. The trigger label stays parenthesized after the status so the
// `Last run <status>` prefix survives verbatim for older assertions.
export function describeIndexLastRun(lastRun: IndexLastRunStatus | null | undefined): string {
  if (!lastRun) return "No runs yet";
  const head =
    typeof lastRun.trigger === "string" && lastRun.trigger.trim()
      ? `Last run ${lastRun.status} (${indexRunTriggerLabel(lastRun.trigger)})`
      : `Last run ${lastRun.status}`;
  const parts: string[] = [head];
  if (typeof lastRun.indexed === "number" && Number.isFinite(lastRun.indexed)) {
    parts.push(`${lastRun.indexed} indexed`);
  }
  if (typeof lastRun.scanned === "number" && Number.isFinite(lastRun.scanned)) {
    parts.push(`${lastRun.scanned} scanned`);
  }
  if (typeof lastRun.errors === "number" && Number.isFinite(lastRun.errors)) {
    parts.push(`${lastRun.errors} errors`);
  }
  if (lastRun.finishedAt != null) {
    const age = formatIndexAge(lastRun.finishedAt);
    if (age !== "Never indexed") {
      parts.push(`finished ${age}`);
    }
  }
  return parts.join(" · ");
}

// Extracts the phase token from a live progress frame message
// ("Indexing extracting: …" or "Indexing extracting files: …"), degrading to
// null when the engine changes the wording so the step list simply holds its
// previous position.
export function resolveIndexPhase(message: string | null | undefined): string | null {
  if (typeof message !== "string") return null;
  const match = /Indexing\s+(\w+)/.exec(message);
  if (!match) return null;
  const phase = match[1].toLowerCase();
  return INDEX_PHASES.includes(phase as (typeof INDEX_PHASES)[number]) ? phase : null;
}

// Extracts the stage token from a live progress frame message
// ("Indexing extracting files: …"), degrading to null when the frame carries
// no stage (discovering and committing frames) or the engine changes the
// wording so the header falls back to the phase copy.
export function resolveIndexStage(message: string | null | undefined): string | null {
  if (typeof message !== "string") return null;
  const match = /Indexing\s+\w+\s+(\w+)/.exec(message);
  if (!match) return null;
  const stage = match[1].toLowerCase();
  return (INDEX_STAGES as readonly string[]).includes(stage) ? stage : null;
}

// Stage-aware header copy for the live progress line. Vision always describes
// images, embedding vectorizes, extracting reads the named corpus, and the
// phase-only frames keep their plain copy; anything unrecognized degrades to
// the generic running copy so the header never sticks on a wire token.
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
    return "Reading…";
  }
  if (phase === "discovering") return "Discovering…";
  if (phase === "committing") return "Committing…";
  if (stage === "files") return "Reading files…";
  if (stage === "mail") return "Reading mail…";
  if (stage === "messages") return "Reading messages…";
  return "Running…";
}

// Reports whether a live progress frame belongs to an index run. The frame is
// adopted only while a run is in flight — either carrying the index tool name
// or, on older engines that omit it, arriving during any run — so a delayed
// frame after the run settles never resurrects cleared progress.
export function isIndexProgressFrame(
  frame: Pick<WSToolProgressFrame, "toolName">,
  runActive: boolean,
): boolean {
  const name = typeof frame.toolName === "string" ? frame.toolName.trim().toLowerCase() : "";
  if (name === INDEX_PROGRESS_TOOL_NAME) return runActive;
  if (name.length > 0) return false;
  return runActive;
}

// Live progress distilled from one frame so the panel renders a stable shape
// regardless of which counters the engine populates.
export interface IndexLiveProgress {
  phase: string | null;
  stage: string | null;
  message: string;
  scanned: number;
  indexed: number;
  elapsedMs: number;
  current: string | null;
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
export default function IndexingPanel({ hideHeader = false }: IndexingPanelProps) {
  const [status, setStatus] = useState<IndexStatusResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // One in-flight slot names the action so Run, Prune, and Reset stay
  // mutually exclusive while a request is pending. Cancel rides a separate
  // flag so it can run concurrent with Run: a local run holds `action="run"`
  // for the whole pass, and Cancel must still reach the engine during it.
  const [action, setAction] = useState<"run" | "prune" | "reset" | null>(null);
  const actionBusy = action !== null;
  const [cancelBusy, setCancelBusy] = useState(false);
  const [liveProgress, setLiveProgress] = useState<IndexLiveProgress | null>(null);
  // Client-side visited steps for the explained phase list. Marked as frames
  // arrive, kept through the terminal broadcast as a post-run mini-summary of
  // what ran, and cleared only when the next run starts or the store resets.
  const [visitedSteps, setVisitedSteps] = useState<Set<string>>(
    () => new Set<string>(),
  );
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

  // True whenever the engine reports a run in flight or this panel started one,
  // so progress frames are only adopted during a real run. The Status pill
  // below stays the authoritative running source; this flag only gates frame
  // adoption and the live block.
  const progressActive = runActive || status?.running === true;
  const indexingEnabled = status?.enabled === true;
  // Mirrors the engine running flag for the broadcast consumer without
  // re-subscribing the shared socket on every status poll.
  const statusRunningRef = useRef(false);
  useEffect(() => {
    statusRunningRef.current = status?.running === true;
  }, [status?.running]);
  // Fallback so a run with no frame never freezes on "Starting…": after ~3s
  // without live progress the header reads "Running…" until a frame arrives
  // or the run settles.
  const [staleRunning, setStaleRunning] = useState(false);
  useEffect(() => {
    if (!progressActive || liveProgress || cancelling) {
      setStaleRunning(false);
      return;
    }
    const timer = setTimeout(() => setStaleRunning(true), 3000);
    return () => clearTimeout(timer);
  }, [progressActive, liveProgress, cancelling]);

  const vectorChunks = status?.vectorChunks ?? 0;
  const keywordChunks = status?.keywordChunks ?? 0;
  const donut = indexDonutArcs(vectorChunks, keywordChunks, DONUT_RADIUS);
  // Real per-source totals for the bars, in canonical Files/Mail/Messages
  // order; older engines without the aggregates degrade to zeroed rows.
  const sourceContent = resolveIndexSourceContent(status);
  const maxSourceDocuments = Math.max(0, ...sourceContent.map((row) => row.documents));
  // Extraction-outcome breakdown for the second chart, largest bucket first so
  // the dominant outcome anchors the track scaling. Document counts are
  // sanitized through floorPositive before sort/max, matching
  // resolveIndexSourceContent, so malformed/negative/NaN payloads degrade to
  // zero instead of misordering the rows or yielding NaN.
  const extractRows: IndexExtractStatusCounts[] = [...(status?.byExtractStatus ?? [])]
    .map((row) => ({ ...row, documents: floorPositive(row.documents) }))
    .sort((left, right) => right.documents - left.documents);
  const maxExtractDocuments = Math.max(0, ...extractRows.map((row) => row.documents));

  const loadStatus = useCallback(async () => {
    setError(null);
    try {
      const response = await getIndexStatus();
      setStatus(response);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Failed to load index status",
      );
    }
  }, []);

  useEffect(() => {
    void loadStatus();
  }, [loadStatus]);

  // Live progress consumer: adopts `tool_progress` frames whenever a run is in
  // flight (engine status or local flight), distilling the phase and stage
  // tokens plus counters and the relative current item. The tail is
  // relative-only server-side, so the panel never renders a filesystem path
  // even though the frame could not carry one. Each frame also marks its
  // explained step visited so the phase list can render a post-run summary.
  // A new index run clears the visited set so the summary never leaks across
  // passes, while the terminal broadcast keeps it and drops only the live
  // counts. Any run broadcast — a pass starting elsewhere or reaching its
  // terminal summary — reloads status so the cards stay fresh without a manual
  // Refresh control. A launch-triggered nightly or catch-up pass this panel
  // did not start also raises an auto-start notice naming the trigger display
  // label explicitly.
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
          // The next run starts fresh: drop the previous summary and any stale
          // live line so the steps rebuild from the incoming frames.
          setVisitedSteps(new Set<string>());
          setLiveProgress(null);
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
          // The pass settled: keep the visited steps as a checked summary and
          // drop only the live counts, so idle still shows what ran.
          setLiveProgress(null);
          if (cancellingRef.current) {
            // The cancelling window ends on the terminal broadcast. A run this
            // panel started still resolves through its awaiting run request with
            // full counts, so only a remote run needs the generic kept-work
            // notice here; the status reload below settles the pill either way.
            if (!runActiveRef.current) {
              setNotice(
                "Index run cancelled: committed work is kept and the next run resumes from there.",
              );
            }
            cancellingRef.current = false;
            setCancelling(false);
          }
        }
        // A completed index pass started elsewhere still refreshes the
        // last-run strip through the status reload; the strip itself carries
        // the trigger label via describeIndexLastRun.
        if (isIndexKind) {
          void loadStatus();
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
      const phase = resolveIndexPhase(progress.message);
      const stage = resolveIndexStage(progress.message);
      setLiveProgress({
        phase,
        stage,
        message: typeof progress.message === "string" ? progress.message : "",
        scanned: progress.scanned,
        indexed: progress.matched,
        elapsedMs: progress.elapsedMs,
        current: relativeProgressCurrent(progress.current),
      });
      const frameSteps = indexStepsForFrame(phase, stage);
      if (frameSteps.length > 0) {
        setVisitedSteps((previous) => {
          let changed = false;
          for (const step of frameSteps) {
            if (!previous.has(step)) {
              changed = true;
              break;
            }
          }
          if (!changed) return previous;
          const next = new Set(previous);
          for (const step of frameSteps) next.add(step);
          return next;
        });
      }
    },
    [loadStatus],
  );

  useSharedWebSocket(handleIndexBroadcast);

  // Clears the local run flight once the engine reports no run in flight, so a
  // run started from another tab still settles the panel's busy state. The
  // cancelling window settles the same way when the broadcast is missed: the
  // status probe is authoritative, so a remote cancel still reaches its kept-
  // work notice and re-enables Run without a separate Stopped variant.
  useEffect(() => {
    if (status?.running !== false) return;
    // Capture locality before clearing: a run this panel started resolves
    // through its awaiting request with full counts, so only a remote run
    // needs the generic kept-work notice here.
    const wasLocalRun = runActiveRef.current;
    if (wasLocalRun) {
      runActiveRef.current = false;
      setRunActive(false);
    }
    if (!cancellingRef.current) return;
    if (!wasLocalRun) {
      setNotice(
        "Index run cancelled: committed work is kept and the next run resumes from there.",
      );
      setLiveProgress(null);
    }
    cancellingRef.current = false;
    setCancelling(false);
  }, [status?.running]);

  // Re-polls status while the cancelling window is open so a missed broadcast
  // still observes the settled run promptly instead of stranding the pill.
  useEffect(() => {
    if (!cancelling) return;
    const timer = setInterval(() => {
      void loadStatus();
    }, 2000);
    return () => clearInterval(timer);
  }, [cancelling, loadStatus]);

  // Starts an on-demand run and awaits its terminal summary. Progress frames
  // keep the live line honest while the request is in flight; the summary fills
  // the notice so a skipped run explains why instead of appearing silent.
  // A locally cancelled run settles here with its full counts, clearing the
  // cancelling window without overwriting the detailed summary. The visited
  // set clears here so the previous summary collapses before the new frames
  // rebuild it.
  const handleRun = async () => {
    if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) return;
    runActiveRef.current = true;
    setRunActive(true);
    setAction("run");
    setError(null);
    setNotice(null);
    setLiveProgress(null);
    setVisitedSteps(new Set<string>());
    try {
      const summary = await runIndex();
      setNotice(describeRunSummary(summary));
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
      setLiveProgress(null);
    }
  };

  // Asks the engine to stop an in-flight run, then holds the cancelling window
  // until the terminal broadcast or the status probe reports a settled run.
  // Committed work survives, so a cancelled run simply resumes from the first
  // unfinished item on the next run. Cancel rides its own busy flag so it can
  // run concurrent with Run instead of multiplexing one shared action slot.
  const handleCancel = async () => {
    if (cancelBusy || cancellingRef.current) return;
    if (action === "prune" || action === "reset") return;
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
        `Pruned ${response?.removed ?? 0} document${response?.removed === 1 ? "" : "s"} indexed before ${formatIndexAsOf(response?.before)}.`,
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
      // The store is empty again, so the previous summary has nothing to
      // describe and the live line has nothing to continue.
      setVisitedSteps(new Set<string>());
      setLiveProgress(null);
      await loadStatus();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Failed to reset the index");
    } finally {
      setAction(null);
    }
  };

  // Explained step active right now, or null once the run settles. The idle
  // summary keeps the visited set with no active step so every visited step
  // renders checked and no step carries live counts.
  const activeStep = liveProgress
    ? resolveIndexStep(liveProgress.phase, liveProgress.stage)
    : null;
  // The Progress card stays visible while a run is in flight and while a
  // completed summary exists. Idle with a previous run keeps the checked steps
  // without live counts; a fresh panel with no run yet stays hidden, and the
  // next run or a reset collapses the summary back to hidden before new steps
  // arrive.
  const showProgressBlock =
    progressActive ||
    liveProgress != null ||
    cancelling ||
    visitedSteps.size > 0;
  const showLiveLiveness = progressActive || liveProgress != null || cancelling;

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

      {/* Run controls top: start, stop, prune, and reset sit above the numbers
          they act on. Each destructive action opens its own modal carrying the
          description, so no helper text repeats under the row. */}
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
              {action === "run" ? "Indexing…" : "Rebuild / Run Now"}
            </span>
          </button>

          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void handleCancel()}
            disabled={cancelBusy || cancelling || !progressActive || action === "prune" || action === "reset"}
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
        {/* Disabled-index hint under the Run row; prune/reset stay independent
            of the enabled flag. */}
        {status?.enabled === false ? (
          <p className="muted text-sm">
            Indexing is off — turn it on in Settings → Indexing to run a pass.
          </p>
        ) : null}
      </div>

      {/* Explained phase steps + shimmer while a run is in flight: the engine
          publishes no fraction, so an animated shimmer proves liveness. The
          header names the active stage ("Reading files…", "Vectorizing…",
          "Describing images…") with live counts, falling back to "Running…"
          when no frame arrives within ~3s so it never freezes on "Starting…".
          A cancelling run keeps the same block with a Cancelling pill and
          header so every Running indicator flips together until the run
          settles. After the terminal broadcast the visited steps stay visible
          as a checked summary with no live counts until the next run or a
          reset collapses them. */}
      {showProgressBlock && (
        <div className="index-live-progress" data-testid="index-live-progress">
          <div className="card">
            <h3>Progress</h3>
            <div className="index-live-header">
              <span
                className={`status-pill ${cancelling || showLiveLiveness ? "running" : "ok"}`}
              >
                {cancelling ? "Cancelling" : showLiveLiveness ? "Indexing" : "Completed"}
              </span>
              {cancelling ? (
                <span className="muted text-xs">
                  Cancelling…
                  {liveProgress ? (
                    <>
                      {" "}
                      {liveProgress.scanned} scanned · {liveProgress.indexed}{" "}
                      indexed · {formatToolProgressElapsedMs(liveProgress.elapsedMs)}
                    </>
                  ) : null}
                </span>
              ) : liveProgress ? (
                <span className="muted text-xs">
                  {resolveIndexLiveTitle(liveProgress.phase, liveProgress.stage)}{" "}
                  {liveProgress.scanned} scanned · {liveProgress.indexed} indexed ·{" "}
                  {formatToolProgressElapsedMs(liveProgress.elapsedMs)}
                </span>
              ) : progressActive ? (
                <span className="muted text-xs">{staleRunning ? "Running…" : "Starting…"}</span>
              ) : (
                <span className="muted text-xs">Completed — steps visited this run</span>
              )}
            </div>
            {/* Explained steps in run order: the live step stays active with
                its counts, visited steps read done, and the rest stay pending.
                The completed summary reuses the same list with no active step,
                so visited steps render checked and carry no live counts.
                Unknown wording holds the previous position. */}
            <ol className="index-phase-steps">
              {INDEX_STEPS.map((step) => {
                const stepStatus = resolveIndexStepStatus(step.id, activeStep, visitedSteps);
                const isActiveStep = stepStatus === "active";
                const isDoneStep = stepStatus === "done";
                return (
                  <li key={step.id} className={stepStatus} title={step.title}>
                    {isDoneStep ? <span aria-hidden="true">✓ </span> : null}
                    <span>{step.label}</span>
                    {isActiveStep && liveProgress ? (
                      <span
                        className="muted text-xs"
                        data-testid={`index-step-counts-${step.id}`}
                      >
                        {" "}
                        {liveProgress.scanned} scanned · {liveProgress.indexed} indexed
                      </span>
                    ) : null}
                  </li>
                );
              })}
            </ol>
            {liveProgress?.message ? (
              <div className="index-live-message">{liveProgress.message}</div>
            ) : null}
            {liveProgress?.current ? (
              <div
                className="tool-progress-current"
                data-testid="index-progress-current"
                title={liveProgress.current}
              >
                current: {liveProgress.current}
              </div>
            ) : null}
            {showLiveLiveness ? (
              <div
                className="tool-progress-shimmer"
                data-testid="index-progress-shimmer"
                role="progressbar"
                aria-label="Index run in progress"
                aria-valuetext="In progress"
              />
            ) : null}
          </div>
        </div>
      )}

      {/* Stat cards middle: size, counts with the vector/keyword split,
          prominent watermark age, per-source pills, last-run strip, and recent
          failures. */}
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
                status plus indexed/scanned/errors and the finish time, so the
                latest outcome reads without opening run history. */}
            <div
              className="index-last-run"
              data-testid="index-last-run"
              style={{ marginTop: 12 }}
            >
              <span className="muted text-sm">{describeIndexLastRun(status.lastRun ?? null)}</span>
            </div>
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
                <div className="muted text-xs">Size</div>
                <div style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}>
                  {formatIndexBytes(status.bytes)}
                </div>
              </div>
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Documents</div>
                <div style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}>
                  {status.documents}
                </div>
              </div>
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Chunks</div>
                <div style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}>
                  {status.chunks}
                </div>
                <div className="muted text-xs" style={{ marginTop: 2 }}>
                  {status.vectorChunks} vector · {status.keywordChunks} keyword
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
                {status.sources.map((source) => (
                  <span
                    key={source.kind}
                    className={`status-pill ${source.enabled ? "ok" : "skipped"}`}
                  >
                    {sourceLabel(source.kind)} · {source.enabled ? "On" : "Off"}
                  </span>
                ))}
              </div>
            ) : null}

            {status.lastErrors.length > 0 ? (
              <div className="index-errors" aria-label="Last index errors">
                <h4>Last errors</h4>
                <ul>
                  {status.lastErrors.map((detail, index) => (
                    <li key={`${index}-${detail.slice(0, 24)}`}>{detail}</li>
                  ))}
                </ul>
                {/* Guided onboarding for the Full Disk Access denial: macOS
                    offers no prompt API, so the denial only surfaces at
                    run time. The button navigates the top frame to the exact
                    Settings pane, where window.open would be treated as a
                    blocked popup for this system scheme. The steps name both
                    grants because macOS attributes the read to the host
                    process: RuneWeaver.app for the app, the terminal emulator
                    for rune-weaver serve. */}
                {hasFullDiskAccessError(status.lastErrors) ? (
                  <div
                    className="index-fda-guidance"
                    data-testid="index-fda-guidance"
                    style={{ marginTop: 8 }}
                  >
                    <p className="muted text-sm" style={{ marginBottom: 8 }}>
                      Messages indexing needs Full Disk Access. Grant it to
                      RuneWeaver.app — or to your terminal emulator (for example
                      Terminal.app or iTerm2) when you run rune-weaver serve —
                      then restart and run Rebuild / Run Now.
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
                      <li>Quit and restart the app or terminal, then run Rebuild / Run Now.</li>
                    </ol>
                  </div>
                ) : null}
              </div>
            ) : null}
          </>
        ) : (
          <p className="muted text-sm">Loading index status…</p>
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
                aria-label={`${vectorChunks} vector chunks, ${keywordChunks} keyword chunks`}
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
                  Vector <strong>{vectorChunks}</strong>
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
                  Keyword <strong>{keywordChunks}</strong>
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
              {sourceContent.map((source) => (
                <div
                  key={source.kind}
                  style={{ display: "flex", alignItems: "center", gap: 8 }}
                >
                  <span className="text-xs muted" style={{ width: 72 }}>
                    {sourceLabel(source.kind)}
                  </span>
                  <div
                    style={{
                      flex: 1,
                      height: 10,
                      borderRadius: 5,
                      background: CHART_TRACK_COLOR,
                      overflow: "hidden",
                    }}
                  >
                    <div
                      data-testid={`index-bar-${source.kind}`}
                      aria-label={`${sourceLabel(source.kind)} ${source.documents} documents`}
                      style={{
                        width: indexSourceBarWidth(source.documents, maxSourceDocuments),
                        height: "100%",
                        borderRadius: 5,
                        background: CHART_VECTOR_COLOR,
                      }}
                    />
                  </div>
                  <span className="text-xs muted" style={{ minWidth: 120, textAlign: "right" }}>
                    {source.documents} docs · {source.chunks} chunks · {formatIndexBytes(source.bytes)}
                  </span>
                </div>
              ))}
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
              {extractRows.length > 0 ? (
                extractRows.map((row) => (
                  <div
                    key={row.status}
                    style={{ display: "flex", alignItems: "center", gap: 8 }}
                  >
                    <span className="text-xs muted" style={{ width: 96 }}>
                      {extractStatusLabel(row.status)}
                    </span>
                    <div
                      style={{
                        flex: 1,
                        height: 10,
                        borderRadius: 5,
                        background: CHART_TRACK_COLOR,
                        overflow: "hidden",
                      }}
                    >
                      <div
                        data-testid={`index-extract-bar-${row.status}`}
                        aria-label={`${extractStatusLabel(row.status)} ${row.documents} documents`}
                        style={{
                          width: indexSourceBarWidth(row.documents, maxExtractDocuments),
                          height: "100%",
                          borderRadius: 5,
                          background: CHART_EXTRACT_COLOR,
                        }}
                      />
                    </div>
                    <span className="text-xs muted" style={{ minWidth: 64, textAlign: "right" }}>
                      {row.documents} docs
                    </span>
                  </div>
                ))
              ) : (
                <span className="text-xs muted">No extraction breakdown yet</span>
              )}
            </div>
          </div>
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
// per-source toggles, exclude globs, caps, and the vision describe toggle,
// persisted only through this form's own Save. Status cards, charts, and run
// controls stay on the Memory tab so one surface never duplicates the other's
// control set.
export function IndexPolicyPanel() {
  const [config, setConfig] = useState<IndexConfigData>(DEFAULT_INDEX_CONFIG);
  const [excludeText, setExcludeText] = useState<string>(
    DEFAULT_INDEX_CONFIG.exclude.join("\n"),
  );
  const [saving, setSaving] = useState(false);
  // Transient save feedback in a top-right stack so the confirmation never
  // blocks the form. Distinct notices stack with independent timers; an
  // identical copy replaces its sibling so repeat saves refresh one notice
  // instead of duplicating, matching the Settings save pattern.
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast } =
    useToastStack();

  // Loads the [index] section through the shared settings read so the editable
  // form starts from the stored policy. An older engine without the section
  // leaves the local defaults in place instead of blanking the form.
  const loadConfig = useCallback(async () => {
    try {
      const settings = await getSettings();
      const index = settings?.index;
      if (index) {
        const merged: IndexConfigData = {
          ...DEFAULT_INDEX_CONFIG,
          ...index,
          roots: Array.isArray(index.roots) ? index.roots : DEFAULT_INDEX_CONFIG.roots,
          exclude: Array.isArray(index.exclude)
            ? index.exclude
            : DEFAULT_INDEX_CONFIG.exclude,
        };
        setConfig(merged);
        setExcludeText(merged.exclude.join("\n"));
      }
    } catch {
      // A settings read failure leaves the local defaults; the save path
      // surfaces transport errors so the form stays usable.
    }
  }, []);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  const persistConfig = useCallback(async (): Promise<boolean> => {
    const exclude = excludeText
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    const saved = await updateSettings({
      index: {
        enabled: config.enabled,
        files: config.files,
        mail: config.mail,
        messages: config.messages,
        roots: config.roots.map((root) => root.trim()).filter(Boolean),
        exclude,
        max_file_mb: config.max_file_mb,
        mail_vector_window: config.mail_vector_window,
        icloud_evicted: config.icloud_evicted,
        describe_images_with_llm: config.describe_images_with_llm,
        nightly_budget: config.nightly_budget,
        db_path: config.db_path.trim(),
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
      };
      setConfig(merged);
      setExcludeText(merged.exclude.join("\n"));
    }
    return true;
  }, [config, excludeText]);

  // Persists the policy form through the [index]-only patch; the status
  // dashboard re-reads its own snapshot whenever it next mounts or a run
  // broadcast arrives, so no cross-tab control surface is needed here.
  const handleSave = async () => {
    if (saving) return;
    setSaving(true);
    try {
      await persistConfig();
      pushSuccessToast("Index settings saved.");
    } catch (failure) {
      pushErrorToast(
        failure instanceof ApiError ? failure.message : "Failed to save index settings",
      );
    } finally {
      setSaving(false);
    }
  };

  // Flips one toggle in local state; the change persists only on Save so a
  // stray click never writes policy without review.
  const updateConfig = (patch: Partial<IndexConfigData>) => {
    setConfig((previous) => ({ ...previous, ...patch }));
  };

  return (
    <section className="panel indexing-panel" aria-label="Index Policy">
      <div className="panel-header-row">
        <div>
          <h2>Index Policy</h2>
          <p className="muted text-sm">
            Choose what the local file, mail, and Messages index covers and how
            it stores content.
          </p>
        </div>
      </div>

      <ToastStack toasts={toasts} onDismiss={dismissToast} />

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
            const checked =
              source.kind === "files"
                ? config.files
                : source.kind === "mail"
                  ? config.mail
                  : config.messages;
            const key =
              source.kind === "files"
                ? "files"
                : source.kind === "mail"
                  ? "mail"
                  : "messages";
            return (
              <div key={source.kind} className="index-source-row">
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
                  <span className="muted text-xs index-source-hint">
                    <AlertTriangleIcon size={12} /> {source.hint}
                  </span>
                ) : null}
              </div>
            );
          })}
        </fieldset>

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

        <div className="form-row">
          <div className="form-group flex-1">
            <label htmlFor="index-mail-window">Mail vector window</label>
            <select
              id="index-mail-window"
              className="input-field"
              value={config.mail_vector_window}
              onChange={(event) =>
                updateConfig({ mail_vector_window: event.target.value })
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
              value={config.icloud_evicted}
              onChange={(event) =>
                updateConfig({ icloud_evicted: event.target.value })
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
          Attachment / file size cap: {config.max_file_mb} MB per file.
        </p>

        <label className="toggle-label">
          <input
            type="checkbox"
            checked={config.describe_images_with_llm}
            onChange={(event) =>
              updateConfig({ describe_images_with_llm: event.target.checked })
            }
          />
          <span>Describe images with the language model</span>
        </label>
        <p className="muted text-xs index-vision-disclosure">
          When enabled, image files are sent to your configured LLM provider to
          generate a description. Leave this off to keep images on-device.
        </p>

        <div className="row">
          <button
            type="button"
            className="primary icon-text-btn"
            onClick={() => void handleSave()}
            disabled={saving}
          >
            <span>{saving ? "Saving…" : "Save Index Settings"}</span>
          </button>
        </div>
      </div>
    </section>
  );
}

// One-line human summary of a completed run, naming why a skipped run did
// nothing so the notice never reads as a silent no-op. The trigger display
// label prefixes the machine-readable summary so the `Index run <status>`
// wording survives verbatim while the notice still names Manual, Nightly,
// and Catch-Up runs explicitly.
export function describeRunSummary(summary: IndexRunResponse): string {
  const label = indexRunTriggerLabel(summary.trigger);
  if (summary.status === "skipped") {
    return summary.skippedReason
      ? `${label} — Index run skipped: ${summary.skippedReason}`
      : `${label} — Index run skipped.`;
  }
  if (summary.status === "cancelled") {
    return `${label} — Index run cancelled: ${summary.documentsIndexed} indexed, ${summary.scanned} scanned. Committed work is kept and the next run resumes from there.`;
  }
  return `${label} — Index run ${summary.status}: ${summary.documentsIndexed} indexed, ${summary.vectorChunks} vectors, ${summary.keywordChunks} keyword-only, ${summary.scanned} scanned, ${summary.errors} errors.`;
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
