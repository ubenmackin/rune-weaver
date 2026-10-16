// Rune Weaver Dashboard — Shared tool execution action row component.

import { useState, useEffect, useRef } from "react";
import type {
  FileReviewStates,
  ToolAction,
  ToolProgress,
  ToolResult,
} from "../api";
import { formatToolProgressCounts } from "../api";
import { ChevronDownIcon, ChevronRightIcon, WrenchIcon } from "./icons";
import DiffCard from "./DiffCard";

export interface ToolActionRowProps {
  action: ToolAction;
  variant?: "chat" | "card";
  // True only while the turn is still streaming: a result-less action is
  // genuinely executing then, while a completed turn with no result is
  // awaiting a decision or was interrupted and must never claim to run.
  isLive?: boolean;
  // Latest throttled progress for this call, keyed by call identity upstream.
  // Only the live chat variant renders it; a completed row keeps its result and
  // never shows a stale progress line.
  progress?: ToolProgress | null;
  // True after a cancel was requested for this call but before its terminal
  // frame settles, so the row reports "Cancelling…" instead of implying the
  // cancel already finished.
  cancelling?: boolean;
  // Requests cancellation of this one call by identity. Optional so card and
  // history surfaces render a plain row with no cancel affordance.
  onCancelTool?: (callID: string, reason?: string) => void;
  // False when a newer files.write row for the same live path and envelope kind
  // owns the file's review; the nested DiffCard then shows a note instead of
  // review controls. Defaults true so single-card surfaces stay actionable.
  ownsFileReview?: boolean;
  // Whether a chat-variant files.write DiffCard starts with its diff body
  // expanded. The card variant ignores it so run details stay fully expanded.
  fileWriteDefaultExpanded?: boolean;
  // Batched review-ledger posture from the rendered surface, forwarded to the
  // nested DiffCard. Undefined keeps the card's own single-path fallback read.
  fileReviewStates?: FileReviewStates | null;
}

interface BrowserRedirect {
  url: string;
  status?: number | null;
}

export interface BrowserNavigate {
  finalUrl?: string | null;
  // Unified envelope mirrors the engine shape ({url,title,text,refs,
  // truncated,authRequired,downloads,note}) plus the shared wire aliases
  // ({finalUrl/finalURL/final_url, textSnapshot/snapshot, redirectChain/ redirect_chain/redirects}).
  title?: string | null;
  redirectCount: number;
  redirectChain: BrowserRedirect[];
  refs: string[];
  authRequired: boolean;
  truncated: boolean;
  downloads: string[];
  note?: string | null;
  textSnapshot?: string | null;
  screenshotDataURL?: string | null;
  screenshotHash?: string | null;
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? value : null;
}

function asRedirectList(value: unknown): BrowserRedirect[] {
  if (!Array.isArray(value)) return [];
  const out: BrowserRedirect[] = [];
  for (const entry of value) {
    if (typeof entry === "string" && entry.trim().length > 0) {
      out.push({ url: entry });
    } else if (entry != null && typeof entry === "object") {
      const record = entry as Record<string, unknown>;
      // Engine redirect steps carry only {url,status} (`BrowserRedirectStep`
      // via `BrowserNavigateWire`), so only `url` resolves here.
      const url = asNonEmptyString(record.url);
      if (url) {
        const status =
          typeof record.status === "number" && Number.isFinite(record.status)
            ? record.status
            : null;
        out.push({ url, status });
      }
    }
  }
  return out;
}

// Reads string-list envelope fields (refs, downloads) that may arrive as
// plain strings or {url} objects across engine versions.
function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const out: string[] = [];
  for (const entry of value) {
    if (typeof entry === "string" && entry.trim().length > 0) {
      out.push(entry);
    } else if (entry != null && typeof entry === "object") {
      // Engine lists resolve through `url` only, matching the redirect
      // entry contract above.
      const record = entry as Record<string, unknown>;
      const url = asNonEmptyString(record.url);
      if (url) out.push(url);
    }
  }
  return out;
}

