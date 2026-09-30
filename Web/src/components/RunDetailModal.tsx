// Rune Weaver Dashboard — Detailed modal viewer for inspectable run logs.
// Shows prompt, executed tool actions, full assistant response, and performance metrics.

import {
  formatRunDuration,
  indexRunLabelForRun,
  parseRunTimestamp,
  type RunLogEntry,
} from "../api";
import { CloseIcon } from "./icons";
import MarkdownText from "./MarkdownText";
import ToolActionRow from "./ToolActionRow";
import Modal from "./Modal";

interface RunDetailModalProps {
  run: RunLogEntry | null;
  onClose: () => void;
}

export default function RunDetailModal({ run, onClose }: RunDetailModalProps) {
  if (!run) return null;

  const isOk = run.status === "ok";
  const isSkipped = run.status === "skipped";
  const isAwaitingApproval = run.status === "awaiting_approval";
  const isRunning = run.status === "running";
  // A cancelled run is a deliberate stop, never a failure: without this case
  // it would fall through to the error copy and read as if execution broke.
  const isCancelled = run.status === "cancelled";
  const isFanOutParent = run.kind === "fanout";
  // Fan-out rows read their own family so a worker's detail never opens
  // mislabeled as a chat turn, and a parent's merged summary is the response
  // surface — it renders through the sanitized Markdown renderer only, never
  // a raw box, so worker content cannot inject markup.
  const kindLabel =
    run.kind === "scheduler"
      ? "Scheduled Run"
      : run.kind === "index"
        ? `${indexRunLabelForRun(run)}`
        : run.kind === "fanout"
          ? "Fan-out Run"
          : run.kind === "fanout_worker"
            ? "Fan-out Worker"
            : "Chat Turn";
  // Debug identifiers stay visible even on older payloads: run and session
  // IDs pin the audit trail to its conversation, while per-tool call IDs
  // correlate gated approvals and history without guessing.
  const sessionID = run.sessionID ?? null;
  const duration = formatRunDuration(run.durationMs);

  return (
    <Modal
      label="Run details"
      onClose={onClose}
      containerClassName="modal-container run-detail-modal"
    >
      <div className="modal-header">
        <div className="run-header-title">
          <span className={`status-pill ${run.status}`}>
            {run.status === "running"
              ? "IN PROGRESS"
              : run.status === "awaiting_approval"
                ? "AWAITING APPROVAL"
                : run.status.toUpperCase()}
          </span>
          <h3>
            {kindLabel}{" "}
            Details
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
                {parseRunTimestamp(run.timestamp).toLocaleString()}
              </span>
            </div>
            {duration ? (
              <div className="meta-card">
                <span className="meta-label">Duration</span>
                <span className="meta-value">{duration}</span>
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
            <div className="meta-card">
              <span className="meta-label">Run ID</span>
              <span
                className="meta-value font-mono"
                title={run.id}
                style={{ wordBreak: "break-all" }}
              >
                {run.id}
              </span>
            </div>
            {sessionID ? (
              <div className="meta-card">
                <span className="meta-label">Session ID</span>
                <span
                  className="meta-value font-mono"
                  title={sessionID}
                  style={{ wordBreak: "break-all" }}
                >
                  {sessionID}
                </span>
              </div>
            ) : null}
            {run.jobID ? (
              <div className="meta-card">
                <span className="meta-label">Job ID</span>
                <span
                  className="meta-value font-mono"
                  title={run.jobID}
                  style={{ wordBreak: "break-all" }}
                >
                  {run.jobID}
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
                  <ToolActionRow key={action.callID || idx} action={action} variant="card" isLive={false} />
                ))}
              </div>
            </div>
          ) : null}

          {/* Agent Response — a fan-out parent's response is the merged
              summary, so the header names it and the text renders through the
              sanitized Markdown renderer only. */}
          <div className="run-section">
            <h4>{isFanOutParent ? "Merged Summary" : "Agent Response"}</h4>
            {run.response ? (
              <div className="agent-response-box">
                <MarkdownText text={run.response} />
              </div>
            ) : (
              <div className="empty-response-note">
                {isSkipped
                  ? "Execution was skipped (a run for this job was already active)."
                  : isAwaitingApproval
                    ? "Awaiting approval — no output yet."
                    : isRunning
                      ? "In progress…"
                      : isCancelled
                        ? "Cancelled before completion — no output was recorded."
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
      </Modal>
  );
}
