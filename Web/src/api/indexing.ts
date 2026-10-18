// Rune Weaver Dashboard — Background indexer API endpoints.
import { fetchJson } from "./http";
import type {
  IndexStatusResponse,
  IndexRunResponse,
  IndexCancelResponse,
  IndexStorageResponse,
  IndexPruneResponse,
  IndexResetResponse,
  IndexReclaimResponse,
} from "./indexing-types";


// Reads the local index status: counts, bytes, per-source enablement, recent failures, the last
// watermark, and live run state.
export function getIndexStatus(): Promise<IndexStatusResponse> {
  return fetchJson<IndexStatusResponse>("/index/status");
}

// Reads the slow index storage breakdown: byte-exact totals plus per-source bytes from the
// TTL-shared slow pass. A missing store reports a zeroed payload rather than failing.
export function getIndexStorage(): Promise<IndexStorageResponse> {
  return fetchJson<IndexStorageResponse>("/index/storage");
}



// Starts an on-demand index run and awaits its terminal summary. Progress rides
// the shared `tool_progress` WebSocket frames while the run is in flight.
export function runIndex(): Promise<IndexRunResponse> {
  return fetchJson<IndexRunResponse>("/index/run", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Asks an in-flight run to stop at its next safe point. The boolean reports
// whether a run was actually in flight when cancellation was requested.
export function cancelIndex(): Promise<IndexCancelResponse> {
  return fetchJson<IndexCancelResponse>("/index/cancel", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Removes documents older than the cutoff. The cutoff is required so a bare
// prune cannot silently clear the store; callers must pass an explicit date.
export function pruneIndex(before: string | number): Promise<IndexPruneResponse> {
  return fetchJson<IndexPruneResponse>("/index/prune", {
    method: "POST",
    body: JSON.stringify({ before }),
  });
}

// Clears the index store; the route fails instead of claiming a partial clear.
export function resetIndex(): Promise<IndexResetResponse> {
  return fetchJson<IndexResetResponse>("/index/reset", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Compacts the index database and reports the on-disk size before and after
// so the pane can show both figures. The counters are on-disk bytes
// (database file plus write-ahead log) so the result reads within ~1% of `du`.
export function reclaimIndex(): Promise<IndexReclaimResponse> {
  return fetchJson<IndexReclaimResponse>("/index/reclaim", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Outcome of `POST /index/request-access`: whether the owner granted EventKit
// access for one source. Carries the boolean plus the single `access` token.
export interface IndexRequestAccessResponse {
  kind: string;
  granted?: boolean | null;
  access?: string | null;
}

// Resolves the granted bit from the single-token shape: the boolean wins
// when present, otherwise the `access` token decides, defaulting to denied
// so a drifted payload never claims access it did not verify.
export function resolveIndexRequestAccessGranted(
  response: IndexRequestAccessResponse | null | undefined,
): boolean {
  if (!response || typeof response !== "object") return false;
  if (typeof response.granted === "boolean") return response.granted;
  const accessToken =
    typeof response.access === "string" ? response.access.trim().toLowerCase() : "";
  return accessToken === "granted";
}

// Requests EventKit access for one source. Prompts only from explicit intent
// (post-save enable, Grant button); status reads never call this.
export function requestIndexAccess(kind: string): Promise<IndexRequestAccessResponse> {
  return fetchJson<IndexRequestAccessResponse>("/index/request-access", {
    method: "POST",
    body: JSON.stringify({ kind }),
  });
}

// Web search (SearXNG) lifecycle surfaced by the engine service. The service runs SearXNG in an
// Apple Container machine with no Docker dependency, so these routes start and stop that machine
// rather than proxying queries.
export interface SearchHealthResponse {
  reachable: boolean;
  url?: string;
  baseURL?: string;
  status?: string | null;
  containerName?: string | null;
  started?: boolean | null;
  stopped?: boolean | null;
  // Whether the managed entry is gone after a remove. Optional because health,
  // ensure, and stop payloads predate removal; absent degrades to the honest
  // reachable probe instead of assuming deleted.
  removed?: boolean | null;
  message?: string | null;
  diagnostics?: string | null;
  // Live Start stage plus Start time while an ensure flight runs (resolving, daemon, pulling,
  // starting, waiting). Optional because older engines predate staged progress and because the
  // keys are absent when idle; absent means no Start is in flight.
  stage?: string | null;
  // Unix seconds when the in-flight Start began. Mirrors the engine shape (a number, never a
  // Date string) so elapsed math stays a subtraction; null or absent means unknown.
  startedAt?: number | null;
}

// Resolves the display URL across the dual `url`/`baseURL` contract so custom
// ports survive regardless of which key the engine encoded.
export function resolveSearchURL(
  response: SearchHealthResponse | null | undefined,
  fallback: string,
): string {
  if (!response) return fallback;
  const candidate =
    (typeof response.url === "string" && response.url.trim()) ||
    (typeof response.baseURL === "string" && response.baseURL.trim()) ||
    "";
  return candidate || fallback;
}

// Single-sourced banner extraction for the search lifecycle: trims the engine `message` (terminal
// cause plus one remediation) and normalizes blank or non-string payloads to null so callers never
// render whitespace as a banner.
export function resolveSearchMessage(
  response: SearchHealthResponse | null | undefined,
): string | null {
  const message = response?.message;
  return typeof message === "string" && message.trim() ? message.trim() : null;
}

// Single-sourced diagnostics extraction for the search lifecycle: trims the engine `diagnostics`
// (chained stage, exit, capped tail, timeout) and normalizes blank or non-string payloads to null so
// the collapsed Settings element only renders when real per-stage detail exists.
export function resolveSearchDiagnostics(
  response: SearchHealthResponse | null | undefined,
): string | null {
  const diagnostics = response?.diagnostics;
  return typeof diagnostics === "string" && diagnostics.trim()
    ? diagnostics.trim()
    : null;
}

// Staged Start progress: while a Start is in flight the engine publishes the current step plus the
// Start time on health payloads, and the dashboard polls about 1s so the amber Starting line tracks
// the cascade instead of sitting static.
export const SEARCH_START_POLL_INTERVAL_MS = 1000;
export const SEARCH_START_CAP_MS = 360_000;

// Single-sourced user copy per Start stage, mirroring StartStage.userCopy on the engine. Unknown
// or drifted stages fall back to a bare Starting label via searchStageCopy so a new engine step
// never renders blank.
export const SEARCH_START_STAGE_COPY: Record<string, string> = {
  resolving: "Checking container runtime",
  daemon: "Waking container service",
  pulling: "Pulling search image",
  starting: "Starting search container",
  waiting: "Waiting for search to respond",
};

// Payloads carrying staged progress: /search/health uses stage/startedAt while /health nests the
// same values under searchStage/searchStartedAt. One shape keeps both poll sites honest.
export interface SearchStartProgressPayload {
  stage?: string | null;
  searchStage?: string | null;
  startedAt?: number | null;
  searchStartedAt?: number | null;
}

// Extracts the live Start stage across both health contracts, normalizing blank or non-string
// payloads to null so the Starting line only renders for a real in-flight step.
export function resolveStartStage(
  response: SearchStartProgressPayload | null | undefined,
): string | null {
  if (!response) return null;
  const raw =
    (typeof response.stage === "string" && response.stage.trim()) ||
    (typeof response.searchStage === "string" && response.searchStage.trim()) ||
    "";
  return raw || null;
}

// Extracts the in-flight Start time (Unix seconds) across both health contracts, normalizing
// missing, non-finite, or non-positive payloads to null so elapsed math falls back to the
// client-side Start instant instead of rendering from a garbage epoch.
export function resolveStartStartedAt(
  response: SearchStartProgressPayload | null | undefined,
): number | null {
  if (!response) return null;
  const raw =
    typeof response.startedAt === "number"
      ? response.startedAt
      : typeof response.searchStartedAt === "number"
        ? response.searchStartedAt
        : null;
  return raw != null && Number.isFinite(raw) && raw > 0 ? raw : null;
}

// Maps a stage to its user copy, degrading unknown stages to a bare Starting label so engine
// drift never blanks the in-flight line.
export function searchStageCopy(stage: string | null | undefined): string {
  if (stage && SEARCH_START_STAGE_COPY[stage]) return SEARCH_START_STAGE_COPY[stage];
  return "Starting";
}

// Reports whether the live Start stage is the minutes-budget image pull, during which the client
// cap suspends so a first-run pull never trips the hung-Start path early. Single-sourced so the
// shared progress hook and any future poll sites agree on the suspend condition.
export function isSearchStartPullingStage(stage: string | null | undefined): boolean {
  return stage === "pulling";
}

// Elapsed whole seconds since the Start began, preferring the engine Start time and falling back
// to the client-side Start instant when the payload carries none. Clamped at zero so clock skew
// never renders a negative count.
export function startElapsedSeconds(
  startedAtSeconds: number | null | undefined,
  clientStartMs: number,
  nowMs: number = Date.now(),
): number {
  const safeClientStartMs = Number.isFinite(clientStartMs) ? clientStartMs : 0;
  const safeNowMs = Number.isFinite(nowMs) ? nowMs : 0;
  const baseMs =
    startedAtSeconds != null && Number.isFinite(startedAtSeconds) && startedAtSeconds > 0
      ? startedAtSeconds * 1000
      : safeClientStartMs;
  return Math.max(0, Math.floor((safeNowMs - baseMs) / 1000));
}

// Reads live SearXNG reachability without touching settings: the profile
// menu dot and the Settings Web pane both poll this so Start and Stop
// stay honest about the container state.
export function getSearchHealth(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/health");
}

// Starts the SearXNG container (pulls the image on first run) and reports
// the resulting health. Idempotent when already running.
export function ensureSearch(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/ensure", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Stops the SearXNG container and reports the resulting health. Idempotent
// when already stopped.
export function stopSearch(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/stop", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Deletes the SearXNG container entry and reports the resulting health. The server stops a running
// entry first rather than half-deleting, and the image cache survives so the next Start recreates
// the entry from cache.
export function removeSearch(): Promise<SearchHealthResponse> {
  return fetchJson<SearchHealthResponse>("/search/remove", {
    method: "POST",
    body: JSON.stringify({}),
  });
}