// Allows only raster thumbnails in the lightbox so a crafted payload cannot
// turn the preview into an executable or SVG-script vector.
// Single-sources the thumbnail allowlist with `asImageDataURL` below.
const SAFE_THUMBNAIL_PREFIXES = [
  "data:image/jpeg;base64,",
  "data:image/png;base64,",
  "data:image/webp;base64,",
  "data:image/gif;base64,",
] as const;

function isSafeThumbnailDataURL(value: string | null | undefined): value is string {
  if (!value) return false;
  return SAFE_THUMBNAIL_PREFIXES.some((prefix) => value.startsWith(prefix));
}

// Strict shared contract mirrored by the engine thumbnail gate
// (BrowserNavigateWire.normalizedDataURL): only data:image/jpeg|png|webp|gif mounts, plus raw helper
// bytes starting with /9j/ or iVBOR.
function asImageDataURL(value: unknown): string | null {
  const raw = asNonEmptyString(value);
  if (!raw) return null;
  const trimmed = raw.trim();
  if (trimmed.startsWith("data:image/")) {
    // Only raster thumbnails reach the lightbox; anything else stays a hash so an unexpected data
    // URL never becomes executable markup.
    return isSafeThumbnailDataURL(trimmed) ? trimmed : null;
  }
  if (trimmed.startsWith("/9j/") || trimmed.startsWith("iVBOR")) {
    return `data:image/jpeg;base64,${trimmed}`;
  }
  return null;
}

// Tolerant reader for browser.navigate JSON results.
export function parseBrowserNavigate(content: string | null | undefined): BrowserNavigate | null {
  if (typeof content !== "string") return null;
  const trimmed = content.trim();
  if (!trimmed.startsWith("{")) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  const record = parsed as Record<string, unknown>;
  // Engine `url` folds into finalUrl so real tool output ({url,...}) renders
  // a summary instead of falling through to null.
  const finalUrl =
    asNonEmptyString(record.finalUrl) ??
    asNonEmptyString(record.finalURL) ??
    asNonEmptyString(record.final_url) ??
    asNonEmptyString(record.url);
  // Engine envelope carries `title` only.
  const title = asNonEmptyString(record.title);
  const primaryChain = asRedirectList(record.redirectChain);
  const fallbackChain = asRedirectList(record.redirect_chain);
  const redirectsChain = asRedirectList(record.redirects);
  const chain =
    primaryChain.length > 0
      ? primaryChain
      : fallbackChain.length > 0
        ? fallbackChain
        : redirectsChain;
  // Engine refs stay separate from the redirect chain so the
  // chain label never misreports refs as redirects.
  const refs = asStringList(record.refs);
  const rawCount = record.redirectCount ?? record.redirect_count;
  // Collapsed count single-sources the engine `-1` rule
  // (`BrowserNavigateEnvelope:init` uses max(0, chain.count - 1)) so a
  // single-step chain renders 0 on both sides instead of 1 vs 0.
  const redirectCount =
    typeof rawCount === "number" && Number.isFinite(rawCount) && rawCount >= 0
      ? Math.floor(rawCount)
      : Math.max(0, chain.length - 1);
  const authRaw =
    record.authRequired ?? record.auth_required ?? record.requiresAuth;
  const authRequired = authRaw === true;
  const truncated = record.truncated === true;
  const downloads = asStringList(record.downloads);
  const note =
    asNonEmptyString(record.note) ??
    asNonEmptyString(record.message) ??
    null;
  const textSnapshot =
    asNonEmptyString(record.textSnapshot) ??
    asNonEmptyString(record.text_snapshot) ??
    asNonEmptyString(record.snapshot);
  // Generic text is a first-class snapshot for browser.navigate results: the parser only runs for
  // that tool, and the engine emits bare {url,text,refs} without alias keys, so gating text behind
  // finalUrl hid real output.
  const genericText = asNonEmptyString(record.text);
  const snapshot = textSnapshot ?? genericText;
  // Engine screenshot hash keys only (screenshotHash/screenshot_hash/imageHash).
  const screenshotHash =
    asNonEmptyString(record.screenshotHash) ??
    asNonEmptyString(record.screenshot_hash) ??
    asNonEmptyString(record.imageHash);
  // Engine data-URL keys only (screenshotDataURL/thumbnailDataURL/
  // imageDataURL/screenshot/thumbnail, normalized through the shared
  // thumbnail gate).
  const screenshotDataURL =
    asImageDataURL(record.screenshotDataURL) ??
    asImageDataURL(record.thumbnailDataURL) ??
    asImageDataURL(record.imageDataURL) ??
    asImageDataURL(record.screenshot) ??
    asImageDataURL(record.thumbnail);
  const hasSignal =
    finalUrl != null ||
    title != null ||
    chain.length > 0 ||
    refs.length > 0 ||
    (typeof rawCount === "number" && Number.isFinite(rawCount)) ||
    authRequired ||
    truncated ||
    downloads.length > 0 ||
    note != null ||
    snapshot != null ||
    screenshotHash != null ||
    screenshotDataURL != null;
  if (!hasSignal) return null;
  return {
    finalUrl: finalUrl ?? null,
    title: title ?? null,
    redirectCount,
    redirectChain: chain,
    refs,
    authRequired,
    truncated,
    downloads,
    note,
    textSnapshot: snapshot,
    screenshotDataURL,
    screenshotHash: screenshotHash ?? null,
  };
}

