// Rune Weaver Dashboard — Inline unified diff viewer with syntax color coding.

import { useState, useMemo } from "react";

interface UnifiedDiffViewProps {
  diff: string;
  maxCollapsedLines?: number;
  className?: string;
}

export default function UnifiedDiffView({
  diff,
  maxCollapsedLines = 30,
  className = "",
}: UnifiedDiffViewProps) {
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState(false);

  const lines = useMemo(() => {
    if (!diff) return [];
    return diff.split("\n");
  }, [diff]);

  const displayedLines = useMemo(() => {
    if (expanded || lines.length <= maxCollapsedLines) {
      return lines;
    }
    return lines.slice(0, maxCollapsedLines);
  }, [lines, expanded, maxCollapsedLines]);

  const handleCopy = () => {
    if (!diff) return;
    navigator.clipboard.writeText(diff).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  if (!diff || lines.length === 0) {
    return <div className="text-xs text-neutral-400 italic p-2">No diff changes</div>;
  }

  return (
    <div className={`unified-diff-container ${className}`}>
      <div className="unified-diff-header">
        <span className="unified-diff-title">Unified Diff ({lines.length} lines)</span>
        <button
          type="button"
          className="unified-diff-copy-btn"
          onClick={handleCopy}
          title="Copy diff to clipboard"
        >
          {copied ? "Copied!" : "Copy"}
        </button>
      </div>

      <div className="unified-diff-content font-mono text-xs">
        {displayedLines.map((line, idx) => {
          let lineType = "context";
          if (line.startsWith("+++") || line.startsWith("---")) {
            lineType = "header";
          } else if (line.startsWith("+")) {
            lineType = "addition";
          } else if (line.startsWith("-")) {
            lineType = "deletion";
          } else if (line.startsWith("@@")) {
            lineType = "hunk";
          }

          return (
            <div key={idx} className={`unified-diff-line diff-${lineType}`}>
              <span className="diff-line-content">{line || " "}</span>
            </div>
          );
        })}
      </div>

      {lines.length > maxCollapsedLines && (
        <button
          type="button"
          className="unified-diff-expand-btn"
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? "▲ Show less" : `▼ Show all ${lines.length} lines (${lines.length - maxCollapsedLines} more)`}
        </button>
      )}
    </div>
  );
}
