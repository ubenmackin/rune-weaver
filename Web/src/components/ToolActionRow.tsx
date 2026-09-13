// Rune Weaver Dashboard — Shared tool execution action row component.
// Renders interactive tool activity in both 'chat' (in-flight or historical turns)
// and 'card' (run log detail modal) variants with collapsible arguments and outputs.

import { useState } from "react";
import type { ToolAction } from "../api";
import { ChevronDownIcon, ChevronRightIcon, WrenchIcon } from "./icons";

export interface ToolActionRowProps {
  action: ToolAction;
  variant?: "chat" | "card";
}

export default function ToolActionRow({
  action,
  variant = "chat",
}: ToolActionRowProps) {
  const [open, setOpen] = useState(false);

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
            <span className="tool-call-id">{(action.callID || "").slice(0, 8)}</span>
          </div>
          <div className="tool-action-badge">
            {action.result ? (
              action.result.isError ? (
                <span className="tool-badge-error">Error</span>
              ) : (
                <span className="tool-badge-ok">Done</span>
              )
            ) : (
              <span className="tool-badge-pending">Running</span>
            )}
          </div>
        </button>

        {open ? (
          <div className="tool-action-body">
            <div className="tool-section">
              <div className="tool-label">Arguments</div>
              <pre className="code-block">{action.argumentsJSON}</pre>
            </div>
            {action.result ? (
              <div className="tool-section">
                <div className="tool-label">Result</div>
                <pre
                  className={`code-block ${
                    action.result.isError ? "error-result" : ""
                  }`}
                >
                  {action.result.content}
                </pre>
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
        {action.result ? (
          <span
            className={`chat-tool-status ${
              action.result.isError ? "error" : "ok"
            }`}
          >
            {action.result.isError ? "Error" : "Done"}
          </span>
        ) : (
          <span className="chat-tool-status running">Running</span>
        )}
      </button>

      {open ? (
        <div className="chat-tool-details">
          <div className="chat-tool-detail-section">
            <span className="chat-tool-detail-label">Arguments:</span>
            <pre className="chat-tool-code">{action.argumentsJSON}</pre>
          </div>
          {action.result ? (
            <div className="chat-tool-detail-section">
              <span className="chat-tool-detail-label">Output:</span>
              <pre
                className={`chat-tool-code ${
                  action.result.isError ? "error-text" : ""
                }`}
              >
                {action.result.content}
              </pre>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