function BrowserSummary({
  browser,
}: {
  browser: BrowserNavigate;
}) {
  return (
    <div className="browser-navigate-summary">
      {browser.finalUrl ? (
        <div className="browser-final-url-row">
          <span className="browser-final-url-label">Final URL:</span>
          <span
            className="browser-final-url"
            title={browser.finalUrl}
            data-testid="browser-final-url"
          >
            {browser.finalUrl}
          </span>
          {browser.redirectCount > 0 ? (
            <span
              className="browser-redirect-count"
              data-testid="browser-redirect-count"
            >
              · {browser.redirectCount} redirect{browser.redirectCount === 1 ? "" : "s"}
            </span>
          ) : null}
        </div>
      ) : browser.redirectCount > 0 ? (
        <div className="browser-final-url-row">
          <span
            className="browser-redirect-count"
            data-testid="browser-redirect-count"
          >
            {browser.redirectCount} redirect{browser.redirectCount === 1 ? "" : "s"}
          </span>
        </div>
      ) : null}
      {browser.title ? (
        <div className="browser-title-row">
          <span
            className="browser-page-title"
            title={browser.title}
            data-testid="browser-title"
          >
            {browser.title}
          </span>
        </div>
      ) : null}
      {browser.refs.length > 0 ? (
        <span
          className="browser-refs-count"
          data-testid="browser-refs-count"
        >
          {browser.refs.length} reference{browser.refs.length === 1 ? "" : "s"}
        </span>
      ) : null}
      {browser.truncated ? (
        <span
          className="pending-approval-badge truncated-badge"
          data-testid="browser-truncated-badge"
          title="Text snapshot was truncated"
        >
          TRUNCATED
        </span>
      ) : null}
      {browser.authRequired ? (
        <span
          className="pending-approval-badge auth-required-badge"
          data-testid="auth-required-badge"
          title="The landing page requires authentication"
        >
          AUTH REQUIRED
        </span>
      ) : null}
      {browser.note ? (
        <div
          className="browser-note-row"
          title={browser.note}
          data-testid="browser-note"
        >
          {browser.note}
        </div>
      ) : null}
    </div>
  );
}

