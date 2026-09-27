// Rune Weaver Dashboard — Collapsible right-hand drawer for staged changes review.
// Shows all un-actioned staged files (.rune_*), full unified diffs, and provides
// per-file Accept/Discard controls as well as batch [Accept All] and [Discard All].

import { useState, useEffect, useCallback } from "react";
import {
  getStagedFiles,
  acceptStagedFile,
  discardStagedFile,
  type StagedFile,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import UnifiedDiffView from "./UnifiedDiffView";
import { CloseIcon, CheckIcon, TrashIcon, FileDiffIcon } from "./icons";

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
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
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
      if (files.length > 0) {
        setSelectedPath((prev) => {
          if (prev && files.some((f) => f.path === prev)) {
            return prev;
          }
          return files[0].path;
        });
      } else {
        setSelectedPath(null);
      }
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

  if (!isOpen) return null;

  const selectedFile = stagedFiles.find((f) => f.path === selectedPath) || stagedFiles[0];

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
          <div className="staged-drawer-layout">
            {/* File List Navigation */}
            <div className="staged-files-list">
              {stagedFiles.map((file) => {
                const filename = file.path.split("/").pop() || file.path;
                const isSelected = selectedFile?.path === file.path;
                const isItemBusy = itemLoading[file.path] || batchLoading;

                return (
                  <div
                    key={file.path}
                    className={`staged-file-item ${isSelected ? "selected" : ""}`}
                    onClick={() => setSelectedPath(file.path)}
                  >
                    <div className="staged-file-item-header">
                      <span className="staged-file-name" title={file.path}>
                        {filename}
                      </span>
                      <div className="staged-file-stats">
                        <span className="stat-add">+{file.additions}</span>
                        <span className="stat-del">-{file.deletions}</span>
                      </div>
                    </div>

                    <span className="staged-file-dir text-xs text-neutral-500 truncate" title={file.path}>
                      {file.path}
                    </span>

                    <div className="staged-file-item-actions" onClick={(e) => e.stopPropagation()}>
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
                );
              })}
            </div>

            {/* Diff Viewer for Selected File */}
            <div className="staged-diff-viewer">
              {selectedFile ? (
                <div className="staged-selected-file-pane">
                  <div className="staged-selected-header">
                    <div>
                      <h3 className="staged-selected-title">
                        {selectedFile.path.split("/").pop()}
                      </h3>
                      <p className="staged-selected-path">{selectedFile.path}</p>
                    </div>
                    <div className="staged-selected-stats">
                      <span className="stat-badge add">+{selectedFile.additions}</span>
                      <span className="stat-badge del">-{selectedFile.deletions}</span>
                    </div>
                  </div>

                  <div className="staged-diff-scroll">
                    <UnifiedDiffView diff={selectedFile.diff} maxCollapsedLines={1000} />
                  </div>
                </div>
              ) : null}
            </div>
          </div>
        )}
      </div>
    </aside>
  );
}
