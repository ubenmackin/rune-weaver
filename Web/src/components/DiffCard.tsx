// Rune Weaver Dashboard — In-chat DiffCard for files.write tool actions.
// Allows users to review changes inline and immediately Accept or Discard them,
// with live WebSocket sync to the Staged Changes drawer.

import { useState, useMemo } from "react";
import { acceptStagedFile, discardStagedFile, type ToolAction, type ToolResult } from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import UnifiedDiffView from "./UnifiedDiffView";
import { CheckIcon, CloseIcon } from "./icons";

// Client-side bound for inline staged mutations: HTTP 200 is the accepted /
// discarded truth, so a hung engine walk must surface a retryable timeout
// instead of leaving the card in a perpetual loading state. WebSocket
// file_accepted / file_discarded frames stay passive reconcilers only.
export const DIFF_CARD_ACTION_TIMEOUT_MS = 10_000;

// Timeout copy doubles as the error text so the banner reads identically
// whether the race timer or the abort rejection wins the settle.
export const DIFF_CARD_ACCEPT_TIMEOUT_MESSAGE =
  "Accept timed out after 10s. The file was not changed. Retry.";
export const DIFF_CARD_DISCARD_TIMEOUT_MESSAGE =
  "Discard timed out after 10s. The file was not changed. Retry.";

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
}

export default function DiffCard({ action: _action, result }: DiffCardProps) {
  const [actionState, setActionState] = useState<"accepted" | "discarded" | null>(null);
  const [loading, setLoading] = useState(false);
  const [pendingAction, setPendingAction] = useState<"accept" | "discard" | null>(null);
  const [failedAction, setFailedAction] = useState<"accept" | "discard" | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const payload = useMemo<FilesWritePayload | null>(() => {
    if (!result.content) return null;
    try {
      const parsed = JSON.parse(result.content);
      if (parsed && typeof parsed.path === "string" && typeof parsed.diff === "string") {
        return parsed as FilesWritePayload;
      }
    } catch {
      // Non-JSON or standard text output
    }
    return null;
  }, [result.content]);

  // Synchronize with external actions via WebSocket
  useSharedWebSocket((frame) => {
    if (!payload) return;
    if (frame.type === "file_accepted") {
      const acceptedPath = (frame as { path?: string }).path;
      // Exact match only: a suffix comparison would resolve an unrelated card
      // whose path merely shares trailing segments with the accepted file.
      if (acceptedPath && acceptedPath === payload.path) {
        setActionState("accepted");
      }
    } else if (frame.type === "file_discarded") {
      const discardedPath = (frame as { path?: string }).path;
      // Exact match only: same trailing-segment collision as above.
      if (discardedPath && discardedPath === payload.path) {
        setActionState("discarded");
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
      // HTTP 200 is the accepted truth: flip the badge immediately without
      // waiting for the detached file_accepted broadcast.
      await Promise.race([
        acceptStagedFile(targetPath, undefined, controller.signal),
        timeoutPromise,
      ]);
      setActionState("accepted");
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
      // HTTP 200 is the discarded truth: flip the badge immediately without
      // waiting for the detached file_discarded broadcast.
      await Promise.race([
        discardStagedFile(targetPath, undefined, controller.signal),
        timeoutPromise,
      ]);
      setActionState("discarded");
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

  if (!payload) {
    return null;
  }

  const filename = payload.path.split("/").pop() || payload.path;
  const handleRetry = failedAction === "discard" ? handleDiscard : handleAccept;

  return (
    <div className="diff-card-root">
      <div className="diff-card-header">
        <div className="diff-card-meta">
          <span className="diff-card-filename font-semibold">{filename}</span>
          <span className="diff-card-path text-xs text-neutral-400 font-mono" title={payload.path}>
            {payload.path}
          </span>
          <div className="diff-card-stats text-xs font-mono">
            <span className="diff-stat-addition">+{payload.additions}</span>
            <span className="diff-stat-deletion">-{payload.deletions}</span>
          </div>
          {payload.status === "staged" ? (
            <span className="diff-status-pill staged">Staged (Review Required)</span>
          ) : (
            <span className="diff-status-pill live">Live Edit</span>
          )}
        </div>

        {payload.status === "staged" && (
          <div className="diff-card-actions">
            {actionState === "accepted" ? (
              <span className="diff-resolved-badge accepted">
                <CheckIcon className="w-3.5 h-3.5 inline mr-1" />
                Accepted
              </span>
            ) : actionState === "discarded" ? (
              <span className="diff-resolved-badge discarded">
                <CloseIcon size={14} className="inline mr-1" />
                Discarded
              </span>
            ) : (
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
            )}
          </div>
        )}
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

      <div className="diff-card-body">
        <UnifiedDiffView diff={payload.diff} maxCollapsedLines={25} />
      </div>
    </div>
  );
}