function BrowserDetails({ browser }: { browser: BrowserNavigate }) {
  const [lightboxOpen, setLightboxOpen] = useState(false);
  const thumbnailBtnRef = useRef<HTMLButtonElement>(null);
  const closeBtnRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const prevFocusRef = useRef<Element | null>(null);
  const hasChain = browser.redirectChain.length > 0;
  const hasRefs = browser.refs.length > 0;
  const hasDownloads = browser.downloads.length > 0;
  const hasNote =
    typeof browser.note === "string" && browser.note.length > 0;
  const hasSnapshot =
    typeof browser.textSnapshot === "string" && browser.textSnapshot.length > 0;
  const hasThumbnail = isSafeThumbnailDataURL(browser.screenshotDataURL);
  const hasHash =
    typeof browser.screenshotHash === "string" && browser.screenshotHash.length > 0;
  // Escape closes the lightbox, Tab stays trapped inside the dialog, and
  // focus returns to the thumbnail so keyboard users never lose place.
  useEffect(() => {
    if (!lightboxOpen) return;
    prevFocusRef.current = document.activeElement;
    closeBtnRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        setLightboxOpen(false);
      } else if (event.key === "Tab") {
        // Scoped to this lightbox panel so multiple open browser rows trap
        // focus in the visible dialog instead of the first panel in document.
        const panel = panelRef.current;
        if (!panel) return;
        const focusables = panel.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])',
        );
        if (focusables.length === 0) {
          event.preventDefault();
          closeBtnRef.current?.focus();
          return;
        }
        const first = focusables[0];
        const last = focusables[focusables.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", onKeyDown, true);
    return () => {
      document.removeEventListener("keydown", onKeyDown, true);
      const prev = prevFocusRef.current as HTMLElement | null;
      if (prev && typeof prev.focus === "function") {
        prev.focus();
      } else {
        thumbnailBtnRef.current?.focus();
      }
    };
  }, [lightboxOpen]);
  const closeLightbox = () => setLightboxOpen(false);
  if (
    !hasChain &&
    !hasRefs &&
    !hasDownloads &&
    !hasNote &&
    !hasSnapshot &&
    !hasThumbnail &&
    !hasHash
  )
    return null;
  return (
    <div className="browser-navigate-details">
      {hasChain ? (
        <details className="browser-chain-details" data-testid="browser-chain-details">
          <summary>
            Redirect chain ({browser.redirectChain.length})
          </summary>
          <ol className="browser-chain-list">
            {browser.redirectChain.map((step, index) => (
              <li key={`${step.url}-${index}`} className="browser-chain-item">
                <span className="browser-chain-url" title={step.url}>
                  {step.url}
                </span>
                {typeof step.status === "number" ? (
                  <span className="browser-chain-status">{step.status}</span>
                ) : null}
              </li>
            ))}
          </ol>
        </details>
      ) : null}
      {hasRefs ? (
        <details className="browser-refs-details" data-testid="browser-refs-details">
          <summary>References ({browser.refs.length})</summary>
          <ol className="browser-chain-list">
            {browser.refs.map((ref, index) => (
              <li key={`${ref}-${index}`} className="browser-chain-item">
                <span className="browser-chain-url" title={ref}>
                  {ref}
                </span>
              </li>
            ))}
          </ol>
        </details>
      ) : null}
      {hasSnapshot ? (
        <details className="browser-snapshot-details" data-testid="browser-snapshot-details">
          <summary>Text snapshot{browser.truncated ? " (truncated)" : ""}</summary>
          <pre className="browser-snapshot-body" data-testid="browser-snapshot">
            {browser.textSnapshot}
          </pre>
        </details>
      ) : null}
      {hasDownloads ? (
        <details className="browser-downloads-details" data-testid="browser-downloads-details">
          <summary>Downloads ({browser.downloads.length})</summary>
          <ol className="browser-chain-list">
            {browser.downloads.map((item, index) => (
              <li key={`${item}-${index}`} className="browser-chain-item">
                <span className="browser-chain-url" title={item}>
                  {item}
                </span>
              </li>
            ))}
          </ol>
        </details>
      ) : null}
      {hasThumbnail ? (
        <div className="browser-screenshot-row">
          <button
            type="button"
            ref={thumbnailBtnRef}
            className="browser-thumbnail-btn"
            onClick={() => setLightboxOpen(true)}
            aria-label="Open screenshot preview"
            aria-haspopup="dialog"
            aria-expanded={lightboxOpen}
            aria-controls="browser-screenshot-lightbox"
            data-testid="browser-thumbnail"
          >
            <img
              src={browser.screenshotDataURL as string}
              alt="Page screenshot thumbnail"
              className="browser-thumbnail"
            />
          </button>
          {hasHash ? (
            <span className="browser-screenshot-hash" title={browser.screenshotHash as string}>
              hash {(browser.screenshotHash as string).slice(0, 12)}
            </span>
          ) : null}
          {lightboxOpen ? (
            <div
              className="browser-lightbox-backdrop"
              data-testid="browser-lightbox"
              onClick={closeLightbox}
            >
              <div
                className="browser-lightbox-panel"
                id="browser-screenshot-lightbox"
                role="dialog"
                aria-modal="true"
                aria-label="Screenshot preview"
                ref={panelRef}
                onClick={(event) => event.stopPropagation()}
              >
                <button
                  type="button"
                  ref={closeBtnRef}
                  className="browser-lightbox-close"
                  onClick={closeLightbox}
                  aria-label="Close screenshot preview"
                >
                  Close
                </button>
                <img
                  src={browser.screenshotDataURL as string}
                  alt="Page screenshot full preview"
                  className="browser-lightbox-image"
                />
              </div>
            </div>
          ) : null}
        </div>
      ) : hasHash ? (
        <div className="browser-screenshot-row">
          <span className="browser-screenshot-hash" title={browser.screenshotHash as string}>
            Screenshot hash {(browser.screenshotHash as string).slice(0, 12)}
          </span>
        </div>
      ) : null}
    </div>
  );
}

