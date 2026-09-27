// Shared running-run polling for the dashboard chat and sidebar.
// Single module-level poller over the run log so mounted views share one
// interval and one in-flight fetch instead of doubling QPS; live WebSocket
// broadcasts plus parked-flight state stay with callers for immediacy while
// this hook covers reloads, missed sockets, and cross-tab turns.

import { useCallback, useMemo, useSyncExternalStore } from "react";
import {
  listRuns,
  parseRunTimestamp,
  RUN_LOG_POLL_LIMIT,
  RUN_POLL_INTERVAL_MS,
  runningSessionIDsFromRuns,
  type RunLogEntry,
  type ToolAction,
  type ToolResult,
} from "../api";

// Frozen view of one run row shared across subscribers. Deep readonly so a
// mistaken in-place edit fails at compile time instead of throwing from the
// runtime freeze; every level still freezes at publish to guard untyped readers.
export type FrozenToolAction = Omit<Readonly<ToolAction>, "result"> & {
  readonly result?: Readonly<ToolResult> | null;
};
export type FrozenRunLogEntry = Omit<Readonly<RunLogEntry>, "toolActions"> & {
  readonly toolActions?: ReadonlyArray<FrozenToolAction>;
};

type RunsListener = () => void;

// Stable empty snapshot for server rendering so hydration starts detached
// without allocating a fresh array per call, which would read as a change.
// Typed readonly so a stray mutation fails compilation instead of corrupting
// every reader at runtime.
const emptyRunsSnapshot: ReadonlyArray<FrozenRunLogEntry> =
  Object.freeze([]);

// Module-level single flight so two mounted views never double the run-log
// QPS: the chat view (parked-settle reconcile) and the sidebar (row badges)
// subscribe to the same tick and the same promise instead of each owning a
// timer. The cache seeds late subscribers so a remount badges instantly while
// the next tick revalidates. The snapshot reference only changes on publish
// or test reset so concurrent readers never tear; the snapshot and every row
// inside it stay frozen so no caller can mutate shared state in place.
let cachedRuns: ReadonlyArray<FrozenRunLogEntry> = emptyRunsSnapshot;
const listeners = new Set<RunsListener>();
let sharedTimer: ReturnType<typeof setInterval> | null = null;
let sharedInFlight: Promise<void> | null = null;

// Copies one run row plus its nested tool actions so a later publish never
// shares mutable objects with a prior snapshot. Each level freezes on the way
// out, and the readonly result type rejects in-place edits at compile time
// instead of throwing from the runtime freeze under concurrent renders.
function freezeRunCopy(
  run: RunLogEntry | FrozenRunLogEntry,
): FrozenRunLogEntry {
  const actions = run.toolActions?.map(
    (action) =>
      Object.freeze({
        ...action,
        result: action.result
          ? Object.freeze({ ...action.result })
          : action.result,
      }) as FrozenToolAction,
  );
  const frozenActions = actions
    ? (Object.freeze(actions) as ReadonlyArray<FrozenToolAction>)
    : undefined;
  return Object.freeze({
    ...run,
    ...(frozenActions ? { toolActions: frozenActions } : {}),
  }) as FrozenRunLogEntry;
}

// Builds the next frozen snapshot from freshly fetched rows. Outer and nested
// copies keep the previous snapshot detached: readers holding it keep a
// consistent view while new readers see the update.
function freezeRunsSnapshot(
  next: ReadonlyArray<RunLogEntry | FrozenRunLogEntry>,
): ReadonlyArray<FrozenRunLogEntry> {
  return Object.freeze(next.map(freezeRunCopy));
}

// Normalizes one fingerprint field so absent shapes compare stable. Null,
// undefined, and empty string all read as empty while numbers and other
// values stringify, keeping omitted keys aligned with explicit nulls.
function fingerprintField(value: unknown): string {
  if (value === null || value === undefined) return "";
  const text = String(value);
  return text === "" ? "" : text;
}

// Builds the equality key for one frozen snapshot in incoming order with no
// sorting. Each row joins its scalar fields with newlines, each action joins
// its fields with pipes and actions join with pipes inside the row, and rows
// join with double newlines; timestamps normalize to epoch millis through
// the shared parser so both wire shapes compare as one value.
export function runsFingerprint(
  runs: ReadonlyArray<FrozenRunLogEntry>,
): string {
  return runs
    .map((run) => {
      const actions = run.toolActions ?? [];
      const actionKeys = actions.map((action) => {
        const resultContent =
          action.result === null || action.result === undefined
            ? ""
            : fingerprintField(action.result.content);
        let resultError = "";
        if (action.result !== null && action.result !== undefined) {
          if (action.result.isError === true) resultError = "1";
          else if (action.result.isError === false) resultError = "0";
        }
        return [
          fingerprintField(action.callID),
          fingerprintField(action.toolName),
          fingerprintField(action.argumentsJSON),
          fingerprintField(action.roundIndex),
          resultContent,
          resultError,
        ].join("|");
      });
      const actionsSection = actionKeys.join("|");
      return [
        fingerprintField(run.id),
        fingerprintField(run.jobID),
        fingerprintField(run.sessionID),
        fingerprintField(run.kind),
        fingerprintField(run.status),
        fingerprintField(run.message),
        String(parseRunTimestamp(run.timestamp).getTime()),
        fingerprintField(run.response),
        fingerprintField(run.totalTokens),
        fingerprintField(run.durationMs),
        actionsSection,
      ].join("\n");
    })
    .join("\n\n");
}

