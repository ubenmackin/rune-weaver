// Rune Weaver Dashboard — Chat token persistence, input history recall stack, and URL session extraction.

import { toNonNegativeInt } from "../../api";
import { normalizeSessionID } from "../../approvalsSession";
import {
  MAX_INPUT_HISTORY,
  strictSessionIDPattern,
  TURN_TIMEOUT_BASE_MS,
  TURN_TIMEOUT_MAX_MS,
  TURN_TIMEOUT_PER_CONTEXT_TOKEN_MS,
} from "./chatTypes";

// Single storage key builder for per-session token caches so session and
// context totals share one prefix shape; the authoritative done frame always
// overwrites whatever was cached here.
export function tokenStoreKey(kind: "session" | "context", id: string): string {
  return kind === "session"
    ? `rw_session_tokens_${id}`
    : `rw_context_tokens_${id}`;
}

// Single loader for cached token totals so reload hydration shares the live
// integer contract instead of flooring a fractional payload one path would
// reject on another.
export function loadTokens(kind: "session" | "context", id: string): number {
  try {
    const raw = localStorage.getItem(tokenStoreKey(kind, id));
    const parsed = raw != null ? Number(raw) : 0;
    return toNonNegativeInt(parsed) ?? 0;
  } catch {
    return 0;
  }
}

// Per-session cached cumulative token total so a reload hydrates the status
// bar instead of resetting to zero; the authoritative `sessionTokens` from
// the next done frame always overwrites it.
export function sessionTokensKey(id: string): string {
  return tokenStoreKey("session", id);
}

export function loadSessionTokens(id: string): number {
  return loadTokens("session", id);
}

export function contextTokensKey(id: string): string {
  return tokenStoreKey("context", id);
}

export function loadContextTokens(id: string): number {
  return loadTokens("context", id);
}

// Per-session input-history storage key so Up/Down recall never leaks across
// sessions. An empty normalized identifier disables storage so untagged
// drafts never share a bucket.
export function historyStorageKey(id: string | null | undefined): string {
  const normalized = normalizeSessionID(id);
  if (!normalized) return "";
  return `rw_input_history_${normalized}`;
}

// Loads the persisted Up/Down recall stack for one session, sanitized to at most MAX_INPUT_HISTORY
// trimmed non-empty strings oldest-first.
export function loadInputHistory(id: string | null | undefined): string[] {
  const key = historyStorageKey(id);
  if (!key) return [];
  try {
    const raw = localStorage.getItem(key);
    if (raw == null) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const cleaned: string[] = [];
    for (const entry of parsed) {
      if (typeof entry !== "string") continue;
      const trimmed = entry.trim();
      if (!trimmed) continue;
      cleaned.push(trimmed);
    }
    return cleaned.slice(-MAX_INPUT_HISTORY);
  } catch {
    return [];
  }
}

// Persists one session's recall stack, sanitized and capped oldest-first.
// Quota or private-mode failures stay silent so sending never fails over
// storage.
export function persistInputHistory(
  id: string | null | undefined,
  entries: string[],
): void {
  const key = historyStorageKey(id);
  if (!key) return;
  try {
    const cleaned: string[] = [];
    for (const entry of entries) {
      if (typeof entry !== "string") continue;
      const trimmed = entry.trim();
      if (!trimmed) continue;
      cleaned.push(trimmed);
    }
    localStorage.setItem(
      key,
      JSON.stringify(cleaned.slice(-MAX_INPUT_HISTORY)),
    );
  } catch {
    // Storage is best-effort only.
  }
}

// Merges a stored recall stack with later additions oldest-first,
// deduplicated so reloads and cross-tab sends converge without duplicates,
// capped to MAX_INPUT_HISTORY.
export function mergeHistoryEntries(stored: string[], additions: string[]): string[] {
  const seen = new Set(stored);
  const merged = [...stored];
  for (const entry of additions) {
    if (typeof entry !== "string") continue;
    if (!entry || seen.has(entry)) continue;
    seen.add(entry);
    merged.push(entry);
  }
  return merged.slice(-MAX_INPUT_HISTORY);
}

// Carries an in-memory recall stack forward when a provisional draft adopts its authoritative
// session identifier: merges and persists under the adopted key, then removes the orphan draft key
// so first turns never leave a permanent `rw_input_history_<draft-uuid>` entry behind.
export function carryHistoryForward(
  fromEntries: string[],
  adoptedID: string | null | undefined,
  draftID?: string | null | undefined,
): string[] {
  const merged = mergeHistoryEntries(
    loadInputHistory(adoptedID),
    fromEntries,
  );
  persistInputHistory(adoptedID, merged);
  try {
    const draftKey = historyStorageKey(draftID);
    const adoptedKey = historyStorageKey(adoptedID);
    if (draftKey && adoptedKey && draftKey !== adoptedKey) {
      localStorage.removeItem(draftKey);
    }
  } catch {
    // Storage is best-effort only.
  }
  return merged;
}

// Compact session total for the collapsed handheld summary line.
export function formatSessionShort(value: number): string {
  const safe = toNonNegativeInt(value) ?? 0;
  if (safe >= 1_000_000) {
    const compact = safe / 1_000_000;
    const rounded = Math.round(compact * 10) / 10;
    return `${Number.isInteger(rounded) ? rounded.toFixed(0) : String(rounded)}M`;
  }
  if (safe >= 1000) {
    const compact = safe / 1000;
    const rounded = Math.round(compact * 10) / 10;
    // One-decimal k rounding can carry 999950-999999 up to 1000k; promote
    // across the boundary to 1M so the compact form never renders the
    // five-character 1000k that defeats its own brevity.
    if (rounded >= 1000) {
      const megaCompact = safe / 1_000_000;
      const megaRounded = Math.round(megaCompact * 10) / 10;
      return `${Number.isInteger(megaRounded) ? megaRounded.toFixed(0) : String(megaRounded)}M`;
    }
    return `${Number.isInteger(rounded) ? rounded.toFixed(0) : String(rounded)}k`;
  }
  return safe.toLocaleString();
}

export function getURLSessionID(): string | null {
  if (typeof window === "undefined") return null;
  const param = new URLSearchParams(window.location.search).get("session");
  if (param && strictSessionIDPattern.test(param)) return param;
  const hash = window.location.hash.replace(/^#/, "");
  if (hash.startsWith("chat/")) {
    const candidate = hash.slice(5).split("?")[0];
    if (strictSessionIDPattern.test(candidate)) return candidate;
  }
  const hashQuery = hash.includes("?") ? hash.substring(hash.indexOf("?")) : "";
  const hashParam = new URLSearchParams(hashQuery).get("session");
  if (hashParam && strictSessionIDPattern.test(hashParam)) return hashParam;
  return null;
}

// Scales the inactivity budget with the model's context window so large prompts on slow local
// models get room to finish prompt evaluation: a small window stays at the 10-minute minimum while a
// large window stretches toward the 15-minute cap instead of the old fixed 5 minutes that cancelled.
export function turnTimeoutMs(contextTokens: number): number {
  const normalized =
    Number.isFinite(contextTokens) && contextTokens > 0
      ? Math.floor(contextTokens)
      : 8192;
  const scaled = normalized * TURN_TIMEOUT_PER_CONTEXT_TOKEN_MS;
  return Math.min(Math.max(TURN_TIMEOUT_BASE_MS, scaled), TURN_TIMEOUT_MAX_MS);
}
