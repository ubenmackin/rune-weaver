// Rune Weaver Dashboard — Memory API endpoints.
import { fetchJson } from "./http";
import type {
  MemorySearchResponse,
  UserFact,
  Preference,
} from "./types";

export function searchMemory(
  query: string,
  limit = 10,
  signal?: AbortSignal,
): Promise<MemorySearchResponse> {
  const params = new URLSearchParams({
    q: query,
    limit: String(limit),
  });
  // The abort signal stays optional so legacy callers keep working while the
  // dashboard can cancel a stale recall when the owner submits a fresh query.
  // An aborted fetch rejects and the caller decides whether silence is honest.
  return fetchJson<MemorySearchResponse>(`/memory/search?${params.toString()}`, {
    signal,
  });
}

// Paged facts view for search-first browsing. The engine serves filtered, windowed rows plus live
// store tallies so the dashboard never pulls an unbounded list to count or to preview.
export interface FactsPageResponse {
  facts: UserFact[];
  total: number;
  semanticCount: number;
  episodeCount: number;
  preferences?: Preference[];
}

// Normalizes a facts payload across engine generations: newer rows carry an
// explicit total while older snapshots carry only the window, so a missing
// total degrades to the window length instead of rendering as unknown.
function normalizeFactsPage(value: FactsPageResponse): FactsPageResponse {
  const facts = Array.isArray(value.facts) ? value.facts : [];
  const total =
    typeof value.total === "number" && Number.isFinite(value.total) && value.total >= 0
      ? Math.floor(value.total)
      : facts.length;
  const semanticCount =
    typeof value.semanticCount === "number" && Number.isFinite(value.semanticCount)
      ? value.semanticCount
      : 0;
  const episodeCount =
    typeof value.episodeCount === "number" && Number.isFinite(value.episodeCount)
      ? value.episodeCount
      : 0;
  return {
    facts,
    total,
    semanticCount,
    episodeCount,
    ...(Array.isArray(value.preferences) ? { preferences: value.preferences } : {}),
  };
}

export function getFacts(
  q = "",
  limit = 20,
  offset = 0,
): Promise<FactsPageResponse> {
  // Every facts read builds its query through one shared encoder so paging, search, and counts
  // agree on parameter spelling.
  const params = new URLSearchParams();
  const trimmed = q.trim();
  if (trimmed) params.set("q", trimmed);
  params.set("limit", String(limit));
  params.set("offset", String(offset));
  const query = params.toString();
  const path = query ? `/memory/facts?${query}` : "/memory/facts";
  return fetchJson<FactsPageResponse>(path).then(normalizeFactsPage);
}

// Canonical episodic listing row for the dashboard finder. Carries full stored content plus
// identity, owning session, and role newest first, so previews never need a second fetch.
export interface EpisodicEpisode {
  id: string;
  sessionID: string;
  role: string;
  content: string;
  timestamp: number;
}

// Canonical recency receipt: windowed rows plus their length for tab counts.
// Episodes cover the episodic tables only; semantic facts, profile, and index
// state stay out of the shape.
export interface EpisodicRecentResponse {
  episodes: EpisodicEpisode[];
  count: number;
}

// Lists recent episodic turns newest first through the shared JSON path so
// malformed limits and unknown sessions surface as ApiError with the engine
// reason instead of a partial list. An unknown session reads as empty.
export function listRecentEpisodes(
  limit = 20,
  sessionID?: string,
): Promise<EpisodicRecentResponse> {
  // Single encoder keeps listing queries aligned with the facts pager: a blank
  // session filter stays omitted so the default call remains a global window.
  const params = new URLSearchParams();
  params.set("limit", String(limit));
  const trimmed = sessionID?.trim();
  if (trimmed) params.set("sessionID", trimmed);
  return fetchJson<EpisodicRecentResponse>(
    `/memory/episodes/recent?${params.toString()}`,
  );
}

export function storeFact(
  content: string,
  source = "dashboard",
): Promise<UserFact> {
  return fetchJson<UserFact>("/memory/facts", {
    method: "POST",
    body: JSON.stringify({ content, source }),
  });
}

export function deleteFact(id: string): Promise<void> {
  return fetchJson<void>(`/memory/facts/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

// Episodic clear receipt: how many rows the store removed plus how many remain.
// The clear is scoped to the episodic tables only, so the dashboard refreshes
// its counts from this payload while semantic facts and profile stay intact.
export interface EpisodicClearResponse {
  deletedCount: number;
  episodeCount: number;
}

// Clears every episodic turn while leaving semantic facts, profile, and index
// state untouched. An empty store clears to zero without failure, so the panel
// resolves normally instead of surfacing an error for nothing stored.
export function clearEpisodes(): Promise<EpisodicClearResponse> {
  return fetchJson<EpisodicClearResponse>("/memory/episodes", {
    method: "DELETE",
  });
}

// Deletes one episodic turn by id. A missing id completes as a no-op on the
// engine, so the dashboard drops the row only after the call resolves.
// Identifiers travel encoded so reserved characters never split the route.
export function deleteEpisode(id: string): Promise<void> {
  return fetchJson<void>(`/memory/episodes/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

// Deletes every episodic turn for one session. An unknown session completes as a no-op on the
// engine, so the dashboard clears stale hits only after the call resolves.
export function deleteSessionEpisodes(sessionID: string): Promise<void> {
  return fetchJson<void>(
    `/memory/episodes/session/${encodeURIComponent(sessionID)}`,
    {
      method: "DELETE",
    },
  );
}