function publishRuns(
  next: ReadonlyArray<RunLogEntry | FrozenRunLogEntry>,
): void {
  // Freeze first so the fingerprint compares the exact rows that would be
  // published; a matching fingerprint keeps the cached reference with no
  // notify so identical ticks never re-render idle views, while a mismatch
  // swaps before notifying to keep snapshot reads tear-free.
  const frozen = freezeRunsSnapshot(next);
  if (runsFingerprint(frozen) === runsFingerprint(cachedRuns)) {
    return;
  }
  cachedRuns = frozen;
  for (const listener of [...listeners]) {
    try {
      listener();
    } catch {
      // One failing subscriber must never break the rest.
    }
  }
}

function fetchSharedRunsOnce(): Promise<void> {
  if (sharedInFlight) return sharedInFlight;
  const task = listRuns(RUN_LOG_POLL_LIMIT)
    .then((response) => {
      if (response && Array.isArray(response.runs)) {
        publishRuns(response.runs);
      }
    })
    .catch(() => {
      // Polling stays best-effort; live broadcasts keep badges fresh.
    })
    .finally(() => {
      sharedInFlight = null;
    });
  sharedInFlight = task;
  return task;
}

function startSharedPoller(): void {
  if (sharedTimer !== null) return;
  void fetchSharedRunsOnce();
  sharedTimer = setInterval(() => {
    void fetchSharedRunsOnce();
  }, RUN_POLL_INTERVAL_MS);
}

function stopSharedPoller(): void {
  if (sharedTimer !== null) {
    clearInterval(sharedTimer);
    sharedTimer = null;
  }
}

// Test-only reset that drops the shared timer, cache, in-flight fetch, and
// subscribers so suites start from a detached poller without reaching into
// module privates. Gated to the test bundle so production never tears down
// the shared interval; outside tests this is a no-op.
export function resetSharedRunsForTesting(): void {
  if (import.meta.env.MODE !== "test") return;
  if (sharedTimer !== null) {
    clearInterval(sharedTimer);
    sharedTimer = null;
  }
  sharedInFlight = null;
  cachedRuns = emptyRunsSnapshot;
  listeners.clear();
}

// External-store subscription owning the shared poller lifetime. The first
// subscriber starts the single interval plus an immediate single-flight
// revalidate; a late subscriber joins the in-flight fetch instead of firing
// a second request. Removing the last subscriber stops the timer so idle
// routes never poll behind the scenes. Ref counting here keeps StrictMode
// double-mount balanced (subscribe/unsubscribe/subscribe) while the shared
// in-flight promise dedupes the remount fetch.
function subscribeSharedRuns(listener: RunsListener): () => void {
  listeners.add(listener);
  if (listeners.size === 1) {
    startSharedPoller();
  } else {
    void fetchSharedRunsOnce();
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      stopSharedPoller();
    }
  };
}

// Snapshot accessor for the external store. Returns the cached frozen
// reference directly so repeated reads compare stable until the next publish
// swaps it; never copies here because a fresh array per call would read as
// changed on every render and loop.
function getSharedRunsSnapshot(): ReadonlyArray<FrozenRunLogEntry> {
  return cachedRuns;
}

// Server snapshot for rendering without a poller. Always the stable empty
// reference so hydration never observes a client-only fetch as a mismatch.
function getSharedRunsServerSnapshot(): ReadonlyArray<FrozenRunLogEntry> {
  return emptyRunsSnapshot;
}

// Shared run-log poller for running-session badges and parked-settle reconcile.
// Readers subscribe through the external-store hook so concurrent rendering
// stays tear-free under StrictMode; mounting views share one interval at the
// centralized cadence while unmounting the last subscriber stops the timer.
// Live `run_started`/`run_completed` broadcasts stay with callers because the
// socket is already shared and adds no QPS, while parked flights stay with the
// chat view that owns their timelines.
export function useRunningRuns() {
  // Tear-free subscription: React re-reads the cached snapshot after each
  // publish notification instead of each view owning divergent state, so a
  // StrictMode remount reseeds from the same cache without a second fetch.
  const runs = useSyncExternalStore(
    subscribeSharedRuns,
    getSharedRunsSnapshot,
    getSharedRunsServerSnapshot,
  );

  // Normalized owner set derived through the shared helper so live and polled
  // views agree on the single active contract (only `running` lights a badge;
  // parked approvals surface through the approvals icon instead).
  const runningIDs = useMemo(() => runningSessionIDsFromRuns(runs), [runs]);

  const refresh = useCallback(() => {
    void fetchSharedRunsOnce();
  }, []);

  return { runs, runningIDs, refresh };
}
