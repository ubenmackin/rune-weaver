// Rune Weaver Dashboard — On-disk storage composition donut and extraction outcomes.
import type {
  IndexExtractStatusCounts,
} from "../../api";
import {
  DONUT_RADIUS,
  DONUT_SIZE,
  DONUT_STROKE,
  extractStatusLabel,
  formatIndexCount,
  indexSourceBarPercent,
  indexSourceBarWidth,
} from "./indexHelpers";

interface IndexStorageBreakdownCardProps {
  vectorChunks: number;
  keywordChunks: number;
  donut: { vectorDash: number; keywordDash: number; circumference: number };
  extractRows: IndexExtractStatusCounts[];
  extractTotalDocuments: number;
}

export default function IndexStorageBreakdownCard({
  vectorChunks,
  keywordChunks,
  donut,
  extractRows,
  extractTotalDocuments,
}: IndexStorageBreakdownCardProps) {
  return (
                <div className="card index-bento-card">
                  <div className="index-bento-card-header">
                    <span className="index-bento-card-title">Composition &amp; Extraction</span>
                    <span className="muted text-xs">
                      {formatIndexCount(vectorChunks + keywordChunks)} chunks
                    </span>
                  </div>
    
                  <div className="index-donut-showcase">
                    <svg
                      width={DONUT_SIZE}
                      height={DONUT_SIZE}
                      viewBox={`0 0 ${DONUT_SIZE} ${DONUT_SIZE}`}
                      role="img"
                      aria-label={`${formatIndexCount(vectorChunks)} vector chunks, ${formatIndexCount(keywordChunks)} keyword chunks`}
                      data-testid="index-donut-chart"
                    >
                      <circle
                        cx={DONUT_SIZE / 2}
                        cy={DONUT_SIZE / 2}
                        r={DONUT_RADIUS}
                        fill="none"
                        className="index-donut-track"
                        strokeWidth={DONUT_STROKE}
                      />
                      <circle
                        cx={DONUT_SIZE / 2}
                        cy={DONUT_SIZE / 2}
                        r={DONUT_RADIUS}
                        fill="none"
                        className="index-donut-vector"
                        strokeWidth={DONUT_STROKE}
                        strokeDasharray={`${donut.vectorDash} ${donut.circumference - donut.vectorDash}`}
                        transform={`rotate(-90 ${DONUT_SIZE / 2} ${DONUT_SIZE / 2})`}
                      />
                      <circle
                        cx={DONUT_SIZE / 2}
                        cy={DONUT_SIZE / 2}
                        r={DONUT_RADIUS}
                        fill="none"
                        className="index-donut-keyword"
                        strokeWidth={DONUT_STROKE}
                        strokeDasharray={`${donut.keywordDash} ${donut.circumference - donut.keywordDash}`}
                        strokeDashoffset={-donut.vectorDash}
                        transform={`rotate(-90 ${DONUT_SIZE / 2} ${DONUT_SIZE / 2})`}
                      />
                    </svg>
                    <div
                      className="text-sm index-donut-legend"
                    >
                      <span className="index-donut-legend-row">
                        <span
                          className="index-donut-swatch index-donut-swatch-vector"
                        />
                        Vector <strong>{formatIndexCount(vectorChunks)}</strong>
                      </span>
                      <span className="index-donut-legend-row">
                        <span
                          className="index-donut-swatch index-donut-swatch-keyword"
                        />
                        Keyword <strong>{formatIndexCount(keywordChunks)}</strong>
                      </span>
                    </div>
                  </div>
    
                  <div
                    data-testid="index-extract-bars"
                    className="index-extract-bars"
                  >
                    <h4 className="text-xs muted index-chart-heading">
                      Extraction outcomes (share of index)
                    </h4>
                    {extractRows.length > 0 ? (
                      extractRows.map((row) => {
                        const barWidth = indexSourceBarWidth(
                          row.documents,
                          extractTotalDocuments,
                        );
                        const barLabel = indexSourceBarPercent(
                          row.documents,
                          extractTotalDocuments,
                        );
                        const isEmpty = row.documents <= 0;
                        return (
                          <div
                            key={row.status}
                            className="index-share-row"
                          >
                            <div
                              className="index-share-row-head"
                            >
                              <span className="text-xs muted">
                                {extractStatusLabel(row.status)}
                              </span>
                              {isEmpty ? null : (
                                <span
                                  className="text-xs muted index-bar-pct"
                                  data-testid={`index-extract-pct-${row.status}`}
                                >
                                  {barLabel}
                                </span>
                              )}
                            </div>
                            {isEmpty ? (
                              <span
                                className="text-xs muted"
                                data-testid={`index-extract-empty-${row.status}`}
                              >
                                No data yet
                              </span>
                            ) : (
                              <div
                                className="progress-track"
                              >
                                <div
                                  data-testid={`index-extract-bar-${row.status}`}
                                  aria-label={`${extractStatusLabel(row.status)} ${formatIndexCount(row.documents)} documents`}
                                  className="progress-fill"
                                  style={{
                                    width: barWidth,
                                  }}
                                />
                              </div>
                            )}
                            <span className="text-xs muted">
                              {formatIndexCount(row.documents)} docs
                            </span>
                          </div>
                        );
                      })
                    ) : (
                      <span className="text-xs muted" data-testid="index-extract-empty">
                        No data yet
                      </span>
                    )}
                  </div>
                </div>
  );
}
