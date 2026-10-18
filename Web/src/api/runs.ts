// Rune Weaver Dashboard — Run logs API endpoints.
import { fetchJson } from "./http";
import type {
  RunLogEntry,
  RunLogsResponse,
} from "./types";
import { RUN_LOG_POLL_LIMIT } from "./types";

export function listRuns(
  limit = RUN_LOG_POLL_LIMIT,
  jobID?: string,
  sessionID?: string,
  goalID?: string,
): Promise<RunLogsResponse> {
  const params = new URLSearchParams({ limit: String(limit) });
  if (jobID) params.set("jobID", jobID);
  if (sessionID) params.set("sessionID", sessionID);
  // Goal scoping reuses the one runs endpoint the scheduler history already
  // reads, so a goal detail drawer and a job drawer stay on one bounded list
  // call instead of a parallel route.
  if (goalID) params.set("goalID", goalID);
  return fetchJson<RunLogsResponse>(`/runs?${params.toString()}`);
}

export function getRun(id: string): Promise<RunLogEntry> {
  return fetchJson<RunLogEntry>(`/runs/${encodeURIComponent(id)}`);
}

export function clearRuns(): Promise<void> {
  return fetchJson<void>("/runs", {
    method: "DELETE",
  });
}

export function deleteRun(id: string): Promise<void> {
  return fetchJson<void>(`/runs/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

// Response from `POST /runs/:id/cancel`, mirroring the engine's `RunCancelResponse`.
export interface CancelRunResponse {
  cancelled: boolean;
  scope: string;
  workerCount?: number;
}

// Stops one in-flight run by row id.
export function cancelRun(id: string): Promise<CancelRunResponse> {
  return fetchJson<CancelRunResponse>(
    `/runs/${encodeURIComponent(id)}/cancel`,
    {
      method: "POST",
    },
  );
}