// Semantic status for a finished tool result, mirrored by both the chat pill and the card variant.
type ToolResultStatusKind =
  | "invalid-tool"
  | "invalid-syntax"
  | "error"
  | "warning"
  | "ok";

interface BashResultEnvelope {
  denied: boolean;
  killReason: string | null;
  exitCode: number;
}

function parseBashResultEnvelope(
  content: string | null | undefined,
): BashResultEnvelope | null {
  if (typeof content !== "string") return null;
  const trimmed = content.trim();
  if (!trimmed.startsWith("{")) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  const record = parsed as Record<string, unknown>;
  // Only envelope-owned keys count, so bare command/stdout/stderr JSON never
  // defaults to a clean exit.
  const hasSignal =
    "denied" in record ||
    "kill_reason" in record ||
    "killReason" in record ||
    "exitCode" in record ||
    "exit_code" in record;
  if (!hasSignal) return null;
  const denied = record.denied === true;
  const rawKill =
    typeof record.kill_reason === "string"
      ? record.kill_reason
      : typeof record.killReason === "string"
        ? record.killReason
        : null;
  const rawExit = record.exitCode ?? record.exit_code;
  const exitCode =
    typeof rawExit === "number" && Number.isFinite(rawExit)
      ? Math.trunc(rawExit)
      : 0;
  return { denied, killReason: rawKill, exitCode };
}

function resolveResultStatus(
  result: ToolResult,
  toolName?: string,
): {
  kind: ToolResultStatusKind;
  label: string;
} {
  // Direct typed exitCode check takes precedence for clean non-zero exits,
  // immune to content truncation, wrapper labels (e.g. untrusted content banners), or JSON escaping.
  if (result.exitCode != null && result.exitCode !== 0) {
    if (toolName === "bash.exec") {
      const envelope = parseBashResultEnvelope(result.content);
      if (envelope?.denied || envelope?.killReason === "denied") {
        return { kind: "error", label: "Denied" };
      }
      if (envelope?.killReason === "wall_timeout") {
        return { kind: "error", label: "Timed out" };
      }
      if (envelope?.killReason === "resource_limit") {
        return { kind: "error", label: "Resource limit" };
      }
    }
    return { kind: "warning", label: `Exited ${result.exitCode}` };
  }

  // Bash-only envelope evidence; every other tool keeps existing behavior.
  if (toolName === "bash.exec") {
    const envelope = parseBashResultEnvelope(result.content);
    if (envelope == null) {
      if (!result.isError) return { kind: "ok", label: "Done" };
      return { kind: "error", label: "Error" };
    }
    // A refused spawn reads as denied even when the numeric code is zero.
    if (envelope.denied || envelope.killReason === "denied") {
      return { kind: "error", label: "Denied" };
    }
    if (envelope.killReason === "wall_timeout") {
      return { kind: "error", label: "Timed out" };
    }
    if (envelope.killReason === "resource_limit") {
      return { kind: "error", label: "Resource limit" };
    }
    if (envelope.exitCode !== 0) {
      return { kind: "warning", label: `Exited ${envelope.exitCode}` };
    }
    // A tool-level failure without envelope evidence stays red even when the
    // numeric exit reads clean, so generic runner faults never show Done.
    if (result.isError) {
      return { kind: "error", label: "Error" };
    }
    return { kind: "ok", label: "Done" };
  }
  if (!result.isError) return { kind: "ok", label: "Done" };
  if (result.errorKind === "invalid_tool") {
    return { kind: "invalid-tool", label: "Unknown Tool" };
  }
  if (result.errorKind === "invalid_syntax") {
    return { kind: "invalid-syntax", label: "Invalid Syntax" };
  }
  if (result.errorKind === "uncertain_outcome") {
    return { kind: "error", label: "Uncertain Outcome" };
  }
  if (result.errorKind === "idempotency_blocked") {
    return { kind: "error", label: "Idempotency Blocked" };
  }
  return { kind: "error", label: "Error" };
}

