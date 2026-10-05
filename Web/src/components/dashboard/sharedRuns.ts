// Rune Weaver Dashboard — Shared Recent Runs Fetcher.
//
// Purpose: collapse the Dashboard's duplicate `GET /runs` polling into a single
// network request shared by the Working Right Now stream and the Recent Reports
// cards, so a cold Dashboard mount issues one fetch instead of two.
//
// Scope: read-only recent-run payloads fetched through the existing `listRuns`
// API helper. Filtering stays in each widget (active versus terminal runs), and
// this module never interprets run status itself.
//
// Architectural role: single-flight cache sitting between the run-log REST
// endpoint and the dashboard widgets. The widgets keep their own filtered state
// while this module owns fetch timing, so polling cadence and WebSocket-driven
// refetches agree on one payload instead of drifting per call site.

import { listRuns, type RunLogEntry } from "../../api";

// Freshness window for the shared payload. Five seconds keeps concurrent mounts
// and WebSocket-driven refetches on one response while staying short enough
// that a newly settled run appears on the next poll tick rather than sticking
// to a stale snapshot.
const SHARED_RUNS_TTL_MS = 5000;

// Single cached payload plus the limit it was fetched with and the wall-clock
// time it completed. The cache key is the one max limit: a smaller caller slices
// from a larger payload, while a larger caller refetches when the cached limit
// cannot satisfy it.
let cachedRuns: RunLogEntry[] | null = null;
let cachedLimit = 0;
let cachedAtMs = 0;

// One in-flight fetch shared by concurrent callers. The accompanying limit
// tracks the largest request seen while the fetch is pending so synchronously
// co-mounted widgets agree on one `GET /runs` sized for the hungriest caller.
// The dispatched pair records the limit the request was actually built with
// plus whether the network has started: a caller arriving after dispatch that
// wants more rows than the dispatched limit can no longer widen the request,
// so it awaits the flight and refetches once instead of slicing short.
let inFlight: Promise<RunLogEntry[]> | null = null;
let inFlightLimit = 0;
let inFlightDispatched = false;
let inFlightEffectiveLimit = 0;

// Resets the cached payload and any pending flight. Test-only: inert in
// production builds so prod callers can never wipe the shared payload; Vitest
// runs with MODE=test, where the reset stays live between cases so one case's
// payload cannot leak into the next through the module-level cache.
export function clearSharedRecentRunsForTesting(): void {
  if (import.meta.env.MODE !== "test") return;
  cachedRuns = null;
  cachedLimit = 0;
  cachedAtMs = 0;
  inFlight = null;
  inFlightLimit = 0;
  inFlightDispatched = false;
  inFlightEffectiveLimit = 0;
}

// Returns the most recent runs, sliced to the caller's limit. Concurrent calls
// collapse onto one `listRuns` sized with the larger limit; fresh-cache calls
// return a slice with zero network; failures never populate the cache and
// propagate to every awaiting caller. Callers reacting to a `run_started` or
// `run_completed` frame pass `forceRefresh` to bypass the freshness window so
// a newly settled run appears now instead of at the next poll tick.
export function getSharedRecentRuns(
  limit: number,
  options?: { forceRefresh?: boolean },
): Promise<RunLogEntry[]> {
  // Normalize once so fractional or out-of-range limits slice deterministically
  // instead of varying the request URL per caller.
  const requested = Number.isFinite(limit) ? Math.max(0, Math.floor(limit)) : 0;
  const forceRefresh = options?.forceRefresh === true;
  const now = Date.now();

  // Fresh cache with a sufficient limit serves immediately. An insufficient
  // limit falls through to a refetch: slicing a smaller payload would silently
  // short a caller that asked for more rows than were ever fetched.
  if (!forceRefresh && cachedRuns !== null && now - cachedAtMs < SHARED_RUNS_TTL_MS && cachedLimit >= requested) {
    return Promise.resolve(cachedRuns.slice(0, requested));
  }

  // A pending fetch absorbs this caller. Bumping the tracked limit before the
  // network starts lets a synchronously co-mounted widget that wants more rows
  // widen the single request; a caller arriving after the request dispatched
  // joins the flight and, when it wants more rows than the dispatched limit
  // holds, refetches once the flight settles rather than slicing short with
  // no error.
  if (inFlight !== null) {
    if (!inFlightDispatched && requested > inFlightLimit) {
      inFlightLimit = requested;
    }
    if (inFlightDispatched && requested > inFlightEffectiveLimit) {
      return inFlight.then(() => getSharedRecentRuns(requested));
    }
    return inFlight.then((runs) => runs.slice(0, requested));
  }

  // Cold or stale path: open the single flight. The fetch defers its network
  // start by one microtask so a second widget mounting in the same commit can
  // widen the limit before the URL is built; without that yield the first
  // mount's limit would win and the hungrier sibling would under-fetch.
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

  inFlight = flight;
  // Clear the flight marker on settle without swallowing the outcome: failures
  // must stay uncached and still reject for every attached caller, while the
  // next call after a failure starts a fresh request.
  const clearFlight = () => {
    if (inFlight === flight) {
      inFlight = null;
      inFlightDispatched = false;
      inFlightEffectiveLimit = 0;
    }
  };
  flight.then(clearFlight, clearFlight);

  return flight.then((runs) => runs.slice(0, requested));
}
