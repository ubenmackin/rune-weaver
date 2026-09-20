// Rune Weaver Dashboard — Interactive chat interface with session history sidebar,
// animated typing indicator, distinct tool activity display, and attached status bar.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  cancelChat,
  compareToolActionsByRound,
  concurrentTurnsBusyMessage,
  decideApproval,
  getSession,
  getSessionToolActions,
  groupToolActionsByRound,
  isActiveRunStatus,
  listApprovals,
  MAX_CHAT_TEXT_LENGTH,
  newSessionId,
  normalizeLineEndings,
  normalizeRoundIndex,
  parseRunTimestamp,
  parseToolProgress,
  placeholderCallIDsInText,
  postChat,
  resolveMaxConcurrentChatTurns,
  sortToolActionsByRound,
  textContainsPlaceholderForCall,
  toNonNegativeInt,
  toolCancel,
  updateSessionTitle,
  type ChatSegment,
  type HealthResponse,
  type PermissionRequest,
  type SessionMessageToolActions,
  type ToolAction,
  type ToolProgress,
  type ToolResult,
  type TrustDuration,
} from "../api";
import SessionSidebar from "./SessionSidebar";
import InlineApprovalBanner from "./InlineApprovalBanner";
import MarkdownText from "./MarkdownText";
import ToolActionRow from "./ToolActionRow";
import { WrenchIcon } from "./icons";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
import { useRunningRuns, type FrozenRunLogEntry } from "../hooks/useRunningRuns";
import type {
  WSIncomingFrame,
  WSToolEndFrame,
  WSToolStartFrame,
} from "../hooks/useSharedWebSocket";
import {
  approvalSessionID,
  isRecord,
  isSameSession,
  mergeApprovalFrame,
  normalizeSessionID,
  runSessionID,
} from "../approvalsSession";
import { sanitizeWarnings } from "../warnings";
import { formatRelativeAgo } from "../relativeTime";
import { logWarn } from "../logger";

interface MessageItem {
  id: string;
  role: "user" | "assistant" | "system" | "tool";
  text: string;
  toolActions?: ToolAction[];
  // Chronological timeline for this turn: text and tool batches alternate in the
  // order the engine produced them so multi-round turns never collapse into one
  // lumped bucket. Flat `text`/`toolActions` stay as back-compat summaries while
  // rendering walks this list in order; absent on turns built before segmentation.
  segments?: ChatSegment[];
  // Completion instant as milliseconds since the epoch on the server clock.
  // The stamp stays grounded in the persisted creation time so live cards and
  // history reloads agree; an omitted stamp renders no footer.
  completedAt?: number;
}

interface InFlightTurn {
  toolActions: ToolAction[];
  text: string;
  // Live chronological timeline built incrementally: the current text segment
  // closes when a tool starts and a fresh text segment opens on the next delta
  // after tools, mirroring the persisted per-round note boundaries for reloads.
  segments: ChatSegment[];
}

// One background turn parked while the user browses another session. The map
// below keys these by normalized session so rapid switches never interleave
// deltas and a return restores the exact live timeline instead of restarting.
// Warnings and token progress travel with the turn for the same reason: one
// session's skipped tools or running sum must never leak into another view.
interface ParkedFlight {
  turn: InFlightTurn | null;
  pending: boolean;
  warnings: string[];
  turnTokens: number | null;
  base: number;
  cancelled: boolean;
  // Last live activity for this flight. Drives least-recently-used eviction and
  // expiry so hidden sessions cannot accumulate without bound while the user
  // keeps browsing; refreshed on every parked frame and on park.
  updatedAt: number;
}

// Normalizes a flight-map key so engine-uppercase and dashboard-lowercase
// spellings of one session share a single parked entry. An empty result means
// the caller lost the owning session, so report through the centralized
// logger instead of letting the turn vanish silently into an unkeyed bucket.
function parkedFlightKey(id: string | null | undefined): string {
  const normalized = normalizeSessionID(id);
  if (!normalized) {
    logWarn(
      "[ChatView] parked flight key missing session id; background turn has no owner",
    );
  }
  return normalized;
}

// Bounds the per-session flight map so hidden sessions cannot accumulate
// without bound while the user keeps browsing. Completed shells evict first
// because dropping a finished timeline loses nothing, with the stalest live
// flight as the hard-cap fallback so the size never exceeds the bound,
// while the expiry outlives the longest healthy inference budget so a slow
// local evaluation never ages out mid-turn. The settle grace keeps a freshly
// parked turn alive until its running row persists, so polling a stale settled
// row never evicts a live turn on a slow persist.
const MAX_PARKED_FLIGHTS = 10;
const PARKED_FLIGHT_TTL_MS = 30 * 60 * 1000;
const PARKED_SETTLE_GRACE_MS = 10 * 1000;

// Outcome of a capped store so callers can surface lossy evictions through
// component state. Completed-shell evictions lose nothing and stay quiet;
// live evictions and refusals drop runnable timelines and must reach visible
// state instead of a production-silent log.
interface ParkedFlightStoreOutcome {
  evictedKey: string | null;
  evictedLive: boolean;
  refused: boolean;
}

// Stores one flight under a least-recently-used cap: touching moves the entry
// to the fresh end and an overfull map evicts the stalest completed shell,
// falling back to the stalest entry overall so the size never exceeds the cap.
// Completed shells go first because dropping a finished timeline loses nothing;
// the fallback drops the stalest live flight whose next frame rebuilds it,
// while expiry still reclaims idle shells and the settle grace keeps a freshly
// parked turn alive until its running row persists.
function storeParkedFlight(
  flights: Map<string, ParkedFlight>,
  key: string,
  flight: ParkedFlight,
): ParkedFlightStoreOutcome {
  // An empty key would silently discard the background turn, so refuse through
  // the centralized logger and report refusal so the caller surfaces it in
  // state instead of dropping streamed progress quietly.
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
  // Every remaining entry is still live, so evict the stalest entry overall to
  // keep the atomic cap instead of growing past it. The evicted flight rebuilds
  // from its next frame while the badge stays lit, so no running turn goes dark.
  // The outcome reports the live drop so the caller surfaces it in state; the
  // dev log stays as the loud local mirror, never the sole prod signal.
  for (const candidateKey of flights.keys()) {
    if (candidateKey === key) continue;
    const evictedLive = flights.get(candidateKey)?.pending ?? false;
    flights.delete(candidateKey);
    logWarn(
      "[ChatView] parked flight map full with live turns; evicted oldest flight to keep cap",
    );
    // Defensive refusal keeps the invariant when the new key alone overflows:
    // dropping the just-parked flight is louder than silently exceeding the cap.
    if (flights.size > MAX_PARKED_FLIGHTS) {
      flights.delete(key);
      logWarn(
        "[ChatView] refusing parked flight; map still over cap after eviction",
      );
      return { evictedKey: candidateKey, evictedLive, refused: true };
    }
    return { evictedKey: candidateKey, evictedLive, refused: false };
  }
  // Defensive refusal keeps the invariant when the new key alone overflows:
  // dropping the just-parked flight is louder than silently exceeding the cap.
  if (flights.size > MAX_PARKED_FLIGHTS) {
    flights.delete(key);
    logWarn(
      "[ChatView] refusing parked flight; map still over cap after eviction",
    );
    return { evictedKey: null, evictedLive: false, refused: true };
  }
  return { evictedKey: null, evictedLive: false, refused: false };
}

// Expired-flight reclaim result so callers can clear badges and surface live
// drops through state. Idle shells of either kind age identically because both
// stop receiving frames once settled; the grace for freshly parked turns lives
// with the caller, not here.
interface PrunedParkedFlights {
  prunedKeys: string[];
  prunedLiveKeys: string[];
}

// Drops flights whose last activity predates the expiry so a missed terminal
// frame cannot pin a shell forever; live and completed shells age identically
// because both stop receiving frames once settled.
function pruneExpiredParkedFlights(
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
function settleParkedFlight(flights: Map<string, ParkedFlight>, key: string): void {
  const flight = flights.get(key);
  if (!flight) return;
  flight.pending = false;
  flight.turn = null;
  flight.updatedAt = Date.now();
  // Re-insert to refresh LRU order like ensureFlight so the settled shell sorts
  // by its settle time instead of its park time and eviction keeps picking the
  // true stalest shell.
  flights.delete(key);
  flights.set(key, flight);
}

// Folds flat summaries from an ordered timeline so legacy readers that only know
// `text`/`toolActions` still see the same content that segmented rendering shows.
function flatTextFromSegments(segments: ChatSegment[]): string {
  return segments
    .filter((segment) => segment.kind === "text")
    .map((segment) => segment.text)
    .filter(Boolean)
    .join("\n\n")
    .trim();
}

// Flattens tool batches oldest-first so the legacy bucket matches segment order.
function flatActionsFromSegments(segments: ChatSegment[]): ToolAction[] {
  const flat: ToolAction[] = [];
  for (const segment of segments) {
    if (segment.kind === "tools") flat.push(...segment.actions);
  }
  return flat;
}

// Appends one started call to the live timeline, closing the open text segment
// by opening a fresh tools batch instead of concatenating onto prior prose.
function appendToolStartToSegments(
  segments: ChatSegment[],
  action: ToolAction,
): ChatSegment[] {
  const next = segments.map((segment) =>
    segment.kind === "tools"
      ? { kind: "tools" as const, actions: [...segment.actions] }
      : { ...segment },
  );
  const last = next[next.length - 1];
  if (last && last.kind === "tools") {
    last.actions.push(action);
    return next;
  }
  return [...next, { kind: "tools" as const, actions: [action] }];
}

// Merges one completed result into the matching live batch by call identity so
// resumed batches rejoin the same timeline instead of forking a duplicate row.
// Without a call-identity match the result attributes to at most the first
// pending same-tool row in timeline order, so batches with multiple same-tool
// calls never fan one result out to every pending sibling; when no pending
// same-tool row exists the frame drops instead of guessing an owner.
function updateToolEndInSegments(
  segments: ChatSegment[],
  callID: string,
  toolName: string,
  result: ToolResult | null,
  roundIndex?: number,
): ChatSegment[] {
  const hasCallIDMatch = segments.some(
    (segment) =>
      segment.kind === "tools" &&
      segment.actions.some((action) => action.callID === callID),
  );
  if (hasCallIDMatch) {
    return segments.map((segment) => {
      if (segment.kind !== "tools") return segment;
      return {
        kind: "tools" as const,
        actions: segment.actions.map((action) =>
          action.callID === callID
            ? {
                ...action,
                result,
                ...(roundIndex !== undefined ? { roundIndex } : {}),
              }
            : action,
        ),
      };
    });
  }
  let claimed = false;
  return segments.map((segment) => {
    if (segment.kind !== "tools" || claimed) return segment;
    let updatedInSegment = false;
    const actions = segment.actions.map((action) => {
      if (!claimed && !action.result && action.toolName === toolName) {
        claimed = true;
        updatedInSegment = true;
        return {
          ...action,
          result,
          ...(roundIndex !== undefined ? { roundIndex } : {}),
        };
      }
      return action;
    });
    if (!updatedInSegment) return segment;
    return {
      kind: "tools" as const,
      actions,
    };
  });
}

// Appends streamed prose to the live timeline, opening a fresh text segment when
// the previous piece is a tool batch so text never merges across round bounds.
function appendDeltaToSegments(
  segments: ChatSegment[],
  deltaText: string,
): ChatSegment[] {
  if (!deltaText) return segments;
  const next = segments.map((segment) =>
    segment.kind === "tools"
      ? { kind: "tools" as const, actions: [...segment.actions] }
      : { ...segment },
  );
  const last = next[next.length - 1];
  if (last && last.kind === "text") {
    return [
      ...next.slice(0, -1),
      { kind: "text" as const, text: last.text + deltaText },
    ];
  }
  return [...next, { kind: "text" as const, text: deltaText }];
}

// Keeps only prose lines not already covered by structured actions, identified
// by the authoritative call identifier, so narration fallback lines never
// double-count with structured actions while unrelated prose stays visible.
function filterUncoveredText(text: string, coveredCallIDs: Set<string>): string {
  // Single line-ending and placeholder sources keep history coverage identical
  // to the shared helpers: carriage returns fold like the engine before
  // matching, and the set grammar decides cover so prose that merely mentions
  // an identifier never hides and future grammar changes land in one place.
  const normalized = normalizeLineEndings(text);
  return normalized
    .split("\n")
    .filter((line) => {
      if (!line.trim()) return false;
      const ids = placeholderCallIDsInText(line);
      if (ids.size === 0) return true;
      for (const id of ids) {
        if (coveredCallIDs.has(id)) return false;
      }
      return true;
    })
    .join("\n")
    .trim();
}

// Collapses repeats of one execution to a single row, keeping the
// execution-backed record over a pending twin so a narrated line plus its
// persisted placeholder never renders as two boxes for one call.
function deduplicateToolActionsByCallID(actions: ToolAction[]): ToolAction[] {
  const best = new Map<string, ToolAction>();
  const order: string[] = [];
  const unidentified: ToolAction[] = [];
  for (const action of actions) {
    if (!action.callID) {
      unidentified.push(action);
      continue;
    }
    const existing = best.get(action.callID);
    if (!existing) {
      best.set(action.callID, action);
      order.push(action.callID);
      continue;
    }
    const existingHasResult = existing.result != null;
    const candidateHasResult = action.result != null;
    if (candidateHasResult && !existingHasResult) {
      best.set(action.callID, action);
    }
  }
  return [...order.map((id) => best.get(id) as ToolAction), ...unidentified];
}

// Shared cold builder for terminal timelines without a live skeleton: dedups by
// preserved call identity, orders oldest-first, groups one tools segment per
// round, then trails uncovered prose. Done and REST paths share it so polling
// and streaming clients interleave identically instead of drifting.
function buildSegmentsFromActionsAndText(
  actions: ToolAction[],
  text: string,
): ChatSegment[] {
  const deduped = deduplicateToolActionsByCallID(actions);
  const ordered = [...deduped].sort(compareToolActionsByRound);
  const built: ChatSegment[] = [];
  for (const group of groupToolActionsByRound(ordered)) {
    built.push({ kind: "tools" as const, actions: group });
  }
  const trailing = text.trim();
  // Avoid duplicating narration fallback lines already covered by structured
  // actions: only uncovered prose becomes a text segment. Without a structured
  // record every line stays visible, so fall back to the full text when all
  // lines filter but no tool segment exists.
  if (trailing.length > 0) {
    const covered = new Set(ordered.map((a) => a.callID).filter(Boolean));
    const uncovered = filterUncoveredText(trailing, covered);
    if (uncovered.length > 0) {
      built.push({ kind: "text" as const, text: uncovered });
    } else if (built.length === 0) {
      built.push({ kind: "text" as const, text: trailing });
    }
  }
  return built;
}

// Builds a terminal timeline from the streamed skeleton plus authoritative done
// actions: tool results merge by call identity while the streamed text order
// stays, so live and reload render the same interleaving without double-counting.
function buildDoneSegments(
  snapshotSegments: ChatSegment[],
  doneToolActions: ToolAction[],
  doneText: string | undefined,
  snapshotText: string,
): ChatSegment[] {
  const dedupedDone = deduplicateToolActionsByCallID(doneToolActions);
  const byCallID = new Map<string, ToolAction>();
  for (const action of dedupedDone) {
    if (action.callID) byCallID.set(action.callID, action);
  }
  if (snapshotSegments.length > 0) {
    const merged = snapshotSegments.map((segment) => {
      if (segment.kind !== "tools") return segment;
      const refreshed = segment.actions.map((action) => {
        const authoritative = action.callID
          ? byCallID.get(action.callID)
          : undefined;
        return authoritative ? { ...authoritative } : { ...action };
      });
      // A narrated line plus its persisted twin share one identifier after the
      // backend preserves call IDs, so collapse repeats here as well.
      return {
        kind: "tools" as const,
        actions: deduplicateToolActionsByCallID(refreshed),
      };
    });
    // Done actions for calls never streamed (parked resumes) append as their own
    // round groups so the same turn timeline grows instead of dropping them.
    const streamedCallIDs = new Set(
      merged.flatMap((segment) =>
        segment.kind === "tools"
          ? segment.actions.map((action) => action.callID)
          : [],
      ),
    );
    const missing = dedupedDone.filter(
      (action) => action.callID && !streamedCallIDs.has(action.callID),
    );
    if (missing.length > 0) {
      const groups = groupToolActionsByRound(
        [...missing].sort(compareToolActionsByRound),
      );
      for (const group of groups) {
        merged.push({ kind: "tools" as const, actions: group });
      }
    }
    // The streamed skeleton already carries every round's prose in order; the
    // terminal text repeats only the final round, so preferring it would discard
    // intermediate narration. Keep streamed prose unless nothing streamed.
    const hasStreamedText = merged.some(
      (segment) => segment.kind === "text" && segment.text.trim().length > 0,
    );
    if (!hasStreamedText && doneText && doneText.trim().length > 0) {
      merged.push({ kind: "text" as const, text: doneText });
    } else if (
      !hasStreamedText &&
      snapshotText.trim().length > 0 &&
      (!doneText || doneText.trim().length === 0)
    ) {
      merged.push({ kind: "text" as const, text: snapshotText });
    }
    return merged;
  }
  // No live skeleton (cold done): share the grouped builder with the REST path
  // so both order and cover-filter identically.
  return buildSegmentsFromActionsAndText(
    dedupedDone,
    doneText ?? snapshotText ?? "",
  );
}

// Builds REST fallback timelines without a live skeleton: round groups in order
// then the terminal text, so polling clients agree with streaming ones.
function buildRestSegments(actions: ToolAction[], text: string): ChatSegment[] {
  return buildSegmentsFromActionsAndText(actions, text);
}

const MAX_MESSAGES = 200;

// Maximum steering texts tracked for retraction. Mirrors the engine
// SteeringQueue.maxPendingPerSession so the optimistic list sheds the same
// oldest entry the server queue drops on overflow.
const MAX_PENDING_STEERS = 20;

// Counts user-visible characters with the same grapheme discipline the engine
// enforces, so emoji-heavy drafts meet one bound on both sides instead of
// passing a UTF-16 length check locally and failing the server limit.
function chatTextLength(text: string): number {
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
    // Segmenter unavailable; fall through to the code-point count below.
  }
  return [...text].length;
}

