// Rune Weaver Dashboard — Recall summary chip rendering diagnostics and source counts.

import {
  formatRecallCollapsed,
  isRecallDiagnosticsVisible,
  type RecallDiagnostics,
} from "../../api";

export default function RecallChip({ diagnostics }: { diagnostics: RecallDiagnostics }) {
  if (!isRecallDiagnosticsVisible(diagnostics)) return null;
  const collapsed = formatRecallCollapsed(diagnostics);
  // Prefer the wire tallies so collapsed and expanded agree; fall back to
  // tallying sources when a drifted payload carries an empty map.
  const tallied: Record<string, number> =
    Object.keys(diagnostics.countsBySource).length > 0
      ? diagnostics.countsBySource
      : (() => {
          const fallback: Record<string, number> = {};
          for (const source of diagnostics.sources) {
            fallback[source] = (fallback[source] ?? 0) + 1;
          }
          return fallback;
        })();
  const entries = Object.entries(tallied).sort(([a], [b]) => a.localeCompare(b));
  return (
    <details className="recall-chip muted" data-testid="recall-chip">
      <summary className="recall-chip-summary muted text-xs">{collapsed}</summary>
      <div className="recall-chip-details muted text-xs">
        {entries.map(([source, count]) => (
          <div key={source} className="recall-chip-row" data-testid="recall-chip-row">
            <span className="recall-chip-source">{source}</span>
            <span className="recall-chip-count">{count}</span>
          </div>
        ))}
        {diagnostics.skippedDocIndex ? (
          <div className="recall-chip-row" data-testid="recall-chip-row">
            <span className="recall-chip-source">index skipped</span>
            <span className="recall-chip-count">skipped</span>
          </div>
        ) : null}
      </div>
    </details>
  );
}
