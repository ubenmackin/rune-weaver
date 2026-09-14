// Rune Weaver Dashboard — Shared tool execution action row component.
// Renders interactive tool activity in both 'chat' (in-flight or historical turns)
// and 'card' (run log detail modal) variants with collapsible arguments and outputs.

import { useState } from "react";
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
