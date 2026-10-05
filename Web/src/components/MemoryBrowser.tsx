// Rune Weaver Dashboard — Memory browser with tabbed recall, facts, and episodic views.
// Purpose: lets the owner search mixed recall, browse paged facts, and review
// recent episodic turns with scoped deletes from one surface.
// Scope: three inner tabs inside the Memory view plus the Index Status pane;
// listing reads stay windowed, deletes confirm behind modals, and tallies stay
// fresh without a restart. Policy editing stays in Settings.
// Architectural role: thin dashboard client over the engine memory routes; the
// engine owns listing scope and validation while this view owns trimming,
// blank-disable, timing display, and per-tab isolated state.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  clearEpisodes,
  deleteEpisode,
  deleteFact,
  deleteSessionEpisodes,
  getFacts,
  listRecentEpisodes,
  searchMemory,
  storeFact,
  type MemoryResult,
  type Preference,
  type EpisodicEpisode,
  type UserFact,
} from "../api";
import IndexingPanel from "./IndexingPanel";
import MarkdownText from "./MarkdownText";
import Modal from "./Modal";
import { CloseIcon, PlusIcon, SearchIcon, TrashIcon } from "./icons";

// Inner memory views plus the outer shell views. The legacy "memory" value is
// kept so the app shell container still compiles; it normalizes to the Search
// tab for rendering. Indexing stays as the status pane.
export type MemoryInnerTab = "search" | "facts" | "episodes";
export type MemoryTab = MemoryInnerTab | "memory" | "indexing";

export interface MemoryBrowserProps {
  view?: MemoryTab;
}

// Resolves the starting tab from the dashboard deep link. Menu-bar entries
// navigate with a memory fragment carrying an inner suffix, so a fresh load
// with that suffix opens selected on the named pane. Unknown or bare memory
// links open on Search so the first paint never strands on an empty choice.
export function getInitialMemoryTab(): MemoryTab {
  if (typeof window === "undefined") return "search";
  const hash = window.location.hash.toLowerCase();
  const query = window.location.search.toLowerCase();
  if (hash.includes("indexing") || query.includes("indexing")) return "indexing";
  if (hash.includes("memory/episodes")) return "episodes";
  if (hash.includes("memory/facts")) return "facts";
  if (hash.includes("memory/search")) return "search";
  if (hash.includes("memory")) return "search";
  return "search";
}

// Normalizes the legacy shell value to an inner tab for rendering. The shell
// passes "memory" as a container meaning any inner tab, so it reads as Search
// until the owner picks another pane.
function normalizeRenderTab(tab: MemoryTab): MemoryInnerTab | "indexing" {
  if (tab === "memory") return "search";
  return tab;
}

function hashContent(content: string): string {
  // cyrb53 53-bit hash: substantially fewer collisions than 32-bit djb2
  // while staying bounded (hex digest, never full content in the key).
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < content.length; i += 1) {
    const ch = content.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 =
    Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^
    Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 =
    Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^
    Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16);
}

function stableMetadataFingerprint(
  metadata: Record<string, string> | undefined | null,
): string {
  if (!metadata) return "";
  const keys = Object.keys(metadata).sort();
  if (keys.length === 0) return "";
  return keys.map((key) => `${key}=${metadata[key]}`).join("|");
}

function baseResultKey(result: MemoryResult): string {
  const contentHash = hashContent(result.content);
  const fingerprint = stableMetadataFingerprint(result.metadata);
  const base = `${result.source}-${contentHash}`;
  return fingerprint ? `${base}-${hashContent(fingerprint)}` : base;
}

// Window sizes stay local so paged reads never widen into unbounded lists.
// Both match the engine defaults: recent windows of twenty rows.
const FACTS_PAGE_SIZE = 20;
const EPISODES_PAGE_SIZE = 20;