// Whether a bash result is a clean non-zero exit that stays honest-amber.
function isBashCleanExitWarning(
  result: ToolResult,
  toolName?: string,
): boolean {
  if (toolName !== "bash.exec") return false;
  if (result.exitCode != null && result.exitCode !== 0) {
    const envelope = parseBashResultEnvelope(result.content);
    if (envelope) {
      if (envelope.denied || envelope.killReason === "denied") return false;
      if (
        envelope.killReason === "wall_timeout" ||
        envelope.killReason === "resource_limit"
      )
        return false;
    }
    return true;
  }
  const envelope = parseBashResultEnvelope(result.content);
  if (!envelope) return false;
  if (envelope.denied || envelope.killReason === "denied") return false;
  if (
    envelope.killReason === "wall_timeout" ||
    envelope.killReason === "resource_limit"
  )
    return false;
  return envelope.exitCode !== 0;
}

// Expanded output tone derives from the envelope, not isError alone, so a
// clean non-zero bash exit renders neutral while keeping isError true.
function shouldUseErrorTone(
  result: ToolResult,
  toolName?: string,
): boolean {
  if (!result.isError) return false;
  if (isBashCleanExitWarning(result, toolName)) return false;
  return true;
}

// Live progress line rendered under the Running pill.
function ToolProgressLine({ progress }: { progress: ToolProgress }) {
  const scope = progress.message.trim();
  const warning =
    typeof progress.warning === "string" && progress.warning.trim().length > 0
      ? progress.warning.trim()
      : null;
  return (
    <div
      className="chat-tool-progress"
      data-testid="tool-progress"
    >
      <div className="chat-tool-progress-scope">
        <span>{scope}</span>
        {warning ? (
          <span
            className="tool-progress-scope-warning"
            data-testid="tool-progress-scope-warning"
            title="This search spans a broad scope"
          >
            — {warning}
          </span>
        ) : null}
      </div>
      <div className="tool-progress-stats" data-testid="tool-progress-stats">
        {formatToolProgressCounts(progress)}
      </div>
      {progress.current ? (
        <div
          className="tool-progress-current"
          data-testid="tool-progress-current"
          title={progress.current}
        >
          current: {progress.current}
        </div>
      ) : null}
      {/* Indeterminate work: the engine publishes no percentage, so an animated
          shimmer proves liveness without a fake progress bar. */}
      <div
        className="tool-progress-shimmer"
        data-testid="tool-progress-shimmer"
        role="progressbar"
        aria-label={`${progress.toolName} in progress`}
        aria-valuetext="In progress"
      />
    </div>
  );
}

