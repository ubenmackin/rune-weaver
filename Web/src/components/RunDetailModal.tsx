// Rune Weaver Dashboard — Detailed modal viewer for inspectable run logs.
// Shows prompt, executed tool actions, full assistant response, and performance metrics.

import type { RunLogEntry } from "../api";
import { CloseIcon } from "./icons";
import MarkdownText from "./MarkdownText";
import ToolActionRow from "./ToolActionRow";

interface RunDetailModalProps {
  run: RunLogEntry | null;
  onClose: () => void;
}

export default function RunDetailModal({ run, onClose }: RunDetailModalProps) {
  if (!run) return null;

  const isOk = run.status === "ok";
  const isSkipped = run.status === "skipped";

  return (
    <div className="modal-backdrop" onClick={onClose} role="dialog" aria-label="Run details" aria-modal="true">
      <div className="modal-container run-detail-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <div className="run-header-title">
            <span className={`status-pill ${run.status}`}>
              {run.status === "running" ? "IN PROGRESS" : run.status.toUpperCase()}
            </span>
            <h3>
              {run.kind === "scheduler" ? "Scheduled Run" : "Chat Turn"} Details
            </h3>
          </div>
          <button
            type="button"
            className="icon-button"
            onClick={onClose}
            aria-label="Dismiss"
          >
            <CloseIcon size={18} />
          </button>
        </div>

        <div className="modal-body">
          {/* Metadata Row */}
          <div className="run-meta-grid">
            <div className="meta-card">
              <span className="meta-label">Triggered At</span>
              <span className="meta-value">
                {new Date(run.timestamp).toLocaleString()}
              </span>
            </div>
            {run.durationMs != null ? (
              <div className="meta-card">
                <span className="meta-label">Duration</span>
                <span className="meta-value">
                  {run.durationMs >= 1000
                    ? `${(run.durationMs / 1000).toFixed(2)}s`
                    : `${run.durationMs}ms`}
                </span>
              </div>
            ) : null}
            {run.totalTokens != null ? (
              <div className="meta-card">
                <span className="meta-label">Tokens</span>
                <span className="meta-value">
                  {run.totalTokens.toLocaleString()}
                </span>
              </div>
            ) : null}
            {run.jobID ? (
              <div className="meta-card">
                <span className="meta-label">Job ID</span>
                <span className="meta-value font-mono">
                  {run.jobID.slice(0, 8)}
                </span>
              </div>
            ) : null}
          </div>

          {/* Prompt / Input */}
          <div className="run-section">
            <h4>Prompt / Input</h4>
            <div className="prompt-display-box">{run.message}</div>
          </div>

          {/* Tool Actions */}
          {run.toolActions && run.toolActions.length > 0 ? (
            <div className="run-section">
              <h4>Tool Executions ({run.toolActions.length})</h4>
              <div className="tool-actions-list">
                {run.toolActions.map((action, idx) => (
                  <ToolActionRow key={action.callID || idx} action={action} variant="card" />
                ))}
              </div>
            </div>
          ) : null}

          {/* Agent Response */}
          <div className="run-section">
            <h4>Agent Response</h4>
            {run.response ? (
              <div className="agent-response-box">
                <MarkdownText text={run.response} />
              </div>
            ) : (
              <div className="empty-response-note">
                {isSkipped
                  ? "Execution was skipped (a run for this job was already active)."
                  : !isOk
                  ? "Execution terminated with error before generating an assistant response."
                  : "No textual response generated."}
              </div>
            )}
          </div>
        </div>

        <div className="modal-footer">
          <button type="button" className="ghost" onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