// Distinguishes a steering rejection from a turn-wide failure so only guidance
// the engine never received rolls back; received guidance stays visible for
// the retry instead of vanishing behind an unrelated failure.
function isSteerMissText(message: string): boolean {
  return (
    message.includes("Turn ended before steering") ||
    message.includes("steering was not applied") ||
    message.includes("No active turn")
  );
}

// Recognizes the authoritative length refusal in either transport shape so an
// optimistic bubble the server never stored can roll back instead of lingering
// as if it had been received.
function isTooLongText(message: string): boolean {
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
function isSteerMissFrame(frame: Record<string, unknown>): boolean {
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
function isTooLongFrame(frame: Record<string, unknown>): boolean {
  if (frame.code === 413 || frame.status === 413) return true;
  const text =
    typeof frame.message === "string"
      ? (frame.message as string)
      : typeof frame.text === "string"
        ? (frame.text as string)
        : "";
  return typeof text === "string" && text.length > 0 && isTooLongText(text);
}

// Interim waiting placeholder prefix for parked approval turns. The engine composes parked text
// without a structured history flag (`waitingOnApprovalMessage`: "Waiting for approval to run
// ..."), so live updates and history reconstruction key interim detection on this prefix.
const WAITING_PREFIX = "Waiting for approval";

// Single storage key builder for per-session token caches so session and
// context totals share one prefix shape; the authoritative done frame always
// overwrites whatever was cached here.
function tokenStoreKey(kind: "session" | "context", id: string): string {
  return kind === "session"
    ? `rw_session_tokens_${id}`
    : `rw_context_tokens_${id}`;
}

// Single loader for cached token totals so reload hydration shares the live
// integer contract instead of flooring a fractional payload one path would
// reject on another.
function loadTokens(kind: "session" | "context", id: string): number {
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
function sessionTokensKey(id: string): string {
  return tokenStoreKey("session", id);
}

function loadSessionTokens(id: string): number {
  return loadTokens("session", id);
}

function contextTokensKey(id: string): string {
  return tokenStoreKey("context", id);
}

function loadContextTokens(id: string): number {
  return loadTokens("context", id);
}

// Validates a tool result before it enters turn state: the engine always
// emits the call identifier, content, and error flag together, so a partial
// object must never render as a completed execution.
function isToolResult(value: unknown): value is ToolResult {
  if (!isRecord(value)) return false;
  return (
    typeof value.toolCallID === "string" &&
    typeof value.content === "string" &&
    typeof value.isError === "boolean"
  );
}

// Validates a tool action before it enters message or turn state, keeping
// history rendering honest about which executions actually ran.
function isToolAction(value: unknown): value is ToolAction {
  if (!isRecord(value)) return false;
  if (typeof value.toolName !== "string") return false;
  if (typeof value.callID !== "string") return false;
  if (typeof value.argumentsJSON !== "string") return false;
  const result = value.result;
  return result == null || isToolResult(result);
}

// Normalizes a completion instant from either wire shape the engine emits
// (ISO-8601 strings from Vapor versus Unix seconds as JSON numbers from
// SQLite persistence) into milliseconds since the epoch. Epoch and
// unparseable stamps drop to undefined so callers render no footer rather
// than a 1970 date, and future skew is handled by the relative formatter.
function normalizeCompletedAtMs(value: unknown): number | undefined {
  if (value == null) return undefined;
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const parsed = parseRunTimestamp(value).getTime();
  if (!Number.isFinite(parsed) || parsed <= 0) return undefined;
  return parsed;
}

// Relative completion label sharing the approvals countdown ladder so elapsed
// time reads with identical granularity across the dashboard. Future stamps
// from clock skew and sub-second deltas collapse to "just now" rather than
// rendering a negative countdown or "0s ago".
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

// Liveness-aware inactivity budget for a WebSocket-started turn. A socket that
// drops with no subsequent activity must not strand the input disabled forever,
// but healthy local inference can spend minutes in prompt evaluation with zero
// deltas to render — the server covers those stretches with session-tagged
// turn_alive heartbeats that re-arm this timer without rendering. Reset on each
// tool execution, streaming delta, approval prompt, warning, or heartbeat so
// multi-turn tool chains never time out while active; only a truly silent
// socket (no frames at all) trips the timeout, while a dropped socket takes
// the immediate close path instead.
const TURN_TIMEOUT_BASE_MS = 600_000;
const TURN_TIMEOUT_PER_CONTEXT_TOKEN_MS = 30;
const TURN_TIMEOUT_MAX_MS = 900_000;

// Scales the inactivity budget with the model's context window so large prompts
// on slow local models get room to finish prompt evaluation: a small window
// stays at the 10-minute minimum while a large window stretches toward the
// 15-minute cap instead of the old fixed 5 minutes that cancelled healthy evals.
function turnTimeoutMs(contextTokens: number): number {
  const normalized =
    Number.isFinite(contextTokens) && contextTokens > 0
      ? Math.floor(contextTokens)
      : 8192;
  const scaled = normalized * TURN_TIMEOUT_PER_CONTEXT_TOKEN_MS;
  return Math.min(Math.max(TURN_TIMEOUT_BASE_MS, scaled), TURN_TIMEOUT_MAX_MS);
}

interface ChatViewProps {
  health?: HealthResponse | null;
}

// Indexes server-derived per-message groups by parent message ID, oldest message
// first. Each group's actions dedup by preserved call identity with results winning
// then sort chronologically by round so reloads interleave identically to live turns;
// untracked rounds keep stored order at their stored slot.
export function toolActionMap(
  groups: SessionMessageToolActions[] | undefined,
): Map<string, ToolAction[]> {
  const map = new Map<string, ToolAction[]>();
  for (const group of groups ?? []) {
    const deduped = deduplicateToolActionsByCallID([...(group.actions ?? [])]);
    map.set(group.messageID, sortToolActionsByRound(deduped));
  }
  return map;
}

// Indexes server-derived per-message completion times by parent message ID so
// reloads reconcile to the same server instant that live done frames advertise.
// Values normalize through the shared run-timestamp parser so ISO strings and
// Unix seconds converge; unparseable or epoch stamps drop so callers fall back
// to the sibling history timestamp for the same message instead of 1970.
export function toolActionCompletedAtMap(
  groups: SessionMessageToolActions[] | undefined,
): Map<string, number> {
  const map = new Map<string, number>();
  for (const group of groups ?? []) {
    const normalized = normalizeCompletedAtMs(group.completedAt);
    if (normalized != null) map.set(group.messageID, normalized);
  }
  return map;
}

// Groups one message's authoritative actions into chronological tools segments,
// oldest round first, so a multi-call note never collapses rounds into one bucket.
function toolsSegmentsForMessage(actions: ToolAction[]): ChatSegment[] {
  const ordered = [...actions].sort(compareToolActionsByRound);
  return groupToolActionsByRound(ordered).map((group) => ({
    kind: "tools" as const,
    actions: group,
  }));
}

export function reconstructMessages(
  rawMessages: Array<{
    id?: string;
    role: string;
    content: string;
    toolCallID?: string | null;
    isError?: boolean | null;
    createdAt?: string | number;
  }> = [],
  // Authoritative server-derived actions keyed by parent message ID (from `GET /sessions/:id/tool-
  // actions` via `toolActionMap`).
  structuredByMessageID?: Map<string, ToolAction[]> | Record<string, ToolAction[]>,
  // Per-message completion times from the same tool-actions payload (via
  // `toolActionCompletedAtMap`). Values arrive already normalized to
  // milliseconds, so this map is read directly without re-entering the
  // seconds-vs-milliseconds heuristic. Optional for back-compat; absent
  // entries fall back to the sibling history `createdAt` for the same note.
  completedAtByMessageID?: Map<string, number> | Record<string, number>,
): MessageItem[] {
  const getStructured = (messageID: string | undefined): ToolAction[] | undefined => {
    if (!structuredByMessageID || !messageID) return undefined;
    if (structuredByMessageID instanceof Map) {
      return structuredByMessageID.get(messageID);
    }
    return (structuredByMessageID as Record<string, ToolAction[]>)[messageID];
  };
  const getStructuredCompletedAt = (
    messageID: string | undefined,
  ): number | undefined => {
    if (!completedAtByMessageID || !messageID) return undefined;
    const raw: unknown =
      completedAtByMessageID instanceof Map
        ? completedAtByMessageID.get(messageID)
        : (completedAtByMessageID as Record<string, number>)[messageID];
    // Single normalization lives in `toolActionCompletedAtMap`; reuse the
    // stored milliseconds directly so early-epoch stamps never re-enter the
    // magnitude heuristic and drift into seconds.
    return typeof raw === "number" &&
      Number.isFinite(raw) &&
      raw > 0
      ? raw
      : undefined;
  };
  // Latest completion across the notes folded into one turn, so a resumed
  // parked batch reports its final synthesis rather than the first park.
  const mergeCompletedAt = (
    current: number | undefined,
    candidate: number | undefined,
  ): number | undefined => {
    if (candidate == null) return current;
    if (current == null) return candidate;
    return Math.max(current, candidate);
  };
  // Flushes one turn's ordered timeline while keeping flat summaries for legacy
  // readers: text joins text segments and actions flatten tool batches in order.
  const flushTurn = (
    segments: ChatSegment[],
    id: string,
    completedAt?: number,
  ): MessageItem => {
    const text = flatTextFromSegments(segments);
    const flat = flatActionsFromSegments(segments);
    return {
      id,
      role: "assistant",
      text,
      toolActions: flat.length > 0 ? flat : undefined,
      segments: [...segments],
      ...(completedAt != null ? { completedAt } : {}),
    };
  };
  const result: MessageItem[] = [];
  let pendingSegments: ChatSegment[] = [];
  let pendingCompletedAt: number | undefined;

  for (let i = 0; i < rawMessages.length; i++) {
    const m = rawMessages[i];
    if (m.role === "user") {
      if (pendingSegments.length > 0) {
        result.push(
          flushTurn(pendingSegments, `interim_${i}`, pendingCompletedAt),
        );
        pendingSegments = [];
        pendingCompletedAt = undefined;
      }
      result.push({
        id: m.id || `${m.createdAt || i}`,
        role: "user",
        text: m.content,
      });
      continue;
    }

    if (m.role === "tool") {
      continue;
    }

    if (m.role === "assistant") {
      const isInterimWaiting = (() => {
        if (!m.content.trim().startsWith(WAITING_PREFIX)) return false;
        for (let j = i + 1; j < rawMessages.length; j++) {
          const next = rawMessages[j];
          if (next.role === "user") break;
          if (next.role === "tool") return true;
          if (next.role === "assistant" && !next.content.trim().startsWith(WAITING_PREFIX)) {
            return true;
          }
        }
        return false;
      })();
      if (isInterimWaiting) {
        continue;
      }

      // Completion for this note prefers the persisted history instant so
      // reloads agree with live server times; the tool-actions timestamp only
      // fills gaps where history omits the creation time.
      const noteCompletedAt = mergeCompletedAt(
        normalizeCompletedAtMs(m.createdAt),
        getStructuredCompletedAt(m.id),
      );
      pendingCompletedAt = mergeCompletedAt(pendingCompletedAt, noteCompletedAt);
      const structured = getStructured(m.id);
      if (structured && structured.length > 0) {
        // A narrated line plus its persisted twin share one preserved identifier,
        // so collapse repeats before covering text to leave a single Done box.
        const dedupedStructured = deduplicateToolActionsByCallID(structured);
        const coveredCallIDs = new Set(
          dedupedStructured.map((action) => action.callID).filter(Boolean),
        );
        // Single coverage path keeps history grouping identical to live turns:
        // the shared filter folds line endings and matches the placeholder set
        // grammar, so narration lines collapse with their record while
        // mention-only prose stays visible.
        const uncovered = filterUncoveredText(m.content, coveredCallIDs);
        // Preserve live order per round: this note's prose precedes its tools, and
        // successive notes append as successive segments instead of one bucket.
        if (uncovered.length > 0) {
          pendingSegments.push({
            kind: "text",
            text: uncovered,
          });
        }
        pendingSegments.push(...toolsSegmentsForMessage(dedupedStructured));
        continue;
      }
      const leftoverLines: string[] = [];
      // Single line-ending source keeps bare prose joining identically to the
      // covered path above instead of leaving stray carriage returns.
      const normalizedBareContent = normalizeLineEndings(m.content);
      for (const rawLine of normalizedBareContent.split("\n")) {
        if (!rawLine.trim()) continue;
        // Without a server record tool activity stays unknown, so every
        // line stays visible as prose instead of guessing its shape.
        leftoverLines.push(rawLine);
      }
      if (leftoverLines.length > 0) {
        pendingSegments.push({
          kind: "text",
          text: leftoverLines.join("\n").trim(),
        });
        // A prose message with no structured record closes the current turn's
        // timeline like before, so consecutive bare messages keep their prior
        // split instead of merging every turn into one.
        result.push(
          flushTurn(
            pendingSegments,
            m.id || `${m.createdAt || i}`,
            pendingCompletedAt,
          ),
        );
        pendingSegments = [];
        pendingCompletedAt = undefined;
      } else if (pendingSegments.length > 0) {
        // Empty message with no server record: keep pending tool context
        // for the next prose turn instead of synthesizing.
        continue;
      } else {
        continue;
      }
    }
  }

  if (pendingSegments.length > 0) {
    result.push(
      flushTurn(
        pendingSegments,
        `trailing_${rawMessages.length}`,
        pendingCompletedAt,
      ),
    );
  }

  return result.filter(
    (m) => m.text.trim().length > 0 || (m.toolActions && m.toolActions.length > 0)
  );
}

// Single first-turn title policy: first line truncated to 40 characters,
// mirroring ConversationSession.displayTitle so dashboard pre-names stay
// consistent with engine titles without recreating the helper per render.
export function autoTitleFromPrompt(text: string): string {
  const firstLine = text.split("\n")[0].trim();
  if (firstLine.length <= 40) return firstLine;
  return firstLine.slice(0, 40) + "…";
}

// Merges terminal warnings over live ones without duplicating the lines the
// engine repeats on done: the terminal frame restates every mid-turn notice,
// so union-by-value keeps one row per skipped tool.
function mergeWarningLists(previous: string[], next: string[]): string[] {
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

export default function ChatView({ health }: ChatViewProps) {
  const [messages, setMessages] = useState<MessageItem[]>([]);
  const [input, setInput] = useState("");
  const [sessionID, setSessionID] = useState<string>(() => {
    return localStorage.getItem("rw_active_session_id") || newSessionId();
  });
  const [pending, setPending] = useState(false);
  const [inFlightTurn, setInFlightTurn] = useState<InFlightTurn | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Degraded-tool notices for the active turn: live warning frames plus the
  // terminal done list. Informational only, so they never gate the input.
  const [turnWarnings, setTurnWarnings] = useState<string[]>([]);
  // Unresolved approvals for the inbox badge: filtered by session below so
  // only this conversation's blocked tools raise the amber indicator.
  const [pendingApprovals, setPendingApprovals] = useState<PermissionRequest[]>([]);
  // Tracks in-flight inline decisions per approval ID so only deciding rows
  // lock, mirroring the inbox per-row pattern while siblings stay actionable.
  const [decidingApprovalIDs, setDecidingApprovalIDs] = useState<Set<string>>(
    () => new Set<string>(),
  );
  // Per-session flights for turns left running while the user browses another
  // session. The active view keeps its own pending/in-flight state for
  // rendering while this map preserves every parked session's timeline,
  // warnings, and token progress so switching never cancels the server turn
  // and returning restores the live bubble instead of restarting.
  const parkedFlightsRef = useRef<Map<string, ParkedFlight>>(new Map());
  // Sessions with a parked running turn, mirrored to state so the sidebar can
  // badge them. The ref stays the source of truth for handlers while state
  // drives rendering; both hold normalized lowercase identifiers.
  const [backgroundRunningIDs, setBackgroundRunningIDs] = useState<string[]>([]);
  const backgroundRunningRef = useRef<Set<string>>(new Set());
  // True while the shared socket is down. The input stays usable for drafts
  // and running turns keep their server slot; recovery clears the notice on
  // reconnect instead of cancelling anything.
  const [reconnecting, setReconnecting] = useState(false);
  // Visible record of lossy flight trims (live evictions, refusals, expired
  // live reclaims). The dev log stays loud locally but is silent in
  // production, so this state is the shipped signal that a background timeline
  // was dropped and will rebuild from its next frame; completed-shell trims
  // lose nothing and never land here.
  const [trimmedLiveFlights, setTrimmedLiveFlights] = useState<string[]>([]);
  // Latest live progress per tool call, keyed by call identity. Keying by callID
  // rather than tool name keeps sibling executions of one tool distinct, so a
  // batch of two scans never shows one call's counters on the other's row.
  const [toolProgressByCallID, setToolProgressByCallID] = useState<
    Map<string, ToolProgress>
  >(() => new Map());
  // Call identities with a cancel in flight. The optimistic mark persists until
  // the terminal frame (tool_end/done/cancelled/error) proves the stop landed or
  // a non-terminal `tool_cancel_miss` frame reports the call was never running,
  // so the row never claims a cancel completed before the engine confirms it.
  const [cancellingToolCallIDs, setCancellingToolCallIDs] = useState<Set<string>>(
    () => new Set<string>(),
  );

  // Status bar metrics
  const [lastTurnTokens, setLastTurnTokens] = useState<number | null>(null);
  const [sessionTokens, setSessionTokens] = useState<number>(0);
  const [contextTokens, setContextTokens] = useState<number>(0);
  const [activeModel, setActiveModel] = useState<string>(
    () => health?.model || "Local LLM",
  );
  const [contextLimit, setContextLimit] = useState<number>(
    () => health?.contextLength || 8192,
  );

  // Sidebar toggle
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [sessionRefreshKey, setSessionRefreshKey] = useState(0);
  const messageListEndRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const sessionIDRef = useRef(sessionID);
  const isFirstMessageRef = useRef(false);
  const latestPromptRef = useRef("");
  const cancelledRef = useRef(false);
  // Owning session captured at turn start so timeout/close cancels the
  // orphaned turn instead of a session switched to mid-turn.
  const turnSessionIDRef = useRef<string | null>(null);
  // A socket that drops after send but before done/error would strand
  // the input disabled with no recovery; the timeout below bounds that
  // window and the close handler below surfaces a retry immediately.
  const turnTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingRef = useRef(false);
  // Tracks optimistic steering bubbles so a server rejection can retract
  // the right one and restore the draft instead of showing guidance never
  // received. A list because rapid steers queue server-side: a single slot
  // would let the second steer overwrite the first and orphan it on error.
  const pendingSteerRef = useRef<Array<{ id: string; text: string }>>([]);
  // Tracks the latest normal optimistic send so an authoritative length refusal
  // can retract exactly that bubble; steering misses never touch it because
  // they belong to the steering list above.
  const pendingNormalRef = useRef<{ id: string; text: string } | null>(null);
  // Snapshot of the live turn for terminal frames: updaters must stay pure,
  // so the done handler reads this ref instead of nesting a message append
  // inside a turn updater, which would duplicate under double-invoke.
  const inFlightTurnRef = useRef<InFlightTurn | null>(null);
  // Mirrors for parking: switching sessions must carry the active banner and
  // running token sum into the parked flight so returning restores them.
  const turnWarningsRef = useRef<string[]>([]);
  const lastTurnTokensRef = useRef<number | null>(null);
  // Live mirror of the session total so the turn handler reads the latest base
  // without re-creating its callback on every token update.
  const sessionTokensRef = useRef(sessionTokens);
  // Prior session base captured at turn start: live token frames add the running
  // turn total onto this base so Turn shows this message's sum and Session shows
  // base plus running, while done stays authoritative for reconciliation.
  const sessionBaseRef = useRef<number>(0);
  // A server-side delete leaves the stored active ID stale; regenerate
  // it exactly once instead of resurrecting the deleted UUID on send.
  const didRecoverSessionRef = useRef(false);
  // Tracks whether the active session is a local draft (new session not yet on server)
  // so we do not issue GET /sessions/<uuid> which would return 404.
  const knownDraftIDRef = useRef<string | null>(
    localStorage.getItem("rw_active_session_id") ? null : sessionID,
  );
  // Wall-clock instant the active turn started or resumed. Guards the
  // missed-terminal reconcile so a just-sent turn never settles before its
  // running row persists; live frames prove liveness while this stamp proves
  // recency after a socket outage.
  const activeTurnStartMsRef = useRef<number | null>(null);
  // Latest polled run-log snapshot mirrored for socket handlers that cannot
  // depend on state closures. Lets reconnect revalidate the active turn
  // against the same authoritative rows the poller uses instead of blindly
  // re-arming the timer. Read-only because the shared poller hands out a
  // frozen snapshot that callers iterate without mutating.
  const sharedRunsRef = useRef<ReadonlyArray<FrozenRunLogEntry>>([]);
  const sharedRunningIDsRef = useRef<string[]>([]);

  // Mirror latest values after commit so concurrent rendering never observes
  // a torn ref written during render.
  useEffect(() => {
    sessionIDRef.current = sessionID;
  }, [sessionID]);
  useEffect(() => {
    pendingRef.current = pending;
  }, [pending]);
  useEffect(() => {
    inFlightTurnRef.current = inFlightTurn;
  }, [inFlightTurn]);
  useEffect(() => {
    turnWarningsRef.current = turnWarnings;
  }, [turnWarnings]);
  useEffect(() => {
    lastTurnTokensRef.current = lastTurnTokens;
  }, [lastTurnTokens]);
  useEffect(() => {
    sessionTokensRef.current = sessionTokens;
  }, [sessionTokens]);
  // Live copy of the context window so the inactivity budget scales without
  // re-creating the arming callback on every health poll.
  const contextLimitRef = useRef(contextLimit);
  useEffect(() => {
    contextLimitRef.current = contextLimit;
  }, [contextLimit]);

  const clearTurnTimeout = useCallback(() => {
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
  }, []);

  const armTurnTimeout = useCallback(() => {
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
    }
    // Prefer the owning session captured at turn start so a re-arm after a
    // mid-turn session switch still cancels the orphaned turn, falling back
    // to the live session only before the first turn marker lands.
    const turnSID = turnSessionIDRef.current ?? sessionIDRef.current;
    const budgetMs = turnTimeoutMs(contextLimitRef.current);
    turnTimeoutRef.current = setTimeout(() => {
      turnTimeoutRef.current = null;
      // Best-effort cancel the orphaned server turn so a retry does not
      // duplicate it, then release the input lock with a retry message.
      void cancelChat(turnSID).catch(() => {
        // Cancel is best-effort; timeout recovery proceeds even when it fails.
      });
      turnSessionIDRef.current = null;
      activeTurnStartMsRef.current = null;
      setInFlightTurn(null);
      setPending(false);
      // Honest liveness copy: with heartbeats re-arming healthy evals, reaching
      // here means no frames at all for the whole budget while the socket stayed
      // open — a large prompt stalled on slow local inference, not a routine
      // pause. Name the cause instead of a bare timed-out line.
      const budgetMinutes = Math.max(1, Math.round(budgetMs / 60000));
      setError(
        `Still thinking took longer than expected — no progress for ${budgetMinutes} minutes with a large prompt on local inference. The interrupted turn was cancelled; retry your message.`,
      );
    }, budgetMs);
  }, []);

  // Marks one normalized session as running or idle in the background set,
  // mirroring to state so the sidebar badge re-renders. The ref stays the
  // source of truth for socket handlers that cannot depend on state closures.
  const markBackgroundRunning = useCallback((normalized: string, running: boolean) => {
    if (!normalized) return;
    const current = backgroundRunningRef.current;
    if (running) {
      if (current.has(normalized)) return;
      current.add(normalized);
    } else {
      if (!current.has(normalized)) return;
      current.delete(normalized);
    }
    setBackgroundRunningIDs([...current]);
  }, []);

  // Drops one call's live progress and cancel mark once its terminal frame
  // lands. Removing by identity keeps sibling executions of the same tool
  // untouched, matching how results merge by call identity elsewhere.
  const forgetToolCall = useCallback((callID: string) => {
    setToolProgressByCallID((previous) => {
      if (!previous.has(callID)) return previous;
      const next = new Map(previous);
      next.delete(callID);
      return next;
    });
    setCancellingToolCallIDs((previous) => {
      if (!previous.has(callID)) return previous;
      const next = new Set(previous);
      next.delete(callID);
      return next;
    });
  }, []);

  // Retires only one call's optimistic "Cancelling…" mark while leaving its live
  // progress row in place. A cancel miss can land before the bus registers the
  // call, so the tool may still be running and only its terminal frame knows the
  // execution is over; dropping progress here would blank a live row and strand
  // it behind a settled-looking error. Identity scoping mirrors forgetToolCall.
  const forgetToolCancelMark = useCallback((callID: string) => {
    setCancellingToolCallIDs((previous) => {
      if (!previous.has(callID)) return previous;
      const next = new Set(previous);
      next.delete(callID);
      return next;
    });
  }, []);

  // Clears every live progress line and cancel mark at a turn boundary. Called
  // on terminal frames and session switches so a finished or parked turn never
  // leaves a stale row bound to a call identity the next turn cannot reuse.
  const clearAllToolProgress = useCallback(() => {
    setToolProgressByCallID((previous) =>
      previous.size === 0 ? previous : new Map<string, ToolProgress>(),
    );
    setCancellingToolCallIDs((previous) =>
      previous.size === 0 ? previous : new Set<string>(),
    );
  }, []);

  // Reaps expired parked flights and surfaces live drops through visible state.
  // Every entry point that can observe a settled shell funnels here so expiry
  // cannot pin idle flights between parks: badges clear for each pruned key
  // while live reclaims join the eviction banner instead of the dev-only log.
  const reapExpiredFlightsAndSurface = useCallback(() => {
    const expired = pruneExpiredParkedFlights(parkedFlightsRef.current);
    for (const prunedKey of expired.prunedKeys) {
      markBackgroundRunning(prunedKey, false);
    }
    if (expired.prunedLiveKeys.length > 0) {
      setTrimmedLiveFlights((previous) => [
        ...previous,
        ...expired.prunedLiveKeys.filter((k) => !previous.includes(k)),
      ]);
    }
  }, [markBackgroundRunning]);

  // Reloads persisted history for one session after its terminal frame was
  // missed. Live timelines cannot reconstruct a finished turn, so the server
  // record wins here; a deleted session recovers the same way as the initial
  // load instead of resurrecting a stale identifier on the next send.
  const reloadActiveHistory = useCallback((activeID: string) => {
    if (!activeID) return;
    if (knownDraftIDRef.current === activeID) return;
    const snapshotID = activeID;
    Promise.all([
      getSession(snapshotID),
      getSessionToolActions(snapshotID).catch(() => null),
    ])
      .then(([res, structured]) => {
        if (
          normalizeSessionID(sessionIDRef.current) !==
          normalizeSessionID(snapshotID)
        ) {
          return;
        }
        if (res && Array.isArray(res.messages)) {
          const mapped = reconstructMessages(
            res.messages,
            structured ? toolActionMap(structured.actions) : undefined,
            structured
              ? toolActionCompletedAtMap(structured.actions)
              : undefined,
          );
          setMessages(mapped);
        }
      })
      .catch((failure) => {
        if (
          normalizeSessionID(sessionIDRef.current) !==
          normalizeSessionID(snapshotID)
        ) {
          return;
        }
        if (
          failure instanceof ApiError &&
          failure.status === 404 &&
          !didRecoverSessionRef.current
        ) {
          didRecoverSessionRef.current = true;
          const next = newSessionId();
          knownDraftIDRef.current = next;
          localStorage.setItem("rw_active_session_id", next);
          setSessionID(next);
        }
      });
  }, []);

  // A dropped socket must never cancel server turns: the engine keeps
  // evaluating while the shared client reconnects, and heartbeats re-arm the
  // active timer on recovery. Only surface a reconnecting notice so the user
  // knows live updates are paused; explicit Cancel stays the sole path that
  // aborts a turn. The liveness timer suspends across the outage so it cannot
  // fire while hidden and cancel a turn the server still owns.
  const handleWSClose = useCallback(() => {
    setReconnecting(true);
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
  }, []);

  // Clears the reconnecting notice once the shared socket recovers. A turn
  // that finished while the socket was down misses both its terminal frame
  // and its run broadcast, so revalidating against the polled run log keeps
  // a completed turn from waiting out the full liveness budget and then
  // surfacing a misleading timeout plus a no-op cancel. Persisted history
  // wins when no running row remains; live turns resume from their next
  // frame with a re-armed budget because nothing was cancelled outright.
  const handleWSOpen = useCallback(() => {
    setReconnecting(false);
    // Reconnect reaps expired shells on the same tick that reconciles the
    // active turn, so a socket outage cannot pin idle flights until the next
    // park. Live reaps surface through state rather than the dev-only log.
    reapExpiredFlightsAndSurface();
    if (!pendingRef.current || cancelledRef.current) {
      return;
    }
    const activeNorm = normalizeSessionID(sessionIDRef.current);
    if (!activeNorm) {
      armTurnTimeout();
      return;
    }
    const turnSID = turnSessionIDRef.current;
    if (turnSID != null && normalizeSessionID(turnSID) !== activeNorm) {
      return;
    }
    if (sharedRunningIDsRef.current.includes(activeNorm)) {
      armTurnTimeout();
      return;
    }
    const startedAt = activeTurnStartMsRef.current;
    if (startedAt == null || Date.now() - startedAt < PARKED_SETTLE_GRACE_MS) {
      armTurnTimeout();
      return;
    }
    let hasSettledEvidence = false;
    let stillRunning = false;
    for (const run of sharedRunsRef.current) {
      const raw = (run as { sessionID?: unknown }).sessionID;
      if (typeof raw !== "string" || !raw.trim()) continue;
      if (raw.trim().toLowerCase() !== activeNorm) continue;
      const status = (run as { status?: unknown }).status;
      if (
        isActiveRunStatus(typeof status === "string" ? status : undefined)
      ) {
        stillRunning = true;
        break;
      }
      const ts = parseRunTimestamp(
        (run as { timestamp?: unknown }).timestamp as string | number,
      ).getTime();
      // Corrupt rows prove nothing: a missing or epoch stamp means a legacy
      // row, so skip it instead of settling a fresh turn on bad evidence.
      if (!Number.isFinite(ts) || ts <= 0) {
        continue;
      }
      if (ts >= startedAt - 5000) {
        hasSettledEvidence = true;
        break;
      }
    }
    if (stillRunning || !hasSettledEvidence) {
      armTurnTimeout();
      return;
    }
    // The active turn settled while the socket was away: release the input
    // without issuing a cancel for a turn the server no longer owns, then
    // reload the persisted reply instead of replaying a stale bubble.
    clearTurnTimeout();
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    pendingRef.current = false;
    setInFlightTurn(null);
    inFlightTurnRef.current = null;
    setPending(false);
    markBackgroundRunning(activeNorm, false);
    reloadActiveHistory(sessionIDRef.current);
  }, [armTurnTimeout, clearTurnTimeout, markBackgroundRunning, reloadActiveHistory, reapExpiredFlightsAndSurface]);

  // Parks the active turn into the per-session map before leaving it, keeping
  // the server turn alive. The inactivity timer is cleared because the parked
  // view no longer locks the input; liveness resumes from the next frame
  // after returning instead of firing a spurious timeout while hidden.
  const parkActiveFlight = useCallback(() => {
    const activeID = sessionIDRef.current;
    const key = parkedFlightKey(activeID);
    // The park site owns the session invariant: without a key the live turn
    // would be abandoned with the server still running it, so report through
    // the centralized logger while keeping the live view.
    if (!key) {
      logWarn(
        "[ChatView] cannot park active turn without a session id; keeping live view",
      );
      return;
    }
    if (!pendingRef.current) {
      return;
    }
    // Enforce the expiry before capping so idle shells never pin the map until
    // the next store; reclaimed live timelines surface through state because
    // the dev log alone stays silent in production.
    reapExpiredFlightsAndSurface();
    const snapshot = inFlightTurnRef.current;
    const outcome = storeParkedFlight(parkedFlightsRef.current, key, {
      turn: snapshot
        ? {
            toolActions: [...snapshot.toolActions],
            text: snapshot.text,
            segments: snapshot.segments.map((segment) =>
              segment.kind === "tools"
                ? { kind: "tools" as const, actions: [...segment.actions] }
                : { ...segment },
            ),
          }
        : { toolActions: [], text: "", segments: [] },
      pending: true,
      // Carry the banner and running sum so returning restores the exact live
      // footer instead of resetting to zero mid-turn.
      warnings: [...turnWarningsRef.current],
      turnTokens: lastTurnTokensRef.current,
      base: sessionBaseRef.current,
      cancelled: cancelledRef.current,
      updatedAt: Date.now(),
    });
    // A live eviction or refusal drops a runnable timeline: keep the badge lit
    // so the turn never goes dark, but record the trim in visible state; the
    // evicted timeline rebuilds from its next frame.
    if (outcome.evictedKey) {
      markBackgroundRunning(outcome.evictedKey, false);
    }
    if (outcome.evictedLive || outcome.refused) {
      const trimmedKey = outcome.evictedKey ?? key;
      setTrimmedLiveFlights((previous) =>
        previous.includes(trimmedKey) ? previous : [...previous, trimmedKey],
      );
    }
    markBackgroundRunning(key, true);
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
  }, [markBackgroundRunning, reapExpiredFlightsAndSurface]);

  // Restores a parked turn when returning to its session, re-arming the
  // liveness timer so a silent socket still releases the input. Sessions with
  // no parked flight return to an idle view; their history reloads from the
  // persisted messages below instead of a stale live snapshot. Completed
  // background turns (terminal arrived while hidden) still restore their
  // warning banner so the return shows the same skipped-tool notice the live
  // view would have, without replaying the done message itself.
  const restoreParkedFlight = useCallback(
    (id: string) => {
      const key = parkedFlightKey(id);
      if (!key) return;
      // Reattach reaps expired shells first so returning never resurrects a
      // stale timeline pinned since the last park; live reaps surface through
      // state for the same production-visibility reason as the park path.
      reapExpiredFlightsAndSurface();
      const parked = parkedFlightsRef.current.get(key);
      if (!parked) {
        return;
      }
      if (!parked.pending) {
        if (parked.warnings.length > 0) {
          setTurnWarnings([...parked.warnings]);
        }
        if (parked.turnTokens != null) {
          setLastTurnTokens(parked.turnTokens);
        }
        parkedFlightsRef.current.delete(key);
        markBackgroundRunning(key, false);
        return;
      }
      parkedFlightsRef.current.delete(key);
      markBackgroundRunning(key, false);
      cancelledRef.current = parked.cancelled;
      sessionBaseRef.current = parked.base;
      if (parked.turnTokens != null) {
        setLastTurnTokens(parked.turnTokens);
        lastTurnTokensRef.current = parked.turnTokens;
        // Show the live session estimate immediately instead of flashing the
        // pre-turn base until the next token frame arrives.
        setSessionTokens(parked.base + parked.turnTokens);
      }
      if (parked.warnings.length > 0) {
        setTurnWarnings([...parked.warnings]);
      }
      if (parked.turn) {
        setInFlightTurn(parked.turn);
      }
      setPending(true);
      pendingRef.current = true;
      turnSessionIDRef.current = id;
      activeTurnStartMsRef.current = Date.now();
      // Re-arm the liveness budget for the restored turn so a silent socket
      // still releases the input instead of stranding it after the switch.
      armTurnTimeout();
    },
    [markBackgroundRunning, armTurnTimeout, reapExpiredFlightsAndSurface],
  );

  // Applies one background frame to its owning parked flight without touching
  // the active view. Rapid switches stay safe because deltas for a hidden
  // session only grow that session's parked timeline; the visible messages
  // never interleave. Terminal frames clear the parked pending flag and
  // persist token totals so returning reloads the completed history instead
  // of replaying a stale bubble or duplicating the done message.
  const updateParkedFlightFromFrame = useCallback(
    (frameSessionID: string, data: WSIncomingFrame) => {
      const key = parkedFlightKey(frameSessionID);
      // Untagged background frames have no owner to attribute progress to, so
      // drop them instead of merging one session's deltas into another. The
      // drop is lossy, so it surfaces through visible state like live
      // evictions: the dev log stays silent in production and cannot be the
      // only signal that streamed progress was discarded.
      if (!key) {
        logWarn(
          "[ChatView] dropping background frame for empty session key",
        );
        setTrimmedLiveFlights((previous) =>
          previous.includes("unknown") ? previous : [...previous, "unknown"],
        );
        return;
      }
      const frameType =
        typeof (data as unknown as Record<string, unknown>).type === "string"
          ? (data as unknown as Record<string, unknown>).type
          : undefined;
      const ensureFlight = (): ParkedFlight => {
        const existing = parkedFlightsRef.current.get(key);
        if (existing) {
          existing.updatedAt = Date.now();
          parkedFlightsRef.current.delete(key);
          parkedFlightsRef.current.set(key, existing);
          return existing;
        }
        const base = loadSessionTokens(frameSessionID);
        const created: ParkedFlight = {
          turn: { toolActions: [], text: "", segments: [] },
          pending: true,
          warnings: [],
          turnTokens: null,
          base,
          cancelled: false,
          updatedAt: Date.now(),
        };
        // A background frame for an unknown session reaps expiry before
        // capping so one missed terminal cannot pin shells across reconnects.
        reapExpiredFlightsAndSurface();
        const outcome = storeParkedFlight(parkedFlightsRef.current, key, created);
        if (outcome.evictedKey) {
          markBackgroundRunning(outcome.evictedKey, false);
        }
        if (outcome.evictedLive || outcome.refused) {
          const trimmedKey = outcome.evictedKey ?? key;
          setTrimmedLiveFlights((previous) =>
            previous.includes(trimmedKey) ? previous : [...previous, trimmedKey],
          );
        }
        markBackgroundRunning(key, true);
        return created;
      };
      if (
        frameType === "delta" ||
        frameType === "tool_start" ||
        frameType === "tool_end" ||
        frameType === "warning" ||
        frameType === "turn_alive" ||
        frameType === "turn_tokens" ||
        frameType === "tool_progress"
      ) {
        const flight = ensureFlight();
        if (!flight.turn) {
          flight.turn = { toolActions: [], text: "", segments: [] };
        }
        flight.pending = true;
        flight.updatedAt = Date.now();
        parkedFlightsRef.current.delete(key);
        parkedFlightsRef.current.set(key, flight);
        markBackgroundRunning(key, true);
        if (frameType === "delta") {
          const rawDelta: unknown = (data as unknown as Record<string, unknown>).delta;
          const deltaText = typeof rawDelta === "string" ? rawDelta : "";
          if (deltaText) {
            flight.turn.text += deltaText;
            flight.turn.segments = appendDeltaToSegments(
              flight.turn.segments,
              deltaText,
            );
          }
        } else if (frameType === "tool_start") {
          const rawToolName: unknown = (data as unknown as Record<string, unknown>).toolName;
          const rawCallID: unknown = (data as unknown as Record<string, unknown>).callID;
          const rawArgs: unknown = (data as unknown as Record<string, unknown>).argumentsJSON;
          if (
            typeof rawToolName !== "string" ||
            typeof rawCallID !== "string" ||
            typeof rawArgs !== "string"
          ) {
            return;
          }
          const started: ToolAction = {
            toolName: rawToolName,
            callID: rawCallID,
            argumentsJSON: rawArgs,
            result: null,
            ...(normalizeRoundIndex(
              (data as WSToolStartFrame).roundIndex,
            ) !== undefined
              ? {
                  roundIndex: normalizeRoundIndex(
                    (data as WSToolStartFrame).roundIndex,
                  ),
                }
              : {}),
          };
          flight.turn.toolActions.push(started);
          flight.turn.segments = appendToolStartToSegments(
            flight.turn.segments,
            started,
          );
        } else if (frameType === "tool_end") {
          const rawCallID: unknown = (data as unknown as Record<string, unknown>).callID;
          const rawToolName: unknown = (data as unknown as Record<string, unknown>).toolName;
          const rawResult: unknown = (data as unknown as Record<string, unknown>).result;
          if (
            typeof rawCallID !== "string" ||
            typeof rawToolName !== "string"
          ) {
            return;
          }
          if (rawResult != null && !isToolResult(rawResult)) return;
          const result = isToolResult(rawResult) ? rawResult : null;
          const round = normalizeRoundIndex(
            (data as WSToolEndFrame).roundIndex,
          );
          const hasMatch = flight.turn.toolActions.some(
            (action) => action.callID === rawCallID,
          );
          // One end frame belongs to one execution: call identity wins, and
          // without it only the first pending same-tool row completes so one
          // result never fans out across sibling executions; with no pending
          // same-tool row the frame drops instead of guessing an owner.
          if (hasMatch) {
            flight.turn.toolActions = flight.turn.toolActions.map((action) =>
              action.callID === rawCallID
                ? {
                    ...action,
                    result,
                    ...(round !== undefined ? { roundIndex: round } : {}),
                  }
                : action,
            );
          } else {
            const fallbackIndex = flight.turn.toolActions.findIndex(
              (action) => !action.result && action.toolName === rawToolName,
            );
            if (fallbackIndex !== -1) {
              flight.turn.toolActions = flight.turn.toolActions.map(
                (action, index) =>
                  index === fallbackIndex
                    ? {
                        ...action,
                        result,
                        ...(round !== undefined ? { roundIndex: round } : {}),
                      }
                    : action,
              );
            }
          }
          flight.turn.segments = updateToolEndInSegments(
            flight.turn.segments,
            rawCallID,
            rawToolName,
            result,
            round,
          );
        } else if (frameType === "warning") {
          const rawWarning: unknown = (data as unknown as Record<string, unknown>).message;
          if (typeof rawWarning !== "string" || !rawWarning.trim()) return;
          if (!flight.warnings.includes(rawWarning)) {
            flight.warnings.push(rawWarning);
          }
        } else if (frameType === "turn_tokens") {
          const rawTotal: unknown = (data as unknown as Record<string, unknown>)
            .turnTotalTokens;
          const turnTotal = toNonNegativeInt(rawTotal);
          if (turnTotal != null) {
            flight.turnTokens = turnTotal;
          }
        }
        // Heartbeats carry no payload while hidden; the parked turn simply
        // stays alive with no timer because it locks no input.
        return;
      }
      if (
        frameType === "done" ||
        frameType === "cancelled" ||
        frameType === "error"
      ) {
        const flight = parkedFlightsRef.current.get(key);
        // Terminal warnings repeat mid-turn notices for polling clients, so
        // merge them into the parked banner even when the reply itself stays
        // hidden until the user returns.
        if (frameType === "done") {
          const terminalWarnings = sanitizeWarnings(
            (data as unknown as Record<string, unknown>).warnings,
          );
          if (terminalWarnings.length > 0 && flight) {
            flight.warnings = mergeWarningLists(
              flight.warnings,
              terminalWarnings,
            );
          }
          // Persist the authoritative total so returning hydrates the footer
          // instead of resetting to zero mid-history.
          const rawSessionTokens: unknown = (data as unknown as Record<string, unknown>)
            .sessionTokens;
          const rawContextTokens: unknown = (data as unknown as Record<string, unknown>)
            .contextTokens;
          const rawTotal: unknown = (data as unknown as Record<string, unknown>).totalTokens;
          const authoritative = toNonNegativeInt(rawSessionTokens);
          const authContextTokens = toNonNegativeInt(rawContextTokens);
          const turnTotal = toNonNegativeInt(rawTotal);
          try {
            if (authoritative != null) {
              localStorage.setItem(
                sessionTokensKey(frameSessionID),
                String(authoritative),
              );
            } else if (flight && turnTotal != null) {
              localStorage.setItem(
                sessionTokensKey(frameSessionID),
                String(flight.base + turnTotal),
              );
            }
            if (authContextTokens != null) {
              localStorage.setItem(
                contextTokensKey(frameSessionID),
                String(authContextTokens),
              );
            }
          } catch {
            // Storage stays best-effort.
          }
        }
        if (flight) {
          flight.pending = false;
          flight.turn = null;
          flight.updatedAt = Date.now();
          // Refresh LRU order like settleParkedFlight so the settled shell sorts
          // by its terminal time and eviction keeps picking the true stalest.
          parkedFlightsRef.current.delete(key);
          parkedFlightsRef.current.set(key, flight);
        } else {
          // A terminal for an untracked session still evicts any badge that
          // polling or a prior broadcast lit.
          parkedFlightsRef.current.delete(key);
        }
        markBackgroundRunning(key, false);
        return;
      }
    },
    [markBackgroundRunning, reapExpiredFlightsAndSurface],
  );

  // Reconciles the badge with the authoritative inbox so approvals decided in another tab do not
  // linger as stale amber badges. Terminal turn frames and run lifecycle broadcasts trigger it;
  // failures keep the prior inbox instead of flashing the badge off on errors.
  const refreshApprovals = useCallback(() => {
    void listApprovals()
      .then((response) => {
        if (response && Array.isArray(response.approvals)) {
          setPendingApprovals(response.approvals);
        }
      })
      .catch(() => {
        // Keep prior inbox on transient failure.
      });
  }, []);

  // Decides one inline approval without blocking the chat input or sibling rows: each row tracks
  // its own in-flight decision so concurrent approvals stay actionable, matching the inbox per-row
  // pattern.
  const handleDecideApproval = useCallback(
    async (
      id: string,
      approved: boolean,
      duration: TrustDuration,
      widen?: boolean,
    ) => {
      setDecidingApprovalIDs((previous) => new Set(previous).add(id));
      try {
        await decideApproval(id, approved, duration, widen);
        setPendingApprovals((previous) =>
          previous.filter((item) => item.id !== id),
        );
      } catch (failure) {
        setError(
          failure instanceof ApiError ? failure.message : "Decision failed",
        );
      } finally {
        setDecidingApprovalIDs((previous) => {
          if (!previous.has(id)) return previous;
          const next = new Set(previous);
          next.delete(id);
          return next;
        });
      }
      refreshApprovals();
    },
    [refreshApprovals],
  );

  useEffect(() => {
    if (health?.model) setActiveModel(health.model);
    if (health?.contextLength) setContextLimit(health.contextLength);
  }, [health]);

  useEffect(() => {
    localStorage.setItem("rw_active_session_id", sessionID);
  }, [sessionID]);

  const handleWSMessage = useCallback((data: WSIncomingFrame) => {
    if (!isRecord(data)) return;
    // Read the wire envelope through the validated record so
    // forward-compatible event shapes stay typed without widening the
    // handler to `any`; malformed envelopes drop before touching state.
    const frameSessionID =
      typeof data.sessionID === "string" ? data.sessionID : undefined;
    const frameType = typeof data.type === "string" ? data.type : undefined;

    // Frames for a hidden session must never leak into the active view, but
    // they still grow that session's parked flight so returning restores the
    // live timeline. Only turn-scoped frames route to the map; global
    // broadcasts (approvals, runs) continue below so badges stay fresh.
    if (
      frameSessionID &&
      normalizeSessionID(frameSessionID) !== normalizeSessionID(sessionIDRef.current)
    ) {
      if (
        frameType === "delta" ||
        frameType === "tool_start" ||
        frameType === "tool_end" ||
        frameType === "done" ||
        frameType === "warning" ||
        frameType === "turn_alive" ||
        frameType === "turn_tokens" ||
        frameType === "tool_progress" ||
        frameType === "cancelled" ||
        frameType === "error"
      ) {
        updateParkedFlightFromFrame(frameSessionID, data);
        return;
      }
      return;
    }
    // Untagged session frames carry no owner, so they must never touch the
    // current view; only global broadcasts (approval/run_*) bypass tagging.
    // Warnings stay session-scoped with the turn frames so one session's
    // skipped tools never alarm another session's banner. Heartbeats stay
    // session-scoped for the same reason so one turn's proof of life never
    // re-arms another session's timer. Token progress stays session-scoped so
    // one turn's running sum never leaks into another session's footer.
    // Terminal failures stay session-scoped as well so a session-less error
    // never retracts the current session's steering bubble. Cancel misses stay
    // session-scoped too so an ownerless frame cannot clear a mark it does not
    // own.
    if (
      !frameSessionID &&
      (frameType === "delta" ||
        frameType === "tool_start" ||
        frameType === "tool_end" ||
        frameType === "done" ||
        frameType === "warning" ||
        frameType === "turn_alive" ||
        frameType === "turn_tokens" ||
        frameType === "tool_progress" ||
        frameType === "tool_cancel_miss" ||
        frameType === "error" ||
        frameType === "cancelled")
    ) {
      return;
    }

    if (frameType === "turn_tokens") {
      // Per-round usage progress: Turn shows this message's running sum and
      // Session shows the prior base plus running, without waiting for done.
      // The shared guard already drops frames missing any counter so a partial
      // payload never zeroes the footer here; out-of-range totals still degrade
      // to no update, cancelled turns keep partials without persisting, and
      // done stays authoritative so multi-tab viewers converge on the next
      // terminal frame.
      const record = data as unknown as Record<string, unknown>;
      const rawTurnTotal = record.turnTotalTokens;
      const rawRoundIndex = record.roundIndex;
      const rawRoundTokens = record.roundTokens;
      // Turn and round counters share the hub and engine integer contract so a
      // fractional payload drops here instead of rendering floored live while
      // failing the engine decoder.
      const parsedTurnTotal = toNonNegativeInt(rawTurnTotal);
      if (parsedTurnTotal == null) {
        return;
      }
      // Round counters share the hub's non-negative integer contract so a drifted engine
      // cannot smuggle a negative or fractional round sum past the turn-total check above.
      if (toNonNegativeInt(rawRoundIndex) == null) {
        return;
      }
      if (toNonNegativeInt(rawRoundTokens) == null) {
        return;
      }
      // Token progress is session-tagged like heartbeats, so a frame for
      // another turn must never rewrite this view's footer: gate the footer
      // updates below on the owning turn, mirroring the liveness check, with
      // the top-of-handler viewed-session filter covering idle viewers.
      if (pendingRef.current && turnSessionIDRef.current != null) {
        if (
          !frameSessionID ||
          normalizeSessionID(frameSessionID) !==
            normalizeSessionID(turnSessionIDRef.current)
        ) {
          return;
        }
      }
      if (cancelledRef.current) return;
      const turnTotal = parsedTurnTotal;
      setLastTurnTokens(turnTotal);
      const base = sessionBaseRef.current;
      // The cumulative base shares the integer contract, so a drifted base
      // degrades to no session update instead of rendering a floored sum.
      const safeBase = toNonNegativeInt(base);
      if (safeBase != null) {
        setSessionTokens(safeBase + turnTotal);
      }
      // Re-arm the inactivity timer while this turn is in flight so long
      // multi-round inference never looks like a dropped socket; idle viewers
      // of the same session update their footer above without arming.
      if (pendingRef.current && turnSessionIDRef.current != null) {
        if (
          !frameSessionID ||
          normalizeSessionID(frameSessionID) !==
            normalizeSessionID(turnSessionIDRef.current)
        ) {
          return;
        }
        armTurnTimeout();
      }
      return;
    }

    if (frameType === "turn_alive") {
      // Liveness heartbeat: the engine is still in prompt evaluation with no
      // deltas to render. Re-arm the inactivity timer without touching message
      // state so healthy long evals never look like a dropped socket, and
      // render nothing so older dashboards that drop unknown types agree.
      // Only re-arm while a turn is actually in flight so a parked approval
      // arriving with no active turn never starts a spurious timer.
      if (pendingRef.current && turnSessionIDRef.current != null) {
        // Heartbeats are session-tagged liveness for one turn, so a frame for
        // another session must never re-arm this turn's timer after a mid-turn
        // session switch leaves an orphaned turn behind.
        if (
          !frameSessionID ||
          normalizeSessionID(frameSessionID) !==
            normalizeSessionID(turnSessionIDRef.current)
        ) {
          return;
        }
        armTurnTimeout();
      }
      return;
    }

    if (frameType === "tool_progress") {
      // Live per-tool progress keeps a long scan observable without waiting for
      // its terminal frame. The shared guard already dropped malformed payloads,
      // so a partial frame never zeroes a row; the keyed map replaces the prior
      // snapshot for the same call so counters stay monotonic instead of
      // accumulating duplicates across throttled updates.
      if (cancelledRef.current) return;
      const progress = parseToolProgress(data);
      if (!progress) return;
      // Session-tagged like heartbeats: a frame for another turn must never
      // repaint this view's rows after a mid-turn session switch, nor keep this
      // turn's inactivity timer alive. Re-arm only after the ownership check so
      // a foreign turn's progress cannot extend the current turn, mirroring the
      // liveness and token-progress branches; idle viewers still repaint below
      // without arming.
      if (pendingRef.current && turnSessionIDRef.current != null) {
        if (
          !frameSessionID ||
          normalizeSessionID(frameSessionID) !==
            normalizeSessionID(turnSessionIDRef.current)
        ) {
          return;
        }
        armTurnTimeout();
      }
      setToolProgressByCallID((previous) => {
        const next = new Map(previous);
        next.set(progress.callID, progress);
        return next;
      });
      return;
    }

    if (frameType === "tool_cancel_miss") {
      // A per-tool cancel that stopped nothing is non-terminal: the engine sends
      // this dedicated type instead of an `error` frame precisely so the view
      // keeps the running turn. Clear only that row's optimistic "Cancelling…"
      // mark and surface the note, matching the REST fallback; touching the
      // timer, segments, or in-flight turn here would drop a live reply over a
      // cancel that never landed. Live progress stays put because a miss can
      // land before the bus registers the call, where the tool is still running
      // and only its terminal frame may retire the row. The top-of-handler
      // filter already proved this frame belongs to the viewed session, so the
      // identity match is scoped.
      const rawMissCallID = (data as unknown as Record<string, unknown>).callID;
      if (typeof rawMissCallID !== "string" || rawMissCallID.length === 0) {
        return;
      }
      forgetToolCancelMark(rawMissCallID);
      if (!cancelledRef.current) {
        const rawMissMessage = (data as unknown as Record<string, unknown>)
          .message;
        setError(
          typeof rawMissMessage === "string" && rawMissMessage.length > 0
            ? rawMissMessage
            : "Tool cancel missed — the tool call already settled",
        );
      }
      return;
    }

    if (frameType === "tool_start") {
      armTurnTimeout();
      if (cancelledRef.current) return;
      // Drop malformed starts: an action without identity cannot correlate
      // with its end frame or approval, so it must never enter turn state.
      const rawToolName: unknown = data.toolName;
      const rawCallID: unknown = data.callID;
      const rawArgumentsJSON: unknown = data.argumentsJSON;
      if (
        typeof rawToolName !== "string" ||
        typeof rawCallID !== "string" ||
        typeof rawArgumentsJSON !== "string"
      ) {
        return;
      }
      const toolName = rawToolName;
      const callID = rawCallID;
      const argumentsJSON = rawArgumentsJSON;
      // Round hints stay ordering-only: drifted shapes degrade to unordered rather
      // than dropping the execution, so malformed rounds never hide tools.
      const startRound = normalizeRoundIndex(
        (data as WSToolStartFrame).roundIndex,
      );
      setPending(true);
      pendingRef.current = true;
      // Passive viewers of the same session learn the turn start from its
      // first frame so the missed-terminal grace below applies to them as
      // well; sender turns already stamped their start on send.
      if (activeTurnStartMsRef.current == null) {
        activeTurnStartMsRef.current = Date.now();
      }
      // Evict only this batch's waiting placeholder (same preserved callID in actions
      // or in the persisted narration text) or uncorrelated waiting with no
      // tool actions; other parked batches in the same session keep their placeholders so resuming
      // one never wipes the other. Non-waiting duplicates still evict by callID overlap.
      setMessages((prev) =>
        prev.filter((m) => {
          if (m.role !== "assistant") return true;
          const overlapsCall =
            (m.toolActions?.some((a) => a.callID === callID) ?? false) ||
            (callID ? textContainsPlaceholderForCall(m.text, callID) : false);
          if (overlapsCall) return false;
          if (!m.text.trim().startsWith(WAITING_PREFIX)) return true;
          if (!m.toolActions || m.toolActions.length === 0) return false;
          return true;
        }),
      );
      setInFlightTurn((prev) => {
        const currentActions = prev ? [...prev.toolActions] : [];
        const started: ToolAction = {
          toolName,
          callID,
          argumentsJSON,
          result: null,
          ...(startRound !== undefined ? { roundIndex: startRound } : {}),
        };
        currentActions.push(started);
        const previousSegments = prev ? prev.segments : [];
        // Closing the open text segment here keeps live interleaving identical to
        // the persisted per-round note boundaries used on reload.
        const segments = appendToolStartToSegments(previousSegments, started);
        return {
          toolActions: currentActions,
          text: prev ? prev.text : "",
          segments,
        };
      });
    } else if (frameType === "tool_end") {
      armTurnTimeout();
      if (cancelledRef.current) return;
      const rawEndCallID: unknown = data.callID;
      const rawEndToolName: unknown = data.toolName;
      const rawEndResult: unknown = data.result;
      if (typeof rawEndCallID !== "string" || typeof rawEndToolName !== "string") {
        return;
      }
      // A malformed result must never enter turn state: absent results stay
      // null while a present-but-invalid payload drops the frame entirely.
      if (rawEndResult != null && !isToolResult(rawEndResult)) {
        return;
      }
      const endCallID = rawEndCallID;
      const endToolName = rawEndToolName;
      const endResult = isToolResult(rawEndResult) ? rawEndResult : null;
      // The call settled, so its live progress and any cancel mark are done:
      // clearing by identity keeps sibling executions of the same tool intact.
      forgetToolCall(endCallID);
      // Live end frames mirror the start round so resumed batches rejoin the
      // same timeline; absent rounds keep the start value instead of clearing it.
      const endRound = normalizeRoundIndex(
        (data as WSToolEndFrame).roundIndex,
      );
      setMessages((prev) => {
        // One end frame belongs to one execution globally: call identity wins
        // everywhere, and without any identity match only the first pending
        // same-tool row across messages completes so one result never fans out
        // to sibling executions or sibling messages; later pendings drop it.
        const hasGlobalCallIDMatch = prev.some(
          (msg) =>
            msg.toolActions?.some((a) => a.callID === endCallID) ?? false,
        );
        let fallbackClaimed = false;
        return prev.map((msg) => {
          if (!msg.toolActions || msg.toolActions.length === 0) return msg;
          if (hasGlobalCallIDMatch) {
            // Match by call identity so batches with multiple same-tool calls
            // never stamp one result onto pending siblings.
            if (!msg.toolActions.some((a) => a.callID === endCallID)) {
              return msg;
            }
            const nextActions = msg.toolActions.map((a) =>
              a.callID === endCallID
                ? {
                    ...a,
                    result: endResult,
                    ...(endRound !== undefined ? { roundIndex: endRound } : {}),
                  }
                : a,
            );
            // Keep segmented timelines in sync with the flat bucket so history
            // reloads and live updates agree on the same chronological rows.
            const nextSegments = msg.segments
              ? updateToolEndInSegments(
                  msg.segments,
                  endCallID,
                  endToolName,
                  endResult,
                  endRound,
                )
              : undefined;
            return {
              ...msg,
              toolActions: nextActions,
              ...(nextSegments ? { segments: nextSegments } : {}),
            };
          }
          if (fallbackClaimed) return msg;
          const fallbackIndex = msg.toolActions.findIndex(
            (a) => !a.result && a.toolName === endToolName,
          );
          if (fallbackIndex === -1) return msg;
          fallbackClaimed = true;
          const nextActions = msg.toolActions.map((a, index) =>
            index === fallbackIndex
              ? {
                  ...a,
                  result: endResult,
                  ...(endRound !== undefined ? { roundIndex: endRound } : {}),
                }
              : a,
          );
          // Keep segmented timelines in sync with the flat bucket so history
          // reloads and live updates agree on the same chronological rows.
          const nextSegments = msg.segments
            ? updateToolEndInSegments(
                msg.segments,
                endCallID,
                endToolName,
                endResult,
                endRound,
              )
            : undefined;
          return {
            ...msg,
            toolActions: nextActions,
            ...(nextSegments ? { segments: nextSegments } : {}),
          };
        });
      });
      setInFlightTurn((prev) => {
        if (!prev) return prev;
        // Same single-execution rule as the message bucket above: call identity
        // wins, and without it only the first pending same-tool row completes
        // so one result never fans out across sibling executions.
        const hasTurnCallIDMatch = prev.toolActions.some(
          (action) => action.callID === endCallID,
        );
        let updated: ToolAction[];
        if (hasTurnCallIDMatch) {
          updated = prev.toolActions.map((action) =>
            action.callID === endCallID
              ? {
                  ...action,
                  result: endResult,
                  ...(endRound !== undefined ? { roundIndex: endRound } : {}),
                }
              : action,
          );
        } else {
          const fallbackIndex = prev.toolActions.findIndex(
            (action) => !action.result && action.toolName === endToolName,
          );
          // No identity and no pending same-tool row means no owner: drop the
          // frame instead of guessing so unrelated executions stay pending.
          if (fallbackIndex === -1) {
            return prev;
          }
          updated = prev.toolActions.map((action, index) =>
            index === fallbackIndex
              ? {
                  ...action,
                  result: endResult,
                  ...(endRound !== undefined ? { roundIndex: endRound } : {}),
                }
              : action,
          );
        }
        return {
          ...prev,
          toolActions: updated,
          segments: updateToolEndInSegments(
            prev.segments,
            endCallID,
            endToolName,
            endResult,
            endRound,
          ),
        };
      });
    } else if (frameType === "delta") {
      armTurnTimeout();
      if (cancelledRef.current) return;
      setPending(true);
      pendingRef.current = true;
      if (activeTurnStartMsRef.current == null) {
        activeTurnStartMsRef.current = Date.now();
      }
      const rawDelta: unknown = data.delta;
      const deltaText = typeof rawDelta === "string" ? rawDelta : "";
      // Deltas carry no batch correlation, so they must not evict parked batches' waiting
      // placeholders (which carry their batch callIDs); batch-specific eviction belongs to
      // tool_start/done callID overlap.
      setMessages((prev) =>
        prev.filter((m) => {
          if (m.role !== "assistant") return true;
          if (!m.text.trim().startsWith(WAITING_PREFIX)) return true;
          if (m.toolActions && m.toolActions.length > 0) return true;
          return false;
        }),
      );
      setInFlightTurn((prev) => ({
        toolActions: prev ? prev.toolActions : [],
        text: (prev ? prev.text : "") + deltaText,
        // Opening a fresh text segment after tools preserves round bounds so the
        // live timeline interleaves exactly like the persisted note boundaries.
        segments: appendDeltaToSegments(prev ? prev.segments : [], deltaText),
      }));
    } else if (frameType === "approval") {
      // Live approval prompts join the inbox immediately so the session
      // badge reflects blocked tools without waiting for the next poll.
      // Malformed prompts drop instead of entering badge state.
      const request = mergeApprovalFrame(data);
      if (!request) {
        return;
      }
      // Only extend the turn timeout while a turn is in flight; a parked
      // approval arriving with no active turn must not re-arm the timer
      // and later fire a spurious timeout cancel.
      if (pendingRef.current && turnSessionIDRef.current != null) {
        armTurnTimeout();
      }
      setPendingApprovals((previous) =>
        previous.some((item) => item.id === request.id)
          ? previous
          : [...previous, request],
      );
    } else if (frameType === "warning") {
      // Degraded-tool notices surface live without failing the turn: the
      // banner accumulates one row per skipped tool and never locks input.
      // Blank or malformed lines drop instead of rendering empty rows.
      const rawWarning: unknown = data.message;
      if (typeof rawWarning !== "string" || rawWarning.trim().length === 0) {
        return;
      }
      // Only extend the turn timeout while a turn is in flight, mirroring
      // approvals, so a broadcast arriving with no active turn never arms a
      // spurious timeout cancel.
      if (pendingRef.current && turnSessionIDRef.current != null) {
        armTurnTimeout();
      }
      const line = rawWarning;
      setTurnWarnings((previous) =>
        previous.includes(line) ? previous : [...previous, line],
      );
    } else if (frameType === "done") {
      clearTurnTimeout();
      clearAllToolProgress();
      turnSessionIDRef.current = null;
      activeTurnStartMsRef.current = null;
      // Late guidance stays queued server-side for the next turn, so only the
      // server-confirmed retained count survives: consumed steers were answered
      // in this turn and release, while the newest retained entries re-attach
      // to the next timeline. An absent signal means an older engine with no
      // late-steering report, so consumed tracking clears as answered.
      const doneRecord = data as unknown as Record<string, unknown>;
      const rawRetained = doneRecord.retainedSteerCount;
      const retained = toNonNegativeInt(rawRetained);
      if (retained != null) {
        pendingSteerRef.current =
          retained === 0 ? [] : pendingSteerRef.current.slice(-retained);
      } else {
        pendingSteerRef.current = [];
      }
      pendingNormalRef.current = null;
      // Terminal warnings repeat every mid-turn notice for polling clients,
      // so merge them even on a cancelled turn: the banner is informational
      // and must not depend on the reply surviving cancellation.
      const earlyWarnings = sanitizeWarnings(
        (data as unknown as Record<string, unknown>).warnings,
      );
      if (earlyWarnings.length > 0) {
        setTurnWarnings((previous) => mergeWarningLists(previous, earlyWarnings));
      }
      if (cancelledRef.current) {
        setInFlightTurn(null);
        setPending(false);
        return;
      }
      const currentSid = frameSessionID || sessionIDRef.current;
      if (
        frameSessionID &&
        normalizeSessionID(frameSessionID) !== normalizeSessionID(sessionIDRef.current)
      ) {
        setSessionID(frameSessionID);
      }
      const rawModelName: unknown = data.modelName;
      const rawContextLength: unknown = data.contextLength;
      const rawTotalTokens: unknown = data.totalTokens;
      const rawSessionTokens: unknown = data.sessionTokens;
      const rawContextTokens: unknown = data.contextTokens;
      const rawDoneText: unknown = data.text;
      const rawToolActions: unknown = data.toolActions;
      const rawIsParked: unknown = data.isParked;
      // Validated per-turn parked flag: only an explicit true marks a waiting
      // turn, so absent or malformed tags default to a normal completion.
      const isParked = rawIsParked === true;
      const modelName = typeof rawModelName === "string" ? rawModelName : undefined;
      const contextLength =
        typeof rawContextLength === "number" ? rawContextLength : undefined;
      // Terminal counters share the live turn-tokens integer contract (finite,
      // non-negative integers): a fractional or otherwise malformed done frame
      // drops to absent instead of flooring, so live and terminal footers agree
      // with the hub and engine decoders and never corrupt the persisted base.
      const totalTokens = toNonNegativeInt(rawTotalTokens);
      const sessionTokensValue = toNonNegativeInt(rawSessionTokens);
      const contextTokensValue = toNonNegativeInt(rawContextTokens);
      const doneText = typeof rawDoneText === "string" ? rawDoneText : undefined;
      // Drop malformed entries so only well-shaped actions enter history; a
      // non-array tag defaults to absent like engines that omit it.
      const doneToolActions = Array.isArray(rawToolActions)
        ? rawToolActions.filter(isToolAction)
        : undefined;
      if (modelName) setActiveModel(modelName);
      if (contextLength) setContextLimit(contextLength);
      if (typeof totalTokens === "number") {
        setLastTurnTokens(totalTokens);
      }
      if (typeof contextTokensValue === "number") {
        setContextTokens(contextTokensValue);
        try {
          localStorage.setItem(contextTokensKey(currentSid), String(contextTokensValue));
        } catch {
          // Storage is best-effort only.
        }
      }
      // Authoritative cumulative total wins when present so reloads,
      // multi-client turns, and retries never drift from local sums. Live token
      // frames already showed base plus running, so this overwrites with the same
      // value. A parked turn keeps the pre-park base because the resume synthesis
      // re-reports the parked tokens inside its running total; advancing the base
      // here would count them twice in the live footer until done reconciles.
      if (typeof sessionTokensValue === "number") {
        const cumulative = sessionTokensValue;
        setSessionTokens(cumulative);
        if (!isParked) {
          sessionBaseRef.current = cumulative;
        }
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(cumulative));
        } catch {
          // Storage is best-effort only.
        }
      } else if (typeof totalTokens === "number") {
        // No authoritative total: derive from the prior base plus this turn so a
        // live footer that already added the running sum does not double-count.
        // A parked turn still moves the displayed total forward while keeping the
        // pre-park base for the same resume overlap reason above.
        const turnTotal = totalTokens;
        const base = sessionBaseRef.current;
        // The derived base keeps the integer contract: a drifted stored base
        // falls back to the live total instead of flooring into the sum.
        const fallbackBase =
          toNonNegativeInt(base) ?? sessionTokensRef.current;
        const next = fallbackBase + turnTotal;
        setSessionTokens(next);
        if (!isParked) {
          sessionBaseRef.current = next;
        }
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(next));
        } catch {
          // Storage is best-effort only.
        }
      }

      if (isFirstMessageRef.current) {
        const title = autoTitleFromPrompt(latestPromptRef.current);
        void updateSessionTitle(currentSid, title).then(() => {
          setSessionRefreshKey((k) => k + 1);
        });
        isFirstMessageRef.current = false;
      }

      // Snapshot the streamed turn outside any updater so each update
      // stays pure; nesting a message append inside a turn updater would
      // run twice under double-invoke and duplicate the assistant message.
      const snapshot = inFlightTurnRef.current;
      const orderedDoneActions = deduplicateToolActionsByCallID([
        ...(doneToolActions ?? []),
      ]).sort(compareToolActionsByRound);
      const finalActions =
        orderedDoneActions.length > 0
          ? orderedDoneActions
          : deduplicateToolActionsByCallID([
              ...(snapshot?.toolActions ?? []),
            ]).sort(compareToolActionsByRound);
      // Chronological terminal timeline: merge authoritative results into the
      // streamed skeleton so multi-round turns keep text/tools interleaved and
      // parked resumes append to the same turn instead of a lumped bucket.
      const doneSegments = buildDoneSegments(
        snapshot?.segments ?? [],
        finalActions,
        doneText,
        snapshot?.text ?? "",
      );
      const legacyText =
        doneSegments.length > 0
          ? flatTextFromSegments(doneSegments)
          : (doneText ?? snapshot?.text ?? "");
      const legacyActions = flatActionsFromSegments(doneSegments);
      // Completion stamps stay grounded in the server instant so live cards
      // agree with history reloads: an omitted stamp renders no footer rather
      // than sampling client receipt time.
      const doneCompletedAt = normalizeCompletedAtMs(
        (data as unknown as Record<string, unknown>).completedAt,
      );
      const finalMsg: MessageItem = {
        id: newSessionId(),
        role: "assistant",
        text: legacyText,
        toolActions: legacyActions.length > 0 ? legacyActions : undefined,
        segments: doneSegments.length > 0 ? doneSegments : undefined,
        ...(doneCompletedAt != null ? { completedAt: doneCompletedAt } : {}),
      };
      setMessages((prev) => {
        // Terminal dedup stays batch-scoped: evict only placeholders whose batch overlaps this
        // turn's preserved callIDs in actions or in narration text, plus generic waiting
        // with no correlation. Other parked batches in the same session keep their
        // placeholders so completing one resume never wipes the other.
        const base = !isParked
          ? prev.filter((m) => {
              if (m.role !== "assistant") return true;
              const overlaps =
                finalActions.length > 0 &&
                ((m.toolActions?.some((a) =>
                  finalActions.some(
                    (fa) => fa.callID && fa.callID === a.callID,
                  ),
                ) ??
                  false) ||
                  finalActions.some(
                    (fa) =>
                      fa.callID &&
                      textContainsPlaceholderForCall(m.text, fa.callID),
                  ));
              if (overlaps) return false;
              if (!m.text.trim().startsWith(WAITING_PREFIX)) return true;
              if (!m.toolActions || m.toolActions.length === 0) return false;
              return true;
            })
          : prev;
        return [...base, finalMsg].slice(-MAX_MESSAGES);
      });
      setInFlightTurn(null);
      inFlightTurnRef.current = null;
      setPending(false);
      if (isParked) {
        // Parked WS turns wait on inbox approval, not completion: the waiting
        // text above stays as the assistant reply while this refresh flips
        // the header to the amber waiting state without waiting for a poll.
        refreshApprovals();
      } else {
        // The finished turn may have consumed parked approvals decided here
        // or in another tab; reconcile so decided identifiers evict promptly.
        refreshApprovals();
      }
    } else if (frameType === "cancelled") {
      clearTurnTimeout();
      clearAllToolProgress();
      turnSessionIDRef.current = null;
      activeTurnStartMsRef.current = null;
      // A cancelled turn ends tracking so a later error cannot retract an
      // already-settled steering bubble from history.
      pendingSteerRef.current = [];
      pendingNormalRef.current = null;
      setInFlightTurn(null);
      setPending(false);
    } else if (frameType === "error") {
      // Only guidance the engine never stored rolls back: a steering miss or
      // an authoritative length refusal retracts its optimistic bubble, while
      // turn-wide failures leave received guidance visible for the retry. The
      // engine withdraws the newest queued text on a race loss, so the newest
      // tracked bubble goes first and the frame must own this session.
      const errorRecord = data as unknown as Record<string, unknown>;
      const ownsSession =
        !!frameSessionID &&
        (normalizeSessionID(frameSessionID) ===
          normalizeSessionID(sessionIDRef.current) ||
          (turnSessionIDRef.current != null &&
            normalizeSessionID(frameSessionID) ===
              normalizeSessionID(turnSessionIDRef.current)));
      if (ownsSession) {
        if (isSteerMissFrame(errorRecord) || isTooLongFrame(errorRecord)) {
          if (pendingSteerRef.current.length > 0) {
            const rejectedSteer = pendingSteerRef.current.pop();
            if (rejectedSteer) {
              const rejectedId = rejectedSteer.id;
              const rejectedText = rejectedSteer.text;
              setMessages((prev) => prev.filter((m) => m.id !== rejectedId));
              setInput((prev) =>
                prev ? `${prev}\n${rejectedText}` : rejectedText,
              );
            }
            pendingNormalRef.current = null;
          } else if (pendingNormalRef.current) {
            const rejectedNormal = pendingNormalRef.current;
            pendingNormalRef.current = null;
            setMessages((prev) =>
              prev.filter((m) => m.id !== rejectedNormal.id),
            );
            setInput((prev) =>
              prev ? `${prev}\n${rejectedNormal.text}` : rejectedNormal.text,
            );
          } else if (isTooLongFrame(errorRecord)) {
            // Authoritative refusal with no tracked bubble (older optimistic
            // send): drop nothing but keep the refusal visible below.
          }
        } else {
          // Turn-wide failure leaves received guidance queued server-side for
          // the retry, so tracking persists while the normal send settles.
          pendingNormalRef.current = null;
        }
      }
      // Foreign-session failures must leave the foreground turn alone: hidden
      // sessions already settle into parked flights above, so reaching here
      // without ownership means the timer, pending flag, and banner below
      // all belong to another turn.
      if (!ownsSession) {
        return;
      }
      clearTurnTimeout();
      clearAllToolProgress();
      turnSessionIDRef.current = null;
      activeTurnStartMsRef.current = null;
      if (!cancelledRef.current) {
        const rawMessage: unknown = data.message;
        const message =
          typeof rawMessage === "string" && rawMessage.length > 0
            ? rawMessage
            : "Chat turn failed";
        setError(message);
      }
      setInFlightTurn(null);
      setPending(false);
    } else if (frameType === "run_started" || frameType === "run_completed") {
      // Run lifecycle broadcasts keep the background badge honest across tabs
      // and reloads. The nested run carries the owning session while the
      // envelope stays untagged, so extract it here instead of the top-level
      // filter above. Completion also reconciles approvals because a parked
      // resume means its inbox rows were decided elsewhere.
      const nestedRun: unknown = (data as unknown as Record<string, unknown>).run;
      const owner = runSessionID(
        nestedRun as Parameters<typeof runSessionID>[0],
      );
      const normalizedOwner = normalizeSessionID(owner);
      // Single active contract with the polled run log: only a live running
      // status keeps the badge lit. Parked approvals arrive as completed and
      // surface through the approvals badge instead of double-badging.
      const nestedStatus =
        typeof (nestedRun as Record<string, unknown> | null)?.status ===
        "string"
          ? ((nestedRun as Record<string, unknown>).status as string)
          : undefined;
      if (normalizedOwner) {
        if (
          frameType === "run_started" &&
          isActiveRunStatus(nestedStatus)
        ) {
          markBackgroundRunning(normalizedOwner, true);
        } else {
          markBackgroundRunning(normalizedOwner, false);
          // A finished background turn may have completed while hidden; drop
          // its parked shell so returning reloads the persisted history
          // instead of replaying a stale live bubble.
          const parked = parkedFlightsRef.current.get(normalizedOwner);
          if (parked && !parked.pending) {
            parkedFlightsRef.current.delete(normalizedOwner);
          } else if (parked && parked.pending) {
            // The run record settled but the stream terminal has not arrived
            // (reloaded socket); keep the parked shell until its done frame
            // or the next poll reconciles, but stop badging it as running.
            markBackgroundRunning(normalizedOwner, false);
          }
        }
      }
      refreshApprovals();
    } else if (
      frameType === "approval_decided" ||
      frameType === "approval_resolved" ||
      frameType === "approval_removed" ||
      frameType === "approval_deleted" ||
      frameType === "approval_completed" ||
      frameType === "approval_cancelled"
    ) {
      // Forward-compatible eviction for explicit approval removal frames:
      // drop the decided identifier locally and reconcile with the server
      // when the frame carries no usable identifier.
      const rawRemovalID: unknown = data.id;
      const rawRemovalApprovalID: unknown = data.approvalID;
      const rawRemovalApprovalId: unknown = data.approvalId;
      const rawRemovalRequest: unknown = data.request;
      const rawRemovalApproval: unknown = data.approval;
      let removalID: string | undefined;
      if (typeof rawRemovalID === "string" && rawRemovalID.length > 0) {
        removalID = rawRemovalID;
      } else if (
        typeof rawRemovalApprovalID === "string" &&
        rawRemovalApprovalID.length > 0
      ) {
        removalID = rawRemovalApprovalID;
      } else if (
        typeof rawRemovalApprovalId === "string" &&
        rawRemovalApprovalId.length > 0
      ) {
        removalID = rawRemovalApprovalId;
      } else if (isRecord(rawRemovalRequest)) {
        const nestedID: unknown = rawRemovalRequest.id;
        if (typeof nestedID === "string" && nestedID.length > 0) {
          removalID = nestedID;
        }
      } else if (isRecord(rawRemovalApproval)) {
        const nestedID: unknown = rawRemovalApproval.id;
        if (typeof nestedID === "string" && nestedID.length > 0) {
          removalID = nestedID;
        }
      }
      if (removalID != null) {
        const decidedID = removalID;
        setPendingApprovals((previous) =>
          previous.filter((item) => item.id !== decidedID),
        );
      }
      if (
        frameSessionID &&
        normalizeSessionID(frameSessionID) === normalizeSessionID(sessionIDRef.current) &&
        data.approved === true
      ) {
        setPending(true);
        pendingRef.current = true;
        activeTurnStartMsRef.current = Date.now();
        // The resume synthesis re-reports the parked tokens inside its running
        // total, so the base stays at its pre-park value; moving it to the parked
        // cumulative would count the initial park twice in the live footer.
      }
      refreshApprovals();
    }
  }, [armTurnTimeout, clearTurnTimeout, clearAllToolProgress, forgetToolCall, forgetToolCancelMark, refreshApprovals, updateParkedFlightFromFrame, markBackgroundRunning]);

  const { sendMessage, isOpen } = useSharedWebSocket(handleWSMessage, handleWSClose, handleWSOpen);

  // Cancels one executing tool by call identity, distinct from the session-wide
  // turn cancel: this stops a single call and lets the model reason about the
  // partial result instead of aborting the whole reply. The optimistic mark
  // flips before the request leaves so the row stops inviting a second click
  // immediately, and the terminal frame or a non-terminal miss frame clears it.
  // The WebSocket frame is preferred while the shared socket is open because it
  // skips a round trip, with the REST route as the fallback so a dropped socket
  // still stops the tool.
  const handleCancelTool = useCallback(
    (callID: string, reason?: string) => {
      const trimmedCallID = callID.trim();
      if (!trimmedCallID) return;
      const cancelSID = turnSessionIDRef.current ?? sessionIDRef.current;
      const trimmedReason = reason?.trim();
      setCancellingToolCallIDs((previous) => {
        if (previous.has(trimmedCallID)) return previous;
        const next = new Set(previous);
        next.add(trimmedCallID);
        return next;
      });
      const sent = sendMessage({
        type: "tool_cancel",
        sessionID: cancelSID,
        callID: trimmedCallID,
        ...(trimmedReason ? { reason: trimmedReason } : {}),
      });
      if (!sent) {
        void toolCancel(cancelSID, trimmedCallID, trimmedReason)
          .then((response) => {
            // A resolved miss means the call settled before the request landed,
            // so no terminal frame is coming to clear the mark. Drop it here and
            // report the miss rather than leaving the row on a false
            // "Cancelling…" forever.
            if (!response.cancelled) {
              forgetToolCall(trimmedCallID);
              setError("Tool cancel missed — the tool call already settled");
            }
          })
          .catch((failure) => {
            // The cancel never reached the engine, so drop the optimistic mark
            // and surface the failure instead of stranding a false "Cancelling…".
            forgetToolCall(trimmedCallID);
            setError(
              failure instanceof ApiError
                ? failure.message
                : "Tool cancel failed",
            );
          });
      }
    },
    [sendMessage, forgetToolCall],
  );

  // Load active session messages on initial mount if existing
  useEffect(() => {
    let cancelled = false;
    const activeID = sessionID;
    // Hydrate the status bar from the cached cumulative total so a reload
    // does not reset a live session to zero; the next authoritative done
    // frame corrects it when the server has newer usage. The hydrated value
    // doubles as the prior base for the next turn's live token frames.
    const hydrated = loadSessionTokens(activeID);
    setSessionTokens(hydrated);
    sessionBaseRef.current = hydrated;
    const hydratedContext = loadContextTokens(activeID);
    setContextTokens(hydratedContext);
    setLastTurnTokens(null);

    // If this session is a local draft (not yet sent or persisted to the server),
    // skip fetching to avoid expected 404 errors in the console.
    if (knownDraftIDRef.current === activeID) {
      setMessages([]);
      return;
    }

    Promise.all([
      getSession(activeID),
      getSessionToolActions(activeID).catch(() => null),
    ])
      .then(([res, structured]) => {
        if (!cancelled && res && Array.isArray(res.messages)) {
          const mapped = reconstructMessages(
            res.messages,
            structured ? toolActionMap(structured.actions) : undefined,
            structured
              ? toolActionCompletedAtMap(structured.actions)
              : undefined,
          );
          setMessages(mapped);
        }
      })
      .catch((failure) => {
        // A 404 means the stored active ID was deleted server-side:
        // mint a fresh session once instead of resurrecting the stale
        // UUID on the next send. Other failures just clear the view.
        if (!cancelled) {
          if (
            failure instanceof ApiError &&
            failure.status === 404 &&
            !didRecoverSessionRef.current
          ) {
            didRecoverSessionRef.current = true;
            const next = newSessionId();
            knownDraftIDRef.current = next;
            localStorage.setItem("rw_active_session_id", next);
            setSessionID(next);
          }
          setMessages([]);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [sessionID]);

  // Never leave a turn timeout armed past unmount.
  useEffect(() => {
    return () => {
      if (turnTimeoutRef.current != null) {
        clearTimeout(turnTimeoutRef.current);
        turnTimeoutRef.current = null;
      }
    };
  }, []);

  // Track unresolved approvals so sessions blocked on a gated tool show an honest amber badge; a
  // single effect on the active session covers both mount and switches, so no double fetch fires on
  // mount. Failures leave the prior inbox intact instead of flashing the badge off on errors.
  useEffect(() => {
    let cancelled = false;
    listApprovals()
      .then((response) => {
        if (!cancelled && response && Array.isArray(response.approvals)) {
          setPendingApprovals(response.approvals);
        }
      })
      .catch(() => {
        // Keep prior inbox on transient failure.
      });
    return () => {
      cancelled = true;
    };
  }, [sessionID]);

  // Shared run-log poller feeding background badges and parked-settle reconcile.
  // One module-level interval serves both this view and the sidebar so two
  // mounted pollers never double the run-log QPS; live broadcasts above stay
  // the immediate path while these polled rows cover reloads, missed sockets,
  // and cross-tab turns. Parked flights remain the source for live timelines.
  const { runs: sharedRuns, runningIDs: sharedRunningIDs } = useRunningRuns();

  // Reconciles background badges with the authoritative run log so reloads
  // and turns started in another tab still badge without a live socket.
  // Parked flights stay the source for live timelines while polled runs cover
  // missed broadcasts; settled runs evict only when no parked pending remains
  // so a stream terminal that arrives just after the poll never flashes.
  // The active turn revalidates here as well so a terminal missed during a
  // socket outage releases the input via persisted history instead of waiting
  // out the liveness budget and then reporting a misleading timeout.
  useEffect(() => {
    sharedRunsRef.current = sharedRuns;
    sharedRunningIDsRef.current = sharedRunningIDs;
    // The shared poll tick doubles as the scheduled expiry sweep so TTL
    // enforces even when no park or frame arrives; live reaps surface through
    // state instead of the production-silent log.
    reapExpiredFlightsAndSurface();
    const running = sharedRunningIDs;
    const activeNorm = normalizeSessionID(sessionIDRef.current);
    for (const norm of running) {
      if (norm && norm !== activeNorm) {
        markBackgroundRunning(norm, true);
      }
    }
    // Sessions with a settled row but no running row finished while the
    // socket was away; settle the parked shell so the concurrency cap
    // frees and a return reloads history instead of a stale bubble. A
    // fresh flight keeps its grace until its running row persists, and a
    // stream terminal arriving just after the poll still wins via the
    // pending check below.
    const settled = new Set<string>();
    for (const run of sharedRuns) {
      const raw = (run as { sessionID?: unknown }).sessionID;
      if (typeof raw !== "string" || !raw.trim()) continue;
      const norm = raw.trim().toLowerCase();
      if (!norm || running.includes(norm)) continue;
      settled.add(norm);
    }
    const nowMs = Date.now();
    for (const [key, flight] of [...parkedFlightsRef.current]) {
      if (!flight.pending || key === activeNorm) continue;
      if (running.includes(key)) continue;
      if (!settled.has(key)) continue;
      if (nowMs - flight.updatedAt < PARKED_SETTLE_GRACE_MS) continue;
      settleParkedFlight(parkedFlightsRef.current, key);
      markBackgroundRunning(key, false);
    }
    for (const norm of [...backgroundRunningRef.current]) {
      if (!norm || norm === activeNorm) continue;
      const stillPolled = running.includes(norm);
      const stillParked = parkedFlightsRef.current.get(norm)?.pending;
      if (!stillPolled && !stillParked) {
        markBackgroundRunning(norm, false);
      }
    }
    // Active-session missed terminal: the socket can drop after send but
    // before done while the engine keeps evaluating, so both the targeted
    // terminal and its run broadcast are missed. Polling stays authoritative
    // here because it runs over REST even while the socket is down. An
    // explicit cancel never lands here since it already releases the input,
    // and a just-sent turn keeps its grace until its running row persists so
    // a slow persist never evicts a live turn. Only a settled row newer than
    // the turn start settles, so stale rows from prior turns never clear a
    // fresh prompt and session filtering keeps background turns untouched.
    if (pendingRef.current && !cancelledRef.current && activeNorm) {
      const liveTurnSID = turnSessionIDRef.current;
      const ownsActive =
        liveTurnSID == null ||
        normalizeSessionID(liveTurnSID) === activeNorm;
      if (ownsActive && !running.includes(activeNorm)) {
        const startedAt = activeTurnStartMsRef.current;
        if (
          startedAt != null &&
          Date.now() - startedAt >= PARKED_SETTLE_GRACE_MS
        ) {
          let hasSettledEvidence = false;
          let stillRunning = false;
          for (const run of sharedRuns) {
            const raw = (run as { sessionID?: unknown }).sessionID;
            if (typeof raw !== "string" || !raw.trim()) continue;
            if (raw.trim().toLowerCase() !== activeNorm) continue;
            const status = (run as { status?: unknown }).status;
            if (
              isActiveRunStatus(
                typeof status === "string" ? status : undefined,
              )
            ) {
              stillRunning = true;
              break;
            }
            const ts = parseRunTimestamp(
              (run as { timestamp?: unknown }).timestamp as
                | string
                | number,
            ).getTime();
            // Corrupt rows prove nothing: a missing or epoch stamp means a
            // legacy row, so skip it instead of settling a fresh turn on bad
            // evidence.
            if (!Number.isFinite(ts) || ts <= 0) {
              continue;
            }
            if (ts >= startedAt - 5000) {
              hasSettledEvidence = true;
              break;
            }
          }
          if (!stillRunning && hasSettledEvidence) {
            // The server no longer owns this turn, so releasing locally
            // issues no cancel; the persisted reply replaces the stale live
            // bubble instead of replaying it.
            clearTurnTimeout();
            turnSessionIDRef.current = null;
            activeTurnStartMsRef.current = null;
            pendingRef.current = false;
            setInFlightTurn(null);
            inFlightTurnRef.current = null;
            setPending(false);
            markBackgroundRunning(activeNorm, false);
            reloadActiveHistory(sessionIDRef.current);
            refreshApprovals();
          }
        }
      }
    }
  }, [sharedRuns, sharedRunningIDs, markBackgroundRunning, clearTurnTimeout, reloadActiveHistory, refreshApprovals, reapExpiredFlightsAndSurface]);

  useEffect(() => {
    messageListEndRef.current?.scrollIntoView?.({ behavior: "smooth" });
  }, [messages, pending, inFlightTurn]);

  const handleInputChange = (event: React.ChangeEvent<HTMLTextAreaElement>) => {
    setInput(event.target.value);
    const target = event.target;
    target.style.height = "auto";
    const maxHeight = 240; // ~10 lines
    target.style.height = `${Math.min(target.scrollHeight, maxHeight)}px`;
  };

  const handleSteer = () => {
    const text = input.trim();
    if (!text || !pending) return;
    // Reject oversize steering locally so the timeline never shows guidance
    // the engine must refuse; matches the server ChatRequest.maxTextLength.
    if (chatTextLength(text) > MAX_CHAT_TEXT_LENGTH) {
      setError(
        `Message too long — keep steering under ${MAX_CHAT_TEXT_LENGTH} characters.`,
      );
      return;
    }
    // The timeline must never show guidance the engine never received, so a
    // dropped socket keeps the draft in the input with an honest error
    // instead of clearing it behind a silent loss.
    const sent = sendMessage({
      text,
      sessionID,
      steer: true,
      source: "dashboard",
    });
    if (!sent) {
      setError(
        "Connection is closed — steering was not sent. Wait for reconnect, then try again.",
      );
      return;
    }
    setInput("");
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
    const steerId = newSessionId();
    const userMsg: MessageItem = {
      id: steerId,
      role: "user",
      text,
    };
    // Queue every optimistic bubble so a rejection retracts exactly one entry
    // in send order instead of the last send overwriting earlier ones. Sheds
    // the oldest like the engine queue when rapid taps exceed its bound, and
    // removes its bubble so the timeline never shows guidance the engine
    // already dropped.
    pendingSteerRef.current.push({ id: steerId, text });
    let shedSteerId: string | null = null;
    if (pendingSteerRef.current.length > MAX_PENDING_STEERS) {
      const shed = pendingSteerRef.current.shift();
      if (shed) shedSteerId = shed.id;
    }
    setMessages((prev) => {
      const withSteer = [...prev, userMsg];
      const withoutShed = shedSteerId
        ? withSteer.filter((m) => m.id !== shedSteerId)
        : withSteer;
      return withoutShed.slice(-MAX_MESSAGES);
    });
  };

  const handleKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      if (pending) {
        handleSteer();
      } else {
        void send();
      }
    }
  };

  // Manual cancel stays immediate even with the longer liveness budget: the
  // user action clears the timer and aborts only its own session's turn
  // without touching background sessions, which keep their server slots.
  async function handleCancel() {
    if (!pending) return;
    const cancelSID = sessionID;
    cancelledRef.current = true;
    clearTurnTimeout();
    clearAllToolProgress();
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    // A cancelled turn settles steering, so a late error cannot retract an
    // already-settled bubble from history.
    pendingSteerRef.current = [];
    pendingNormalRef.current = null;
    // A cancelled active turn must never resurrect as a background badge.
    parkedFlightsRef.current.delete(parkedFlightKey(cancelSID));
    markBackgroundRunning(parkedFlightKey(cancelSID), false);
    try {
      if (isOpen()) {
        sendMessage({
          type: "cancel",
          sessionID: cancelSID,
        });
      }
      await cancelChat(cancelSID);
    } catch {
      // Best-effort cancellation
    } finally {
      setInFlightTurn(null);
      setPending(false);
    }
  }

  async function send() {
    const text = input.trim();
    if (!text || pending) return;
    // Reject oversize sends locally so the timeline never shows a message the
    // engine must refuse with an authoritative length error.
    if (chatTextLength(text) > MAX_CHAT_TEXT_LENGTH) {
      setError(
        `Message too long — keep messages under ${MAX_CHAT_TEXT_LENGTH} characters.`,
      );
      return;
    }
    // Bound parallel turns so slow local inference never stacks silently:
    // the active turn plus every parked background turn counts toward the
    // server-advertised cap, and a full house refuses with an honest busy
    // notice. The active slot counts even though the input lock usually
    // guards it, so a state commit that lags behind the ref never admits a
    // turn past the shared limit. The cap resolves through the health
    // advertisement so client refusal agrees with server enforcement instead
    // of drifting on a local constant.
    const parkedPendingCount = [...parkedFlightsRef.current.values()].filter(
      (flight) => flight.pending,
    ).length;
    const activeTurnCount = pendingRef.current || pending ? 1 : 0;
    const turnCap = resolveMaxConcurrentChatTurns(health);
    if (activeTurnCount + parkedPendingCount + 1 > turnCap) {
      setError(concurrentTurnsBusyMessage(turnCap));
      return;
    }
    cancelledRef.current = false;
    knownDraftIDRef.current = null;
    setPending(true);
    setError(null);
    // Each turn owns its banner: stale degraded-tool lines clear on send so
    // the next live or terminal notice starts from an honest empty state.
    setTurnWarnings([]);

    const isFirst = messages.length === 0;
    isFirstMessageRef.current = isFirst;
    latestPromptRef.current = text;

    const userMessage: MessageItem = {
      id: newSessionId(),
      role: "user",
      text,
    };
    // Remember the optimistic bubble so an authoritative length refusal can
    // retract exactly this send; turn-wide failures leave it visible.
    pendingNormalRef.current = { id: userMessage.id, text };

    setMessages((prev) => [...prev, userMessage].slice(-MAX_MESSAGES));
    setInput("");
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }

    setInFlightTurn({ toolActions: [], text: "", segments: [] });
    // A fresh turn owns a fresh progress map: any prior turn's rows are gone,
    // so stale call identities never resurface under the new reply.
    clearAllToolProgress();
    // Remember the owning session so timeout/close cancels this turn even
    // when the user switches sessions before the terminal frame arrives.
    turnSessionIDRef.current = sessionID;
    activeTurnStartMsRef.current = Date.now();
    // Freeze the prior session base so live token frames add the running turn
    // total onto a stable starting point instead of compounding onto themselves.
    // The live ref holds the latest committed total even when a prior turn's
    // update has not re-rendered yet, so the next turn never restarts from a
    // stale snapshot and reconciles without double-counting.
    sessionBaseRef.current = sessionTokensRef.current;

    // Stream via WebSocket if connection is open
    if (isOpen()) {
      sendMessage({
        text,
        sessionID,
        source: "dashboard",
      });
      // Bound the terminal frame: a drop before done/error releases the
      // input lock with a retry instead of stranding it.
      armTurnTimeout();
      return;
    }

    // Fallback to REST postChat
    try {
      const response = await postChat(text, sessionID, "dashboard");
      // The server stored the optimistic bubble, so no retraction remains.
      pendingNormalRef.current = null;
      // A cancel racing the REST round-trip must not append the late
      // reply, matching the WebSocket path that guards cancelledRef.
      if (cancelledRef.current) return;
      // Validated per-turn parked flag: only an explicit true marks a waiting
      // turn, so absent tags from older engines stay normal completions.
      const isParked = response.isParked === true;
      const currentSid = response.sessionID || sessionID;
      if (
        response.sessionID &&
        normalizeSessionID(response.sessionID) !== normalizeSessionID(sessionID)
      ) {
        setSessionID(response.sessionID);
      }

      if (response.modelName) setActiveModel(response.modelName);
      if (response.contextLength) setContextLimit(response.contextLength);
      // REST counters share the streaming integer contract: fractional totals
      // drop instead of flooring so polling and streaming footers agree with
      // the hub and engine decoders.
      const total = toNonNegativeInt(response.totalTokens);
      const restSessionTokens = toNonNegativeInt(response.sessionTokens);
      const restContextTokens = toNonNegativeInt(response.contextTokens);
      if (typeof total === "number") {
        setLastTurnTokens(total);
      }
      if (typeof restContextTokens === "number") {
        setContextTokens(restContextTokens);
        try {
          localStorage.setItem(contextTokensKey(currentSid), String(restContextTokens));
        } catch {
          // Storage is best-effort only.
        }
      }
      if (typeof restSessionTokens === "number") {
        setSessionTokens(restSessionTokens);
        if (!isParked) {
          sessionBaseRef.current = restSessionTokens;
        }
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(restSessionTokens));
        } catch {
          // Storage is best-effort only.
        }
      } else if (typeof total === "number") {
        // REST has no live footer, so the cached base plus this turn is the
        // honest total. A parked turn keeps the pre-park base because a later
        // resume synthesis re-reports the parked tokens in its running total.
        // The base keeps the integer contract so a drifted store never seeds
        // a fractional sum.
        const restBase = sessionBaseRef.current;
        const restFallbackBase =
          toNonNegativeInt(restBase) ?? sessionTokensRef.current;
        const next = restFallbackBase + total;
        setSessionTokens(next);
        if (!isParked) {
          sessionBaseRef.current = next;
        }
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(next));
        } catch {
          // Storage is best-effort only.
        }
      }

      // Pre-name session on first turn
      if (isFirst) {
        const title = autoTitleFromPrompt(text);
        void updateSessionTitle(currentSid, title).then(() => {
          setSessionRefreshKey((k) => k + 1);
        });
        isFirstMessageRef.current = false;
      }

      const orderedRestActions = [...response.toolActions].sort(
        compareToolActionsByRound,
      );
      const restSegments = buildRestSegments(
        orderedRestActions,
        response.text,
      );
      const restFlatText =
        restSegments.length > 0
          ? flatTextFromSegments(restSegments)
          : response.text;
      const restFlat = flatActionsFromSegments(restSegments);
      // Same grounding rule as the streaming path so polling and streaming
      // clients render identical footers; an omitted stamp renders no footer.
      const restCompletedAt = normalizeCompletedAtMs(
        (response as unknown as Record<string, unknown>).completedAt,
      );
      const assistantMessage: MessageItem = {
        id: newSessionId(),
        role: "assistant",
        text: restFlatText,
        toolActions: restFlat.length > 0 ? restFlat : undefined,
        segments: restSegments.length > 0 ? restSegments : undefined,
        ...(restCompletedAt != null ? { completedAt: restCompletedAt } : {}),
      };

      setMessages((prev) => [...prev, assistantMessage].slice(-MAX_MESSAGES));
      // REST turns carry no stream, so terminal warnings are the only banner
      // source here; malformed lists degrade to no banner like the WS path.
      const restWarnings = sanitizeWarnings(response.warnings);
      if (restWarnings.length > 0) {
        setTurnWarnings((previous) => mergeWarningLists(previous, restWarnings));
      }
      if (isParked) {
        // Parked REST turns (WS closed) wait on inbox approval: refresh immediately so the header
        // shows the amber waiting state instead of appearing completed, while the waiting text
        // above keeps the pending UI honest without relying on an unrelated poll.
        refreshApprovals();
      }
    } catch (failure) {
      // Suppress the late failure when the turn was already cancelled.
      if (cancelledRef.current) return;
      const message =
        failure instanceof ApiError ? failure.message : "Chat failed";
      // The server stays authoritative on length: an oversize refusal rolls
      // back its optimistic bubble while turn-wide failures leave received
      // messages visible.
      const isLengthRefusal =
        (failure instanceof ApiError &&
          (failure.status === 413 || isTooLongText(failure.message))) ||
        (!(failure instanceof ApiError) && isTooLongText(message));
      if (isLengthRefusal) {
        const optimisticId = userMessage.id;
        pendingNormalRef.current = null;
        setMessages((prev) => prev.filter((m) => m.id !== optimisticId));
        setInput((prev) => (prev ? `${prev}\n${text}` : text));
      } else {
        pendingNormalRef.current = null;
      }
      setError(message);
    } finally {
      // Mirror every streaming terminal path: a heartbeat-armed timer must not
      // outlive the REST turn and fire a spurious cancel after completion.
      clearTurnTimeout();
      clearAllToolProgress();
      turnSessionIDRef.current = null;
      activeTurnStartMsRef.current = null;
      setInFlightTurn(null);
      setPending(false);
    }
  }

  function handleNewSession() {
    // Switching never cancels: the active turn parks into the per-session map
    // and keeps its server slot while the fresh draft starts idle.
    parkActiveFlight();
    const nextID = newSessionId();
    knownDraftIDRef.current = nextID;
    setSessionID(nextID);
    setMessages([]);
    setInFlightTurn(null);
    inFlightTurnRef.current = null;
    setPending(false);
    pendingRef.current = false;
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    cancelledRef.current = false;
    clearAllToolProgress();
    setError(null);
    // Banners belong to their session, so switching drafts never carries
    // another conversation's skipped-tool lines into the fresh view.
    setTurnWarnings([]);
    turnWarningsRef.current = [];
    setLastTurnTokens(null);
    lastTurnTokensRef.current = null;
    const fresh = loadSessionTokens(nextID);
    setSessionTokens(fresh);
    sessionBaseRef.current = fresh;
    const freshContext = loadContextTokens(nextID);
    setContextTokens(freshContext);
  }

  function handleSelectSession(id: string) {
    if (normalizeSessionID(id) === normalizeSessionID(sessionID)) return;
    // Keep the prior server turn alive in the background instead of
    // cancelling it; its frames accumulate in the parked map and the return
    // restores the live bubble without duplicating completed history.
    parkActiveFlight();
    knownDraftIDRef.current = null;
    setSessionID(id);
    // Clear the visible live state before the history reload so a rapid
    // switch never interleaves the prior session's deltas into the new view;
    // the parked restore below re-applies the target's own live bubble.
    setInFlightTurn(null);
    inFlightTurnRef.current = null;
    setPending(false);
    pendingRef.current = false;
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    cancelledRef.current = false;
    clearAllToolProgress();
    setError(null);
    setTurnWarnings([]);
    turnWarningsRef.current = [];
    setLastTurnTokens(null);
    lastTurnTokensRef.current = null;
    const hydrated = loadSessionTokens(id);
    setSessionTokens(hydrated);
    sessionBaseRef.current = hydrated;
    const hydratedContext = loadContextTokens(id);
    setContextTokens(hydratedContext);
    restoreParkedFlight(id);
  }

  const usedPercent =
    contextLimit > 0
      ? Math.round((contextTokens / contextLimit) * 100)
      : 0;
  // Amber badge count for this session only; other sessions' approvals never
  // leak into this header.
  const sessionApprovals = approvalsForSession(pendingApprovals, sessionID);
  const sessionPendingCount = sessionApprovals.length;
  // Liveness helpers for the persistent footer below: a tool with no result is
  // still running on the engine, while completed tools plus partial text mean
  // the next prompt round is processing silently with no frames to render.
  const hasRunningTools =
    inFlightTurn?.toolActions.some((action) => !action.result) ?? false;
  const hasPartialText =
    (inFlightTurn?.text.trim().length ?? 0) > 0;

  return (
    <div className="chat-layout">
      {/* Session History Sidebar */}
      <SessionSidebar
        currentSessionID={sessionID}
        onSelectSession={handleSelectSession}
        onNewSession={handleNewSession}
        isOpen={sidebarOpen}
        onToggleOpen={() => setSidebarOpen(!sidebarOpen)}
        refreshTrigger={sessionRefreshKey}
        pendingApprovals={pendingApprovals}
        runningSessionIDs={backgroundRunningIDs}
      />

      {/* Main Chat Area */}
      <section className="chat-main-panel" aria-label="Chat">
        <div className="chat-panel-header">
          <div className="chat-panel-title">
            {!sidebarOpen && (
              <button
                type="button"
                className="open-sidebar-btn"
                onClick={() => setSidebarOpen(true)}
                title="Open session history"
              >
                History
              </button>
            )}
            <h2>Chat</h2>
            <span className="session-id-tag font-mono" title={sessionID}>
              {sessionID.slice(0, 8)}
            </span>
            {sessionPendingCount > 0 ? (
              <span
                className="pending-approval-badge"
                data-testid="session-pending-badge"
                title={`${sessionPendingCount} approval${sessionPendingCount > 1 ? "s" : ""} awaiting decision for this session`}
              >
                Pending approval ({sessionPendingCount})
              </span>
            ) : null}
          </div>

          <button
            type="button"
            className="ghost new-session-btn"
            onClick={handleNewSession}
            aria-label="New session"
          >
            New Session
          </button>
        </div>

        {/* Message Stream */}
        <div className="message-list" aria-live="polite">
          {messages.length === 0 && !pending ? (
            <div className="chat-empty-state">
              <h3>What would you like to work on?</h3>
              <p className="muted">
                Ask questions, inspect mail, manage schedules, or recall notes.
              </p>
            </div>
          ) : null}

          {messages.map((message) => {
            const actions =
              message.role === "assistant" ? (message.toolActions ?? []) : [];
            const hasTools = actions.length > 0;
            const hasText = Boolean(message.text && message.text.trim().length > 0);
            if (!hasText && !hasTools) return null;
            // Segmented turns render text and tool batches in chronological order
            // so multi-round timelines never collapse into one lumped bucket.
            // Turns built before segmentation fall back to the legacy bucket below.
            const segments =
              message.role === "assistant" && message.segments
                ? message.segments
                : undefined;

            return (
              <div key={message.id} className={`message ${message.role}`}>
                {segments && segments.length > 0 ? (
                  <>
                    {segments.map((segment, segmentIndex) =>
                      segment.kind === "tools" ? (
                        <div
                          key={`tools-${segmentIndex}`}
                          className="chat-tool-container"
                        >
                          <div className="chat-tool-heading">
                            <WrenchIcon size={12} />
                            <span>Tool Activity ({segment.actions.length})</span>
                          </div>
                          <div className="chat-tool-list">
                            {segment.actions.map((action, i) => (
                              <ToolActionRow
                                key={action.callID || `${segmentIndex}-${i}`}
                                action={action}
                                isLive={false}
                              />
                            ))}
                          </div>
                        </div>
                      ) : segment.text.trim().length > 0 ? (
                        <div
                          key={`text-${segmentIndex}`}
                          className="message-text"
                        >
                          {message.role === "assistant" ? (
                            <MarkdownText text={segment.text} />
                          ) : (
                            segment.text
                          )}
                        </div>
                      ) : null,
                    )}
                  </>
                ) : (
                  <>
                    {/* Distinct Tool Activity if assistant called tools */}
                    {hasTools ? (
                      <div className="chat-tool-container">
                        <div className="chat-tool-heading">
                          <WrenchIcon size={12} />
                          <span>Tool Activity ({actions.length})</span>
                        </div>
                        <div className="chat-tool-list">
                          {actions.map((action, i) => (
                            <ToolActionRow
                              key={action.callID || i}
                              action={action}
                              isLive={false}
                            />
                          ))}
                        </div>
                      </div>
                    ) : null}

                    {/* Message Content */}
                    {hasText ? (
                      <div className="message-text">
                        {message.role === "assistant" ? (
                          <MarkdownText text={message.text} />
                        ) : (
                          message.text
                        )}
                      </div>
                    ) : null}
                  </>
                )}
                {/* Completion footer: local relative time with an absolute
                    tooltip so each agent card carries its when without touching
                    markdown rendering. Missing stamps render no footer. */}
                {message.role === "assistant" &&
                message.completedAt != null ? (
                  <div
                    className="message-completed-footer muted text-xs"
                    style={{ marginTop: "8px" }}
                    title={new Date(message.completedAt).toLocaleString()}
                  >
                    {formatCompletionRelative(message.completedAt)}
                  </div>
                ) : null}
              </div>
            );
          })}

          {/* Active in-flight assistant response with live tools and streaming text */}
          {pending && inFlightTurn && (inFlightTurn.toolActions.length > 0 || inFlightTurn.text.trim().length > 0) ? (
            <div className="message assistant streaming-bubble">
              {inFlightTurn.segments && inFlightTurn.segments.length > 0 ? (
                <>
                  {inFlightTurn.segments.map((segment, segmentIndex) =>
                    segment.kind === "tools" ? (
                      <div
                        key={`live-tools-${segmentIndex}`}
                        className="chat-tool-container"
                      >
                        <div className="chat-tool-heading">
                          <WrenchIcon size={12} />
                          <span>Tool Activity ({segment.actions.length})</span>
                        </div>
                        <div className="chat-tool-list">
                          {segment.actions.map((action, i) => (
                            <ToolActionRow
                              key={action.callID || `live-${segmentIndex}-${i}`}
                              action={action}
                              isLive
                              progress={
                                toolProgressByCallID.get(action.callID) ?? null
                              }
                              cancelling={cancellingToolCallIDs.has(
                                action.callID,
                              )}
                              onCancelTool={handleCancelTool}
                            />
                          ))}
                        </div>
                      </div>
                    ) : segment.text.trim().length > 0 ? (
                      <div
                        key={`live-text-${segmentIndex}`}
                        className="message-text"
                      >
                        <MarkdownText text={segment.text} />
                      </div>
                    ) : null,
                  )}
                </>
              ) : (
                <>
                  {inFlightTurn.toolActions.length > 0 ? (
                    <div className="chat-tool-container">
                      <div className="chat-tool-heading">
                        <WrenchIcon size={12} />
                        <span>Tool Activity ({inFlightTurn.toolActions.length})</span>
                      </div>
                      <div className="chat-tool-list">
                        {inFlightTurn.toolActions.map((action, i) => (
                          <ToolActionRow
                            key={action.callID || i}
                            action={action}
                            isLive
                            progress={
                              toolProgressByCallID.get(action.callID) ?? null
                            }
                            cancelling={cancellingToolCallIDs.has(action.callID)}
                            onCancelTool={handleCancelTool}
                          />
                        ))}
                      </div>
                    </div>
                  ) : null}

                  {inFlightTurn.text.trim().length > 0 ? (
                    <div className="message-text">
                      <MarkdownText text={inFlightTurn.text} />
                    </div>
                  ) : null}
                </>
              )}
            </div>
          ) : null}

          {/* Persistent liveness footer: the engine emits zero renderable frames
              while the next prompt round processes (heartbeats re-arm silently),
              so visibility keys on pending alone rather than partial text.
              Parked, cancelled, and error turns clear pending and therefore hide
              this without extra guards. The idle copy stays honest about large
              prompts on slow local models instead of implying a stall. */}
          {pending ? (
            <div className="message assistant pending-bubble">
              <div className="typing-indicator" aria-label="Rune Weaver is thinking">
                <span className="typing-dot" />
                <span className="typing-dot" />
                <span className="typing-dot" />
              </div>
              <span className="typing-text">
                {hasRunningTools
                  ? "Executing tools…"
                  : hasPartialText
                    ? "Thinking…"
                    : "Still thinking — large prompts take a while…"}
              </span>
            </div>
          ) : null}

          <div ref={messageListEndRef} />
        </div>

        {error ? <p className="error chat-error">{error}</p> : null}

        {/* Reconnecting notice stays informational while the socket recovers:
            running turns keep their server slots, so the input never locks and
            no retry copy appears here. */}
        {reconnecting ? (
          <p
            className="muted chat-reconnecting"
            role="status"
            aria-label="Reconnecting to server"
            data-testid="chat-reconnecting"
          >
            Reconnecting… background turns keep running.
          </p>
        ) : null}

        {/* Trimmed-flight notice surfaces lossy LRU/TTL evictions through
            visible state: the dev log stays silent in production, so without
            this banner a shipped bundle would drop a live background timeline
            with no signal. The badge stays lit and the next frame rebuilds
            the timeline, so this informs without locking input. */}
        {trimmedLiveFlights.length > 0 ? (
          <p
            className="muted flight-eviction-notice"
            role="status"
            aria-label="Background turn trimmed"
            data-testid="flight-eviction-notice"
          >
            A background turn view was trimmed to stay within memory bounds; it
            rebuilds from the next live update.
            <button
              type="button"
              className="ghost flight-eviction-dismiss"
              aria-label="Dismiss trim notice"
              onClick={() => setTrimmedLiveFlights([])}
            >
              Dismiss
            </button>
          </p>
        ) : null}

        {/* Degraded-tool banner sits above the input like the fatal error, but
            stays amber and dismissible: skipped tools never fail the turn, so
            the notice must never lock Send the way a red error interrupts. */}
        {turnWarnings.length > 0 ? (
          <div
            data-testid="turn-warnings-banner"
            role="status"
            aria-label="Degraded tool warnings"
            className="turn-warnings-banner"
          >
            <div className="turn-warnings-header">
              <strong>
                {turnWarnings.length === 1
                  ? "A tool was skipped for this turn"
                  : `${turnWarnings.length} tools were skipped for this turn`}
              </strong>
              <button
                type="button"
                className="ghost turn-warnings-dismiss"
                aria-label="Dismiss warnings"
                onClick={() => setTurnWarnings([])}
              >
                Dismiss
              </button>
            </div>
            <ul className="turn-warnings-list">
              {turnWarnings.map((warning) => (
                <li key={warning}>{warning}</li>
              ))}
            </ul>
          </div>
        ) : null}

        {/* Inline session approvals sit between the parked waiting text and
            the input as a non-modal list, so deciding never blocks typing. */}
        {sessionApprovals.length > 0 ? (
          <div
            className="inline-approval-list"
            aria-label="Session approvals awaiting decision"
          >
            {sessionApprovals.map((request) => (
              <InlineApprovalBanner
                key={request.id}
                request={request}
                deciding={decidingApprovalIDs.has(request.id)}
                onDecide={(id, approved, duration, widen) =>
                  void handleDecideApproval(id, approved, duration, widen)
                }
              />
            ))}
          </div>
        ) : null}

        {/* Input & Status Bar Container */}
        <div className="chat-footer-box">
          <div className="chat-input-row">
            <textarea
              ref={textareaRef}
              id="chat-message-prompt"
              name="chat_message_prompt"
              rows={3}
              aria-label="Chat input"
              placeholder={
                pending
                  ? "Steer agent mid-turn… (Shift+Return for newline)"
                  : "Message Rune Weaver… (Shift+Return for newline)"
              }
              value={input}
              onChange={handleInputChange}
              onKeyDown={handleKeyDown}
              // Grapheme guard in send/steer is authoritative: native maxLength
              // counts UTF-16 units and would miscount emoji.
              // always enabled so pending turns accept steering
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              data-lpignore="true"
              data-1p-ignore="true"
              data-form-type="other"
            />
            {pending ? (
              input.trim().length > 0 ? (
                <button
                  type="button"
                  className="primary chat-send-btn"
                  onClick={handleSteer}
                  aria-label="Steer turn"
                >
                  Steer
                </button>
              ) : (
                <button
                  type="button"
                  className="chat-cancel-btn"
                  onClick={() => void handleCancel()}
                  aria-label="Cancel turn"
                >
                  Cancel
                </button>
              )
            ) : (
              <button
                type="button"
                className="primary chat-send-btn"
                onClick={() => void send()}
                disabled={input.trim().length === 0}
              >
                Send
              </button>
            )}
          </div>

          {/* Pinned Status Bar Attached Below Input */}
          <div className="chat-status-bar" aria-label="Session metrics">
            <div className="status-bar-item">
              <span className="status-bullet green" />
              <span className="status-bar-label">LLM:</span>
              <span className="status-bar-value">{activeModel}</span>
            </div>

            <div className="status-bar-divider">•</div>

            <div className="status-bar-item">
              <span className="status-bar-label">Turn:</span>
              <span className="status-bar-value">
                {lastTurnTokens != null
                  ? `${lastTurnTokens.toLocaleString()} tokens`
                  : "—"}
              </span>
            </div>

            <div className="status-bar-divider">•</div>

            <div className="status-bar-item">
              <span className="status-bar-label">Context:</span>
              <span
                className={`status-bar-value ${
                  usedPercent >= 80 ? "status-warning" : ""
                }`}
              >
                {contextTokens.toLocaleString()} /{" "}
                {contextLimit.toLocaleString()} tokens ({usedPercent}%)
              </span>
            </div>

            <div className="status-bar-divider">•</div>

            <div className="status-bar-item">
              <span className="status-bar-label">Session:</span>
              <span className="status-bar-value">
                {sessionTokens.toLocaleString()} tokens
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
