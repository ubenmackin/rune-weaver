// Rune Weaver Dashboard — Chat interface formatting, clipboard, selection, and parked flight utilities.

import { normalizeLineEndings, type PermissionRequest } from "../../api";
import {
  approvalSessionID,
  isSameSession,
  normalizeSessionID,
} from "../../approvalsSession";
import { formatRelativeAgo } from "../../relativeTime";
import { logWarn } from "../../logger";
import {
  MAX_PARKED_FLIGHTS,
  PARKED_FLIGHT_TTL_MS,
  type MessageItem,
  type ParkedFlight,
  type ParkedFlightStoreOutcome,
  type PrunedParkedFlights,
} from "./chatTypes";
import { flatTextFromSegments } from "./chatTimeline";

export async function copyToClipboard(text: string): Promise<boolean> {
  if (
    typeof navigator !== "undefined" &&
    navigator.clipboard &&
    typeof navigator.clipboard.writeText === "function"
  ) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Fall through to fallback
    }
  }
  if (typeof document !== "undefined" && typeof document.execCommand === "function") {
    try {
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.style.position = "fixed";
      textarea.style.left = "-9999px";
      textarea.style.top = "-9999px";
      document.body.appendChild(textarea);
      textarea.focus();
      textarea.select();
      const success = document.execCommand("copy");
      document.body.removeChild(textarea);
      return success;
    } catch {
      return false;
    }
  }
  return false;
}

export function getMessageCopyContent(message: MessageItem): string {
  const text = (
    message.text ||
    (message.segments ? flatTextFromSegments(message.segments) : "")
  ).trim();
  if (text.length > 0) return text;
  if (message.errorText && message.errorText.trim().length > 0) {
    return message.errorText.trim();
  }
  return "";
}

// Relative completion label sharing the approvals countdown ladder so elapsed time reads with
// identical granularity across the dashboard.
export function formatCompletionRelative(
  completedAtMs: number,
  nowMs: number = Date.now(),
): string {
  return formatRelativeAgo(nowMs - completedAtMs);
}

// Filters the approvals inbox to one session so the chat header badge only
// reflects turns blocked on this conversation; unattributed entries stay in
// the global inbox instead of alarming every session.
export function approvalsForSession(
  approvals: PermissionRequest[] | undefined | null,
  sessionID: string | null | undefined,
): PermissionRequest[] {
  const target = normalizeSessionID(sessionID);
  if (!target) return [];
  return (approvals ?? []).filter((request) => {
    const sid = approvalSessionID(request);
    return isSameSession(sid, target);
  });
}

// Reports whether the user holds a non-collapsed text selection inside the
// message list. A collapsed caret is no selection for scroll purposes, and
// whitespace-only or out-of-list selections never suppress auto-scroll.
export function messageListHasActiveSelection(
  list: HTMLElement | null,
): boolean {
  if (!list) return false;
  const selection = window.getSelection();
  if (!selection) return false;
  if (selection.isCollapsed) return false;
  if (selection.rangeCount === 0) return false;
  if (selection.toString().trim().length === 0) return false;
  const anchor = selection.anchorNode;
  const focus = selection.focusNode;
  if (!anchor || !focus) return false;
  return list.contains(anchor) && list.contains(focus);
}

// Single first-turn title policy: truncates first line to 40 graphemes, matching engine discipline
// so concurrent client pre-names and server auto-titles converge on one value instead of flickering
// under last-write-wins.
export function autoTitleFromPrompt(text: string): string {
  const normalized = normalizeLineEndings(text);
  const parts = normalized.split("\n");
  if (parts.length > 0 && parts[parts.length - 1] === "") {
    parts.pop();
  }
  const firstLine = (parts[0] ?? text).trim();
  let graphemes: string[];
  try {
    const segmenterCtor = (
      Intl as unknown as {
        Segmenter?: new (
          locales?: string | string[],
          options?: { granularity?: string },
        ) => { segment(input: string): Iterable<{ segment: string }> };
      }
    ).Segmenter;
    if (typeof segmenterCtor === "function") {
      graphemes = Array.from(
        new segmenterCtor(undefined, { granularity: "grapheme" }).segment(
          firstLine,
        ),
        (part) => part.segment,
      );
    } else {
      graphemes = [...firstLine];
    }
  } catch {
    graphemes = [...firstLine];
  }
  if (graphemes.length <= 40) return firstLine;
  return graphemes.slice(0, 40).join("") + "…";
}

// Counts user-visible characters with the same grapheme discipline the engine
// enforces, so emoji-heavy drafts meet one bound on both sides instead of
// passing a UTF-16 length check locally and failing the server limit.
export function chatTextLength(text: string): number {
  try {
    const segmenterCtor = (
      Intl as unknown as {
        Segmenter?: new () => { segment(input: string): Iterable<unknown> };
      }
    ).Segmenter;
    if (typeof segmenterCtor === "function") {
      return Array.from(new segmenterCtor().segment(text)).length;
    }
  } catch {
    // Segmenter unavailable; fall through to code-point count below.
  }
  return [...text].length;
}

// Distinguishes a steering rejection from a turn-wide failure so only guidance
// the engine never received rolls back; received guidance stays visible for
// the retry instead of vanishing behind an unrelated failure.
export function isSteerMissText(message: string): boolean {
  return (
    message.includes("Turn ended before steering") ||
    message.includes("steering was not applied") ||
    message.includes("No active turn")
  );
}

// Recognizes the authoritative length refusal in either transport shape so an
// optimistic bubble the server never stored can roll back instead of lingering
// as if it had been received.
export function isTooLongText(message: string): boolean {
  const lowered = message.toLowerCase();
  return (
    lowered.includes("too long") ||
    lowered.includes("exceeds") ||
    lowered.includes("payload too large")
  );
}

