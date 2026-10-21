// Rune Weaver Dashboard — Chat status bar showing token usage metrics across mobile and desktop.

import type { Dispatch, SetStateAction } from "react";

interface ChatStatusBarProps {
  footerExpanded: boolean;
  setFooterExpanded: Dispatch<SetStateAction<boolean>>;
  pct: number;
  sessionShort: string;
  safeTurnTokens: number | null;
  safeContextTokens: number;
  safeContextLimit: number;
  safeSessionTokens: number;
  activeModel: string;
}

export default function ChatStatusBar({
  footerExpanded,
  setFooterExpanded,
  pct,
  sessionShort,
  safeTurnTokens,
  safeContextTokens,
  safeContextLimit,
  safeSessionTokens,
  activeModel,
}: ChatStatusBarProps) {
  return (
    <div
      className={`chat-status-bar${footerExpanded ? " footer-expanded" : ""}`}
      aria-label="Session metrics"
    >
      <div className="status-bar-mobile-summary">
        <span
          className={`status-bar-value${pct >= 80 ? " status-warning" : ""}`}
        >
          Ctx {pct}%
        </span>
        <span className="status-bar-divider" aria-hidden="true">
          •
        </span>
        <span className="status-bar-value">{sessionShort} sess</span>
        <button
          type="button"
          className="status-bar-details-toggle"
          aria-expanded={footerExpanded}
          aria-controls={footerExpanded ? "footer-detail" : undefined}
          onClick={() => setFooterExpanded((previous) => !previous)}
        >
          Details
        </button>
      </div>
      {footerExpanded ? (
        <div id="footer-detail" className="status-bar-detail">
          <div className="status-bar-detail-row">
            <span className="status-bar-label">Turn:</span>
            <span className="status-bar-value">
              {safeTurnTokens != null
                ? `${safeTurnTokens.toLocaleString()} tokens`
                : "-"}
            </span>
          </div>
          <div className="status-bar-detail-row">
            <span className="status-bar-label">Context:</span>
            <span className="status-bar-value">
              {safeContextTokens.toLocaleString()} /{" "}
              {safeContextLimit.toLocaleString()} tokens ({pct}%)
            </span>
          </div>
          <div className="status-bar-detail-row">
            <span className="status-bar-label">Session:</span>
            <span className="status-bar-value">
              {safeSessionTokens.toLocaleString()} tokens
            </span>
          </div>
        </div>
      ) : null}
      <div className="status-bar-desktop-metrics">
        <div className="status-bar-item status-bar-item--model">
          <span className="status-bullet green" />
          <span className="status-bar-label">LLM:</span>
          <span className="status-bar-value">{activeModel}</span>
        </div>

        <div className="status-bar-divider" aria-hidden="true">
          •
        </div>

        <div className="status-bar-item status-bar-item--turn">
          <span className="status-bar-label">Turn:</span>
          <span className="status-bar-value">
            {safeTurnTokens != null
              ? `${safeTurnTokens.toLocaleString()} tokens`
              : "-"}
          </span>
        </div>

        <div className="status-bar-divider" aria-hidden="true">
          •
        </div>

        <div className="status-bar-item status-bar-item--context">
          <span className="status-bar-label">Context:</span>
          <span
            className={`status-bar-value${
              pct >= 80 ? " status-warning" : ""
            }`}
          >
            {safeContextTokens.toLocaleString()} /{" "}
            {safeContextLimit.toLocaleString()} tokens ({pct}%)
          </span>
        </div>

        <div className="status-bar-divider" aria-hidden="true">
          •
        </div>

        <div className="status-bar-item status-bar-item--session">
          <span className="status-bar-label">Session:</span>
          <span className="status-bar-value">
            {safeSessionTokens.toLocaleString()} tokens
          </span>
        </div>
      </div>
    </div>
  );
}
