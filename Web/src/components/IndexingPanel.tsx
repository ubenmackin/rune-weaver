// Rune Weaver Dashboard — Local index status dashboard (orchestration entrypoint).

import { useIndexingState } from "./indexing/useIndexingState";
import IndexBentoHeader from "./indexing/IndexBentoHeader";
import IndexStatCards from "./indexing/IndexStatCards";
import IndexPipelineQueueCard from "./indexing/IndexPipelineQueueCard";
import IndexStorageBreakdownCard from "./indexing/IndexStorageBreakdownCard";
import IndexErrorsCard from "./indexing/IndexErrorsCard";
import IndexModals from "./indexing/IndexModals";
import type { IndexingPanelProps } from "./indexing/indexHelpers";
import { isIndexDiscovering } from "./indexing/indexHelpers";

// Re-export all helper utilities and sub-panels so consumers and tests retain 100% API parity
export * from "./indexing/indexHelpers";
export * from "./indexing/indexPolicyHelpers";
export { IndexPolicyPanel } from "./indexing/IndexPolicyPanel";

export default function IndexingPanel({ hideHeader = false, highlightRun = false, onRunStarted }: IndexingPanelProps) {
  const state = useIndexingState();

  // Nudge clears only after the run starts so a parked run keeps its highlight.
  async function handleRunWithHighlight() {
    const started = await state.handleRun();
    if (started) onRunStarted?.();
  }

  return (
    <section className="panel indexing-panel" aria-label="Index Status">
      {/* Reconnect notice rendered as a fixed centered toast so an outage stays visible
          without shifting the panel header or layout. Leaves on socket recovery or explicit
          retry/dismiss. */}
      {state.reconnecting && !state.reconnectDismissed ? (
        <div
          className="connection-toast"
          data-testid="index-reconnecting"
          role="alert"
          aria-live="assertive"
        >
          <span className="connection-toast-message">
            Live updates paused. Reconnecting to server… Indexing continues in the background.
          </span>
          <div className="connection-toast-actions">
            <button
              type="button"
              className="ghost"
              data-testid="index-reconnect-retry"
              onClick={state.handleRetryConnection}
            >
              Retry now
            </button>
            <button
              type="button"
              className="ghost"
              data-testid="index-reconnect-dismiss"
              onClick={() => state.setReconnectDismissed(true)}
            >
              Dismiss
            </button>
          </div>
        </div>
      ) : null}

      {hideHeader ? null : (
        <div className="panel-header-row">
          <div className="panel-header-left">
            <h2>Index</h2>
            <p className="muted">
              Vector and keyword indexes over local files, mail, and messages.
            </p>
          </div>
        </div>
      )}

      {state.error ? (
        <div className="banner error index-panel-banner" role="alert">
          <span>{state.error}</span>
        </div>
      ) : null}

      {state.notice ? (
        <div className="banner info index-panel-banner" role="status">
          <span>{state.notice}</span>
        </div>
      ) : null}

      {state.reclaimResult ? (
        <div
          className="banner info index-panel-banner"
          role="status"
          data-testid="index-reclaim-banner"
        >
          <span>{state.reclaimSummary}</span>
        </div>
      ) : null}

      <IndexBentoHeader
        action={state.action}
        actionBusy={state.actionBusy}
        cancelBusy={state.cancelBusy}
        cancelling={state.cancelling}
        indexingEnabled={state.indexingEnabled}
        progressActive={state.progressActive}
        showLiveBlock={state.showLiveBlock}
        liveHeaderText={state.liveHeader}
        liveCurrent={state.liveCurrent}
        pipelineSteps={state.pipelineSteps}
        queueLanes={state.liveQueues}
        liveSources={state.liveSources}
        reclaimSummary={state.reclaimSummary}
        status={state.status}
        isDiscovering={isIndexDiscovering(state.live)}
        highlightRun={highlightRun}
        onRun={() => void handleRunWithHighlight()}
        onCancel={() => void state.handleCancel()}
        onOpenPrune={() => {
          state.setPruneBefore("");
          state.setPendingPrune(true);
        }}
        onReclaim={() => void state.handleReclaim()}
        onOpenRebuild={() => {
          state.setPendingRebuild(true);
        }}
      />

      <IndexStatCards
        status={state.status}
        cancelling={state.cancelling}
        runActive={state.runActive}
        statusEffortReality={state.statusEffortReality}
        lastRunText={state.lastRunText}
        storage={state.storage}
        storageBreakdownTotal={state.storageBreakdownTotal}
        displayDocuments={state.displayDocuments}
        liveIndexedDelta={state.liveIndexedDelta}
        displayChunks={state.displayChunks}
        vectorChunks={state.vectorChunks}
        keywordChunks={state.keywordChunks}
      />

      {state.status ? (
        <div className="index-charts-section">
          <h3>Charts</h3>
          <div className="index-bento-charts-grid">
            <IndexPipelineQueueCard
              status={state.status}
              sourceContent={state.sourceContent}
              sourceTotalDocuments={state.sourceTotalDocuments}
              accessBusy={state.accessBusy}
              onRequestAccess={(kind) => void state.handleGrantAccess(kind)}
            />

            <IndexStorageBreakdownCard
              vectorChunks={state.vectorChunks}
              keywordChunks={state.keywordChunks}
              donut={state.donut}
              extractRows={state.extractRows}
              extractTotalDocuments={state.extractTotalDocuments}
            />
          </div>
        </div>
      ) : null}

      <IndexErrorsCard
        errors={state.status?.lastErrors}
        errorsExpanded={state.errorsExpanded}
        expandedErrors={state.expandedErrors}
        onToggleErrorsExpanded={() => state.setErrorsExpanded((prev) => !prev)}
        onToggleErrorDetail={state.toggleErrorDetail}
      />

      <IndexModals
        pendingPrune={state.pendingPrune}
        pendingRebuild={state.pendingRebuild}
        action={state.action}
        pruneBefore={state.pruneBefore}
        pruneError={state.pruneError}
        resetError={state.resetError}
        onClosePrune={() => {
          if (state.action === "prune") return;
          state.setPendingPrune(false);
        }}
        onCloseRebuild={() => {
          if (state.action === "reset") return;
          state.setPendingRebuild(false);
        }}
        onChangePruneBefore={state.setPruneBefore}
        onConfirmPrune={() => void state.handleConfirmPrune()}
        onConfirmRebuild={() => void state.handleConfirmRebuild()}
      />
    </section>
  );
}
