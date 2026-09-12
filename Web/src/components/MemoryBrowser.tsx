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
} from "../api";

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

  async function removeFact(id: string) {
    setError(null);
    try {
      await deleteFact(id);
      await loadFacts();
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Delete fact failed",
      );
    }
  }

  // Stable keys without positional index: duplicates of the same
  // source+content share a base key and are disambiguated by occurrence
  // within that group, so filtering an unrelated row never remounts the
  // survivors. Computed per render from current order only.
  const seenBaseKeys = new Map<string, number>();
  function resultKey(result: MemoryResult): string {
    const base = baseResultKey(result);
    const occurrence = seenBaseKeys.get(base) ?? 0;
    seenBaseKeys.set(base, occurrence + 1);
    return occurrence === 0 ? base : `${base}#${occurrence}`;
  }

  return (
    <section className="panel" aria-label="Memory browser">
      <h2>Memory</h2>
      {error ? <p className="error">{error}</p> : null}
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
          className="primary"
          disabled={busy || query.trim().length === 0}
          onClick={() => void search()}
        >
          Search
        </button>
      </div>
      <div>
        {/* TEMPORARY: MemoryResult has no stable backend id yet. Keys use
            stable bounded identity only (source + 53-bit content hash plus
            a metadata fingerprint, with an occurrence suffix for
            exact-duplicate collisions), never the positional index, full
            content, or unstable score, so reorder/filter never remounts
            identical rows. When the backend adds result.id, use
            key={result.id}. */}
        {results.map((result) => (
          <div className="card" key={resultKey(result)}>
            <div className="muted">
              [{result.source}] {result.score.toFixed(2)}
            </div>
            <div>{result.content}</div>
          </div>
        ))}
      </div>
      <h3>Facts browser</h3>
      <div className="row">
        <input
          type="text"
          aria-label="New fact"
          placeholder="Remember this…"
          value={newFact}
          onChange={(event) => setNewFact(event.target.value)}
        />
        <button
          type="button"
          className="ghost"
          disabled={busy || newFact.trim().length === 0}
          onClick={() => void addFact()}
        >
          Remember
        </button>
      </div>
      <p className="muted">
        {facts
          ? `${facts.facts.length} facts · ${facts.semanticCount} semantic · ${facts.episodeCount} episodes`
          : "Loading facts…"}
      </p>
      {facts?.facts.map((fact) => (
        <div className="card" key={fact.id}>
          <div>{fact.content}</div>
          <div className="muted">{fact.source}</div>
          <button
            type="button"
            className="danger"
            onClick={() => void removeFact(fact.id)}
          >
            Delete
          </button>
        </div>
      ))}
      {facts && facts.preferences.length > 0 ? (
        <div>
          <h4>Preferences</h4>
          {facts.preferences.map((preference) => (
            <div className="card" key={preference.key}>
              <strong>{preference.key}</strong>: {preference.value}
            </div>
          ))}
        </div>
      ) : null}
    </section>
  );
}
