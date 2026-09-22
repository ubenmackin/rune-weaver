// Rune Weaver Dashboard — Local index status and control panel.
//
// Renders the master indexer toggle, per-source enablement, the file exclude
// editor, mail vector window, attachment cap, iCloud eviction policy, and the
// vision describe toggle, plus live store counts, the last watermark, and
// recent run failures. Run, Prune, and Rebuild drive the engine index routes
// and live progress rides the shared WebSocket `tool_progress` frames, so the
// panel never invents a completion fraction the engine cannot supply.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_CONFIG,
  INDEX_ICLOUD_EVICTIONS,
  INDEX_MAIL_VECTOR_WINDOWS,
  cancelIndex,
  getIndexStatus,
  getSettings,
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
import type { WSToolProgressFrame } from "../hooks/useSharedWebSocket";
import { AlertTriangleIcon, RefreshIcon, StopIcon, TrashIcon } from "./icons";
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

export default function IndexingPanel() {
  const [status, setStatus] = useState<IndexStatusResponse | null>(null);
  const [config, setConfig] = useState<IndexConfigData>(DEFAULT_INDEX_CONFIG);
  const [excludeText, setExcludeText] = useState<string>(
    DEFAULT_INDEX_CONFIG.exclude.join("\n"),
  );
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // One in-flight slot names the action so Run, Cancel, Prune, and Rebuild stay
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
  // Non-blocking destructive confirmations: prune and rebuild each render a
  // true modal so stored memory is never cleared by an accidental click.
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

  const loadStatus = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await getIndexStatus();
      setStatus(response);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Failed to load index status",
      );
    } finally {
      setLoading(false);
    }
  }, []);

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
      // A settings read failure leaves the local defaults; the status load above
      // surfaces the transport error so the panel stays usable.
    }
  }, []);

  useEffect(() => {
    void loadStatus();
    void loadConfig();
  }, [loadStatus, loadConfig]);

  // Live progress consumer: adopts `tool_progress` frames for the index run,
  // distilling the phase token plus counters and the relative current item. The
  // tail is relative-only server-side, so the panel never renders a filesystem
  // path even though the frame could not carry one.
  useSharedWebSocket((frame) => {
    if (frame.type !== "tool_progress") return;
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
  });

  // Clears the local run flight once the engine reports no run in flight, so a
  // run started from another tab still settles the panel's busy state.
  useEffect(() => {
    if (status?.running !== false) return;
    if (!runActiveRef.current) return;
    runActiveRef.current = false;
    setRunActive(false);
  }, [status?.running]);

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

  // Persists the policy form, then re-reads status so per-source enablement and
  // counts reflect the just-saved policy without a page reload.
  const handleSave = async () => {
    if (actionBusy) return;
    setSaving(true);
    setError(null);
    setNotice(null);
    try {
      await persistConfig();
      await loadStatus();
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
    <section className="panel indexing-panel" aria-label="Indexing">
      <div className="panel-header-row">
        <div>
          <h2>Indexing</h2>
          <p className="muted text-sm">
            Index local files, mail, and Messages so the agent can recall them.
            The indexer is off until you enable it.
          </p>
        </div>
        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => {
              void loadStatus();
              void loadConfig();
            }}
            disabled={loading || actionBusy}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
        </div>
      </div>

      {error ? <p className="error">{error}</p> : null}
      {notice ? <p className="muted text-sm">{notice}</p> : null}

      {/* Status summary: size, counts, watermark, and live run state. */}
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
        <p className="muted text-sm index-counts">
          {status
            ? `${formatIndexBytes(status.bytes)} · ${status.documents} documents · ${status.chunks} chunks (${status.vectorChunks} vector, ${status.keywordChunks} keyword)`
            : "Loading index status…"}
        </p>
        <p className="muted text-sm index-as-of">
          Index as of: {formatIndexAsOf(status?.indexAsOf)}
        </p>

        {status && status.lastErrors.length > 0 ? (
          <div className="index-errors" aria-label="Last index errors">
            <h4>Last errors</h4>
            <ul>
              {status.lastErrors.map((detail, index) => (
                <li key={`${index}-${detail.slice(0, 24)}`}>{detail}</li>
              ))}
            </ul>
          </div>
        ) : null}

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
            {/* Indeterminate work: the engine publishes no fraction, so an
                animated shimmer proves liveness without a fake progress bar. */}
            <div
              className="tool-progress-shimmer"
              data-testid="index-progress-shimmer"
              role="progressbar"
              aria-label="Index run in progress"
              aria-valuetext="In progress"
            />
          </div>
        )}
      </div>

      {/* Index policy form. */}
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
            disabled={saving || actionBusy}
          >
            <span>{saving ? "Saving…" : "Save Index Settings"}</span>
          </button>
        </div>
      </div>

      {/* Control actions. */}
      <div className="index-actions-section">
        <h3>Run</h3>
        <div className="row">
          <button
            type="button"
            className="primary icon-text-btn"
            onClick={() => void handleRun()}
            disabled={actionBusy || !config.enabled}
            title={
              config.enabled
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
        <p className="muted text-xs">
          Prune removes documents older than the cutoff date you choose; Reset
          clears the whole index so the next run rebuilds from scratch.
        </p>
      </div>

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
              Keep
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