export default function MemoryBrowser({ view }: MemoryBrowserProps = {}) {
  const [localTab, setLocalTab] = useState<MemoryTab>(() => {
    if (view !== undefined) {
      // The shell container "memory" means any inner tab: honor a deep link
      // when it names one, otherwise start on Search.
      if (view === "memory") {
        const initial = getInitialMemoryTab();
        if (initial === "facts" || initial === "episodes" || initial === "search") {
          return initial;
        }
        return "search";
      }
      return view;
    }
    return getInitialMemoryTab();
  });

  // The shell pins Index Status; the memory container follows local state so
  // inner tabs can switch without remounting. Standalone follows the URL.
  const activeTab: MemoryTab =
    view === "indexing"
      ? "indexing"
      : view === "memory"
        ? (localTab === "indexing" ? "search" : localTab)
        : localTab;
  const renderTab = normalizeRenderTab(activeTab);

  function selectInnerTab(next: MemoryInnerTab) {
    setLocalTab(next);
    // Hash suffixes keep deep links shareable while leaving the outer tab
    // stable: the shell splits on "/" and keeps "memory" as the outer tab.
    if (typeof window !== "undefined") {
      window.location.hash = `memory/${next}`;
    }
  }

  // Live tallies for tab labels come from the facts route so labels never
  // drift from the stored store. Refreshed on mount and after deletes only;
  // searches never touch it so recall stays isolated from stored counts.
  const [episodeCount, setEpisodeCount] = useState<number | null>(null);
  const [semanticCount, setSemanticCount] = useState<number | null>(null);
  const [factsTotalCount, setFactsTotalCount] = useState<number | null>(null);

  const refreshCounts = useCallback(async () => {
    try {
      const page = await getFacts("", FACTS_PAGE_SIZE, 0);
      setEpisodeCount(page.episodeCount);
      setSemanticCount(page.semanticCount);
      setFactsTotalCount(page.total);
    } catch {
      // Tallies degrade to the last known values so a transient read never
      // blanks the tab labels.
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    getFacts("", FACTS_PAGE_SIZE, 0)
      .then((page) => {
        if (cancelled) return;
        setEpisodeCount(page.episodeCount);
        setSemanticCount(page.semanticCount);
        setFactsTotalCount(page.total);
      })
      .catch(() => {
        // Counts stay null and labels render without tallies.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Follows deep links while the view is open: hash edits fire hashchange
  // while query-only history moves fire popstate. Skipped when the shell pins
  // Index Status so the URL never overrides the selected view.
  useEffect(() => {
    if (view === "indexing") return;
    function syncTabFromUrl() {
      if (typeof window === "undefined") return;
      const next = getInitialMemoryTab();
      if (next === "indexing") {
        if (view === undefined) {
          setLocalTab("indexing");
        }
        return;
      }
      const normalized: MemoryTab = next === "memory" ? "search" : next;
      setLocalTab((previous) => (previous === normalized ? previous : normalized));
    }
    window.addEventListener("hashchange", syncTabFromUrl);
    window.addEventListener("popstate", syncTabFromUrl);
    return () => {
      window.removeEventListener("hashchange", syncTabFromUrl);
      window.removeEventListener("popstate", syncTabFromUrl);
    };
  }, [view]);

  // Search tab owns its query, hits, timing, busy, and error in isolation so
  // recall never leaks into the facts or episodes panes.
  const [searchQuery, setSearchQuery] = useState("");
  const [searchResults, setSearchResults] = useState<MemoryResult[]>([]);
  const [searchBusy, setSearchBusy] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [searchElapsedMs, setSearchElapsedMs] = useState<number | null>(null);
  const searchAbortRef = useRef<AbortController | null>(null);

  useEffect(
    () => () => {
      // Abandoning an in-flight recall on unmount keeps a late response from
      // settling state on a gone view.
      searchAbortRef.current?.abort();
    },
    [],
  );

  async function runSearch() {
    const trimmed = searchQuery.trim();
    if (!trimmed) return;
    // A fresh submit cancels the prior recall so only the latest query can
    // settle; the aborted pass stays silent instead of flashing stale hits.
    searchAbortRef.current?.abort();
    const controller = new AbortController();
    searchAbortRef.current = controller;
    setSearchBusy(true);
    setSearchError(null);
    // Timing starts before the fetch and ends after it resolves so the line
    // reports fetch milliseconds honestly, including ranking time.
    const started = performance.now();
    try {
      const response = await searchMemory(trimmed, 10, controller.signal);
      if (controller.signal.aborted) return;
      setSearchResults(response.memories);
      setSearchElapsedMs(Math.max(0, Math.round(performance.now() - started)));
      // Search success never refetches stored facts: recall and stored
      // tallies stay independent so typing never churns the other tabs.
    } catch (failure) {
      if (controller.signal.aborted) return;
      if (failure instanceof DOMException && failure.name === "AbortError") return;
      setSearchError(failure instanceof ApiError ? failure.message : "Search failed");
      setSearchResults([]);
      setSearchElapsedMs(null);
    } finally {
      // Only the owning controller clears busy: an aborted pass leaves busy
      // to the fresh submit that replaced it so double submits stay parked.
      if (searchAbortRef.current === controller) {
        setSearchBusy(false);
      }
    }
  }

  // Facts tab owns its search text, windowed rows, paging cursor, busy, and
  // error apart from recall. Reads stay windowed so the pane never pulls an
  // unbounded list to preview or to count.
  const [factsQuery, setFactsQuery] = useState("");
  const [factsActiveQuery, setFactsActiveQuery] = useState("");
  const [factsList, setFactsList] = useState<UserFact[]>([]);
  const [factsTotal, setFactsTotal] = useState<number | null>(null);
  const [factsOffset, setFactsOffset] = useState(0);
  const [factsBusy, setFactsBusy] = useState(false);
  const [factsError, setFactsError] = useState<string | null>(null);
  const [factsPreferences, setFactsPreferences] = useState<Preference[]>([]);
  const [newFact, setNewFact] = useState("");
  const [factsLoadedOnce, setFactsLoadedOnce] = useState(false);

  async function fetchFactsWindow(nextQuery: string, nextOffset: number, append: boolean) {
    setFactsBusy(true);
    setFactsError(null);
    try {
      const page = await getFacts(nextQuery, FACTS_PAGE_SIZE, nextOffset);
      // The window carries live tallies, so tab labels settle on the same
      // pass without a second counts fetch.
      setEpisodeCount(page.episodeCount);
      setSemanticCount(page.semanticCount);
      setFactsTotalCount(page.total);
      if (append) {
        setFactsList((previous) => [...previous, ...page.facts]);
      } else {
        setFactsList(page.facts);
        setFactsActiveQuery(nextQuery);
      }
      setFactsTotal(page.total);
      setFactsOffset(nextOffset + page.facts.length);
      if (page.preferences) setFactsPreferences(page.preferences);
      setFactsLoadedOnce(true);
    } catch (failure) {
      setFactsError(failure instanceof ApiError ? failure.message : "Facts failed");
    } finally {
      setFactsBusy(false);
    }
  }

  function showRecentFacts() {
    void fetchFactsWindow("", 0, false);
  }

  function searchFacts() {
    const trimmed = factsQuery.trim();
    if (!trimmed) return;
    void fetchFactsWindow(trimmed, 0, false);
  }

  function loadMoreFacts() {
    if (factsBusy) return;
    if (factsTotal !== null && factsList.length >= factsTotal) return;
    void fetchFactsWindow(factsActiveQuery, factsOffset, true);
  }

  // Lazily previews the first window when the Facts pane first opens so the
  // default Search paint never pays for a list the owner may not open.
  useEffect(() => {
    if (renderTab !== "facts") return;
    if (factsLoadedOnce || factsBusy) return;
    void fetchFactsWindow("", 0, false);
    // Runs on tab entry only; query changes flow through explicit actions.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [renderTab]);

  async function addFact() {
    const content = newFact.trim();
    if (!content) return;
    setFactsBusy(true);
    setFactsError(null);
    try {
      await storeFact(content, "dashboard");
      setNewFact("");
      // Re-reads the active window plus tallies so the new row appears with
      // settled counts and no restart.
      const page = await getFacts(factsActiveQuery, FACTS_PAGE_SIZE, 0);
      setEpisodeCount(page.episodeCount);
      setSemanticCount(page.semanticCount);
      setFactsTotalCount(page.total);
      setFactsList(page.facts);
      setFactsTotal(page.total);
      setFactsOffset(page.facts.length);
      if (page.preferences) setFactsPreferences(page.preferences);
      setFactsLoadedOnce(true);
    } catch (failure) {
      setFactsError(
        failure instanceof ApiError ? failure.message : "Store fact failed",
      );
    } finally {
      setFactsBusy(false);
    }
  }

  // Non-blocking delete confirmation: the pending fact renders a true modal
  // so an accidental trash click never drops persisted memory without review.
  const [pendingDeleteFact, setPendingDeleteFact] = useState<UserFact | null>(null);
  const [deletingFactId, setDeletingFactId] = useState<string | null>(null);

  async function confirmDeleteFact() {
    if (!pendingDeleteFact) return;
    const fact = pendingDeleteFact;
    setDeletingFactId(fact.id);
    setFactsError(null);
    try {
      await deleteFact(fact.id);
      // Drops the row locally and refreshes tallies so labels settle; the
      // window is not re-paged here so the owner's scroll position survives.
      setFactsList((previous) => previous.filter((row) => row.id !== fact.id));
      setFactsTotal((previous) => (previous !== null ? Math.max(0, previous - 1) : previous));
      setFactsOffset((previous) => Math.max(0, previous - 1));
      setFactsTotalCount((previous) =>
        previous !== null ? Math.max(0, previous - 1) : previous,
      );
      setPendingDeleteFact(null);
      await refreshCounts();
    } catch (failure) {
      setFactsError(
        failure instanceof ApiError ? failure.message : "Delete fact failed",
      );
    } finally {
      setDeletingFactId(null);
    }
  }

  function cancelDeleteFact() {
    setPendingDeleteFact(null);
  }

  // Episodes finder owns its contents query, windowed hits, busy, and error
  // apart from recall and facts. Contents searches filter mixed recall to
  // episodic rows while recency previews read the bounded listing, so the pane
  // never pulls an unbounded list to find or to count.
  type FinderItem = MemoryResult | EpisodicEpisode;
  const [finderQuery, setFinderQuery] = useState("");
  const [finderBusy, setFinderBusy] = useState(false);
  const [finderResults, setFinderResults] = useState<FinderItem[]>([]);
  const [finderError, setFinderError] = useState<string | null>(null);
  const [finderLoadedOnce, setFinderLoadedOnce] = useState(false);
  const [finderSource, setFinderSource] = useState<"recent" | "contents" | "session" | null>(
    null,
  );
  const [finderSourceParam, setFinderSourceParam] = useState("");
  const [pendingDeleteAllShown, setPendingDeleteAllShown] = useState(false);

  // Distinguishes mixed recall hits from listing rows without branching on
  // content: recall carries scored metadata while listing rows carry a direct
  // session link, so each shape keeps its own delete address.
  function isFinderMemoryResult(item: FinderItem): item is MemoryResult {
    return "metadata" in item && "score" in item;
  }

  // Single address for every finder row: recall hits delete through their
  // metadata id while listing rows delete through their direct id. Absent ids
  // hide their Delete affordance instead of firing an unaddressable delete.
  function finderItemId(item: FinderItem): string | undefined {
    if (isFinderMemoryResult(item)) {
      const raw = item.metadata?.id;
      const trimmed = typeof raw === "string" ? raw.trim() : "";
      return trimmed ? trimmed : undefined;
    }
    const raw = (item as EpisodicEpisode).id;
    const trimmed = typeof raw === "string" ? raw.trim() : "";
    return trimmed ? trimmed : undefined;
  }

  // Owning session for the short-session chip: recall tucks it under metadata
  // while listing rows carry it directly, so both render the same prefix.
  function finderItemSession(item: FinderItem): string {
    if (isFinderMemoryResult(item)) {
      const meta = (item.metadata ?? {}) as Record<string, string>;
      const sid = meta.session_id ?? meta.sessionID ?? "";
      return typeof sid === "string" ? sid : "";
    }
    const sid = (item as EpisodicEpisode).sessionID ?? "";
    return typeof sid === "string" ? sid : "";
  }

  // Role badge for the finder card: recall tucks the role under metadata while
  // listing rows carry it directly, so mixed and recency hits read alike.
  function finderItemRole(item: FinderItem): string {
    if (isFinderMemoryResult(item)) {
      const meta = (item.metadata ?? {}) as Record<string, string>;
      const role = meta.role ?? item.source ?? "episodic";
      return typeof role === "string" && role ? role : "episodic";
    }
    const role = (item as EpisodicEpisode).role ?? "";
    return typeof role === "string" && role ? role : "episodic";
  }

  // Occurrence time for the date chip: listing rows carry Unix seconds while
  // recall hits carry no clock, so missing clocks omit the date rather than
  // rendering the epoch.
  function finderItemTimestamp(item: FinderItem): number | null {
    if (isFinderMemoryResult(item)) {
      return null;
    }
    return (item as EpisodicEpisode).timestamp ?? null;
  }

  // Finds episodic turns by contents: pulls a bounded mixed window then keeps
  // only episodic rows, so semantic and profile hits never enter the finder.
  async function runFinderContentsSearch() {
    const trimmed = finderQuery.trim();
    if (!trimmed) return;
    setFinderBusy(true);
    setFinderError(null);
    try {
      const response = await searchMemory(trimmed, 50);
      const episodicOnly = response.memories.filter(
        (row) => row.source === "episodic",
      );
      setFinderResults(episodicOnly);
      setFinderSource("contents");
      setFinderSourceParam(trimmed);
      setFinderLoadedOnce(true);
    } catch (failure) {
      setFinderError(
        failure instanceof ApiError ? failure.message : "Episodic search failed",
      );
      setFinderResults([]);
    } finally {
      setFinderBusy(false);
    }
  }

  // Previews the newest bounded window so the owner can audit recency without
  // typing a query first.
  async function runShowRecentFinder() {
    setFinderBusy(true);
    setFinderError(null);
    try {
      const response = await listRecentEpisodes(EPISODES_PAGE_SIZE);
      setFinderResults(response.episodes);
      setFinderSource("recent");
      setFinderSourceParam("");
      setFinderLoadedOnce(true);
    } catch (failure) {
      setFinderError(
        failure instanceof ApiError ? failure.message : "Episodes failed",
      );
      setFinderResults([]);
    } finally {
      setFinderBusy(false);
    }
  }

  // Previews one session from the trimmed session input at call time, so
  // padding never addresses a blank session.
  async function runPreviewSessionFinder() {
    const trimmed = sessionInput.trim();
    if (!trimmed) return;
    setFinderBusy(true);
    setFinderError(null);
    try {
      const response = await listRecentEpisodes(EPISODES_PAGE_SIZE, trimmed);
      setFinderResults(response.episodes);
      setFinderSource("session");
      setFinderSourceParam(trimmed);
      setFinderLoadedOnce(true);
    } catch (failure) {
      setFinderError(
        failure instanceof ApiError ? failure.message : "Episodes failed",
      );
      setFinderResults([]);
    } finally {
      setFinderBusy(false);
    }
  }

  // Re-reads the last finder source after a delete batch so the pane settles
  // without a restart. Falls back to the recency window when no source ran yet.
  async function refetchActiveFinderSource() {
    if (finderSource === "contents") {
      const query = finderSourceParam;
      if (!query) return;
      const response = await searchMemory(query, 50);
      setFinderResults(
        response.memories.filter((row) => row.source === "episodic"),
      );
      setFinderLoadedOnce(true);
      return;
    }
    if (finderSource === "session") {
      const sessionID = finderSourceParam;
      if (!sessionID) return;
      const response = await listRecentEpisodes(EPISODES_PAGE_SIZE, sessionID);
      setFinderResults(response.episodes);
      setFinderLoadedOnce(true);
      return;
    }
    const response = await listRecentEpisodes(EPISODES_PAGE_SIZE);
    setFinderResults(response.episodes);
    setFinderLoadedOnce(true);
  }

  // Lazily previews recency when the Episodes pane first opens for the same
  // reason as facts: the default Search paint never pays for it.
  useEffect(() => {
    if (renderTab !== "episodes") return;
    if (finderLoadedOnce || finderBusy) return;
    void runShowRecentFinder();
    // Runs on tab entry only; finder edits flow through explicit actions.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [renderTab]);

  // Episodic cleanup state stays beside the fact-delete pair so each
  // destructive flow owns its pending row plus busy flag: per-hit deletes
  // target one row by id, while the footer panel targets the whole store or
  // one session behind the same centered Modal pattern.
  const [pendingSearchEpisodic, setPendingSearchEpisodic] = useState<MemoryResult | null>(
    null,
  );
  const [pendingEpisodeRow, setPendingEpisodeRow] = useState<EpisodicEpisode | null>(null);
  const [deletingEpisodicId, setDeletingEpisodicId] = useState<string | null>(null);
  const [pendingClearAll, setPendingClearAll] = useState(false);
  const [pendingClearSession, setPendingClearSession] = useState(false);
  const [cleanupBusy, setCleanupBusy] = useState(false);
  const [sessionInput, setSessionInput] = useState("");

  // Confirms one per-hit Search delete by the hit's metadata id, then drops
  // exactly that row and refreshes tallies. A hit without an id never reaches
  // here because its Delete affordance stays hidden.
  async function confirmDeleteSearchEpisodic() {
    if (!pendingSearchEpisodic) return;
    const target = pendingSearchEpisodic;
    const episodeId = target.metadata?.id;
    if (!episodeId) {
      setPendingSearchEpisodic(null);
      return;
    }
    setDeletingEpisodicId(episodeId);
    setSearchError(null);
    try {
      await deleteEpisode(episodeId);
      setSearchResults((previous) =>
        previous.filter((row) => row.metadata?.id !== episodeId),
      );
      // The finder may hold the same episodic hit from a contents search, so
      // it drops there too instead of lingering after its row is gone.
      setFinderResults((previous) =>
        previous.filter((row) => finderItemId(row) !== episodeId),
      );
      setPendingSearchEpisodic(null);
      await refreshCounts();
    } catch (failure) {
      setSearchError(
        failure instanceof ApiError
          ? failure.message
          : "Delete episodic result failed",
      );
    } finally {
      setDeletingEpisodicId(null);
    }
  }

  function cancelDeleteSearchEpisodic() {
    setPendingSearchEpisodic(null);
  }

  // Confirms one finder row delete by its listing id, then drops that row from
  // the finder window and refreshes tallies without re-paging the whole store.
  async function confirmDeleteEpisodeRow() {
    if (!pendingEpisodeRow) return;
    const target = pendingEpisodeRow;
    setDeletingEpisodicId(target.id);
    setFinderError(null);
    try {
      await deleteEpisode(target.id);
      setFinderResults((previous) =>
        previous.filter((row) => finderItemId(row) !== target.id),
      );
      setPendingEpisodeRow(null);
      await refreshCounts();
    } catch (failure) {
      setFinderError(
        failure instanceof ApiError
          ? failure.message
          : "Delete episodic result failed",
      );
    } finally {
      setDeletingEpisodicId(null);
    }
  }

  function cancelDeleteEpisodeRow() {
    setPendingEpisodeRow(null);
  }

  // Removes exactly the shown finder set behind one confirm: deletes
  // sequentially through the single-delete route and stops on the first
  // failure so a rejected id never masks behind later successes, then reloads
  // tallies plus the active finder source.
  async function confirmDeleteAllShown() {
    if (finderResults.length === 0) return;
    const ids = finderResults
      .map((row) => finderItemId(row))
      .filter((id): id is string => typeof id === "string" && id.length > 0);
    if (ids.length === 0) {
      setPendingDeleteAllShown(false);
      return;
    }
    setFinderBusy(true);
    setFinderError(null);
    try {
      for (const id of ids) {
        await deleteEpisode(id);
      }
      await refreshCounts();
      await refetchActiveFinderSource();
      setPendingDeleteAllShown(false);
    } catch (failure) {
      setFinderError(
        failure instanceof ApiError
          ? failure.message
          : "Delete shown episodes failed",
      );
      // Settles tallies plus the active source even on a partial batch so the
      // pane reflects which rows survived the stopped sequence.
      try {
        await refreshCounts();
        await refetchActiveFinderSource();
      } catch {
        // The finder error above already owns the failure copy.
      }
    } finally {
      setFinderBusy(false);
    }
  }

  function cancelDeleteAllShown() {
    if (finderBusy) return;
    setPendingDeleteAllShown(false);
  }

  // Confirms the whole-store episodic clear behind the same centered Modal as
  // fact delete. On success the pane reloads the active finder source and
  // tallies and drops stale recall hits so cleared rows never linger.
  async function confirmClearAllEpisodes() {
    setCleanupBusy(true);
    if (renderTab === "episodes") setFinderError(null);
    else setSearchError(null);
    try {
      await clearEpisodes();
      setSearchResults([]);
      setSearchElapsedMs(null);
      setFinderResults([]);
      setFinderLoadedOnce(true);
      await refreshCounts();
      await refetchActiveFinderSource();
      setPendingClearAll(false);
    } catch (failure) {
      const message =
        failure instanceof ApiError ? failure.message : "Clear episodes failed";
      if (renderTab === "episodes") setFinderError(message);
      else setSearchError(message);
    } finally {
      setCleanupBusy(false);
    }
  }

  function cancelClearAllEpisodes() {
    setPendingClearAll(false);
  }

  // Confirms the per-session episodic clear using the trimmed session input at
  // confirm time, then reloads the active finder source and tallies like the
  // whole-store path. A blank input never reaches here because its button
  // stays disabled.
  async function confirmClearSessionEpisodes() {
    const sessionID = sessionInput.trim();
    if (!sessionID) return;
    setCleanupBusy(true);
    if (renderTab === "episodes") setFinderError(null);
    else setSearchError(null);
    try {
      await deleteSessionEpisodes(sessionID);
      setSearchResults([]);
      setSearchElapsedMs(null);
      await refreshCounts();
      await refetchActiveFinderSource();
      setPendingClearSession(false);
    } catch (failure) {
      const message =
        failure instanceof ApiError
          ? failure.message
          : "Clear session episodes failed";
      if (renderTab === "episodes") setFinderError(message);
      else setSearchError(message);
    } finally {
      setCleanupBusy(false);
    }
  }

  function cancelClearSessionEpisodes() {
    setPendingClearSession(false);
  }

  // Zero stored turns disables both destructive buttons with an honest title,
  // while a blank session input disables only its own button so the
  // whole-store path stays available when episodes exist.
  const resolvedEpisodeCount = episodeCount ?? 0;
  const hasEpisodes = resolvedEpisodeCount > 0;
  const trimmedSessionInput = sessionInput.trim();
  const trimmedSearch = searchQuery.trim();
  const trimmedNewFact = newFact.trim();
  const trimmedFactsQuery = factsQuery.trim();
  const trimmedFinderQuery = finderQuery.trim();
  const factsHasMore =
    factsTotal !== null ? factsList.length < factsTotal : false;

  // Stable keys without positional index: duplicates of the same source+content share a base key
  // and are disambiguated by occurrence within that group, so filtering an unrelated row never
  // remounts the survivors. Computed per render from current order only.
  const seenBaseKeys = new Map<string, number>();
  function resultKey(result: MemoryResult): string {
    const base = baseResultKey(result);
    const occurrence = seenBaseKeys.get(base) ?? 0;
    seenBaseKeys.set(base, occurrence + 1);
    return occurrence === 0 ? base : `${base}#${occurrence}`;
  }

  // Stable finder keys with the same no-index contract as recall rows: an
  // addressable row keys by its episode id while an unaddressable recall hit
  // keys by its content hash, so deleting one survivor never remounts the rest.
  const seenFinderKeys = new Map<string, number>();
  function finderKey(item: FinderItem): string {
    const id = finderItemId(item);
    const base = id ?? `finder-${hashContent(item.content)}`;
    const occurrence = seenFinderKeys.get(base) ?? 0;
    seenFinderKeys.set(base, occurrence + 1);
    return occurrence === 0 ? base : `${base}#${occurrence}`;
  }

  // Human date for the finder card header: listing clocks render localized
  // while recall hits without a clock omit the date instead of epoching.
  function formatFinderTimestamp(value: number | null): string {
    if (value === null || value === undefined) return "";
    try {
      const date = new Date(value * 1000);
      if (Number.isNaN(date.getTime())) return "";
      return date.toLocaleString();
    } catch {
      return "";
    }
  }

  return (
    <>
      <section
        className="panel memory-panel"
        aria-label={renderTab === "indexing" ? "Index Status" : "Memory browser"}
      >
        <div className="panel-header-row">
          <div>
            <h2>{renderTab === "indexing" ? "Index Status" : "Memory"}</h2>
            <p className="muted text-sm">
              {renderTab === "indexing"
                ? "Monitor the local file, mail, and Messages index."
                : "Search episodic recall and semantic memory, manage stored user facts."}
            </p>
          </div>
        </div>

        {renderTab === "indexing" ? (
          <div id="memory-panel-index" aria-label="Index Status">
            <IndexingPanel hideHeader />
          </div>
        ) : (
          <>
            <div className="memory-tabs" role="tablist" aria-label="Memory views">
              <button
                type="button"
                role="tab"
                aria-selected={renderTab === "search"}
                aria-controls="memory-panel-search"
                className={`memory-tab${renderTab === "search" ? " active" : ""}`}
                onClick={() => selectInnerTab("search")}
              >
                Search
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={renderTab === "facts"}
                aria-controls="memory-panel-facts"
                className={`memory-tab${renderTab === "facts" ? " active" : ""}`}
                onClick={() => selectInnerTab("facts")}
              >
                {factsTotalCount !== null ? `Facts (${factsTotalCount})` : "Facts"}
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={renderTab === "episodes"}
                aria-controls="memory-panel-episodes"
                className={`memory-tab${renderTab === "episodes" ? " active" : ""}`}
                onClick={() => selectInnerTab("episodes")}
              >
                {episodeCount !== null ? `Episodes (${episodeCount})` : "Episodes"}
              </button>
            </div>

            {renderTab === "search" ? (
              <div id="memory-panel-search" role="tabpanel" aria-label="Search">
                {searchError ? <p className="error">{searchError}</p> : null}
                <div className="memory-search-section">
                  <h3>Search</h3>
                  <div className="row">
                    <input
                      type="text"
                      aria-label="Memory search"
                      placeholder="Search memories…"
                      value={searchQuery}
                      onChange={(event) => setSearchQuery(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") void runSearch();
                      }}
                    />
                    <button
                      type="button"
                      className="primary icon-text-btn"
                      disabled={searchBusy || trimmedSearch.length === 0}
                      onClick={() => void runSearch()}
                    >
                      <SearchIcon size={14} />
                      <span>Search</span>
                    </button>
                  </div>
                  {searchElapsedMs !== null ? (
                    <p className="muted text-sm memory-timing">
                      {`${searchResults.length} hits in ${searchElapsedMs}ms`}
                    </p>
                  ) : null}
                </div>

                {searchResults.length > 0 ? (
                  <div className="memory-results-container">
                    <h4>Search Results ({searchResults.length})</h4>
                    <div className="memory-results-list">
                      {searchResults.map((result) => (
                        <div className="card memory-result-card" key={resultKey(result)}>
                          <div className="memory-card-header">
                            <div className="memory-badges">
                              <span className="badge memory-source-badge">
                                {result.source}
                              </span>
                              <span className="badge memory-score-badge">
                                Score: {result.score.toFixed(2)}
                              </span>
                            </div>
                            {result.metadata && Object.keys(result.metadata).length > 0 ? (
                              <span className="muted text-xs">
                                {Object.entries(result.metadata)
                                  .map(([k, v]) => `${k}: ${v}`)
                                  .join(" · ")}
                              </span>
                            ) : null}
                          </div>
                          <div className="memory-card-content">
                            <MarkdownText text={result.content} className="memory-markdown" />
                          </div>
                          {/* Only episodic hits with a stored id offer deletion:
                              semantic and profile rows have no episode row to
                              delete, and an episodic hit without metadata id
                              cannot address its row. */}
                          {result.source === "episodic" && result.metadata?.id ? (
                            <div className="memory-card-actions">
                              <button
                                type="button"
                                className="danger icon-text-btn"
                                aria-label="Delete episodic result"
                                onClick={() => setPendingSearchEpisodic(result)}
                              >
                                <TrashIcon size={14} />
                                <span>Delete</span>
                              </button>
                            </div>
                          ) : null}
                        </div>
                      ))}
                    </div>
                  </div>
                ) : null}
              </div>
            ) : null}

            {renderTab === "facts" ? (
              <div id="memory-panel-facts" role="tabpanel" aria-label="Facts">
                {factsError ? <p className="error">{factsError}</p> : null}
                <div className="memory-facts-section">
                  <h3>Facts</h3>
                  <p className="muted text-sm">
                    Add persistent facts, background context, or personal preferences for
                    the agent to remember.
                  </p>
                  <div className="row">
                    <input
                      type="text"
                      aria-label="New fact"
                      placeholder="Remember this…"
                      value={newFact}
                      onChange={(event) => setNewFact(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") void addFact();
                      }}
                    />
                    <button
                      type="button"
                      className="ghost icon-text-btn"
                      disabled={factsBusy || trimmedNewFact.length === 0}
                      onClick={() => void addFact()}
                    >
                      <PlusIcon size={14} />
                      <span>Remember</span>
                    </button>
                  </div>

                  <div className="row" style={{ marginTop: 12 }}>
                    <input
                      type="text"
                      aria-label="Search facts"
                      placeholder="Search facts…"
                      value={factsQuery}
                      onChange={(event) => setFactsQuery(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") void searchFacts();
                      }}
                    />
                    <button
                      type="button"
                      className="primary icon-text-btn"
                      disabled={factsBusy || trimmedFactsQuery.length === 0}
                      onClick={() => void searchFacts()}
                    >
                      <SearchIcon size={14} />
                      <span>Search</span>
                    </button>
                    <button
                      type="button"
                      className="ghost"
                      disabled={factsBusy}
                      onClick={() => void showRecentFacts()}
                    >
                      Show Recent 20
                    </button>
                  </div>

                  <p className="muted text-sm memory-counts">
                    {factsTotal !== null
                      ? `${factsList.length} shown · ${factsTotal} total · ${semanticCount ?? 0} semantic · ${episodeCount ?? 0} episodes`
                      : factsLoadedOnce
                        ? `${factsList.length} facts`
                        : "Search or show recent to preview facts…"}
                  </p>

                  <div className="facts-list">
                    {factsList.map((fact) => (
                      <div className="card fact-item-card" key={fact.id}>
                        <div className="fact-item-main">
                          <MarkdownText text={fact.content} className="memory-markdown" />
                          <div className="fact-item-meta">
                            <span className="badge memory-source-badge">{fact.source}</span>
                            {fact.lastConfirmed ? (
                              <span className="muted text-xs">
                                {new Date(fact.lastConfirmed).toLocaleDateString()}
                              </span>
                            ) : null}
                          </div>
                        </div>
                        <button
                          type="button"
                          className="danger icon-text-btn"
                          aria-label={`Delete fact ${fact.id}`}
                          onClick={() => setPendingDeleteFact(fact)}
                        >
                          <TrashIcon size={14} />
                          <span>Delete</span>
                        </button>
                      </div>
                    ))}
                  </div>

                  {factsHasMore ? (
                    <div className="row" style={{ marginTop: 12 }}>
                      <button
                        type="button"
                        className="ghost"
                        disabled={factsBusy}
                        onClick={() => void loadMoreFacts()}
                      >
                        {factsBusy ? "Loading…" : "More"}
                      </button>
                    </div>
                  ) : null}

                  <div className="memory-preferences-section">
                    <h4>Knowledge</h4>
                    {factsPreferences.length > 0 ? (
                      <div className="preferences-list">
                        {factsPreferences.map((preference) => (
                          <div className="card preference-card" key={preference.key}>
                            <strong>{preference.key}</strong>: <span>{preference.value}</span>
                          </div>
                        ))}
                      </div>
                    ) : (
                      <p className="muted text-sm">
                        Stored preferences appear here when the engine sends them.
                      </p>
                    )}
                  </div>
                </div>
              </div>
            ) : null}

            {renderTab === "episodes" ? (
              <div id="memory-panel-episodes" role="tabpanel" aria-label="Episodes">
                {finderError ? <p className="error">{finderError}</p> : null}
                <div className="memory-section-card memory-search-section">
                  <h3>Episodes</h3>
                  <p className="muted text-sm">
                    Recent episodic turns, newest first. Find by contents, show
                    recent, or preview one session.
                  </p>
                  <div className="row">
                    <input
                      type="text"
                      aria-label="Search episodic contents"
                      placeholder="Search episodic contents…"
                      value={finderQuery}
                      onChange={(event) => setFinderQuery(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") void runFinderContentsSearch();
                      }}
                    />
                    <button
                      type="button"
                      className="primary icon-text-btn"
                      disabled={finderBusy || trimmedFinderQuery.length === 0}
                      onClick={() => void runFinderContentsSearch()}
                    >
                      <SearchIcon size={14} />
                      <span>Search</span>
                    </button>
                    <button
                      type="button"
                      className="ghost"
                      disabled={finderBusy}
                      onClick={() => void runShowRecentFinder()}
                    >
                      Show Recent
                    </button>
                  </div>
                  <p className="muted text-sm memory-counts">
                    {finderLoadedOnce
                      ? `${resolvedEpisodeCount} episodes stored`
                      : "Loading episodic turns…"}
                  </p>
                  {finderLoadedOnce ? (
                    <div className="row">
                      <span className="muted text-sm">
                        {`${finderResults.length} turns shown`}
                      </span>
                      {finderResults.length > 0 ? (
                        <button
                          type="button"
                          className="danger icon-text-btn"
                          disabled={finderBusy}
                          title={
                            !hasEpisodes ? "No episodic turns stored" : undefined
                          }
                          onClick={() => setPendingDeleteAllShown(true)}
                        >
                          <TrashIcon size={14} />
                          <span>Delete All Shown</span>
                        </button>
                      ) : null}
                    </div>
                  ) : null}
                  {finderResults.length > 0 ? (
                    <div className="memory-results-list">
                      {finderResults.map((item) => {
                        const itemId = finderItemId(item);
                        const sessionID = finderItemSession(item);
                        const role = finderItemRole(item);
                        const stamped = formatFinderTimestamp(
                          finderItemTimestamp(item),
                        );
                        const shortSession = sessionID
                          ? String(sessionID).slice(0, 8)
                          : "";
                        const headerMeta = [shortSession, stamped]
                          .filter(Boolean)
                          .join(" · ");
                        const episodic = isFinderMemoryResult(item);
                        return (
                          <div
                            className="card memory-result-card"
                            key={finderKey(item)}
                          >
                            <div className="memory-card-header">
                              <div className="memory-badges">
                                <span className="badge memory-source-badge">
                                  {role}
                                </span>
                              </div>
                              {headerMeta ? (
                                <span className="muted text-xs">
                                  {headerMeta}
                                </span>
                              ) : null}
                            </div>
                            <div className="memory-card-content">
                              <MarkdownText
                                text={item.content}
                                className="memory-markdown"
                              />
                            </div>
                            {itemId ? (
                              <div className="memory-card-actions">
                                <button
                                  type="button"
                                  className="danger icon-text-btn"
                                  aria-label={
                                    episodic
                                      ? "Delete episodic result"
                                      : `Delete episode ${itemId}`
                                  }
                                  onClick={() => {
                                    if (episodic) {
                                      setPendingSearchEpisodic(
                                        item as MemoryResult,
                                      );
                                    } else {
                                      setPendingEpisodeRow(
                                        item as EpisodicEpisode,
                                      );
                                    }
                                  }}
                                >
                                  <TrashIcon size={14} />
                                  <span>Delete</span>
                                </button>
                              </div>
                            ) : null}
                          </div>
                        );
                      })}
                    </div>
                  ) : null}
                  {finderLoadedOnce &&
                  finderResults.length === 0 &&
                  !finderBusy ? (
                    <p className="muted text-sm">
                      No episodic turns match with current query
                    </p>
                  ) : null}
                </div>

                {/* Episodic cleanup footer: the count comes from the facts tallies
                    so the panel never drifts from the stored store, and both
                    destructive paths confirm behind the centered Modal before
                    reloading the active finder source and tallies. Clearing
                    applies immediately with no restart because every read opens
                    the store directly. */}
                <div className="memory-section-card episodic-cleanup-panel">
                  <h4>Episodic Cleanup</h4>
                  <p className="muted text-sm">
                    {episodeCount !== null
                      ? `${resolvedEpisodeCount} episodic turns stored`
                      : "Loading episodic turns…"}
                  </p>
                  <div className="row episodic-session-row">
                    <input
                      type="text"
                      aria-label="Session UUID"
                      placeholder="Session UUID…"
                      value={sessionInput}
                      onChange={(event) => setSessionInput(event.target.value)}
                    />
                    <button
                      type="button"
                      className="ghost"
                      disabled={
                        finderBusy || trimmedSessionInput.length === 0
                      }
                      onClick={() => void runPreviewSessionFinder()}
                    >
                      Preview
                    </button>
                    <button
                      type="button"
                      className="ghost icon-text-btn"
                      disabled={
                        !hasEpisodes ||
                        trimmedSessionInput.length === 0 ||
                        cleanupBusy
                      }
                      title={!hasEpisodes ? "No episodic turns stored" : undefined}
                      onClick={() => setPendingClearSession(true)}
                    >
                      <TrashIcon size={14} />
                      <span>Clear session</span>
                    </button>
                  </div>
                  <div className="row episodic-clear-all-row">
                    <button
                      type="button"
                      className="danger icon-text-btn"
                      disabled={!hasEpisodes || cleanupBusy}
                      title={!hasEpisodes ? "No episodic turns stored" : undefined}
                      onClick={() => setPendingClearAll(true)}
                    >
                      <TrashIcon size={14} />
                      <span>Clear all episodes</span>
                    </button>
                  </div>
                </div>
              </div>
            ) : null}
          </>
        )}
      </section>

      {/* Centered Modal for persisted fact delete confirmation */}
      {pendingDeleteFact ? (
        <Modal
          label="Confirm delete fact"
          onClose={() => {
            if (deletingFactId === pendingDeleteFact.id) return;
            cancelDeleteFact();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete memory fact?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDeleteFact}
              disabled={deletingFactId === pendingDeleteFact.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete this stored fact. This cannot be undone.
            </p>
            {/* Bounded preview keeps the dialog compact for long facts while
                still showing enough to confirm the right row is targeted. */}
            <p
              className="muted text-sm"
              style={{ margin: "12px 0 0 0", overflowWrap: "anywhere" }}
            >
              &ldquo;
              {pendingDeleteFact.content.length > 120
                ? `${pendingDeleteFact.content.slice(0, 120)}…`
                : pendingDeleteFact.content}
              &rdquo;
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDeleteFact}
              disabled={deletingFactId === pendingDeleteFact.id}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDeleteFact()}
              disabled={deletingFactId === pendingDeleteFact.id}
              aria-label="Confirm delete fact"
            >
              {deletingFactId === pendingDeleteFact.id ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Centered Modal for one Search-tab episodic delete: confirms the
          metadata-id delete before dropping the row and refreshing tallies. */}
      {pendingSearchEpisodic ? (
        <Modal
          label="Confirm delete episodic result"
          onClose={() => {
            if (deletingEpisodicId !== null) return;
            cancelDeleteSearchEpisodic();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete episodic turn?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDeleteSearchEpisodic}
              disabled={deletingEpisodicId !== null}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete this episodic turn. This cannot be undone.
            </p>
            <p
              className="muted text-sm"
              style={{ margin: "12px 0 0 0", overflowWrap: "anywhere" }}
            >
              &ldquo;
              {pendingSearchEpisodic.content.length > 120
                ? `${pendingSearchEpisodic.content.slice(0, 120)}…`
                : pendingSearchEpisodic.content}
              &rdquo;
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDeleteSearchEpisodic}
              disabled={deletingEpisodicId !== null}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDeleteSearchEpisodic()}
              disabled={deletingEpisodicId !== null}
              aria-label="Confirm delete episodic result"
            >
              {deletingEpisodicId !== null ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Centered Modal for one Episodes-tab row delete: same idempotent route
          as Search hits, but the row drops from the recency window. */}
      {pendingEpisodeRow ? (
        <Modal
          label="Confirm delete episode"
          onClose={() => {
            if (deletingEpisodicId !== null) return;
            cancelDeleteEpisodeRow();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete episodic turn?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDeleteEpisodeRow}
              disabled={deletingEpisodicId !== null}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete this episodic turn. This cannot be undone.
            </p>
            <p
              className="muted text-sm"
              style={{ margin: "12px 0 0 0", overflowWrap: "anywhere" }}
            >
              &ldquo;
              {pendingEpisodeRow.content.length > 120
                ? `${pendingEpisodeRow.content.slice(0, 120)}…`
                : pendingEpisodeRow.content}
              &rdquo;
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDeleteEpisodeRow}
              disabled={deletingEpisodicId !== null}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDeleteEpisodeRow()}
              disabled={deletingEpisodicId !== null}
              aria-label="Confirm delete episode"
            >
              {deletingEpisodicId !== null ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Centered Modal for the whole-store episodic clear. Success reloads
          recency and tallies so cleared rows never linger. */}
      {pendingClearAll ? (
        <Modal
          label="Confirm clear all episodes"
          onClose={() => {
            if (cleanupBusy) return;
            cancelClearAllEpisodes();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Clear all episodes?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelClearAllEpisodes}
              disabled={cleanupBusy}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete all {resolvedEpisodeCount} episodic turns.
              Semantic facts and preferences are kept. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelClearAllEpisodes}
              disabled={cleanupBusy}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmClearAllEpisodes()}
              disabled={cleanupBusy}
              aria-label="Confirm clear all episodes"
            >
              {cleanupBusy ? "Clearing…" : "Clear all"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Centered Modal for the per-session episodic clear. The trimmed session
          input addresses the delete; success reloads recency and tallies. */}
      {pendingClearSession ? (
        <Modal
          label="Confirm clear session episodes"
          onClose={() => {
            if (cleanupBusy) return;
            cancelClearSessionEpisodes();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Clear session episodes?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelClearSessionEpisodes}
              disabled={cleanupBusy}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete episodic turns for this session. This
              cannot be undone.
            </p>
            <p
              className="muted text-sm"
              style={{ margin: "12px 0 0 0", overflowWrap: "anywhere" }}
            >
              &ldquo;{trimmedSessionInput}&rdquo;
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelClearSessionEpisodes}
              disabled={cleanupBusy}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmClearSessionEpisodes()}
              disabled={cleanupBusy}
              aria-label="Confirm clear session episodes"
            >
              {cleanupBusy ? "Clearing…" : "Clear session"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Centered Modal for the shown-set bulk delete. States the shown count
          so the owner can audit exactly which window the confirm addresses;
          success reloads tallies plus the active finder source. */}
      {pendingDeleteAllShown ? (
        <Modal
          label="Confirm delete shown episodes"
          onClose={() => {
            if (finderBusy) return;
            cancelDeleteAllShown();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete shown episodes?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDeleteAllShown}
              disabled={finderBusy}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete {finderResults.length} episodic turns
              shown. Semantic facts and preferences are kept. This cannot be
              undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDeleteAllShown}
              disabled={finderBusy}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDeleteAllShown()}
              disabled={finderBusy}
              aria-label="Confirm delete shown episodes"
            >
              {finderBusy ? "Deleting…" : "Delete shown"}
            </button>
          </div>
        </Modal>
      ) : null}
    </>
  );
}
