// Rune Weaver Dashboard — Shared tool execution action row component.
// Renders interactive tool activity in both 'chat' (in-flight or completed turns)
// and 'card' (run log detail modal) variants with collapsible arguments and outputs.

import { useState, useEffect, useRef } from "react";
import type { ToolAction } from "../api";
import { ChevronDownIcon, ChevronRightIcon, WrenchIcon } from "./icons";

export interface ToolActionRowProps {
  action: ToolAction;
  variant?: "chat" | "card";
  // True only while the turn is still streaming: a result-less action is
  // genuinely executing then, while a completed turn with no result is
  // awaiting a decision or was interrupted and must never claim to run.
  isLive?: boolean;
}

interface BrowserRedirect {
  url: string;
  status?: number | null;
}

export interface BrowserNavigate {
  finalUrl?: string | null;
  // Unified envelope mirrors the engine shape ({url,title,text,refs,
  // truncated,authRequired,downloads,note}) plus the shared wire aliases
  // ({finalUrl/finalURL/final_url, textSnapshot/snapshot, redirectChain/
  // redirect_chain/redirects}) single-sourced with `BrowserNavigateWire`, so
  // engine and dashboard agree on every key.
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
// (BrowserNavigateWire.normalizedDataURL): only data:image/jpeg|png|webp|gif
// mounts, plus raw helper bytes starting with /9j/ or iVBOR. Bare base64 of
// any length never mounts, so engine and dashboard agree on what counts as
// an image.
function asImageDataURL(value: unknown): string | null {
  const raw = asNonEmptyString(value);
  if (!raw) return null;
  const trimmed = raw.trim();
  if (trimmed.startsWith("data:image/")) {
    // Only raster thumbnails reach the lightbox; anything else stays a hash
    // so an unexpected data URL never becomes executable markup.
    // Single-sourced through `isSafeThumbnailDataURL` so the allowlist
    // cannot drift between parsing and rendering.
    return isSafeThumbnailDataURL(trimmed) ? trimmed : null;
  }
  if (trimmed.startsWith("/9j/") || trimmed.startsWith("iVBOR")) {
    return `data:image/jpeg;base64,${trimmed}`;
  }
  return null;
}

// Tolerant reader for browser.navigate JSON results. Accepts the single unified schema single-sourced
// with the engine wire (`BrowserNavigateWire` + `BrowserNavigateEnvelope`): engine keys
// ({url,title,text,refs,truncated,authRequired,downloads,note}) plus the shared wire aliases
// ({finalUrl/finalURL/final_url, textSnapshot/text_snapshot/snapshot, redirectChain/redirect_chain/
// redirects, redirect_count, auth_required/requiresAuth, screenshot_hash/imageHash,
// screenshotDataURL/thumbnailDataURL/imageDataURL/screenshot/thumbnail}). No other aliases resolve,
// so engine and dashboard agree on every field.
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
  // finalUrl hid real output. Only the engine text keys resolve
  // (textSnapshot/text_snapshot/snapshot/text).
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

export default function ToolActionRow({
  action,
  variant = "chat",
  isLive = false,
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
            {result ? (
              result.isError ? (
                <span className="tool-badge-error">Error</span>
              ) : (
                <span className="tool-badge-ok">Done</span>
              )
            ) : isLive ? (
              <span className="tool-badge-pending">Running</span>
            ) : (
              <span className="tool-badge-pending">Pending</span>
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
            {result ? (
              <div className="tool-section">
                <div className="tool-label">Result</div>
                <pre
                  className={`code-block ${
                    result.isError ? "error-result" : ""
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
        {result ? (
          <span
            className={`chat-tool-status ${
              result.isError ? "error" : "ok"
            }`}
          >
            {result.isError ? "Error" : "Done"}
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
          {result ? (
            <div className="chat-tool-detail-section">
              <span className="chat-tool-detail-label">Output:</span>
              <pre
                className={`chat-tool-code ${
                  result.isError ? "error-text" : ""
                }`}
              >
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
