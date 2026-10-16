// Rune Weaver Dashboard — Shared Recent Runs Fetcher.

import { listRuns, type RunLogEntry } from "../../api";

// Single run-title fallback shared by the Working Right Now stream, the Recent Reports cards, and
// the dashboard greeting caption: message first (trimmed), then goal/job ownership, then a short id.
export function getSharedRunTitle(run: RunLogEntry): string {
  if (run.message && run.message.trim()) return run.message.trim();
  if (run.goalId) return `Goal Execution: ${run.goalId}`;
  if (run.jobID) return `Scheduled Job: ${run.jobID}`;
  return `Interactive Task ${run.id.slice(0, 8)}`;
}

// Freshness window for the shared payload.
const SHARED_RUNS_TTL_MS = 5000;

// Single cached payload plus the limit it was fetched with and the wall-clock time it completed.
let cachedRuns: RunLogEntry[] | null = null;
let cachedLimit = 0;
let cachedAtMs = 0;

// One in-flight fetch shared by concurrent callers.
let inFlight: Promise<RunLogEntry[]> | null = null;
let inFlightLimit = 0;
let inFlightDispatched = false;
let inFlightEffectiveLimit = 0;

// One queued fresh fetch scheduled when a caller asks for `forceRefresh` while a flight is already
// in the network (`inFlightDispatched === true`).
let nextFlight: Promise<RunLogEntry[]> | null = null;
let nextFlightLimit = 0;

// Resets the cached payload and any pending flight.
export function clearSharedRecentRunsForTesting(): void {
  if (import.meta.env.MODE !== "test") return;
  cachedRuns = null;
  cachedLimit = 0;
  cachedAtMs = 0;
  inFlight = null;
  inFlightLimit = 0;
  inFlightDispatched = false;
  inFlightEffectiveLimit = 0;
  nextFlight = null;
  nextFlightLimit = 0;
}

// Returns the most recent runs, sliced to the caller's limit.
export function getSharedRecentRuns(
  limit: number,
  options?: { forceRefresh?: boolean },
): Promise<RunLogEntry[]> {
  // Normalize once so fractional or out-of-range limits slice deterministically
  // instead of varying the request URL per caller.
  const requested = Number.isFinite(limit) ? Math.max(0, Math.floor(limit)) : 0;
  const forceRefresh = options?.forceRefresh === true;
  const now = Date.now();

  // Fresh cache with a sufficient limit serves immediately unless a forced refresh was requested or
  // a forced refresh flight is already queued.
  if (
    !forceRefresh &&
    nextFlight === null &&
    cachedRuns !== null &&
    now - cachedAtMs < SHARED_RUNS_TTL_MS &&
    cachedLimit >= requested
  ) {
    return Promise.resolve(cachedRuns.slice(0, requested));
  }

  // If a forced refresh is already scheduled for after the current flight, join it.
  if (nextFlight !== null) {
    if (requested > nextFlightLimit) {
      nextFlightLimit = requested;
    }
    return nextFlight.then((runs) => runs.slice(0, requested));
  }

  // A pending fetch absorbs this caller if not dispatched yet or if no forceRefresh is requested.
  // Bumping the tracked limit before the network starts lets a synchronously co-mounted widget
  // that wants more rows widen the single request.
  if (inFlight !== null) {
    if (!inFlightDispatched && requested > inFlightLimit) {
      inFlightLimit = requested;
    }

    if (forceRefresh && inFlightDispatched) {
      // The current in-flight request was already dispatched before this forceRefresh
      // was requested. Queue a fresh fetch to run as soon as inFlight settles, so this
      // caller receives post-event data rather than the pre-event response.
      nextFlightLimit = Math.max(nextFlightLimit, requested);
      const currentFlight = inFlight;
      const queued = (async (): Promise<RunLogEntry[]> => {
        try {
          await currentFlight;
        } catch {
          // Failure of previous in-flight request does not cancel the forced retry.
        }
        const targetLimit = nextFlightLimit;
        nextFlight = null;
        nextFlightLimit = 0;
        return getSharedRecentRuns(targetLimit, { forceRefresh: true });
      })();
      nextFlight = queued;
      const clearNext = () => {
        if (nextFlight === queued) {
          nextFlight = null;
          nextFlightLimit = 0;
        }
      };
      queued.then(clearNext, clearNext);
      return queued.then((runs) => runs.slice(0, requested));
    }

    if (inFlightDispatched && requested > inFlightEffectiveLimit) {
      return inFlight.then(() => getSharedRecentRuns(requested));
    }
    return inFlight.then((runs) => runs.slice(0, requested));
  }

  // Cold or stale path: open the single flight.
  inFlightLimit = requested;
  inFlightDispatched = false;
  inFlightEffectiveLimit = 0;
  const flight = (async (): Promise<RunLogEntry[]> => {
    await Promise.resolve();
    const effectiveLimit = inFlightLimit;
    inFlightEffectiveLimit = effectiveLimit;
    inFlightDispatched = true;
    const res = await listRuns(effectiveLimit);
    // Guard against nullish payloads the same way every run-history surface
    // does, so a malformed response caches as an empty list rather than
    // crashing every slicer awaiting the flight.
    const runs = res.runs ?? [];
    cachedRuns = runs;
    cachedLimit = effectiveLimit;
    cachedAtMs = Date.now();
    return runs;
  })();

  const clearFlight = () => {
    if (inFlight === settledPromise) {
      inFlight = null;
      inFlightDispatched = false;
      inFlightEffectiveLimit = 0;
    }
  };
  const settledPromise = flight.finally(clearFlight);
  inFlight = settledPromise;

  return settledPromise.then((runs) => runs.slice(0, requested));
}
