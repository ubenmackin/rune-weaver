// Rune Weaver Dashboard — Collapsible right-hand drawer for staged changes review.
// Shows all un-actioned staged files (.rune_*), one collapsible card per file
// with its full unified diff, and provides per-file Accept/Discard controls as
// well as batch [Accept All] and [Discard All]. Cards start collapsed so a long
// review queue scans by filename first; expansion is keyed by path so live
// refetches never reopen the wrong file.

import { useState, useEffect, useCallback } from "react";
import {
  getStagedFiles,
  acceptStagedFile,
  discardStagedFile,
  type StagedFile,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import UnifiedDiffView from "./UnifiedDiffView";
import {
  CloseIcon,
  CheckIcon,
  TrashIcon,
  FileDiffIcon,
  ChevronDownIcon,
  ChevronRightIcon,
} from "./icons";

interface StagedChangesDrawerProps {
  isOpen: boolean;
  onClose: () => void;
  onCountChange?: (count: number) => void;
}

export default function StagedChangesDrawer({
  isOpen,
  onClose,
  onCountChange,
}: StagedChangesDrawerProps) {
  const [stagedFiles, setStagedFiles] = useState<StagedFile[]>([]);
  // Expansion is keyed by path rather than index so a live refetch that
  // reorders or removes files never reopens the wrong card.
  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(false);
  const [batchLoading, setBatchLoading] = useState(false);
  const [itemLoading, setItemLoading] = useState<Record<string, boolean>>({});
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const fetchFiles = useCallback(async () => {
    try {
      setLoading(true);
      setErrorMsg(null);
      const res = await getStagedFiles();
      const files = res.files || [];
      setStagedFiles(files);
      onCountChange?.(files.length);
      // Drop expansion keys for files that are no longer staged so a path
      // re-staged later starts collapsed instead of inheriting stale state.
      setExpandedPaths((prev) =>
        new Set([...prev].filter((p) => files.some((f) => f.path === p))),
      );
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed loading staged files");
    } finally {
      setLoading(false);
    }
  }, [onCountChange]);

  useEffect(() => {
    fetchFiles();
  }, [isOpen, fetchFiles]);

  // Keep staged files list synced in real-time
  useSharedWebSocket((frame) => {
    if (
      frame.type === "file_accepted" ||
      frame.type === "file_discarded" ||
      frame.type === "tool_end"
    ) {
      fetchFiles();
    }
  });

  const handleAcceptSingle = async (path: string) => {
    setItemLoading((prev) => ({ ...prev, [path]: true }));
    setErrorMsg(null);
    try {
      await acceptStagedFile(path);
      await fetchFiles();
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed to accept file");
    } finally {
      setItemLoading((prev) => ({ ...prev, [path]: false }));
    }
  };

  const handleDiscardSingle = async (path: string) => {
    setItemLoading((prev) => ({ ...prev, [path]: true }));
    setErrorMsg(null);
    try {
      await discardStagedFile(path);
      await fetchFiles();
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed to discard file");
    } finally {
      setItemLoading((prev) => ({ ...prev, [path]: false }));
    }
  };

  const handleAcceptAll = async () => {
    if (stagedFiles.length === 0 || batchLoading) return;
    setBatchLoading(true);
    setErrorMsg(null);
    try {
      await acceptStagedFile(undefined, true);
      await fetchFiles();
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed to accept all staged files");
    } finally {
      setBatchLoading(false);
    }
  };

  const handleDiscardAll = async () => {
    if (stagedFiles.length === 0 || batchLoading) return;
    setBatchLoading(true);
    setErrorMsg(null);
    try {
      await discardStagedFile(undefined, true);
      await fetchFiles();
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "Failed to discard all staged files");
    } finally {
      setBatchLoading(false);
    }
  };

  // One derived flag drives the batch toggle's label and direction: expanding
  // every path only when the set is not already complete, so a partially
  // expanded queue always converges to fully expanded on the first click.
  const allExpanded =
    stagedFiles.length > 0 && stagedFiles.every((f) => expandedPaths.has(f.path));

  const handleToggleAll = () => {
    setExpandedPaths(allExpanded ? new Set<string>() : new Set(stagedFiles.map((f) => f.path)));
  };

  const toggleExpanded = (path: string) => {
    setExpandedPaths((prev) => {
      const next = new Set(prev);
      if (next.has(path)) {
        next.delete(path);
      } else {
        next.add(path);
      }
      return next;
    });
  };

  if (!isOpen) return null;

  return (
    <aside className="staged-drawer-backdrop" onClick={onClose}>
      <div className="staged-drawer-container" onClick={(e) => e.stopPropagation()}>
        {/* Drawer Header */}
        <div className="staged-drawer-header">
          <div className="staged-drawer-title-group">
            <FileDiffIcon size={18} className="text-purple-400" />
            <h2 className="staged-drawer-title">Staged Changes</h2>
            <span className="staged-drawer-count-badge">
              {stagedFiles.length} {stagedFiles.length === 1 ? "file" : "files"}
            </span>
          </div>

          <div className="staged-drawer-header-actions">
            {stagedFiles.length > 0 && (
              <>
                <button
                  type="button"
                  className="ghost staged-expand-all-btn"
                  onClick={handleToggleAll}
                >
                  {allExpanded ? "Collapse all" : "Expand all"}
                </button>
                <button
                  type="button"
                  className="staged-batch-btn accept"
                  onClick={handleAcceptAll}
                  disabled={batchLoading}
                >
                  <CheckIcon size={14} className="inline mr-1" />
                  Accept All
                </button>
                <button
                  type="button"
                  className="staged-batch-btn discard"
                  onClick={handleDiscardAll}
                  disabled={batchLoading}
                >
                  <TrashIcon size={14} className="inline mr-1" />
                  Discard All
                </button>
              </>
            )}
            <button
              type="button"
              className="staged-drawer-close-btn"
              onClick={onClose}
              title="Close drawer"
            >
              <CloseIcon size={18} />
            </button>
          </div>
        </div>

        {errorMsg && <div className="staged-drawer-error">{errorMsg}</div>}

        {/* Drawer Content */}
        {loading && stagedFiles.length === 0 ? (
          <div className="staged-drawer-empty">Loading staged files…</div>
        ) : stagedFiles.length === 0 ? (
          <div className="staged-drawer-empty">
            <FileDiffIcon size={32} className="text-neutral-500 mb-2 opacity-50" />
            <p className="font-semibold text-neutral-300">No staged changes</p>
            <p className="text-xs text-neutral-500 mt-1">
              Edits made by the agent with <code>files.write</code> will appear here for review.
            </p>
          </div>
        ) : (
          <div className="staged-drawer-body">
            {stagedFiles.map((file) => {
              const filename = file.path.split("/").pop() || file.path;
              const isExpanded = expandedPaths.has(file.path);
              const isItemBusy = itemLoading[file.path] || batchLoading;

              return (
                <div key={file.path} className="staged-change-card">
                  <div className="staged-change-card-header">
                    <button
                      type="button"
                      className="staged-change-toggle"
                      aria-expanded={isExpanded}
                      aria-label={`${isExpanded ? "Collapse" : "Expand"} diff for ${filename}`}
                      onClick={() => toggleExpanded(file.path)}
                    >
                      {isExpanded ? <ChevronDownIcon size={14} /> : <ChevronRightIcon size={14} />}
                    </button>

                    <span className="staged-file-name" title={file.path}>
                      {filename}
                    </span>

                    <span className="staged-change-path" title={file.path}>
                      {file.path}
                    </span>

                    <div className="staged-file-stats">
                      <span className="stat-add">+{file.additions}</span>
                      <span className="stat-del">-{file.deletions}</span>
                    </div>

                    <div className="staged-change-actions">
                      <button
                        type="button"
                        className="staged-item-btn accept"
                        onClick={() => handleAcceptSingle(file.path)}
                        disabled={isItemBusy}
                      >
                        Accept
                      </button>
                      <button
                        type="button"
                        className="staged-item-btn discard"
                        onClick={() => handleDiscardSingle(file.path)}
                        disabled={isItemBusy}
                      >
                        Discard
                      </button>
                    </div>
                  </div>

                  {isExpanded && (
                    <div className="staged-change-card-body">
                      <UnifiedDiffView diff={file.diff} maxCollapsedLines={1000} />
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </aside>
  );
}
