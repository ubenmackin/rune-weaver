// Rune Weaver Dashboard — In-chat DiffCard for files.write tool actions.
// Allows users to review changes inline and immediately Accept or Discard them,
// with live WebSocket sync to the Staged Changes drawer.

import { useState, useMemo } from "react";
import { acceptStagedFile, discardStagedFile, type ToolAction, type ToolResult } from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import UnifiedDiffView from "./UnifiedDiffView";
import { CheckIcon, CloseIcon } from "./icons";

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
    setLoading(true);
    setErrorMsg(null);
    try {
      await acceptStagedFile(payload.path);
      setActionState("accepted");
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed to accept file");
    } finally {
      setLoading(false);
    }
  };

  const handleDiscard = async () => {
    if (!payload || loading) return;
    setLoading(true);
    setErrorMsg(null);
    try {
      await discardStagedFile(payload.path);
      setActionState("discarded");
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed to discard file");
    } finally {
      setLoading(false);
    }
  };

  if (!payload) {
    return null;
  }

  const filename = payload.path.split("/").pop() || payload.path;

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
                  {loading ? "Accepting…" : "Accept"}
                </button>
                <button
                  type="button"
                  className="diff-action-btn discard"
                  onClick={handleDiscard}
                  disabled={loading}
                >
                  {loading ? "Discarding…" : "Discard"}
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      {errorMsg && <div className="diff-error-banner text-xs text-red-400 px-3 py-1">{errorMsg}</div>}

      <div className="diff-card-body">
        <UnifiedDiffView diff={payload.diff} maxCollapsedLines={25} />
      </div>
    </div>
  );
}