// Per-call cancel affordance for the live chat row. The reason is optional, so
// the popover submits either a trimmed note or nothing at all; Escape dismisses
// without cancelling so an accidental open never stops a running tool.
function ToolCancelControl({
  toolName,
  callID,
  cancelling,
  onCancelTool,
}: {
  toolName: string;
  callID: string;
  cancelling: boolean;
  onCancelTool: (callID: string, reason?: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  // Escape closes the popover without submitting so keyboard users can back out
  // of a cancel the same way they dismiss the browser lightbox.
  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        setOpen(false);
      }
    };
    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [open]);
  if (cancelling) {
    return (
      <span
        className="chat-tool-cancelling"
        role="status"
        data-testid="tool-cancelling"
      >
        Cancelling…
      </span>
    );
  }
  const submit = () => {
    const trimmed = reason.trim();
    onCancelTool(callID, trimmed.length > 0 ? trimmed : undefined);
    setOpen(false);
    setReason("");
  };
  const dismiss = () => {
    setOpen(false);
    setReason("");
  };
  return (
    <div className="chat-tool-cancel">
      <button
        type="button"
        className="chat-tool-cancel-btn"
        aria-label={`Cancel tool ${toolName}`}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen((previous) => !previous)}
      >
        ✕ Cancel tool
      </button>
      {open ? (
        <div
          className="tool-cancel-popover"
          role="dialog"
          aria-label={`Cancel ${toolName}`}
        >
          <label
            className="tool-cancel-reason-label"
            htmlFor={`tool-cancel-reason-${callID}`}
          >
            Reason (optional)
          </label>
          <input
            id={`tool-cancel-reason-${callID}`}
            className="tool-cancel-reason-input"
            aria-label="Cancel reason"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="Why cancel this tool?"
            autoComplete="off"
          />
          <div className="tool-cancel-popover-actions">
            <button
              type="button"
              className="chat-tool-cancel-confirm"
              aria-label={`Confirm cancel tool ${toolName}`}
              onClick={submit}
            >
              Cancel tool
            </button>
            <button
              type="button"
              className="ghost tool-cancel-dismiss"
              aria-label="Dismiss cancel"
              onClick={dismiss}
            >
              Dismiss
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default function ToolActionRow({
  action,
  variant = "chat",
  isLive = false,
  progress = null,
  cancelling = false,
  onCancelTool,
  ownsFileReview = true,
  fileWriteDefaultExpanded = true,
  fileReviewStates,
}: ToolActionRowProps) {
  const [open, setOpen] = useState(false);
  const result = action.result;
  // Honest status: only live streaming actions may show as running; every
  // other result-less entry is pending, never running.
  const pendingWithoutResult = result == null && !isLive;
  // Browser navigate extras render only for successful navigate results with
  // a recognizable JSON shape; every other tool keeps the plain row.
  const browser =
    action.toolName === "browser.navigate" && result && !result.isError
      ? parseBrowserNavigate(result.content)
      : null;
  // One classification shared by both variants, rendered below with
  // surface-specific class prefixes.
  const status = result ? resolveResultStatus(result, action.toolName) : null;

  if (variant === "card") {
    return (
      <div className="tool-action-card">
        <button
          type="button"
          className="tool-action-header"
          onClick={() => setOpen(!open)}
        >
          <div className="tool-action-title">
            {open ? <ChevronDownIcon size={14} /> : <ChevronRightIcon size={14} />}
            <WrenchIcon size={14} className="tool-icon" />
            <span className="tool-name">{action.toolName}</span>
            <span className="tool-call-id" title={action.callID || ""}>
              {action.callID || ""}
            </span>
          </div>
          <div className="tool-action-badge">
            {status ? (
              <span className={`tool-badge tool-badge-${status.kind}`}>
                {status.label}
              </span>
            ) : isLive ? (
              <span className="tool-badge tool-badge-pending">Running</span>
            ) : (
              <span className="tool-badge tool-badge-pending">Pending</span>
            )}
            {browser?.authRequired ? (
              <span
                className="pending-approval-badge auth-required-badge"
                data-testid="auth-required-badge"
              >
                AUTH REQUIRED
              </span>
            ) : null}
          </div>
        </button>

        {open ? (
          <div className="tool-action-body">
            <div className="tool-section">
              <div className="tool-label">Call ID</div>
              <pre className="code-block font-mono">{action.callID || ""}</pre>
            </div>
            <div className="tool-section">
              <div className="tool-label">Arguments</div>
              <pre className="code-block">{action.argumentsJSON}</pre>
            </div>
            {browser ? <BrowserSummary browser={browser} /> : null}
            {browser ? <BrowserDetails browser={browser} /> : null}
            {action.toolName === "files.write" && result && !result.isError ? (
              <div className="tool-section">
                <DiffCard
                  action={action}
                  result={result}
                  ownsFileReview={ownsFileReview}
                  fileReviewStates={fileReviewStates}
                />
              </div>
            ) : result ? (
              <div className="tool-section">
                <div className="tool-label">Result</div>
                <pre
                  className={`code-block ${
                    shouldUseErrorTone(result, action.toolName)
                      ? "error-result"
                      : ""
                  }`}
                >
                  {result.content}
                </pre>
              </div>
            ) : pendingWithoutResult ? (
              <div className="tool-section">
                <div className="tool-label">Result</div>
                <pre className="code-block">Awaiting result — no output recorded yet.</pre>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
    );
  }

  return (
    <div className="chat-tool-pill">
      <div className="chat-tool-pill-header">
        <button
          type="button"
          className="chat-tool-toggle"
          onClick={() => setOpen(!open)}
        >
          {open ? <ChevronDownIcon size={12} /> : <ChevronRightIcon size={12} />}
          <WrenchIcon size={12} className="chat-tool-icon" />
          <span className="chat-tool-name">{action.toolName}</span>
          <span className="chat-tool-call-id" title={action.callID || ""}>
            {action.callID || ""}
          </span>
          {status ? (
            <span className={`chat-tool-status ${status.kind}`}>
              {status.label}
            </span>
          ) : isLive ? (
            <span className="chat-tool-status running">Running</span>
          ) : (
            <span className="chat-tool-status pending">Pending</span>
          )}
          {browser?.authRequired ? (
            <span
              className="pending-approval-badge auth-required-badge"
              data-testid="auth-required-badge"
            >
              AUTH REQUIRED
            </span>
          ) : null}
        </button>
        {/* Cancel is offered only for a genuinely executing call: a completed
            row has nothing to stop, and history surfaces pass no handler. */}
        {isLive && result == null && onCancelTool ? (
          <ToolCancelControl
            toolName={action.toolName}
            callID={action.callID}
            cancelling={cancelling}
            onCancelTool={onCancelTool}
          />
        ) : null}
      </div>

      {/* Progress renders whether collapsed or expanded so a long-running scan
          stays observable without forcing the row open. */}
      {isLive && result == null && progress ? (
        <ToolProgressLine progress={progress} />
      ) : null}

      {action.toolName === "files.write" && result && !result.isError ? (
        <div style={{ marginTop: 8 }}>
          <DiffCard
            action={action}
            result={result}
            ownsFileReview={ownsFileReview}
            defaultExpanded={fileWriteDefaultExpanded}
            fileReviewStates={fileReviewStates}
          />
        </div>
      ) : null}

      {open ? (
        <div className="chat-tool-details">
          <div className="chat-tool-detail-section">
            <span className="chat-tool-detail-label">Call ID:</span>
            <pre className="chat-tool-code font-mono">{action.callID || ""}</pre>
          </div>
          <div className="chat-tool-detail-section">
            <span className="chat-tool-detail-label">Arguments:</span>
            <pre className="chat-tool-code">{action.argumentsJSON}</pre>
          </div>
          {browser ? <BrowserSummary browser={browser} /> : null}
          {browser ? <BrowserDetails browser={browser} /> : null}
          {action.toolName !== "files.write" && result ? (
            <div className="chat-tool-detail-section">
              <span className="chat-tool-detail-label">Output:</span>
              <pre
                className={`chat-tool-code ${
                  shouldUseErrorTone(result, action.toolName)
                    ? "error-text"
                    : ""
                }`}
              >
                {result.content}
              </pre>
            </div>
          ) : result?.isError ? (
            <div className="chat-tool-detail-section">
              <span className="chat-tool-detail-label">Output:</span>
              <pre className="chat-tool-code error-text">
                {result.content}
              </pre>
            </div>
          ) : pendingWithoutResult ? (
            <div className="chat-tool-detail-section">
              <span className="chat-tool-detail-label">Output:</span>
              <pre className="chat-tool-code">Awaiting result — no output recorded yet.</pre>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
