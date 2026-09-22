// Rune Weaver Dashboard — Local index status dashboard and policy form.
//
// The status dashboard (Memory → Index Status) owns Run/Cancel/Prune/Reset,
// the stat cards, and frontend-only SVG/CSS charts computed from the existing
// GET /index/status fields; the policy form (Settings → Indexing) owns the
// enable/sources/excludes/caps fields with its own Save, so neither surface
// duplicates the other's control set. Status freshness comes from the shared
// WebSocket run broadcasts — there is no manual Refresh button — and live
// progress rides the `tool_progress` frames, so the panel never invents a
// completion fraction the engine cannot supply.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_CONFIG,
  INDEX_ICLOUD_EVICTIONS,
  INDEX_MAIL_VECTOR_WINDOWS,
  cancelIndex,
  getIndexStatus,
  getSettings,
  indexWatermarkAgeMs,
  parseRunTimestamp,
  pruneIndex,
  resetIndex,
  runIndex,
  updateSettings,
  type IndexConfigData,
  type IndexRunResponse,
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

// Engine index source kinds in canonical run order, each with its display label.
// The Messages label carries the Full Disk Access hint because reading the chat
// database requires that grant on macOS.
const INDEX_SOURCES: Array<{ kind: string; label: string; hint?: string }> = [
  { kind: "files", label: "Files" },
  { kind: "mail", label: "Mail" },
  {
    kind: "messages",
    label: "Messages",
    hint: "Requires Full Disk Access in System Settings → Privacy & Security.",
  },
];

// Display label for a status source kind, falling back to the engine's wire
// token so an unknown future source still renders honestly.
function sourceLabel(kind: string): string {
  return INDEX_SOURCES.find((source) => source.kind === kind)?.label ?? kind;
}

// Ordered index phases, mirroring IndexPhase on the engine. The live progress
// line names the current step by matching the phase token in the frame message.
const INDEX_PHASES = ["discovering", "extracting", "embedding", "committing"] as const;

// Tool identity the engine stamps on index progress frames. Progress is only
// adopted while a run is active and either carries this name or, on older
// engines that omit it, arrives during our own in-flight run.
export const INDEX_PROGRESS_TOOL_NAME = "index";

// User copy per phase so the step list renders plain language rather than the
// engine's wire token.
const INDEX_PHASE_COPY: Record<string, string> = {
  discovering: "Discovering",
  extracting: "Reading",
  embedding: "Vectorizing",
  committing: "Committing",
};

// Chart palette drawn from the dashboard theme tokens: the vector segment uses
// the accent purple, the keyword segment the accent blue, and the tracks reuse
// the border color so both charts read as native surfaces without new CSS.
const CHART_VECTOR_COLOR = "var(--accent-purple)";
const CHART_KEYWORD_COLOR = "var(--accent-blue)";
const CHART_TRACK_COLOR = "var(--border-color)";

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

// Extracts the phase token from a live progress frame message
// ("Indexing extracting: …"), degrading to null when the engine changes the
// wording so the step list simply holds its previous position.
export function resolveIndexPhase(message: string | null | undefined): string | null {
  if (typeof message !== "string") return null;
  const match = /Indexing\s+(\w+)/.exec(message);
  if (!match) return null;
  const phase = match[1].toLowerCase();
  return INDEX_PHASES.includes(phase as (typeof INDEX_PHASES)[number]) ? phase : null;
}

// Reports whether a live progress frame belongs to an index run. The engine
// stamps the index tool name when present; otherwise a frame is adopted only
// while the caller has an active run, so unrelated tool progress never leaks in.
export function isIndexProgressFrame(
  frame: Pick<WSToolProgressFrame, "toolName">,
  runActive: boolean,
): boolean {
  const name = typeof frame.toolName === "string" ? frame.toolName.trim().toLowerCase() : "";
  if (name === INDEX_PROGRESS_TOOL_NAME) return true;
  if (name.length > 0) return false;
  return runActive;
}

// Live progress distilled from one frame so the panel renders a stable shape
// regardless of which counters the engine populates.
export interface IndexLiveProgress {
  phase: string | null;
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
  // One in-flight slot names the action so Run, Cancel, Prune, and Reset stay
  // mutually exclusive while a request is pending.
  const [action, setAction] = useState<
    "run" | "cancel" | "prune" | "reset" | null
  >(null);
  const actionBusy = action !== null;
  const [liveProgress, setLiveProgress] = useState<IndexLiveProgress | null>(null);
  // Synchronous guard for the run flight: state commits asynchronously, so a
  // double-click before re-render would otherwise start two runs. The ref flips
  // immediately and the state mirrors it for rendering.
  const runActiveRef = useRef(false);
  const [runActive, setRunActive] = useState(false);
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

