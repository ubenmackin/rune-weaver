// Rune Weaver Dashboard — On-disk storage composition donut and extraction outcomes.
import type {
  IndexExtractStatusCounts,
} from "../../api";
import {
  CHART_EXTRACT_COLOR,
  CHART_KEYWORD_COLOR,
  CHART_TRACK_COLOR,
  CHART_VECTOR_COLOR,
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
                        stroke={CHART_TRACK_COLOR}
                        strokeWidth={DONUT_STROKE}
                      />
                      <circle
                        cx={DONUT_SIZE / 2}
                        cy={DONUT_SIZE / 2}
                        r={DONUT_RADIUS}
                        fill="none"
                        stroke={CHART_VECTOR_COLOR}
                        strokeWidth={DONUT_STROKE}
                        strokeDasharray={`${donut.vectorDash} ${donut.circumference - donut.vectorDash}`}
                        transform={`rotate(-90 ${DONUT_SIZE / 2} ${DONUT_SIZE / 2})`}
                      />
                      <circle
                        cx={DONUT_SIZE / 2}
                        cy={DONUT_SIZE / 2}
                        r={DONUT_RADIUS}
                        fill="none"
                        stroke={CHART_KEYWORD_COLOR}
                        strokeWidth={DONUT_STROKE}
                        strokeDasharray={`${donut.keywordDash} ${donut.circumference - donut.keywordDash}`}
                        strokeDashoffset={-donut.vectorDash}
                        transform={`rotate(-90 ${DONUT_SIZE / 2} ${DONUT_SIZE / 2})`}
                      />
                    </svg>
                    <div
                      style={{ display: "flex", flexDirection: "column", gap: 6 }}
                      className="text-sm"
                    >
                      <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                        <span
                          style={{
                            width: 10,
                            height: 10,
                            borderRadius: 2,
                            display: "inline-block",
                            background: CHART_VECTOR_COLOR,
                          }}
                        />
                        Vector <strong>{formatIndexCount(vectorChunks)}</strong>
                      </span>
                      <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                        <span
                          style={{
                            width: 10,
                            height: 10,
                            borderRadius: 2,
                            display: "inline-block",
                            background: CHART_KEYWORD_COLOR,
                          }}
                        />
                        Keyword <strong>{formatIndexCount(keywordChunks)}</strong>
                      </span>
                    </div>
                  </div>
    
                  <div
                    data-testid="index-extract-bars"
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: 10,
                      marginTop: 14,
                    }}
                  >
                    <h4 className="text-xs muted" style={{ margin: 0, fontWeight: 600 }}>
                      Extraction outcomes — share of index
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
                                {extractStatusLabel(row.status)}
                              </span>
                              {isEmpty ? null : (
                                <span
                                  className="text-xs muted"
                                  data-testid={`index-extract-pct-${row.status}`}
                                  style={{ textAlign: "right" }}
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
                                style={{
                                  width: "100%",
                                  height: 10,
                                  borderRadius: 5,
                                  background: CHART_TRACK_COLOR,
                                  overflow: "hidden",
                                }}
                              >
                                <div
                                  data-testid={`index-extract-bar-${row.status}`}
                                  aria-label={`${extractStatusLabel(row.status)} ${formatIndexCount(row.documents)} documents`}
                                  style={{
                                    width: barWidth,
                                    height: "100%",
                                    borderRadius: 5,
                                    background: CHART_EXTRACT_COLOR,
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
