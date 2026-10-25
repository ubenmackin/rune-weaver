// Rune Weaver Dashboard — Sources & Coverage Bento card (pills and share-of-index bars).
import {
  resolveIndexSourceSkippedReason,
  type IndexStatusResponse,
  type IndexStorageResponse,
} from "../../api";
import {
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
          className="index-source-pills index-source-pills-bar"
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
                    className="ghost ml-2"
                    aria-label={`Grant ${sourceLabel(source.kind)} access`}
                    disabled={!!accessBusy[source.kind]}
                    onClick={() => onRequestAccess(source.kind)}
                  >
                    {accessBusy[source.kind] ? "Requesting…" : "Grant"}
                  </button>
                ) : null}
                {showDenied ? (
                  <span
                    className="muted text-xs ml-2"
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
        className="index-share-bars"
      >
        <h4 className="text-xs muted index-chart-heading">
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
              className="index-share-row"
            >
              <div
                className="index-share-row-head"
              >
                <span className="text-xs muted">
                  {sourceLabel(source.kind)}
                </span>
                {isEmpty ? null : (
                  <span
                    className="text-xs muted index-bar-pct"
                    data-testid={`index-bar-pct-${source.kind}`}
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
                  className="progress-track"
                >
                  <div
                    data-testid={`index-bar-${source.kind}`}
                    aria-label={`${sourceLabel(source.kind)} ${formatIndexCount(source.documents)} documents`}
                    className="progress-fill"
                    style={{
                      width: barWidth,
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
