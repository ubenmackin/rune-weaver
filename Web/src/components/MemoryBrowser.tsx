// Rune Weaver Dashboard — Memory browser for searching episodic/semantic recall and managing facts.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  deleteFact,
  getFacts,
  searchMemory,
  storeFact,
  type FactsResponse,
  type MemoryResult,
  type UserFact,
} from "../api";
import MarkdownText from "./MarkdownText";
import Modal from "./Modal";
import { CloseIcon, PlusIcon, RefreshIcon, SearchIcon, TrashIcon } from "./icons";

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

export default function MemoryBrowser() {
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

  const loadFacts = useCallback(async () => {
    try {
      setFacts(await getFacts());
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Facts failed");
    }
  }, []);

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
      <section className="panel memory-panel" aria-label="Memory browser">
      <div className="panel-header-row">
        <div>
          <h2>Memory</h2>
          <p className="muted text-sm">
            Search episodic recall, semantic embeddings, and manage stored user facts.
          </p>
        </div>

        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => {
              void loadFacts();
              if (query.trim()) void search();
            }}
            disabled={busy}
          >
            <RefreshIcon size={14} className={busy ? "spin" : ""} />
            <span>{busy ? "Refreshing…" : "Refresh"}</span>
          </button>
        </div>
      </div>

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
      </div>
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
    </>
  );
}
