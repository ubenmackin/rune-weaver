// Rune Weaver Dashboard — Memory browser for searching episodic/semantic recall and managing facts.
// Renders one dedicated section per view prop: the Search and Memory view or the Index Status
// dashboard (run controls, stat cards, and frontend-only charts) with no inner tab bar; section
// selection stays with the app shell and policy editing stays in Settings.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  clearEpisodes,
  deleteEpisode,
  deleteFact,
  deleteSessionEpisodes,
  getFacts,
  searchMemory,
  storeFact,
  type FactsResponse,
  type MemoryResult,
  type UserFact,
} from "../api";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
} from "../hooks/useSharedWebSocket";
import IndexingPanel from "./IndexingPanel";
import MarkdownText from "./MarkdownText";
import Modal from "./Modal";
import { CloseIcon, PlusIcon, SearchIcon, TrashIcon } from "./icons";

// Memory section sub-views: recall/facts browsing or the local index status
// dashboard. Each mount renders one dedicated section selected by the view
// prop with no inner tab bar.
export type MemoryTab = "memory" | "indexing";

export interface MemoryBrowserProps {
  view?: MemoryTab;
}

// Initial inner tab from the dashboard deep link: the menu-bar Index Status
// entry navigates to the memory fragment carrying the indexing subpath, so a
// fresh load with that suffix (or an indexing query) opens selected on the
// status pane instead of the default Search and Memory view.
export function getInitialMemoryTab(): MemoryTab {
  if (typeof window === "undefined") return "memory";
  if (window.location.hash.toLowerCase().includes("indexing")) return "indexing";
  if (window.location.search.toLowerCase().includes("indexing")) return "indexing";
  return "memory";
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

export default function MemoryBrowser({ view }: MemoryBrowserProps = {}) {
  const [localTab, setLocalTab] = useState<MemoryTab>(() =>
    view !== undefined ? view : getInitialMemoryTab(),
  );
  const activeTab: MemoryTab = view ?? localTab;
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<MemoryResult[]>([]);
  const [facts, setFacts] = useState<FactsResponse | null>(null);
  const [newFact, setNewFact] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // Non-blocking delete confirmation: the pending fact renders a true modal
  // so an accidental trash click never drops persisted memory without review.
  const [pendingDeleteFact, setPendingDeleteFact] = useState<UserFact | null>(
    null,
  );
  const [deletingFactId, setDeletingFactId] = useState<string | null>(null);
  // Episodic cleanup state stays beside the fact-delete pair so each destructive
  // flow owns its pending row plus busy flag: per-hit delete targets one search
  // hit by metadata id, while the footer panel targets the whole store or one
  // session behind the same centered Modal pattern. Success refetches facts and
  // drops local hits so the panel count and search list never go stale.
  const [sessionInput, setSessionInput] = useState("");
  const [pendingEpisodicResult, setPendingEpisodicResult] =
    useState<MemoryResult | null>(null);
  const [deletingEpisodicId, setDeletingEpisodicId] = useState<string | null>(
    null,
  );
  const [pendingClearAll, setPendingClearAll] = useState(false);
  const [pendingClearSession, setPendingClearSession] = useState(false);
  const [cleanupBusy, setCleanupBusy] = useState(false);

  const loadFacts = useCallback(async () => {
    try {
      setFacts(await getFacts());
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Facts failed");
    }
  }, []);

  // Live refresh without a manual control: any terminal run broadcast
  // (scheduler, chat, or index pass) reloads stored facts so the list stays
  // fresh while the view is open. Progress frames stay with the indexing pane.
  const handleRunBroadcast = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as WSGenericFrame).type;
      if (frameType !== "run_completed") return;
      void loadFacts();
    },
    [loadFacts],
  );

  useSharedWebSocket(handleRunBroadcast);

  // Follows the Index Status deep link while the view is open: a menu-bar
  // navigation to the memory fragment carrying the indexing subpath selects
  // the status pane instead of leaving the default view mounted. Syncs both
  // ways so leaving the deep link (back navigation or a plain memory link)
  // returns to the Search and Memory view instead of stranding the status
  // pane. Hash edits fire hashchange while query-only history moves fire
  // popstate, so both are observed. Skipped when the view prop controls the
  // tab so the URL never overrides the selected view.
  useEffect(() => {
    if (view !== undefined) return;
    function syncTabFromUrl() {
      if (typeof window === "undefined") return;
      const isIndexing =
        window.location.hash.toLowerCase().includes("indexing") ||
        window.location.search.toLowerCase().includes("indexing");
      setLocalTab(isIndexing ? "indexing" : "memory");
    }
    window.addEventListener("hashchange", syncTabFromUrl);
    window.addEventListener("popstate", syncTabFromUrl);
    return () => {
      window.removeEventListener("hashchange", syncTabFromUrl);
      window.removeEventListener("popstate", syncTabFromUrl);
    };
  }, [view]);

  useEffect(() => {
    let cancelled = false;
    getFacts()
      .then((response) => {
        if (!cancelled) setFacts(response);
      })
      .catch((failure) => {
        if (!cancelled) {
          setError(failure instanceof ApiError ? failure.message : "Facts failed");
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function search() {
    const trimmed = query.trim();
    if (!trimmed) return;
    setBusy(true);
    setError(null);
    try {
      const response = await searchMemory(trimmed, 10);
      setResults(response.memories);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Search failed");
    } finally {
      setBusy(false);
    }
  }

  async function addFact() {
    const content = newFact.trim();
    if (!content) return;
    setBusy(true);
    setError(null);
    try {
      await storeFact(content, "dashboard");
      setNewFact("");
      await loadFacts();
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Store fact failed",
      );
    } finally {
      setBusy(false);
    }
  }

  async function confirmDeleteFact() {
    if (!pendingDeleteFact) return;
    const fact = pendingDeleteFact;
    setDeletingFactId(fact.id);
    setError(null);
    try {
      await deleteFact(fact.id);
      await loadFacts();
      setPendingDeleteFact(null);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Delete fact failed",
      );
    } finally {
      setDeletingFactId(null);
    }
  }

  function cancelDeleteFact() {
    setPendingDeleteFact(null);
  }

  // Confirms one per-hit episodic delete by the hit's metadata id, then drops
  // exactly that row from local results and reloads facts so the footer count
  // settles without a restart. A hit without an id never reaches here because
  // its Delete affordance stays hidden.
  async function confirmDeleteEpisodicResult() {
    if (!pendingEpisodicResult) return;
    const target = pendingEpisodicResult;
    const episodeId = target.metadata?.id;
    if (!episodeId) {
      setPendingEpisodicResult(null);
      return;
    }
    setDeletingEpisodicId(episodeId);
    setError(null);
    try {
      await deleteEpisode(episodeId);
      setResults((previous) =>
        previous.filter((row) => row.metadata?.id !== episodeId),
      );
      await loadFacts();
      setPendingEpisodicResult(null);
    } catch (failure) {
      setError(
        failure instanceof ApiError
          ? failure.message
          : "Delete episodic result failed",
      );
    } finally {
      setDeletingEpisodicId(null);
    }
  }

  function cancelDeleteEpisodicResult() {
    setPendingEpisodicResult(null);
  }

  // Confirms the whole-store episodic clear behind the same centered Modal as
  // fact delete. On success the panel refetches facts and drops local hits so
  // a stale search list cannot resurrect cleared rows.
  async function confirmClearAllEpisodes() {
    setCleanupBusy(true);
    setError(null);
    try {
      await clearEpisodes();
      setResults([]);
      await loadFacts();
      setPendingClearAll(false);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Clear episodes failed",
      );
    } finally {
      setCleanupBusy(false);
    }
  }

  function cancelClearAllEpisodes() {
    setPendingClearAll(false);
  }

  // Confirms the per-session episodic clear using the trimmed session input at
  // confirm time, then refetches facts and drops local hits like the
  // whole-store path. A blank input never reaches here because its button stays
  // disabled.
  async function confirmClearSessionEpisodes() {
    const sessionID = sessionInput.trim();
    if (!sessionID) return;
    setCleanupBusy(true);
    setError(null);
    try {
      await deleteSessionEpisodes(sessionID);
      setResults([]);
      await loadFacts();
      setPendingClearSession(false);
    } catch (failure) {
      setError(
        failure instanceof ApiError
          ? failure.message
          : "Clear session episodes failed",
      );
    } finally {
      setCleanupBusy(false);
    }
  }

  function cancelClearSessionEpisodes() {
    setPendingClearSession(false);
  }

  // Zero stored turns disables both destructive footer buttons with an honest
  // title, while a blank session input disables only its own button so the
  // whole-store path stays available when episodes exist.
  const episodeCount = facts?.episodeCount ?? 0;
  const hasEpisodes = episodeCount > 0;
  const trimmedSessionInput = sessionInput.trim();

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

  return (
    <>
      <section
        className="panel memory-panel"
        aria-label={activeTab === "indexing" ? "Index Status" : "Memory browser"}
      >
        <div className="panel-header-row">
          <div>
            <h2>{activeTab === "indexing" ? "Index Status" : "Memory"}</h2>
            <p className="muted text-sm">
              {activeTab === "indexing"
                ? "Monitor the local file, mail, and Messages index."
                : "Search episodic recall and semantic memory, manage stored user facts."}
            </p>
          </div>
        </div>

        {activeTab === "indexing" ? (
          <div
            id="memory-panel-index"
            aria-label="Index Status"
          >
            <IndexingPanel hideHeader />
          </div>
        ) : (
          <div
            id="memory-panel-search"
            aria-label="Search and Memory"
          >
            {error ? <p className="error">{error}</p> : null}

          <div className="memory-search-section">
            <h3>Search</h3>
            <div className="row">
              <input
                type="text"
                aria-label="Memory search"
                placeholder="Search memories…"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") void search();
                }}
              />
              <button
                type="button"
                className="primary icon-text-btn"
                disabled={busy || query.trim().length === 0}
                onClick={() => void search()}
              >
                <SearchIcon size={14} />
                <span>Search</span>
              </button>
            </div>
          </div>

      {results.length > 0 ? (
        <div className="memory-results-container">
          <h4>Search Results ({results.length})</h4>
          <div className="memory-results-list">
            {/* TEMPORARY: MemoryResult has no stable backend id yet. */}
            {results.map((result) => (
              <div className="card memory-result-card" key={resultKey(result)}>
                <div className="memory-card-header">
                  <div className="memory-badges">
                    <span className="badge memory-source-badge">{result.source}</span>
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
                {/* Only episodic hits with a stored id offer deletion: semantic and
                    profile rows have no episode row to delete, and an episodic hit
                    without metadata id cannot address its row. */}
                {result.source === "episodic" && result.metadata?.id ? (
                  <div className="memory-card-actions">
                    <button
                      type="button"
                      className="danger icon-text-btn"
                      aria-label="Delete episodic result"
                      onClick={() => setPendingEpisodicResult(result)}
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

      <div className="memory-facts-section">
        <h3>User Facts & Knowledge</h3>
        <p className="muted text-sm">
          Add persistent facts, background context, or personal preferences for the agent to remember.
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
            disabled={busy || newFact.trim().length === 0}
            onClick={() => void addFact()}
          >
            <PlusIcon size={14} />
            <span>Remember</span>
          </button>
        </div>

        <p className="muted text-sm memory-counts">
          {facts
            ? `${facts.facts.length} facts · ${facts.semanticCount} semantic · ${facts.episodeCount} episodes`
            : "Loading facts…"}
        </p>

        <div className="facts-list">
          {facts?.facts.map((fact) => (
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

        {facts && facts.preferences.length > 0 ? (
          <div className="memory-preferences-section">
            <h4>Preferences</h4>
            <div className="preferences-list">
              {facts.preferences.map((preference) => (
                <div className="card preference-card" key={preference.key}>
                  <strong>{preference.key}</strong>: <span>{preference.value}</span>
                </div>
              ))}
            </div>
          </div>
        ) : null}

        {/* Episodic cleanup footer: the count comes from the facts payload so
            the panel never drifts from the stored store, and both destructive
            paths confirm behind the centered Modal before refetching facts and
            dropping stale search hits. Clearing applies immediately with no
            restart because every read opens the store directly. */}
        <div className="episodic-cleanup-panel">
          <h4>Episodic cleanup</h4>
          <p className="muted text-sm">
            {facts
              ? `${facts.episodeCount} episodic turns stored`
              : "Loading episodic turns…"}
          </p>
          <div className="row">
            <input
              type="text"
              aria-label="Session UUID"
              placeholder="Session UUID…"
              value={sessionInput}
              onChange={(event) => setSessionInput(event.target.value)}
            />
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
          <div className="row">
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
        </div>
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
              This will permanently delete this stored fact. This cannot be
              undone.
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

      {/* Centered Modal for one episodic search-hit delete: confirms the
          metadata-id delete before dropping the row and reloading facts. */}
      {pendingEpisodicResult ? (
        <Modal
          label="Confirm delete episodic result"
          onClose={() => {
            if (deletingEpisodicId !== null) return;
            cancelDeleteEpisodicResult();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete episodic turn?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDeleteEpisodicResult}
              disabled={deletingEpisodicId !== null}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently delete this episodic turn. This cannot be
              undone.
            </p>
            <p
              className="muted text-sm"
              style={{ margin: "12px 0 0 0", overflowWrap: "anywhere" }}
            >
              &ldquo;
              {pendingEpisodicResult.content.length > 120
                ? `${pendingEpisodicResult.content.slice(0, 120)}…`
                : pendingEpisodicResult.content}
              &rdquo;
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDeleteEpisodicResult}
              disabled={deletingEpisodicId !== null}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDeleteEpisodicResult()}
              disabled={deletingEpisodicId !== null}
              aria-label="Confirm delete episodic result"
            >
              {deletingEpisodicId !== null ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Centered Modal for the whole-store episodic clear. Success refetches
          facts and drops local hits so cleared rows never linger. */}
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
              This will permanently delete all {episodeCount} episodic turns.
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
          input addresses the delete; success refetches facts and drops hits. */}
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
    </>
  );
}
