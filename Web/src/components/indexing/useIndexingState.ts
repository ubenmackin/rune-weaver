// Rune Weaver Dashboard — State, live WebSocket synchronization, and actions hook for IndexingPanel.
import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_EFFORT,
  cancelIndex,
  describeIndexRun,
  formatIndexCount,
  formatToolProgressElapsedMs,
  getIndexStatus,
  getIndexStorage,
  pruneIndex,
  reclaimIndex,
  relativeProgressCurrent,
  requestIndexAccess,
  resetIndex,
  runIndex,
  type IndexExtractStatusCounts,
  type IndexLiveQueueLane,
  type IndexLiveSourceStatus,
  type IndexLiveStatus,
  type IndexReclaimResponse,
  type IndexStatusResponse,
  type IndexStorageResponse,
} from "../../api";
import { useSharedWebSocket } from "../../hooks/useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
  WSToolProgressFrame,
} from "../../hooks/useSharedWebSocket";
import {
  DONUT_RADIUS,
  cachedHasStorage,
  cachedIndexAdoptedMidRun,
  cachedIndexStatus,
  describeAutoStartNotice,
  floorPositive,
  formatIndexAsOf,
  formatIndexLiveHeader,
  formatIndexRate,
  formatIndexReclaimResult,
  indexDonutArcs,
  isIndexProgressFrame,
  resolveDisplayIndexErrors,
  resolveIndexLastRunText,
  resolveIndexPipelineSteps,
  resolveIndexSourceContent,
  resolveIndexStorageBreakdown,
  setCachedHasStorage,
  setCachedIndexAdoptedMidRun,
  setCachedIndexStatus,
} from "./indexHelpers";
import {
  describeEffortReality,
  resolveEffortWorkers,
  resolveMachineCores,
  resolveStatusEffort,
} from "./indexPolicyHelpers";

