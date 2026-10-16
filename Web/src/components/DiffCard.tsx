// Rune Weaver Dashboard — In-chat DiffCard for files.write tool actions.

import { useEffect, useMemo, useState } from "react";
import {
  acceptLiveReview,
  acceptStagedFile,
  declineLiveReview,
  discardStagedFile,
  getFileReviewStates,
  type FileReviewState,
  type FileReviewStates,
  type ToolAction,
  type ToolResult,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { ChevronDownIcon, ChevronRightIcon } from "./icons";
import UnifiedDiffView from "./UnifiedDiffView";

// Client-side bound for inline review mutations: HTTP 200 is the accepted / discarded / reverted
// truth, so a hung engine walk must surface a retryable timeout instead of leaving the card in a
// perpetual loading state.
export const DIFF_CARD_ACTION_TIMEOUT_MS = 10_000;

// Timeout copy doubles as the error text so the banner reads identically
// whether the race timer or the abort rejection wins the settle.
export const DIFF_CARD_ACCEPT_TIMEOUT_MESSAGE =
  "Accept timed out after 10s. The file was not changed. Retry.";
export const DIFF_CARD_DISCARD_TIMEOUT_MESSAGE =
  "Discard timed out after 10s. The file was not changed. Retry.";
export const DIFF_CARD_LIVE_ACCEPT_TIMEOUT_MESSAGE =
  "Live accept timed out after 10s. The review was not resolved. Retry.";
export const DIFF_CARD_LIVE_DECLINE_TIMEOUT_MESSAGE =
  "Live decline timed out after 10s. The file was not changed. Retry.";

// Muted copy shown in place of review controls when a newer write for the same
// file and envelope kind owns the ledger row.
export const DIFF_CARD_OWNED_BY_NEWER_NOTE =
  "A newer write owns this file's review.";

interface FilesWritePayload {
  status: "staged" | "live";
  path: string;
  stagingPath?: string;
  backupPath?: string;
  diff: string;
  additions: number;
  deletions: number;
  message: string;
}

interface DiffCardProps {
  action?: ToolAction;
  result: ToolResult;
  // False when a newer files.write card for the same live path and envelope
  // kind owns this file's review; a pending card then shows a note instead of
  // review controls. Defaults true so single-card surfaces stay actionable.
  ownsFileReview?: boolean;
  // Whether the diff body starts expanded. Chat threads the chat-settings
  // default here; run details pass nothing so their diffs stay expanded.
  defaultExpanded?: boolean;
  // Batched ledger posture hydrated by the rendered surface in one request per card-set change.
  fileReviewStates?: FileReviewStates | null;
}

// Parses a files.write result envelope. Errored results, non-JSON output, and
// shapes without a reviewable path/diff pair yield null so the card body and
// the list-level ownership scan agree on what counts as a reviewable write.
function parseFilesWritePayload(
  result: ToolResult | null | undefined,
): FilesWritePayload | null {
  if (!result || result.isError || !result.content) return null;
  try {
    const parsed = JSON.parse(result.content);
    if (
      parsed &&
      typeof parsed.path === "string" &&
      typeof parsed.diff === "string"
    ) {
      return parsed as FilesWritePayload;
    }
  } catch {
    // Non-JSON or standard text output
  }
  return null;
}

// Narrows a parsed envelope status to the two ledger-tracked kinds so the
// card's hydration paths and the exported review-target helpers share one
// classification instead of re-deriving the staged/live gate.
function envelopeKind(
  status: FilesWritePayload["status"],
): "staged" | "live" | null {
  return status === "staged" ? "staged" : status === "live" ? "live" : null;
}

// Classifies a reviewable envelope once: the card body, its ledger hydration,
// and the list-level ownership scan all agree on the same staged/live gate.
// Dry-run "preview" envelopes and malformed output have no ledger row.
function parseWriteReviewTarget(
  result: ToolResult | null | undefined,
): { kind: "staged" | "live"; path: string } | null {
  const payload = parseFilesWritePayload(result);
  if (!payload) return null;
  const kind = envelopeKind(payload.status);
  if (!kind) return null;
  return { kind, path: payload.path };
}

// Envelope kind plus live path for the review ledger, or null when the result has no reviewable
// envelope.
export function writeReviewTarget(
  result: ToolResult | null | undefined,
): { kind: "staged" | "live"; path: string } | null {
  return parseWriteReviewTarget(result);
}

// Ownership key for the newest-card rule: two cards share one review exactly when their live path
// and envelope kind match.
export function writeReviewKey(
  result: ToolResult | null | undefined,
): string | null {
  const target = parseWriteReviewTarget(result);
  return target ? `${target.kind}\u0000${target.path}` : null;
}

// Maps the envelope kind plus hydrated resolution to the single status pill.
function reviewStatusPill(
  status: FilesWritePayload["status"],
  resolution: FileReviewState | null,
): { label: string; tone: string } {
  switch (resolution) {
    case "accepted":
      return { label: "Accepted", tone: "accepted" };
    case "discarded":
      return { label: "Discarded", tone: "discarded" };
    case "superseded":
      return { label: "Superseded", tone: "superseded" };
    case "reverted":
      return { label: "Reverted", tone: "reverted" };
    case "unknown":
      return status === "staged"
        ? { label: "No longer staged", tone: "neutral" }
        : { label: "No longer pending", tone: "neutral" };
    default:
      return status === "staged"
        ? { label: "Staged (Review Required)", tone: "staged" }
        : { label: "Live Edit", tone: "live" };
  }
}

export default function DiffCard({
  action: _action,
  result,
  ownsFileReview = true,
  defaultExpanded = true,
  fileReviewStates,
}: DiffCardProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  const [resolution, setResolution] = useState<FileReviewState | null>(null);
  const [loading, setLoading] = useState(false);
  // The action union spans both review kinds: live decline splits into the
  // revert and discard labels the envelope's rollback posture proves, while
  // staged cards only ever use accept/discard.
  const [pendingAction, setPendingAction] = useState<
    "accept" | "revert" | "discard" | null
  >(null);
  const [failedAction, setFailedAction] = useState<
    "accept" | "revert" | "discard" | null
  >(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  // Mirror a default change onto already-mounted cards so flipping the chat
  // setting updates existing write cards, not just newly mounted ones.
  useEffect(() => {
    setExpanded(defaultExpanded);
  }, [defaultExpanded]);

  const payload = useMemo(() => parseFilesWritePayload(result), [result.content]);

  // Hydrate the stored outcome once per card so a reload shows Accepted, Discarded, or another
  // terminal state instead of a fresh actionable card.
  useEffect(() => {
    if (!payload) return;
    if (fileReviewStates !== undefined) return;
    const kind = envelopeKind(payload.status);
    if (!kind) return;
    const controller = new AbortController();
    let cancelled = false;
    getFileReviewStates([payload.path], controller.signal)
      .then(({ stagedStates, liveStates }) => {
        if (cancelled) return;
        const mapped: FileReviewState | undefined =
          (kind === "staged" ? stagedStates : liveStates)[payload.path];
        if (mapped === undefined) return;
        // First write wins: a click or WebSocket frame that already settled
        // the card must never be downgraded by a late hydration response.
        setResolution((prev) => (prev === null ? mapped : prev));
      })
      .catch(() => {
        // No banner, no state change: the actionable card survives the error.
      });
    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [payload, fileReviewStates]);

  // Adopt the surface's batched posture for this card's own ledger row.
  useEffect(() => {
    if (!payload || !fileReviewStates) return;
    const kind = envelopeKind(payload.status);
    if (!kind) return;
    const mapped: FileReviewState | undefined = (
      kind === "staged"
        ? fileReviewStates.stagedStates
        : fileReviewStates.liveStates
    )[payload.path];
    if (mapped === undefined) return;
    setResolution((prev) => (prev === null ? mapped : prev));
  }, [fileReviewStates, payload]);

  // Synchronize with external actions via WebSocket.
  useSharedWebSocket((frame) => {
    if (!payload) return;
    if (frame.type === "file_accepted" && payload.status === "staged") {
      const acceptedPath = frame.path;
      // Exact match only: a suffix comparison would resolve an unrelated card
      // whose path merely shares trailing segments with the accepted file.
      if (acceptedPath && acceptedPath === payload.path) {
        setResolution("accepted");
      }
    } else if (frame.type === "file_discarded" && payload.status === "staged") {
      const discardedPath = frame.path;
      // Exact match only: same trailing-segment collision as above.
      if (discardedPath && discardedPath === payload.path) {
        setResolution("discarded");
      }
    } else if (frame.type === "file_superseded") {
      // A superseding live write resolves the staged ledger row inside the write tool rather than a
      // route, so the mounted staged card must settle to the terminal pill without a reload; a live
      // card for the same path tracks a different review and keeps its own posture.
      if (payload.status !== "staged") return;
      const supersededPath = frame.path;
      const supersededState = frame.state;
      // Exact path match plus the closed terminal state, so a drifted frame
      // can never pin an unrelated card or a resolution the pill cannot
      // render.
      if (
        supersededPath &&
        supersededPath === payload.path &&
        supersededState === "superseded"
      ) {
        setResolution("superseded");
      }
    } else if (frame.type === "live_resolved" && payload.status === "live") {
      const resolvedPath = frame.path;
      const resolvedState = frame.state;
      // Only live cards consume the live-ledger terminal event: a staged card for the same path
      // tracks a different review, so adopting a live outcome would contradict what its own ledger
      // row reads on reload.
      if (
        resolvedPath &&
        resolvedPath === payload.path &&
        (resolvedState === "accepted" ||
          resolvedState === "reverted" ||
          resolvedState === "discarded")
      ) {
        setResolution(resolvedState);
      }
    }
  });

  const handleAccept = async () => {
    if (!payload || loading) return;
    const targetPath = payload.path;
    const controller = new AbortController();
    setLoading(true);
    setPendingAction("accept");
    setFailedAction(null);
    setErrorMsg(null);
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<never>((_, reject) => {
      timeoutId = setTimeout(() => {
        controller.abort();
        reject(new Error(DIFF_CARD_ACCEPT_TIMEOUT_MESSAGE));
      }, DIFF_CARD_ACTION_TIMEOUT_MS);
    });
    try {
      // HTTP 200 is the accepted truth: flip the pill immediately without
      // waiting for the detached file_accepted broadcast.
      await Promise.race([
        acceptStagedFile(targetPath, undefined, controller.signal),
        timeoutPromise,
      ]);
      setResolution("accepted");
    } catch (err) {
      if (controller.signal.aborted) {
        setErrorMsg(DIFF_CARD_ACCEPT_TIMEOUT_MESSAGE);
      } else {
        setErrorMsg(err instanceof Error ? err.message : "Failed to accept file");
      }
      setFailedAction("accept");
    } finally {
      if (timeoutId !== undefined) clearTimeout(timeoutId);
      setLoading(false);
      setPendingAction(null);
    }
  };

  const handleDiscard = async () => {
    if (!payload || loading) return;
    const targetPath = payload.path;
    const controller = new AbortController();
    setLoading(true);
    setPendingAction("discard");
    setFailedAction(null);
    setErrorMsg(null);
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<never>((_, reject) => {
      timeoutId = setTimeout(() => {
        controller.abort();
        reject(new Error(DIFF_CARD_DISCARD_TIMEOUT_MESSAGE));
      }, DIFF_CARD_ACTION_TIMEOUT_MS);
    });
    try {
      // HTTP 200 is the discarded truth: flip the pill immediately without
      // waiting for the detached file_discarded broadcast.
      await Promise.race([
        discardStagedFile(targetPath, undefined, controller.signal),
        timeoutPromise,
      ]);
      setResolution("discarded");
    } catch (err) {
      if (controller.signal.aborted) {
        setErrorMsg(DIFF_CARD_DISCARD_TIMEOUT_MESSAGE);
      } else {
        setErrorMsg(err instanceof Error ? err.message : "Failed to discard file");
      }
      setFailedAction("discard");
    } finally {
      if (timeoutId !== undefined) clearTimeout(timeoutId);
      setLoading(false);
      setPendingAction(null);
    }
  };

  const handleLiveAccept = async () => {
    if (!payload || loading) return;
    const targetPath = payload.path;
    const controller = new AbortController();
    setLoading(true);
    setPendingAction("accept");
    setFailedAction(null);
    setErrorMsg(null);
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<never>((_, reject) => {
      timeoutId = setTimeout(() => {
        controller.abort();
        reject(new Error(DIFF_CARD_LIVE_ACCEPT_TIMEOUT_MESSAGE));
      }, DIFF_CARD_ACTION_TIMEOUT_MS);
    });
    try {
      // HTTP 200 is the accepted truth: flip the pill immediately without
      // waiting for the detached live_resolved broadcast.
      await Promise.race([
        acceptLiveReview(targetPath, controller.signal),
        timeoutPromise,
      ]);
      setResolution("accepted");
    } catch (err) {
      if (controller.signal.aborted) {
        setErrorMsg(DIFF_CARD_LIVE_ACCEPT_TIMEOUT_MESSAGE);
      } else {
        setErrorMsg(
          err instanceof Error ? err.message : "Failed to accept live review",
        );
      }
      setFailedAction("accept");
    } finally {
      if (timeoutId !== undefined) clearTimeout(timeoutId);
      setLoading(false);
      setPendingAction(null);
    }
  };

  const handleLiveDecline = async () => {
    if (!payload || loading) return;
    const targetPath = payload.path;
    // The envelope's rollback posture names the outcome this decline produces: an existing-file
    // review restores its copy, a new-file review deletes the created file.
    const hasRollbackCopy = Boolean(payload.backupPath);
    const declineAction = hasRollbackCopy ? "revert" : "discard";
    const controller = new AbortController();
    setLoading(true);
    setPendingAction(declineAction);
    setFailedAction(null);
    setErrorMsg(null);
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<never>((_, reject) => {
      timeoutId = setTimeout(() => {
        controller.abort();
        reject(new Error(DIFF_CARD_LIVE_DECLINE_TIMEOUT_MESSAGE));
      }, DIFF_CARD_ACTION_TIMEOUT_MS);
    });
    try {
      // HTTP 200 is the mutation truth: flip the pill immediately without
      // waiting for the detached live_resolved broadcast.
      await Promise.race([
        declineLiveReview(targetPath, controller.signal),
        timeoutPromise,
      ]);
      setResolution(hasRollbackCopy ? "reverted" : "discarded");
    } catch (err) {
      if (controller.signal.aborted) {
        setErrorMsg(DIFF_CARD_LIVE_DECLINE_TIMEOUT_MESSAGE);
      } else {
        setErrorMsg(
          err instanceof Error ? err.message : "Failed to decline live review",
        );
      }
      setFailedAction(declineAction);
    } finally {
      if (timeoutId !== undefined) clearTimeout(timeoutId);
      setLoading(false);
      setPendingAction(null);
    }
  };

  if (!payload) {
    return null;
  }

  const filename = payload.path.split("/").pop() || payload.path;
  // Retry re-runs the handler that failed so a live decline never retries as
  // an accept and each card kind keeps its own API route.
  const handleRetry =
    failedAction === "accept"
      ? payload.status === "live"
        ? handleLiveAccept
        : handleAccept
      : payload.status === "live"
        ? handleLiveDecline
        : handleDiscard;
  // Pending covers both "not yet hydrated" (null) and a ledger row with no
  // resolution yet: both keep the review open, so the pill and the ownership
  // rules treat them identically.
  const reviewPending = resolution === null || resolution === "pending";
  const pill = reviewStatusPill(payload.status, resolution);

  return (
    <div className="diff-card-root">
      <div className="diff-card-header">
        <button
          type="button"
          className="diff-card-collapse-toggle"
          aria-expanded={expanded}
          aria-label={expanded ? "Collapse file diff" : "Expand file diff"}
          onClick={() => setExpanded((current) => !current)}
        >
          {expanded ? <ChevronDownIcon size={14} /> : <ChevronRightIcon size={14} />}
        </button>
        <div className="diff-card-meta">
          <span className="diff-card-filename font-semibold">{filename}</span>
          <span className="diff-card-path text-xs text-neutral-400 font-mono" title={payload.path}>
            {payload.path}
          </span>
          <div className="diff-card-stats text-xs font-mono">
            <span className="diff-stat-addition">+{payload.additions}</span>
            <span className="diff-stat-deletion">-{payload.deletions}</span>
          </div>
          <span className={`diff-status-pill ${pill.tone}`}>{pill.label}</span>
        </div>

        {payload.status === "staged" && reviewPending && ownsFileReview ? (
          <div className="diff-card-actions">
            <div className="diff-btn-group">
              <button
                type="button"
                className="diff-action-btn accept"
                onClick={handleAccept}
                disabled={loading}
              >
                {pendingAction === "accept" && loading ? "Accepting…" : "Accept"}
              </button>
              <button
                type="button"
                className="diff-action-btn discard"
                onClick={handleDiscard}
                disabled={loading}
              >
                {pendingAction === "discard" && loading ? "Discarding…" : "Discard"}
              </button>
            </div>
          </div>
        ) : payload.status === "live" && reviewPending && ownsFileReview ? (
          // A live decline only reads as Revert when the envelope proves a rollback copy exists; a
          // new-file review has nothing to restore, so the same handler is labeled Discard instead.
          <div className="diff-card-actions">
            <div className="diff-btn-group">
              <button
                type="button"
                className="diff-action-btn accept"
                onClick={handleLiveAccept}
                disabled={loading}
              >
                {pendingAction === "accept" && loading ? "Accepting…" : "Accept"}
              </button>
              {payload.backupPath ? (
                <button
                  type="button"
                  className="diff-action-btn discard"
                  onClick={handleLiveDecline}
                  disabled={loading}
                >
                  {pendingAction === "revert" && loading ? "Reverting…" : "Revert"}
                </button>
              ) : (
                <button
                  type="button"
                  className="diff-action-btn discard"
                  onClick={handleLiveDecline}
                  disabled={loading}
                >
                  {pendingAction === "discard" && loading
                    ? "Discarding…"
                    : "Discard"}
                </button>
              )}
            </div>
          </div>
        ) : reviewPending && !ownsFileReview ? (
          <div className="diff-card-actions">
            <span className="diff-review-note">{DIFF_CARD_OWNED_BY_NEWER_NOTE}</span>
          </div>
        ) : null}
      </div>

      {errorMsg && (
        <div className="diff-error-banner text-xs text-red-400 px-3 py-1">
          <span>{errorMsg}</span>
          <button
            type="button"
            className="diff-error-retry"
            onClick={handleRetry}
            disabled={loading}
          >
            Retry
          </button>
        </div>
      )}

      {expanded ? (
        <div className="diff-card-body">
          <UnifiedDiffView diff={payload.diff} maxCollapsedLines={25} />
        </div>
      ) : null}
    </div>
  );
}
