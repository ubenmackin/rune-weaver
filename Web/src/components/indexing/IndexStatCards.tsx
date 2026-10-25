// Rune Weaver Dashboard — Index status banner and summary metric cards.
import type {
  IndexStatusResponse,
  IndexStorageResponse,
} from "../../api";
import {
  formatIndexAge,
  formatIndexAsOf,
  formatIndexBytes,
  formatIndexCount,
  percentOf,
  type IndexStorageBreakdown,
} from "./indexHelpers";

interface IndexStatCardsProps {
  status: (IndexStatusResponse & IndexStorageResponse) | null;
  cancelling: boolean;
  runActive: boolean;
  statusEffortReality: string | null;
  lastRunText: string;
  storage: IndexStorageBreakdown;
  storageBreakdownTotal: number;
  displayDocuments: number;
  liveIndexedDelta: number;
  displayChunks: number;
  vectorChunks: number;
  keywordChunks: number;
}

export default function IndexStatCards({
  status,
  cancelling,
  runActive,
  statusEffortReality,
  lastRunText,
  storage,
  storageBreakdownTotal,
  displayDocuments,
  liveIndexedDelta,
  displayChunks,
  vectorChunks,
  keywordChunks,
}: IndexStatCardsProps) {
  return (
    <div className="index-status-section">
      <div className="index-status-banner">
        <div className="index-status-banner-left">
          <h3>Status</h3>
          <div className="index-status-line">
            {cancelling ? (
              <span className="status-pill running">Cancelling</span>
            ) : status?.running || runActive ? (
              <span className="status-pill running">Running</span>
            ) : status?.enabled ? (
              <span className="status-pill ok">Enabled</span>
            ) : (
              <span className="status-pill skipped">Disabled</span>
            )}
          </div>
          {statusEffortReality ? (
            <p
              className="muted text-sm index-effort-badge"
              data-testid="index-effort-status"
            >
              {statusEffortReality}
            </p>
          ) : null}
        </div>
        {status ? (
          <div
            className="index-last-run"
            data-testid="index-last-run"
          >
            <span className="muted text-sm">{lastRunText}</span>
          </div>
        ) : null}
      </div>

      {status ? (
        <>
          <div className="index-stat-cards">
            <div className="card index-stat-card">
              <div className="muted text-xs index-stat-label">Size on disk</div>
              <div
                className="index-stat-value"
                data-testid="index-stat-size-value"
              >
                <span data-testid="index-stat-size-figure">
                  {formatIndexBytes(storage.onDisk)}
                </span>
                {storage.hasStorage ? null : (
                  <span
                    className="muted text-xs index-size-sizing"
                    data-testid="index-size-sizing"
                  >
                    Sizing storage…
                  </span>
                )}
              </div>
              {storage.hasBreakdown && storageBreakdownTotal > 0 ? (
                <div
                  className="progress-track"
                  data-testid="index-size-meter"
                  aria-hidden="true"
                >
                  <span
                    className="progress-fill"
                    style={{ width: `${percentOf(storage.text, storageBreakdownTotal)}%` }}
                  />
                  <span
                    className="progress-fill"
                    style={{ width: `${percentOf(storage.vector, storageBreakdownTotal)}%` }}
                  />
                  <span
                    className="progress-fill"
                    style={{ width: `${percentOf(storage.fts, storageBreakdownTotal)}%` }}
                  />
                  <span
                    className="progress-fill"
                    style={{ width: `${percentOf(storage.free, storageBreakdownTotal)}%` }}
                  />
                </div>
              ) : null}
              {storage.hasBreakdown ? (
                <div
                  className="muted text-xs mt-1"
                  data-testid="index-size-breakdown"
                >
                  <span data-testid="index-size-text">
                    Text {formatIndexBytes(storage.text)}
                  </span>
                  {" · "}
                  <span data-testid="index-size-vectors">
                    Vectors {formatIndexBytes(storage.vector)}
                  </span>
                  {" · "}
                  <span data-testid="index-size-fts">
                    FTS {formatIndexBytes(storage.fts)}
                  </span>
                  {" · "}
                  <span data-testid="index-size-free">
                    Free {formatIndexBytes(storage.free)}
                  </span>
                </div>
              ) : null}
              {storage.hasOnDisk ? (
                <div
                  className="muted text-xs index-stat-sub"
                  data-testid="index-size-files"
                >
                  DB {formatIndexBytes(storage.dbFile)} · WAL{" "}
                  {formatIndexBytes(storage.wal)}
                </div>
              ) : null}
              <div
                className="muted text-xs index-stat-sub"
                data-testid="index-size-content"
              >
                Content {formatIndexBytes(storage.content)}
              </div>
            </div>
            <div className="card index-stat-card">
              <div className="muted text-xs index-stat-label">Documents</div>
              <div
                className="index-stat-value"
                data-testid="index-stat-documents-value"
              >
                {formatIndexCount(displayDocuments)}
              </div>
              {liveIndexedDelta > 0 ? (
                <div
                  className="index-stat-live-delta text-xs"
                  data-testid="index-stat-documents-live"
                >
                  +{formatIndexCount(liveIndexedDelta)} this run
                </div>
              ) : (
                <div className="muted text-xs index-stat-sub">
                  Across {formatIndexCount(status.sources.filter((s) => s.enabled).length)} active sources
                </div>
              )}
            </div>
            <div className="card index-stat-card">
              <div className="muted text-xs index-stat-label">Chunks</div>
              <div
                className="index-stat-value"
                data-testid="index-stat-chunks-value"
              >
                {formatIndexCount(displayChunks)}
              </div>
              {vectorChunks + keywordChunks > 0 ? (
                <div className="progress-track" aria-hidden="true">
                  <span
                    className="progress-fill"
                    style={{ width: `${percentOf(vectorChunks, vectorChunks + keywordChunks)}%` }}
                  />
                  <span
                    className="progress-fill"
                    style={{ width: `${percentOf(keywordChunks, vectorChunks + keywordChunks)}%` }}
                  />
                </div>
              ) : null}
              <div className="muted text-xs index-stat-sub">
                {formatIndexCount(vectorChunks)} vector · {formatIndexCount(keywordChunks)} keyword
              </div>
            </div>
            <div
              className="card index-stat-card index-watermark-card"
              data-testid="index-watermark-card"
            >
              <div className="muted text-xs index-stat-label">Last indexed</div>
              <div className="index-stat-value">
                {formatIndexAge(status.indexAsOf)}
              </div>
              <div className="muted text-xs index-stat-sub">
                {formatIndexAsOf(status.indexAsOf)}
              </div>
            </div>
          </div>
        </>
      ) : (
        <div className="index-status-skeleton" data-testid="index-status-skeleton" role="status" aria-busy="true" aria-label="Loading index status">
          {/* Cold-boot skeleton: same card and pill geometry as the loaded panel
              so the first paint reserves space without the old text paragraph. */}
          <div className="index-stat-cards">
            <div className="card index-stat-card">
              <div className="muted text-xs index-stat-label">Size on disk</div>
              <div className="index-stat-value muted text-sm">Loading…</div>
            </div>
            <div className="card index-stat-card">
              <div className="muted text-xs index-stat-label">Documents</div>
              <div className="index-stat-value muted text-sm">Loading…</div>
            </div>
            <div className="card index-stat-card">
              <div className="muted text-xs index-stat-label">Chunks</div>
              <div className="index-stat-value muted text-sm">Loading…</div>
            </div>
            <div className="card index-stat-card index-watermark-card">
              <div className="muted text-xs index-stat-label">Last indexed</div>
              <div className="index-stat-value muted text-sm">Loading…</div>
            </div>
          </div>
          <div
            className="index-source-pills index-source-pills-skeleton"
          >
            <span className="status-pill skipped">Loading…</span>
            <span className="status-pill skipped">Loading…</span>
            <span className="status-pill skipped">Loading…</span>
          </div>
        </div>
      )}
    </div>
  );
}