  // True whenever the engine reports a run in flight or this panel started one,
  // so progress frames are only adopted during a real run.
  const progressActive = runActive || status?.running === true;
  const indexingEnabled = status?.enabled === true;

  const vectorChunks = status?.vectorChunks ?? 0;
  const keywordChunks = status?.keywordChunks ?? 0;
  const donut = indexDonutArcs(vectorChunks, keywordChunks, DONUT_RADIUS);

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

  // Live progress consumer: adopts `tool_progress` frames for the index run,
  // distilling the phase token plus counters and the relative current item. The
  // tail is relative-only server-side, so the panel never renders a filesystem
  // path even though the frame could not carry one. Any run broadcast — a pass
  // starting elsewhere or reaching its terminal summary — reloads status so the
  // cards stay fresh without a manual Refresh control.
  const handleIndexBroadcast = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as WSGenericFrame).type;
      if (frameType === "run_started" || frameType === "run_completed") {
        void loadStatus();
        return;
      }
      if (frameType !== "tool_progress") return;
      const progress = frame as WSToolProgressFrame;
      if (!isIndexProgressFrame(progress, runActiveRef.current)) return;
      setLiveProgress({
        phase: resolveIndexPhase(progress.message),
        message: typeof progress.message === "string" ? progress.message : "",
        scanned: progress.scanned,
        indexed: progress.matched,
        elapsedMs: progress.elapsedMs,
        current:
          typeof progress.current === "string" && progress.current.trim()
            ? progress.current.trim()
            : null,
      });
    },
    [loadStatus],
  );

  useSharedWebSocket(handleIndexBroadcast);

  // Clears the local run flight once the engine reports no run in flight, so a
  // run started from another tab still settles the panel's busy state.
  useEffect(() => {
    if (status?.running !== false) return;
    if (!runActiveRef.current) return;
    runActiveRef.current = false;
    setRunActive(false);
  }, [status?.running]);

  // Starts an on-demand run and awaits its terminal summary. Progress frames
  // keep the live line honest while the request is in flight; the summary fills
  // the notice so a skipped run explains why instead of appearing silent.
  const handleRun = async () => {
    if (actionBusy || runActiveRef.current) return;
    runActiveRef.current = true;
    setRunActive(true);
    setAction("run");
    setError(null);
    setNotice(null);
    setLiveProgress(null);
    try {
      const summary = await runIndex();
      setNotice(describeRunSummary(summary));
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

  // Asks the engine to stop an in-flight run at its next safe point. Committed
  // work survives, so a cancelled run simply resumes from the first unfinished
  // item on the next run.
  const handleCancel = async () => {
    if (actionBusy) return;
    setAction("cancel");
    setError(null);
    setNotice(null);
    try {
      const response = await cancelIndex();
      setNotice(
        response?.cancelled
          ? "Cancellation requested; committed work is kept and the next run resumes from there."
          : "No index run was in flight.",
      );
      await loadStatus();
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Failed to cancel index run",
      );
    } finally {
      setAction(null);
    }
  };

  const handleConfirmPrune = async () => {
    if (actionBusy) return;
    const trimmed = pruneBefore.trim();
    if (!trimmed) {
      setPruneError("Choose a cutoff date before pruning.");
      return;
    }
    const cutoff = new Date(trimmed);
    if (Number.isNaN(cutoff.getTime())) {
      setPruneError("Choose a valid cutoff date before pruning.");
      return;
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
    if (actionBusy) return;
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
            disabled={actionBusy || !indexingEnabled}
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
            disabled={actionBusy || !progressActive}
          >
            <StopIcon size={14} />
            <span>{action === "cancel" ? "Cancelling…" : "Cancel"}</span>
          </button>

          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => {
              setPruneBefore("");
              setPruneError(null);
              setPendingPrune(true);
            }}
            disabled={actionBusy}
          >
            <TrashIcon size={14} />
            <span>{action === "prune" ? "Pruning…" : "Prune"}</span>
          </button>

          <button
            type="button"
            className="danger icon-text-btn"
            onClick={() => setPendingRebuild(true)}
            disabled={actionBusy}
          >
            <TrashIcon size={14} />
            <span>{action === "reset" ? "Clearing…" : "Reset Index"}</span>
          </button>
        </div>
      </div>

      {/* Live phase steps + shimmer while a run is in flight: the engine
          publishes no fraction, so an animated shimmer proves liveness. */}
      {(progressActive || liveProgress) && (
        <div className="index-live-progress" data-testid="index-live-progress">
          <div className="index-live-header">
            <span className="status-pill running">Indexing</span>
            {liveProgress ? (
              <span className="muted text-xs">
                {liveProgress.scanned} scanned · {liveProgress.indexed} indexed ·{" "}
                {formatElapsed(liveProgress.elapsedMs)}
              </span>
            ) : (
              <span className="muted text-xs">Starting…</span>
            )}
          </div>
          {/* Phase steps: the current phase is highlighted from the frame
              message; unknown wording holds the previous position. */}
          <ol className="index-phase-steps">
            {INDEX_PHASES.map((phase) => (
              <li
                key={phase}
                className={liveProgress?.phase === phase ? "active" : ""}
              >
                {INDEX_PHASE_COPY[phase]}
              </li>
            ))}
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
          <div
            className="tool-progress-shimmer"
            data-testid="index-progress-shimmer"
            role="progressbar"
            aria-label="Index run in progress"
            aria-valuetext="In progress"
          />
        </div>
      )}

      {/* Stat cards middle: size, counts with the vector/keyword split,
          watermark age, per-source pills, and recent failures. */}
      <div className="index-status-section">
        <h3>Status</h3>
        <div className="index-status-line">
          {status?.running || runActive ? (
            <span className="status-pill running">Running</span>
          ) : status?.enabled ? (
            <span className="status-pill ok">Enabled</span>
          ) : (
            <span className="status-pill skipped">Disabled</span>
          )}
        </div>

        {status ? (
          <>
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
              <div className="card index-stat-card" style={{ padding: 12, marginBottom: 0 }}>
                <div className="muted text-xs">Last indexed</div>
                <div
                  style={{ fontSize: 16, fontWeight: 700, marginTop: 2 }}
                  title={formatIndexAsOf(status.indexAsOf)}
                >
                  {formatIndexAge(status.indexAsOf)}
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
              </div>
            ) : null}
          </>
        ) : (
          <p className="muted text-sm">Loading index status…</p>
        )}
      </div>

      {/* Charts bottom: frontend-only SVG donut (vector vs keyword) plus CSS
          bars for per-source enablement — plain markup computed from the
          status payload, no chart dependency and no extra route. */}
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
              {status.sources.map((source) => (
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
                      style={{
                        width: source.enabled ? "100%" : "0%",
                        height: "100%",
                        borderRadius: 5,
                        background: CHART_VECTOR_COLOR,
                      }}
                    />
                  </div>
                  <span className="text-xs muted" style={{ width: 24, textAlign: "right" }}>
                    {source.enabled ? "On" : "Off"}
                  </span>
                </div>
              ))}
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
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

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
    setError(null);
    setNotice(null);
    try {
      await persistConfig();
      setNotice("Index settings saved.");
    } catch (failure) {
      setError(
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

      {error ? <p className="error">{error}</p> : null}
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

// Formats the live elapsed time with a tenth of a second under ten seconds and
// whole seconds beyond, matching the chat tool progress convention.
function formatElapsed(elapsedMs: number): string {
  const seconds = Math.max(0, elapsedMs) / 1000;
  const rounded = seconds >= 10 ? Math.round(seconds) : Math.round(seconds * 10) / 10;
  return `${rounded}s`;
}

// One-line human summary of a completed run, naming why a skipped run did
// nothing so the notice never reads as a silent no-op.
function describeRunSummary(summary: IndexRunResponse): string {
  if (summary.status === "skipped") {
    return summary.skippedReason
      ? `Index run skipped: ${summary.skippedReason}`
      : "Index run skipped.";
  }
  if (summary.status === "cancelled") {
    return `Index run cancelled: ${summary.documentsIndexed} indexed, ${summary.scanned} scanned.`;
  }
  return `Index run ${summary.status}: ${summary.documentsIndexed} indexed, ${summary.vectorChunks} vectors, ${summary.keywordChunks} keyword-only, ${summary.scanned} scanned, ${summary.errors} errors.`;
}