export function useIndexingState() {
    const [status, setStatus] = useState<(IndexStatusResponse & IndexStorageResponse) | null>(() => cachedIndexStatus);
    // Slow arrival flag for the sizing gate. False until the storage merge
    // lands so `Sizing storage…` shows only while slow is pending, even for an
    // honest empty index whose breakdown stays all zeros.
    const [hasStorage, setHasStorage] = useState(() => cachedHasStorage);
    // Adoption parity mirror for the projection gate below. Initialized from the
    // cache so a remount mid-run keeps suppressing the cached baseline's deltas
    // without waiting for the revalidation poll to answer.
    const [midRunAdopted, setMidRunAdopted] = useState(() => cachedIndexAdoptedMidRun);
    const [error, setError] = useState<string | null>(null);
    const [notice, setNotice] = useState<string | null>(null);
    // One in-flight slot names the action so Run, Prune, Reset, and Reclaim stay mutually exclusive
    // while a request is pending.
    const [action, setAction] = useState<"run" | "prune" | "reset" | "reclaim" | null>(null);
    const actionBusy = action !== null;
    const [cancelBusy, setCancelBusy] = useState(false);
    // Last reclaim outcome for the before/after block. Kept separate from the
    // top notice so both figures stay visible after the status reload replaces
    // the size card, instead of scrolling away with the transient notice.
    const [reclaimResult, setReclaimResult] = useState<IndexReclaimResponse | null>(null);
    // Synchronous guard for the run flight: state commits asynchronously, so a
    // double-click before re-render would otherwise start two runs. The ref flips
    // immediately and the state mirrors it for rendering.
    const runActiveRef = useRef(false);
    const [runActive, setRunActive] = useState(false);
    // Cancelling window after a successful cancel request: the engine has been asked to stop but the
    // run has not settled yet.
    const cancellingRef = useRef(false);
    const [cancelling, setCancelling] = useState(false);
    const [reconnecting, setReconnecting] = useState(false);
    const [reconnectDismissed, setReconnectDismissed] = useState(false);
    // Non-blocking destructive confirmations: prune and reset each render a
    // true modal so stored memory is never cleared by an accidental click. Each
    // modal carries its own description, so the button row stays label-only.
    const [pendingPrune, setPendingPrune] = useState(false);
    const [pendingRebuild, setPendingRebuild] = useState(false);
    // Explicit prune cutoff chosen in the confirm modal. Kept as the raw date
    // input value so an empty choice blocks the request instead of falling back
    // to now and silently clearing the store.
    const [pruneBefore, setPruneBefore] = useState<string>("");
    const [pruneError, setPruneError] = useState<string | null>(null);
    // Reset refusal surfaced inside the confirm modal, mirroring the prune
    // error slot so a confirm blocked by an in-flight run explains itself
    // instead of landing as a dead click.
    const [resetError, setResetError] = useState<string | null>(null);
    // Last-errors display state: the block stays collapsed behind its header toggle so a noisy pass
    // never pushes surrounding content, plus per-row expansion for long lines.
    const [errorsExpanded, setErrorsExpanded] = useState(false);
    const [expandedErrors, setExpandedErrors] = useState<Set<string>>(
      () => new Set<string>(),
    );
    // Overlapping loads commit newest-wins under this generation counter; stat cards project
    // preRunBaseline + inRunLiveDelta so Documents/Chunks move mid-run and only Size on disk
    // stays frozen until run_completed.
    const loadGenerationRef = useRef(0);
    const [accessBusy, setAccessBusy] = useState<Record<string, boolean>>({});
  
    // True whenever the engine reports a run in flight or this panel started one, so the in-run poll
    // stays active and Run stays disabled during a real run.
    const progressActive = runActive || status?.running === true;
    const indexingEnabled = status?.enabled === true;
    // Mirrors the engine running flag for the broadcast consumer without
    // re-subscribing the shared socket on every status poll.
    const statusRunningRef = useRef(false);
    // Ref mirror of the committed status so async loaders can decide
    // freeze-vs-adopt from current truth without re-subscribing effects or
    // widening callback dependencies into a refetch loop.
    const statusRef = useRef(status);
    useEffect(() => {
      statusRef.current = status;
      statusRunningRef.current = status?.running === true;
    }, [status]);
    // Polled live snapshot for the grep-style block. Null when idle; the block
    // mounts only from this, never from frame parsing, and unmounts on settle
    // when the engine clears it. The Status pill owns the Running indicator.
    const live: IndexLiveStatus | null = status?.live ?? null;
    // Sanitized relative tail for the single file line. Defense-in-depth mirrors
    // the ToolProgress contract so a handcrafted payload can never render an
    // absolute path the engine keeps private.
    const liveCurrent = live ? relativeProgressCurrent(live.current) : null;
  
    // In-flight projections: a baseline adopted before the run adds the run's cumulative
    // live deltas on top, while a snapshot adopted mid-run already holds those commits,
    // so each projection waits for the settle instead of double-counting in-flight work.
    const liveIndexedDelta = !midRunAdopted && live ? floorPositive(live.indexed) : 0;
    const liveVectorDelta = !midRunAdopted && live ? floorPositive(live.vectorChunks) : 0;
    const liveKeywordDelta = !midRunAdopted && live ? floorPositive(live.keywordChunks) : 0;
    const liveChunksDelta = liveVectorDelta + liveKeywordDelta;
    const displayDocuments = floorPositive(status?.documents) + liveIndexedDelta;
    const vectorChunks = floorPositive(status?.vectorChunks) + liveVectorDelta;
    const keywordChunks = floorPositive(status?.keywordChunks) + liveKeywordDelta;
    const displayChunks = floorPositive(status?.chunks) + liveChunksDelta;
    const donut = indexDonutArcs(vectorChunks, keywordChunks, DONUT_RADIUS);
    // Real per-source totals for the bars, in canonical Files/Mail/Messages/Calendars/Reminders
    // order; older engines without the aggregates degrade to zeroed rows, and only a baseline
    // adopted before the run projects live per-source deltas on top of the settled totals.
    const sourceContent = resolveIndexSourceContent(status, midRunAdopted ? null : live);
    const pipelineSteps = resolveIndexPipelineSteps(live, cancelling);
    const liveQueues: IndexLiveQueueLane[] = live?.queues ?? [];
    const liveSources: IndexLiveSourceStatus[] = live?.sources ?? [];
    // Displayed-total denominator for the source chart: every visible row shares
    // this sum so each bar reads as its honest fraction of the index.
    const sourceTotalDocuments = sourceContent.reduce((sum, row) => sum + row.documents, 0);
    // Extraction-outcome breakdown for the second chart, largest bucket first so the dominant outcome
    // leads the list while every bar still scales by the displayed total.
    const extractRows: IndexExtractStatusCounts[] = [...(status?.byExtractStatus ?? [])]
      .map((row) => ({ ...row, documents: floorPositive(row.documents) }))
      .sort((left, right) => right.documents - left.documents);
    // Displayed-total denominator for the extraction chart: the sum across the
    // outcome rows above, so labels and widths agree with the source chart rule.
    const extractTotalDocuments = extractRows.reduce((sum, row) => sum + row.documents, 0);
    // Honest on-disk storage: the database file plus the write-ahead log as the primary figure, the
    // text/vector/FTS/free rows as the breakdown, and the content total as the secondary detail.
    const storage = resolveIndexStorageBreakdown(status, hasStorage);
    const storageBreakdownTotal = storage.text + storage.vector + storage.fts + storage.free;
    // Resolved effort reality for the status pane: the canonical nested `effort` block when present,
    // otherwise the local mapping against the machine cores so the line still reflects the hardware.
    const statusEffort = resolveStatusEffort(status);
    const statusEffortPreset = statusEffort.preset;
    const statusCoreCount = resolveMachineCores(statusEffort.coreCount);
    const statusResolvedWorkers =
      statusEffort.resolvedWorkers ??
      (statusEffortPreset && statusCoreCount != null
        ? resolveEffortWorkers(statusEffortPreset, statusCoreCount, null)
        : null);
    const hasStatusEffort =
      statusEffortPreset != null ||
      statusEffort.resolvedWorkers != null ||
      statusEffort.coreCount != null;
    const statusEffortReality = hasStatusEffort
      ? describeEffortReality(
          statusEffortPreset ?? DEFAULT_INDEX_EFFORT,
          statusResolvedWorkers,
          statusCoreCount,
        )
      : null;
    // Reclaim result copy for the dedicated before/after block, kept beside the
    // transient notice so both figures survive the post-reclaim status reload.
    const reclaimSummary = formatIndexReclaimResult(reclaimResult);
  
    /// Reloads index status in two phases and commits the last-good snapshot to the module cache.
    /// Ownership: sole owner of fetch plus cache commit; phase 1 owns fast counts, phase 2 owns slow byte totals.
    /// Edge cases: fast success caches and paints before slow resolves; slow merge keeps fast counts and never clears them while in flight; slow failure leaves phase-1 state plus the error slot untouched and never nulls status; overlapping polls keep only the newest merge via the generation counter.
    const loadStatus = useCallback(async () => {
      const generation = loadGenerationRef.current + 1;
      loadGenerationRef.current = generation;
      setError(null);
      let fast: IndexStatusResponse | null = null;
      // Baseline hold gate: while a fresh snapshot reports a run in flight, the baseline committed
      // snapshot stays anchored and live deltas project on top of it, preventing expensive storage
      // byte queries or overlapping polls from thrashing SQLite mid-run.
      let frozeCommitted = false;
      try {
        const response = await getIndexStatus();
        fast = response;
        if (statusRef.current != null && response.running === true) {
          frozeCommitted = true;
          const frozen = statusRef.current;
          const merged: IndexStatusResponse & IndexStorageResponse = {
            ...frozen,
            running: response.running,
            live: response.live,
          };
          setCachedIndexStatus(merged);
          setStatus(merged);
          // The slow sizing gate stays untouched: frozen cards keep their
          // storage state instead of flashing the sizing copy mid-run.
        } else {
          setCachedIndexStatus(response);
          // Fast resets the slow arrival gate so sizing shows until the fresh
          // storage merge lands for this generation.
          setCachedHasStorage(false);
          setStatus(response);
          setHasStorage(false);
          // An adopt while a run is already in flight anchors a baseline that
          // carries the run's commits; a settled adopt is self-consistent.
          setCachedIndexAdoptedMidRun(response.running === true);
          setMidRunAdopted(response.running === true);
        }
      } catch (failure) {
        // Only the newest poll owns the error slot so a stale rejection never
        // clears a newer panel that already painted.
        if (loadGenerationRef.current !== generation) return null;
        setError(
          failure instanceof ApiError ? failure.message : "Failed to load index status",
        );
        return null;
      }
      // Phase 2 fires without awaiting paint so the cold mount paints counts, pills, and the last-run
      // strip immediately. The generation guard keeps only the newest storage answer when polls
      // overlap.
      void (async () => {
        if (frozeCommitted) return;
        try {
          const s = await getIndexStorage();
          if (loadGenerationRef.current !== generation) return;
          setStatus((prev) => {
            if (prev == null) return prev;
            const merged: IndexStatusResponse & IndexStorageResponse = {
              ...prev,
              bytes: s.bytes ?? prev.bytes,
              textBytes: s.textBytes ?? prev.textBytes,
              vectorBytes: s.vectorBytes ?? prev.vectorBytes,
              ftsBytes: s.ftsBytes ?? prev.ftsBytes,
              freeBytes: s.freeBytes ?? prev.freeBytes,
              dbFileBytes: s.dbFileBytes ?? prev.dbFileBytes,
              walBytes: s.walBytes ?? prev.walBytes,
              contentBytes: s.contentBytes ?? prev.contentBytes,
              bySource: s.bySource != null && s.bySource.length > 0 ? s.bySource : prev.bySource,
            };
            // Recommit the module cache so a tab switch paints merged sizes instantly.
            setCachedIndexStatus(merged);
            return merged;
          });
          // Slow arrival flips the sizing gate so an honest empty index hides
          // the sizing copy once slow lands instead of gating on non-zero.
          setCachedHasStorage(true);
          setHasStorage(true);
        } catch {
          // Storage failure leaves phase-1 state plus the existing error slot
          // untouched and never nulls status.
        }
      })();
      return fast;
    }, []);
  
    // Live-only poll while a run is in flight: fetches status and adopts the live snapshot plus
    // running flag so live count deltas project smoothly while on-disk byte sizing stays deferred.
    // A cold-boot adopt records mid-run parity exactly like loadStatus does.
    const loadLiveOnly = useCallback(async () => {
      try {
        const fresh = await getIndexStatus();
        // statusRef mirrors committed truth: null only before the first commit,
        // matching the updater's prev == null branch.
        const coldBoot = statusRef.current == null;
        setStatus((prev) => {
          if (prev == null) {
            setCachedIndexStatus(fresh);
            setCachedIndexAdoptedMidRun(fresh.running === true);
            return fresh;
          }
          const merged: IndexStatusResponse & IndexStorageResponse = {
            ...prev,
            running: fresh.running,
            live: fresh.live,
          };
          setCachedIndexStatus(merged);
          return merged;
        });
        if (coldBoot && fresh.running === true) {
          setMidRunAdopted(true);
        }
      } catch {
        // Live-only failure leaves the frozen cards plus the existing error
        // slot untouched and never nulls status.
      }
    }, []);
  
    useEffect(() => {
      void loadStatus();
    }, [loadStatus]);
  
    // Live broadcast consumer: run_completed reloads settled counts + storage atomically with
    // no manual Refresh control, while `tool_progress` and run_started refresh the live snapshot
    // — numbers always come from the polled status live snapshot, never from frame parsing.
    const handleIndexBroadcast = useCallback(
      (frame: WSIncomingFrame) => {
        const frameType = (frame as WSGenericFrame).type;
        if (frameType === "run_started" || frameType === "run_completed") {
          const nested = (frame as WSGenericFrame).run as
            | { kind?: unknown; message?: unknown; response?: unknown }
            | undefined;
          const isIndexKind =
            typeof nested?.kind === "string" && nested.kind === "index";
          if (frameType === "run_started" && isIndexKind) {
            if (!runActiveRef.current && !cancellingRef.current) {
              const notice = describeAutoStartNotice({
                message: nested.message,
                response: nested.response,
              });
              if (notice) {
                setNotice(notice);
              }
            }
          }
          if (frameType === "run_completed" && isIndexKind) {
            runActiveRef.current = false;
            setRunActive(false);
            const wasCancelling = cancellingRef.current;
            cancellingRef.current = false;
            setCancelling(false);
            void loadStatus().then((fresh) => {
              if (fresh?.lastRun) {
                setNotice(describeIndexRun(fresh.lastRun));
              } else if (wasCancelling) {
                setNotice(
                  "Last run cancelled · Committed work is kept and the next run resumes from there.",
                );
              }
            });
            return;
          }
          // A run_started frame refreshes the live snapshot while storage byte
          // sizing waits for run_completed below.
          if (isIndexKind) {
            void loadLiveOnly();
          }
          return;
        }
        if (frameType !== "tool_progress") return;
        const progress = frame as WSToolProgressFrame;
        if (
          !isIndexProgressFrame(
            progress,
            runActiveRef.current || cancellingRef.current || statusRunningRef.current,
          )
        )
          return;
        // Poll-now trigger for the live snapshot: live numbers and count deltas
        // render from status.live without re-running expensive storage queries.
        void loadLiveOnly();
      },
      [loadStatus, loadLiveOnly],
    );
  
    const handleWSClose = useCallback(() => {
      setReconnecting(true);
      setReconnectDismissed(false);
    }, []);
  
    const handleWSOpen = useCallback(() => {
      setReconnecting(false);
      void loadStatus();
    }, [loadStatus]);
  
    const { retryConnection } = useSharedWebSocket(
      handleIndexBroadcast,
      handleWSClose,
      handleWSOpen,
    );
  
    const handleRetryConnection = useCallback(() => {
      setReconnectDismissed(false);
      retryConnection();
    }, [retryConnection]);
  
    // Clears the local run flight once the engine reports no run in flight, so a run started from
    // another tab still settles the panel's busy state.
    useEffect(() => {
      if (status?.running !== false) return;
      // Capture locality before clearing: a run this panel started resolves
      // through its awaiting request with full counts, so only a remote run
      // refreshes its notice here from the shared strip entry.
      const wasLocalRun = runActiveRef.current;
      if (wasLocalRun) {
        runActiveRef.current = false;
        setRunActive(false);
      }
      if (!cancellingRef.current) return;
      if (!wasLocalRun) {
        if (status?.lastRun) {
          setNotice(describeIndexRun(status.lastRun));
        } else {
          setNotice(
            "Last run cancelled · Committed work is kept and the next run resumes from there.",
          );
        }
      }
      cancellingRef.current = false;
      setCancelling(false);
    }, [status?.running, status?.lastRun]);
  
    // Polls the live snapshot every ~2s while progress is active or cancelling is open,
    // keeping the live pipeline card and projected count deltas updated without storage query thrash.
    useEffect(() => {
      if (!progressActive && !cancelling) return;
      const timer = setInterval(() => {
        if (typeof document !== "undefined" && document.hidden) return;
        void loadLiveOnly();
      }, 2000);
      return () => clearInterval(timer);
    }, [progressActive, cancelling, loadLiveOnly]);
  
    // Starts an on-demand run asynchronously. The start request returns immediately (~5ms) without
    // holding an idle HTTP socket open over long-running passes. Resolves true only on actual start;
    // guards, skips, and failures resolve false so the nudge stays.
    const handleRun = async (): Promise<boolean> => {
      if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) return false;
      runActiveRef.current = true;
      setRunActive(true);
      setAction("run");
      setError(null);
      setNotice(null);
      try {
        const startResult = await runIndex();
        if (startResult.status === "skipped") {
          setNotice(startResult.skippedReason || "Index run was skipped.");
          runActiveRef.current = false;
          setRunActive(false);
          await loadStatus();
          return false;
        }
        setNotice("Manual run started.");
        if (cancellingRef.current) {
          cancellingRef.current = false;
          setCancelling(false);
        }
        await loadStatus();
        return true;
      } catch (failure) {
        // If a network blip occurred but the run is actually underway on the server,
        // probe status so we stay in the active tracking flow instead of displaying an error.
        const fresh = await loadStatus().catch(() => null);
        if (fresh?.running !== true) {
          setError(failure instanceof ApiError ? failure.message : "Index run failed");
          runActiveRef.current = false;
          setRunActive(false);
          return false;
        }
        return true;
      } finally {
        setAction(null);
      }
    };
  
    // Asks the engine to stop an in-flight run, then holds the cancelling window until the terminal
    // broadcast or the status probe reports a settled run.
    const handleCancel = async () => {
      if (cancelBusy || cancellingRef.current) return;
      if (action === "prune" || action === "reset" || action === "reclaim") return;
      setCancelBusy(true);
      setError(null);
      try {
        const response = await cancelIndex();
        if (response?.cancelled) {
          // Enter the cancelling window: the pill flips to Cancelling, both Run
          // and Cancel stay disabled, and the kept-work notice lands only once
          // the run actually settles instead of on the request itself.
          cancellingRef.current = true;
          setCancelling(true);
        } else {
          setNotice("No index run was in flight.");
        }
        await loadStatus();
      } catch (failure) {
        setError(
          failure instanceof ApiError ? failure.message : "Failed to cancel index run",
        );
      } finally {
        setCancelBusy(false);
      }
    };
  
    // Compacts the index database, then shows the before and after on-disk figures so the reclaimed
    // delta reads without reopening the size card.
    const handleGrantAccess = async (kind: string) => {
      if (accessBusy[kind]) return;
      setAccessBusy((prev) => ({ ...prev, [kind]: true }));
      try {
        await requestIndexAccess(kind);
        await loadStatus();
      } catch {
        // Keep the Grant affordance so the owner can retry explicitly.
      } finally {
        setAccessBusy((prev) => ({ ...prev, [kind]: false }));
      }
    };
  
    const handleReclaim = async () => {
      if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) return;
      setAction("reclaim");
      setError(null);
      setNotice(null);
      try {
        const response = await reclaimIndex();
        setReclaimResult(response);
        const summary = formatIndexReclaimResult(response);
        if (summary) setNotice(summary);
        await loadStatus();
      } catch (failure) {
        setError(failure instanceof ApiError ? failure.message : "Failed to reclaim index space");
      } finally {
        setAction(null);
      }
    };
  
    const handleConfirmPrune = async () => {
      if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) {
        setPruneError("An index run is in flight. Wait for it to settle before pruning.");
        return;
      }
      const trimmed = pruneBefore.trim();
      if (!trimmed) {
        setPruneError("Choose a cutoff date before pruning.");
        return;
      }
      // The date input yields a calendar day with no zone; build local midnight
      // from its parts so toISOString ships the operator's day instead of a
      // UTC-midnight value shifted by the timezone offset.
      const dateParts = trimmed.split("-").map(Number);
      let cutoff: Date;
      if (
        dateParts.length === 3 &&
        dateParts.every((part) => Number.isFinite(part)) &&
        Number.isInteger(dateParts[0]) &&
        Number.isInteger(dateParts[1]) &&
        Number.isInteger(dateParts[2])
      ) {
        const [year, month, day] = dateParts as [number, number, number];
        cutoff = new Date(year, month - 1, day);
        if (
          Number.isNaN(cutoff.getTime()) ||
          cutoff.getFullYear() !== year ||
          cutoff.getMonth() !== month - 1 ||
          cutoff.getDate() !== day
        ) {
          setPruneError("Choose a valid cutoff date before pruning.");
          return;
        }
      } else {
        cutoff = new Date(trimmed);
        if (Number.isNaN(cutoff.getTime())) {
          setPruneError("Choose a valid cutoff date before pruning.");
          return;
        }
      }
      setPruneError(null);
      setPendingPrune(false);
      setAction("prune");
      setError(null);
      setNotice(null);
      try {
        const response = await pruneIndex(cutoff.toISOString());
        setNotice(
          `Pruned ${formatIndexCount(response?.removed ?? 0)} document${response?.removed === 1 ? "" : "s"} indexed before ${formatIndexAsOf(response?.before)}.`,
        );
        await loadStatus();
      } catch (failure) {
        setError(failure instanceof ApiError ? failure.message : "Failed to prune the index");
      } finally {
        setAction(null);
      }
    };
  
    const handleConfirmRebuild = async () => {
      if (actionBusy || cancelBusy || cancellingRef.current || runActiveRef.current || statusRunningRef.current) {
        setResetError("An index run is in flight. Wait for it to settle before resetting.");
        return;
      }
      setResetError(null);
      setPendingRebuild(false);
      setAction("reset");
      setError(null);
      setNotice(null);
      try {
        await resetIndex();
        setNotice("Index cleared. Run Rebuild to re-index from scratch.");
        await loadStatus();
      } catch (failure) {
        setError(failure instanceof ApiError ? failure.message : "Failed to reset the index");
      } finally {
        setAction(null);
      }
    };
  
    // The live pipeline block mounts only from the polled live snapshot — or during the cancelling
    // window — and unmounts fully on settle with no persistence.
    const showLiveBlock = live != null || cancelling;
    // Line 1 without any pill: trigger label plus stage-aware title with counts, rate, and elapsed
    // while the snapshot is present, and Cancelling… during the stop window. Never renders a Running
    // fallback.
    const cancellingRate = live
      ? formatIndexRate(
          typeof live.rate === "number" ? live.rate : null,
          typeof live.elapsedMs === "number" ? live.elapsedMs : 0,
        )
      : null;
    const cancellingRatePart = cancellingRate ? ` · ${cancellingRate}` : "";
    const liveHeaderText = cancelling
      ? live
        ? `Cancelling… ${formatIndexCount(live.scanned)} scanned · ${formatIndexCount(live.indexed)} indexed${cancellingRatePart} · ${formatToolProgressElapsedMs(typeof live.elapsedMs === "number" ? live.elapsedMs : 0)}`
        : "Cancelling…"
      : (formatIndexLiveHeader(live) ?? "");
    // Fresh stores have no last run yet: while the first pass is in flight the live block already
    // proves liveness, so the last-run line names it instead of reading as an empty history.
    const lastRunText = resolveIndexLastRunText(
      status?.lastRun ?? null,
      progressActive || showLiveBlock || cancelling,
    );
    // Last-errors card projection: deduped lines with the raw Full Disk Access bullet suppressed
    // whenever the guided onboarding renders, since the guidance is the formatted form of that
  // Prunes the expanded set to the current display list so a failure that
  // ages out of lastErrors cannot keep its full text alive in state, bounding
  // the set to the visible rows instead of every error ever seen.
  useEffect(() => {
    const allowed = new Set(resolveDisplayIndexErrors(status?.lastErrors));
    setExpandedErrors((previous) => {
      if (previous.size === 0) return previous;
      let pruned = false;
      for (const entry of previous) {
        if (!allowed.has(entry)) {
          pruned = true;
          break;
        }
      }
      if (!pruned) return previous;
      const next = new Set<string>();
      for (const entry of previous) {
        if (allowed.has(entry)) next.add(entry);
      }
      return next;
    });
  }, [status?.lastErrors]);

  const toggleErrorDetail = useCallback((detail: string) => {
    setExpandedErrors((previous) => {
      const next = new Set(previous);
      if (next.has(detail)) {
        next.delete(detail);
      } else {
        next.add(detail);
      }
      return next;
    });
  }, []);

  return {
    status,
    hasStorage,
    error,
    notice,
    action,
    actionBusy,
    cancelBusy,
    cancelling,
    reclaimResult,
    reclaimSummary,
    runActive,
    indexingEnabled,
    progressActive,
    progressPercent: null,
    showLiveBlock,
    liveHeaderText,
    liveHeader: liveHeaderText,
    liveCurrent,
    liveElapsed:
      live && typeof live.elapsedMs === "number"
        ? formatToolProgressElapsedMs(live.elapsedMs)
        : null,
    liveRate: cancellingRate,
    pipelineSteps,
    liveQueues,
    liveSources,
    reconnecting,
    reconnectDismissed,
    pendingPrune,
    pendingRebuild,
    pruneBefore,
    pruneError,
    resetError,
    errorsExpanded,
    expandedErrors,
    accessBusy,
    live,
    sourceContent,
    sourceTotalDocuments,
    extractRows,
    extractTotalDocuments,
    vectorChunks,
    keywordChunks,
    displayDocuments,
    liveIndexedDelta,
    displayChunks,
    donut,
    storage,
    storageBreakdownTotal,
    effortReality: statusEffortReality,
    statusEffortReality,
    lastRunText,
    handleRun,
    handleCancel,
    handleRetryConnection,
    handleGrantAccess,
    handleReclaim,
    handleConfirmPrune,
    handleConfirmRebuild,
    toggleErrorDetail,
    setReconnectDismissed,
    setErrorsExpanded,
    setPendingPrune,
    setPendingRebuild,
    setPruneBefore,
  };
}