// Matches a steering-miss error frame across engine vintages: an explicit miss
// code or steering identity wins when present, with the miss copy as the
// fallback for frames that carry only human-readable text.
export function isSteerMissFrame(frame: Record<string, unknown>): boolean {
  const code = frame.code ?? frame.errorCode;
  if (typeof code === "string" && (code === "steer-miss" || code === "steer_miss")) {
    return true;
  }
  if (typeof frame.steerId === "string" && frame.steerId.length > 0) {
    return true;
  }
  if (typeof frame.steerID === "string" && (frame.steerID as string).length > 0) {
    return true;
  }
  const text =
    typeof frame.message === "string"
      ? (frame.message as string)
      : typeof frame.text === "string"
        ? (frame.text as string)
        : "";
  return typeof text === "string" && text.length > 0 && isSteerMissText(text);
}

// Matches an authoritative length refusal across transports: a numeric 413
// signal wins when present, with the refusal copy as the fallback.
export function isTooLongFrame(frame: Record<string, unknown>): boolean {
  if (frame.code === 413 || frame.status === 413) return true;
  const text =
    typeof frame.message === "string"
      ? (frame.message as string)
      : typeof frame.text === "string"
        ? (frame.text as string)
        : "";
  return typeof text === "string" && text.length > 0 && isTooLongText(text);
}

// Merges terminal warnings over live ones without duplicating the lines the
// engine repeats on done: the terminal frame restates every mid-turn notice,
// so union-by-value keeps one row per skipped tool.
export function mergeWarningLists(previous: string[], next: string[]): string[] {
  if (next.length === 0) return previous;
  const seen = new Set(previous);
  const merged = [...previous];
  for (const entry of next) {
    if (!seen.has(entry)) {
      seen.add(entry);
      merged.push(entry);
    }
  }
  return merged;
}

// Normalizes a flight-map key so engine-uppercase and dashboard-lowercase spellings of one session
// share a single parked entry.
export function parkedFlightKey(id: string | null | undefined): string {
  const normalized = normalizeSessionID(id);
  if (!normalized) {
    logWarn(
      "[ChatView] parked flight key missing session id; background turn has no owner",
    );
  }
  return normalized;
}

// Stores one flight under a least-recently-used cap: touching moves the entry to the fresh end and
// an overfull map evicts the stalest completed shell, falling back to the stalest entry overall so
// the size never exceeds the cap.
export function storeParkedFlight(
  flights: Map<string, ParkedFlight>,
  key: string,
  flight: ParkedFlight,
): ParkedFlightStoreOutcome {
  if (!key) {
    logWarn(
      "[ChatView] dropping parked flight for empty session key; background turn not preserved",
    );
    return { evictedKey: null, evictedLive: false, refused: true };
  }
  if (flights.has(key)) flights.delete(key);
  flights.set(key, flight);
  if (flights.size <= MAX_PARKED_FLIGHTS)
    return { evictedKey: null, evictedLive: false, refused: false };
  let oldestCompletedKey: string | null = null;
  let oldestCompletedAt = Number.POSITIVE_INFINITY;
  for (const [candidateKey, candidate] of flights) {
    if (candidateKey === key) continue;
    if (!candidate.pending && candidate.updatedAt < oldestCompletedAt) {
      oldestCompletedAt = candidate.updatedAt;
      oldestCompletedKey = candidateKey;
    }
  }
  if (oldestCompletedKey) {
    flights.delete(oldestCompletedKey);
    return { evictedKey: oldestCompletedKey, evictedLive: false, refused: false };
  }
  for (const candidateKey of flights.keys()) {
    if (candidateKey === key) continue;
    const evictedLive = flights.get(candidateKey)?.pending ?? false;
    flights.delete(candidateKey);
    logWarn(
      "[ChatView] parked flight map full with live turns; evicted oldest flight to keep cap",
    );
    if (flights.size > MAX_PARKED_FLIGHTS) {
      flights.delete(key);
      logWarn(
        "[ChatView] refusing parked flight; map still over cap after eviction",
      );
      return { evictedKey: candidateKey, evictedLive, refused: true };
    }
    return { evictedKey: candidateKey, evictedLive, refused: false };
  }
  if (flights.size > MAX_PARKED_FLIGHTS) {
    flights.delete(key);
    logWarn(
      "[ChatView] refusing parked flight; map still over cap after eviction",
    );
    return { evictedKey: null, evictedLive: false, refused: true };
  }
  return { evictedKey: null, evictedLive: false, refused: false };
}

// Drops flights whose last activity predates the expiry so a missed terminal
// frame cannot pin a shell forever; live and completed shells age identically
// because both stop receiving frames once settled.
export function pruneExpiredParkedFlights(
  flights: Map<string, ParkedFlight>,
  nowMs: number = Date.now(),
): PrunedParkedFlights {
  const prunedKeys: string[] = [];
  const prunedLiveKeys: string[] = [];
  for (const [key, flight] of [...flights]) {
    if (nowMs - flight.updatedAt > PARKED_FLIGHT_TTL_MS) {
      const wasLive = flight.pending;
      flights.delete(key);
      prunedKeys.push(key);
      if (wasLive) prunedLiveKeys.push(key);
    }
  }
  return { prunedKeys, prunedLiveKeys };
}

// Marks one parked flight settled without replaying its reply: clears the live
// timeline and flips pending so the concurrency cap frees and a later return
// reloads persisted history instead of a stale bubble.
export function settleParkedFlight(flights: Map<string, ParkedFlight>, key: string): void {
  const flight = flights.get(key);
  if (!flight) return;
  flight.pending = false;
  flight.turn = null;
  flight.updatedAt = Date.now();
  flights.delete(key);
  flights.set(key, flight);
}
