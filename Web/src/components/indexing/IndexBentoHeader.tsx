// Rune Weaver Dashboard — Indexing hero run header with progress and stage indicators.
import { Fragment } from "react";
import { StopIcon, TrashIcon } from "../icons";
import type {
  IndexLiveQueueLane,
  IndexLiveSourceStatus,
  IndexStatusResponse,
} from "../../api";
import {
  formatIndexCount,
  sourceLabel,
  type IndexPipelineStep,
} from "./indexHelpers";

interface IndexBentoHeaderProps {
  action: "run" | "prune" | "reset" | "reclaim" | null;
  actionBusy: boolean;
  cancelBusy: boolean;
  cancelling: boolean;
  indexingEnabled: boolean;
  progressActive: boolean;
  showLiveBlock: boolean;
  liveHeaderText: string;
  liveCurrent: string | null;
  pipelineSteps: IndexPipelineStep[];
  queueLanes: IndexLiveQueueLane[];
  liveSources: IndexLiveSourceStatus[];
  reclaimSummary: string | null;
  status: IndexStatusResponse | null;
  onRun: () => void;
  onCancel: () => void;
  onOpenPrune: () => void;
  onReclaim: () => void;
  onOpenRebuild: () => void;
}

export default function IndexBentoHeader({
  action,
  actionBusy,
  cancelBusy,
  cancelling,
  indexingEnabled,
  progressActive,
  showLiveBlock,
  liveHeaderText,
  liveCurrent,
  pipelineSteps,
  queueLanes,
  liveSources,
  reclaimSummary,
  status,
  onRun,
  onCancel,
  onOpenPrune,
  onReclaim,
  onOpenRebuild,
}: IndexBentoHeaderProps) {
  return (
    <>
      <div className="index-actions-section index-bento-header">
        <div className="index-bento-header-top">
          <h3>Run</h3>
          <div className="row">
            <button
              type="button"
              className="primary icon-text-btn"
              onClick={onRun}
              disabled={actionBusy || cancelBusy || cancelling || !indexingEnabled || progressActive}
              title={
                indexingEnabled
                  ? "Run an on-demand index pass"
                  : "Enable indexing to run a pass"
              }
            >
              <span>
                {action === "run" ? "Indexing…" : "Run"}
              </span>
            </button>

            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={onCancel}
              disabled={cancelBusy || cancelling || !progressActive || action === "prune" || action === "reset" || action === "reclaim"}
            >
              <StopIcon size={14} />
              <span>{cancelBusy || cancelling ? "Cancelling…" : "Cancel"}</span>
            </button>

            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={onOpenPrune}
              disabled={actionBusy || cancelBusy || progressActive || cancelling}
            >
              <TrashIcon size={14} />
              <span>{action === "prune" ? "Pruning…" : "Prune"}</span>
            </button>

            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={onReclaim}
              disabled={actionBusy || cancelBusy || progressActive || cancelling}
              title="Compact the index database to reclaim free space"
            >
              <span>{action === "reclaim" ? "Reclaiming…" : "Reclaim space"}</span>
            </button>

            <button
              type="button"
              className="danger icon-text-btn"
              onClick={onOpenRebuild}
              disabled={actionBusy || cancelBusy || progressActive || cancelling}
            >
              <TrashIcon size={14} />
              <span>{action === "reset" ? "Clearing…" : "Reset Index"}</span>
            </button>
          </div>
        </div>
        {/* Disabled-index hint under the Run row; prune/reclaim/reset stay
            independent of the enabled flag. */}
        {status?.enabled === false ? (
          <p className="muted text-sm">
            Indexing is off — turn it on in Settings → Indexing to run a pass.
          </p>
        ) : null}
        {/* Reclaim outcome keeps both on-disk figures visible after the size
            card reloads, so the compaction delta never scrolls away with the
            transient notice. */}
        {reclaimSummary ? (
          <p
            className="muted text-sm"
            data-testid="index-reclaim-result"
            style={{ marginTop: 8 }}
          >
            {reclaimSummary}
          </p>
        ) : null}
      </div>

      {/* Live Indexing Pipeline Card under Run while the polled snapshot is present: header
          strip plus animated 4-stage pipeline flow track, 4-lane modality queue grid, source
          strip, ticker, and activity bar. Unmounts fully on settle. */}
      {showLiveBlock && (
        <div className="index-live-progress" data-testid="index-live-progress">
          <div
            className="index-live-header muted text-xs"
            data-testid="index-live-header"
          >
            {liveHeaderText}
          </div>

          <div
            className="index-pipeline-track"
            data-testid="index-live-pipeline"
            aria-label="Indexing pipeline stages"
          >
            {pipelineSteps.map((step, index) => {
              const nextStep = pipelineSteps[index + 1];
              const connectorState =
                step.state === "done" && nextStep && nextStep.state !== "pending"
                  ? "flowing"
                  : step.state === "active"
                    ? "active"
                    : "pending";
              return (
                <Fragment key={step.id}>
                  <div
                    className={`index-pipeline-step ${step.state}`}
                    data-testid={`index-pipeline-step-${step.id}`}
                    data-state={step.state}
                  >
                    <span className="index-pipeline-node" aria-hidden="true" />
                    <div className="index-pipeline-step-body">
                      <span className="index-pipeline-label">{step.label}</span>
                      {step.metric ? (
                        <span
                          className="index-pipeline-metric muted text-xs"
                          data-testid={`index-pipeline-metric-${step.id}`}
                        >
                          {step.metric}
                        </span>
                      ) : null}
                    </div>
                  </div>
                  {index < pipelineSteps.length - 1 ? (
                    <div
                      className={`index-pipeline-connector ${connectorState}`}
                      data-testid={`index-pipeline-connector-${step.id}`}
                      data-state={connectorState}
                      aria-hidden="true"
                    >
                      <span className="index-pipeline-connector-flow" />
                    </div>
                  ) : null}
                </Fragment>
              );
            })}
          </div>

          {queueLanes.length > 0 ? (
            <div
              className="index-queue-lanes-grid"
              data-testid="index-live-queues"
            >
              {queueLanes.map((lane) => {
                const pct =
                  lane.queued > 0
                    ? Math.min(100, Math.round((lane.processed / lane.queued) * 100))
                    : 0;
                const isActive = lane.queued > lane.processed;
                return (
                  <div
                    key={lane.lane}
                    className={`index-queue-lane-card${isActive ? " active" : ""}`}
                    data-testid={`index-queue-lane-${lane.lane}`}
                  >
                    <div className="index-queue-lane-header">
                      <span className="index-queue-lane-label">{lane.label}</span>
                      <span
                        className="index-queue-lane-counts muted text-xs"
                        data-testid={`index-queue-counts-${lane.lane}`}
                      >
                        {formatIndexCount(lane.processed)} / {formatIndexCount(lane.queued)}
                      </span>
                    </div>
                    <div className="index-queue-lane-track">
                      <div
                        className="index-queue-lane-fill"
                        style={{ width: `${pct}%` }}
                      />
                    </div>
                  </div>
                );
              })}
            </div>
          ) : null}

          {liveSources.length > 0 ? (
            <div
              className="index-live-sources-strip"
              data-testid="index-live-sources"
            >
              {liveSources.map((src) => {
                const running = src.state === "running";
                return (
                  <span
                    key={src.kind}
                    className={`index-live-source-chip ${running ? "running" : "completed"}`}
                    data-testid={`index-live-source-${src.kind}`}
                  >
                    <span className="index-live-source-dot" aria-hidden="true" />
                    <span className="index-live-source-name">
                      {sourceLabel(src.kind)}
                    </span>
                    <span className="index-live-source-state muted text-xs">
                      {running ? "Running" : "Done"} ·{" "}
                      {formatIndexCount(src.indexed)} indexed
                    </span>
                  </span>
                );
              })}
            </div>
          ) : null}

          {liveCurrent ? (
            <div
              className="tool-progress-current index-live-current"
              data-testid="index-live-current"
              title={liveCurrent}
            >
              {liveCurrent}
            </div>
          ) : null}
          <div
            className="tool-progress-shimmer index-live-activity"
            data-testid="index-live-activity"
            role="progressbar"
            aria-label="Index run in progress"
            aria-valuetext="In progress"
          />
        </div>
      )}
    </>
  );
}
