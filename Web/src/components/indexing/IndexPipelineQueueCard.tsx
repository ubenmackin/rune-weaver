// Rune Weaver Dashboard — Sources & Coverage Bento card (pills and share-of-index bars).
import {
  resolveIndexSourceSkippedReason,
  type IndexStatusResponse,
  type IndexStorageResponse,
} from "../../api";
import {
  CHART_TRACK_COLOR,
  CHART_VECTOR_COLOR,
  formatIndexBytes,
  formatIndexCount,
  indexAccessDeniedGuidance,
  indexSourceBarPercent,
  indexSourceBarWidth,
  indexSourcePillTitle,
  indexSourcePillTone,
  shouldShowIndexAccessDeniedGuidance,
  shouldShowIndexGrantButton,
  sourceLabel,
  type IndexSourceContentRow,
} from "./indexHelpers";

interface IndexPipelineQueueCardProps {
  status: (IndexStatusResponse & IndexStorageResponse) | null;
  sourceContent: IndexSourceContentRow[];
  sourceTotalDocuments: number;
  accessBusy: Record<string, boolean>;
  onRequestAccess: (kind: string) => void;
}

export default function IndexPipelineQueueCard({
  status,
  sourceContent,
  sourceTotalDocuments,
  accessBusy,
  onRequestAccess,
}: IndexPipelineQueueCardProps) {
  if (!status) return null;

  return (
    <div className="card index-bento-card">
      <div className="index-bento-card-header">
        <span className="index-bento-card-title">Sources &amp; Coverage</span>
        <span className="muted text-xs">
          {formatIndexCount(sourceTotalDocuments)} total docs
        </span>
      </div>
      {status.sources && status.sources.length > 0 ? (
        <div
          className="index-source-pills"
          style={{ display: "flex", flexWrap: "wrap", gap: 8, marginBottom: 14 }}
        >
          {status.sources.map((source) => {
            const tone = indexSourcePillTone(source);
            const title = indexSourcePillTitle(source);
            const showGrant = shouldShowIndexGrantButton(source);
            const showDenied = shouldShowIndexAccessDeniedGuidance(source);
            return (
              <span
                key={source.kind}
                className={`status-pill ${tone}`}
                title={title ?? undefined}
              >
                {sourceLabel(source.kind)} · {source.enabled ? "On" : "Off"}
                {showGrant ? (
                  <button
                    type="button"
                    className="ghost"
                    aria-label={`Grant ${sourceLabel(source.kind)} access`}
                    disabled={!!accessBusy[source.kind]}
                    onClick={() => onRequestAccess(source.kind)}
                    style={{ marginLeft: 8 }}
                  >
                    {accessBusy[source.kind] ? "Requesting…" : "Grant"}
                  </button>
                ) : null}
                {showDenied ? (
                  <span
                    className="muted text-xs"
                    style={{ marginLeft: 8 }}
                  >
                    {indexAccessDeniedGuidance(source.kind)}
                  </span>
                ) : null}
              </span>
            );
          })}
        </div>
      ) : null}

      <div
        data-testid="index-source-bars"
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 10,
        }}
      >
        <h4 className="text-xs muted" style={{ margin: 0, fontWeight: 600 }}>
          Documents by source (share of index)
        </h4>
        {sourceContent.map((source) => {
          const barWidth = indexSourceBarWidth(
            source.documents,
            sourceTotalDocuments,
          );
          const barLabel = indexSourceBarPercent(
            source.documents,
            sourceTotalDocuments,
          );
          const isEmpty = source.documents <= 0;
          const skippedReason = resolveIndexSourceSkippedReason(
            status.lastRun ?? null,
            source.kind,
          );
          return (
            <div
              key={source.kind}
              style={{ display: "flex", flexDirection: "column", gap: 4 }}
            >
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  alignItems: "baseline",
                  gap: 8,
                }}
              >
                <span className="text-xs muted">
                  {sourceLabel(source.kind)}
                </span>
                {isEmpty ? null : (
                  <span
                    className="text-xs muted"
                    data-testid={`index-bar-pct-${source.kind}`}
                    style={{ textAlign: "right" }}
                  >
                    {barLabel}
                  </span>
                )}
              </div>
              {isEmpty ? (
                <span
                  className="text-xs muted"
                  data-testid={`index-bar-empty-${source.kind}`}
                >
                  No data yet
                </span>
              ) : (
                <div
                  style={{
                    width: "100%",
                    height: 10,
                    borderRadius: 5,
                    background: CHART_TRACK_COLOR,
                    overflow: "hidden",
                  }}
                >
                  <div
                    data-testid={`index-bar-${source.kind}`}
                    aria-label={`${sourceLabel(source.kind)} ${formatIndexCount(source.documents)} documents`}
                    style={{
                      width: barWidth,
                      height: "100%",
                      borderRadius: 5,
                      background: CHART_VECTOR_COLOR,
                      transition: "width 240ms ease",
                    }}
                  />
                </div>
              )}
              <span className="text-xs muted">
                {formatIndexCount(source.documents)} docs · {formatIndexCount(source.chunks)} chunks · {formatIndexBytes(source.bytes)}
              </span>
              {skippedReason ? (
                <span
                  className="muted text-xs"
                  data-testid={`index-source-note-${source.kind}`}
                >
                  {skippedReason}
                </span>
              ) : null}
            </div>
          );
        })}
      </div>
    </div>
  );
}
