// Rune Weaver Dashboard — Interactive chat interface with session history sidebar,
// animated typing indicator, distinct tool activity display, and attached status bar.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  cancelChat,
  compareToolActionsByRound,
  decideApproval,
  getSession,
  getSessionToolActions,
  groupToolActionsByRound,
  listApprovals,
  newSessionId,
  normalizeRoundIndex,
  postChat,
  sortToolActionsByRound,
  updateSessionTitle,
  type ChatSegment,
  type HealthResponse,
  type PermissionRequest,
  type SessionMessageToolActions,
  type ToolAction,
  type ToolResult,
  type TrustDuration,
} from "../api";
import SessionSidebar from "./SessionSidebar";
import InlineApprovalBanner from "./InlineApprovalBanner";
import MarkdownText from "./MarkdownText";
import ToolActionRow from "./ToolActionRow";
import { WrenchIcon } from "./icons";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";
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
} from "../approvalsSession";
import { sanitizeWarnings } from "../warnings";

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
}

interface InFlightTurn {
  toolActions: ToolAction[];
  text: string;
  // Live chronological timeline built incrementally: the current text segment
  // closes when a tool starts and a fresh text segment opens on the next delta
  // after tools, mirroring the persisted per-round note boundaries for reloads.
  segments: ChatSegment[];
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
// Falls back to pending same-tool rows only when no call identity matches, so
// batches with multiple same-tool calls never misattribute one result to all rows.
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
  return segments.map((segment) => {
    if (segment.kind !== "tools") return segment;
    return {
      kind: "tools" as const,
      actions: segment.actions.map((action) => {
        const isMatch = hasCallIDMatch
          ? action.callID === callID
          : !action.result && action.toolName === toolName;
        return isMatch
          ? {
              ...action,
              result,
              ...(roundIndex !== undefined ? { roundIndex } : {}),
            }
          : action;
      }),
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
  return text
    .split("\n")
    .filter((line) => {
      if (!line.trim()) return false;
      for (const callID of coveredCallIDs) {
        if (callID && line.includes(`[${callID}]`)) return false;
      }
      return true;
    })
    .join("\n")
    .trim();
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
  const byCallID = new Map<string, ToolAction>();
  for (const action of doneToolActions) {
    if (action.callID) byCallID.set(action.callID, action);
  }
  if (snapshotSegments.length > 0) {
    const merged = snapshotSegments.map((segment) => {
      if (segment.kind !== "tools") return segment;
      return {
        kind: "tools" as const,
        actions: segment.actions.map((action) => {
          const authoritative = action.callID
            ? byCallID.get(action.callID)
            : undefined;
          return authoritative ? { ...authoritative } : { ...action };
        }),
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
    const missing = doneToolActions.filter(
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
  // No live skeleton (cold done): group authoritative actions by round oldest-first
  // then trail the terminal text, matching the history reconstruction order.
  const ordered = [...doneToolActions].sort(compareToolActionsByRound);
  const built: ChatSegment[] = [];
  for (const group of groupToolActionsByRound(ordered)) {
    built.push({ kind: "tools" as const, actions: group });
  }
  const trailing = (doneText ?? snapshotText ?? "").trim();
  // Avoid duplicating narration fallback lines already covered by structured
  // actions: only uncovered prose becomes a text segment.
  if (trailing.length > 0) {
    const covered = new Set(
      ordered.map((action) => action.callID).filter(Boolean),
    );
    const uncovered = filterUncoveredText(trailing, covered);
    if (uncovered.length > 0) {
      built.push({ kind: "text" as const, text: uncovered });
    } else if (built.length === 0) {
      built.push({ kind: "text" as const, text: trailing });
    }
  }
  return built;
}

// Builds REST fallback timelines without a live skeleton: round groups in order
// then the terminal text, so polling clients agree with streaming ones.
function buildRestSegments(actions: ToolAction[], text: string): ChatSegment[] {
  const ordered = [...actions].sort(compareToolActionsByRound);
  const built: ChatSegment[] = [];
  for (const group of groupToolActionsByRound(ordered)) {
    built.push({ kind: "tools" as const, actions: group });
  }
  if (text.trim().length > 0) {
    const covered = new Set(ordered.map((a) => a.callID).filter(Boolean));
    const uncovered = filterUncoveredText(text, covered);
    // Without a structured record every line stays visible as prose instead of
    // guessing its shape, so fall back to the full text when all lines filter.
    if (uncovered.length > 0) {
      built.push({ kind: "text" as const, text: uncovered });
    } else if (built.length === 0) {
      built.push({ kind: "text" as const, text: text.trim() });
    } else if (ordered.length === 0) {
      built.push({ kind: "text" as const, text: text.trim() });
    }
  }
  return built;
}

const MAX_MESSAGES = 200;

// Interim waiting placeholder prefix for parked approval turns. The engine composes parked text
// without a structured history flag (`waitingOnApprovalMessage`: "Waiting for approval to run
// ..."), so live updates and history reconstruction key interim detection on this prefix.
const WAITING_PREFIX = "Waiting for approval";

// Per-session cached cumulative token total so a reload hydrates the status
// bar instead of resetting to zero; the authoritative `sessionTokens` from
// the next done frame always overwrites it.
function sessionTokensKey(id: string): string {
  return `rw_session_tokens_${id}`;
}

function loadSessionTokens(id: string): number {
  try {
    const raw = localStorage.getItem(sessionTokensKey(id));
    const parsed = raw != null ? Number(raw) : 0;
    return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0;
  } catch {
    return 0;
  }
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
// first. Each group's actions sort chronologically by round so reloads interleave
// identically to live turns; untracked rounds keep stored order at their stored slot.
export function toolActionMap(
  groups: SessionMessageToolActions[] | undefined,
): Map<string, ToolAction[]> {
  const map = new Map<string, ToolAction[]>();
  for (const group of groups ?? []) {
    map.set(group.messageID, sortToolActionsByRound([...(group.actions ?? [])]));
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
): MessageItem[] {
  const getStructured = (messageID: string | undefined): ToolAction[] | undefined => {
    if (!structuredByMessageID || !messageID) return undefined;
    if (structuredByMessageID instanceof Map) {
      return structuredByMessageID.get(messageID);
    }
    return (structuredByMessageID as Record<string, ToolAction[]>)[messageID];
  };
  // Flushes one turn's ordered timeline while keeping flat summaries for legacy
  // readers: text joins text segments and actions flatten tool batches in order.
  const flushTurn = (segments: ChatSegment[], id: string): MessageItem => {
    const text = flatTextFromSegments(segments);
    const flat = flatActionsFromSegments(segments);
    return {
      id,
      role: "assistant",
      text,
      toolActions: flat.length > 0 ? flat : undefined,
      segments: [...segments],
    };
  };
  const result: MessageItem[] = [];
  let pendingSegments: ChatSegment[] = [];

  for (let i = 0; i < rawMessages.length; i++) {
    const m = rawMessages[i];
    if (m.role === "user") {
      if (pendingSegments.length > 0) {
        result.push(flushTurn(pendingSegments, `interim_${i}`));
        pendingSegments = [];
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

      const structured = getStructured(m.id);
      if (structured && structured.length > 0) {
        const coveredCallIDs = new Set(
          structured.map((action) => action.callID).filter(Boolean),
        );
        const leftoverLines: string[] = [];
        for (const rawLine of m.content.split("\n")) {
          if (!rawLine.trim()) continue;
          // Hide only lines the server record covers, identified by the
          // authoritative call identifier, so unrelated prose stays visible and
          // narration fallback lines never double-count with structured actions.
          let isCovered = false;
          for (const callID of coveredCallIDs) {
            if (rawLine.includes(`[${callID}]`)) {
              isCovered = true;
              break;
            }
          }
          if (isCovered) continue;
          leftoverLines.push(rawLine);
        }
        // Preserve live order per round: this note's prose precedes its tools, and
        // successive notes append as successive segments instead of one bucket.
        if (leftoverLines.length > 0) {
          pendingSegments.push({
            kind: "text",
            text: leftoverLines.join("\n").trim(),
          });
        }
        pendingSegments.push(...toolsSegmentsForMessage(structured));
        continue;
      }
      const leftoverLines: string[] = [];
      for (const rawLine of m.content.split("\n")) {
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
        result.push(flushTurn(pendingSegments, m.id || `${m.createdAt || i}`));
        pendingSegments = [];
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
    result.push(flushTurn(pendingSegments, `trailing_${rawMessages.length}`));
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

  // Status bar metrics
  const [lastTurnTokens, setLastTurnTokens] = useState<number | null>(null);
  const [sessionTokens, setSessionTokens] = useState<number>(0);
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
  // Snapshot of the live turn for terminal frames: updaters must stay pure,
  // so the done handler reads this ref instead of nesting a message append
  // inside a turn updater, which would duplicate under double-invoke.
  const inFlightTurnRef = useRef<InFlightTurn | null>(null);
  // A server-side delete leaves the stored active ID stale; regenerate
  // it exactly once instead of resurrecting the deleted UUID on send.
  const didRecoverSessionRef = useRef(false);
  // Tracks whether the active session is a local draft (new session not yet on server)
  // so we do not issue GET /sessions/<uuid> which would return 404.
  const knownDraftIDRef = useRef<string | null>(
    localStorage.getItem("rw_active_session_id") ? null : sessionID,
  );

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

  // Release a stranded turn when the socket drops mid-turn.
  const handleWSClose = useCallback(() => {
    if (!pendingRef.current) return;
    // Cancel the turn's owning session, not whatever session is active now,
    // so switching sessions mid-turn never cancels the new session.
    const turnSID = turnSessionIDRef.current ?? sessionIDRef.current;
    void cancelChat(turnSID).catch(() => {
      // Cancel is best-effort; close recovery releases the input even when it fails.
    });
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
    turnSessionIDRef.current = null;
    setInFlightTurn(null);
    setPending(false);
    setError(
      "Connection lost during the turn. Retry your message — the interrupted turn was cancelled.",
    );
  }, []);

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
    async (id: string, approved: boolean, duration: TrustDuration) => {
      setDecidingApprovalIDs((previous) => new Set(previous).add(id));
      try {
        await decideApproval(id, approved, duration);
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

    // Ignore frames intended for another session to prevent cross-session pollution
    if (
      frameSessionID &&
      normalizeSessionID(frameSessionID) !== normalizeSessionID(sessionIDRef.current)
    ) {
      return;
    }
    // Untagged session frames carry no owner, so they must never touch the
    // current view; only global broadcasts (approval/run_*) bypass tagging.
    // Warnings stay session-scoped with the turn frames so one session's
    // skipped tools never alarm another session's banner. Heartbeats stay
    // session-scoped for the same reason so one turn's proof of life never
    // re-arms another session's timer.
    if (
      !frameSessionID &&
      (frameType === "delta" ||
        frameType === "tool_start" ||
        frameType === "tool_end" ||
        frameType === "done" ||
        frameType === "warning" ||
        frameType === "turn_alive")
    ) {
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
      // Evict only this batch's waiting placeholder (same callID) or uncorrelated waiting with no
      // tool actions; other parked batches in the same session keep their placeholders so resuming
      // one never wipes the other. Non-waiting duplicates still evict by callID overlap.
      setMessages((prev) =>
        prev.filter((m) => {
          if (m.role !== "assistant") return true;
          const overlapsCall =
            m.toolActions?.some((a) => a.callID === callID) ?? false;
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
      // Live end frames mirror the start round so resumed batches rejoin the
      // same timeline; absent rounds keep the start value instead of clearing it.
      const endRound = normalizeRoundIndex(
        (data as WSToolEndFrame).roundIndex,
      );
      setMessages((prev) =>
        prev.map((msg) => {
          if (!msg.toolActions || msg.toolActions.length === 0) return msg;
          // Match by call identity first so batches with multiple same-tool
          // calls never stamp one result onto every pending sibling; the
          // pending same-tool fallback only applies when no call identity
          // matches in this message.
          const hasCallIDMatch = msg.toolActions.some(
            (a) => a.callID === endCallID,
          );
          const hasMatch = hasCallIDMatch
            ? true
            : msg.toolActions.some(
                (a) => !a.result && a.toolName === endToolName,
              );
          if (!hasMatch) return msg;
          const nextActions = msg.toolActions.map((a) => {
            const isMatch = hasCallIDMatch
              ? a.callID === endCallID
              : !a.result && a.toolName === endToolName;
            return isMatch
              ? {
                  ...a,
                  result: endResult,
                  ...(endRound !== undefined ? { roundIndex: endRound } : {}),
                }
              : a;
          });
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
        })
      );
      setInFlightTurn((prev) => {
        if (!prev) return prev;
        // Same call-identity-first rule as the message bucket above: one end
        // frame updates only its own call, with the pending same-tool fallback
        // reserved for frames that match nothing by identity.
        const hasTurnCallIDMatch = prev.toolActions.some(
          (action) => action.callID === endCallID,
        );
        const updated = prev.toolActions.map((action) => {
          const isMatch = hasTurnCallIDMatch
            ? action.callID === endCallID
            : !action.result && action.toolName === endToolName;
          if (isMatch) {
            return {
              ...action,
              result: endResult,
              ...(endRound !== undefined ? { roundIndex: endRound } : {}),
            };
          }
          return action;
        });
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
      turnSessionIDRef.current = null;
      // Terminal warnings repeat every mid-turn notice for polling clients,
      // so merge them even on a cancelled turn: the banner is informational
      // and must not depend on the reply surviving cancellation.
      const earlyWarnings = sanitizeWarnings(
        (data as Record<string, unknown>).warnings,
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
      const rawDoneText: unknown = data.text;
      const rawToolActions: unknown = data.toolActions;
      const rawIsParked: unknown = data.isParked;
      // Validated per-turn parked flag: only an explicit true marks a waiting
      // turn, so absent or malformed tags default to a normal completion.
      const isParked = rawIsParked === true;
      const modelName = typeof rawModelName === "string" ? rawModelName : undefined;
      const contextLength =
        typeof rawContextLength === "number" ? rawContextLength : undefined;
      const totalTokens =
        typeof rawTotalTokens === "number" ? rawTotalTokens : undefined;
      const sessionTokensValue =
        typeof rawSessionTokens === "number" ? rawSessionTokens : undefined;
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
      // Authoritative cumulative total wins when present so reloads,
      // multi-client turns, and retries never drift from local sums.
      if (typeof sessionTokensValue === "number") {
        const cumulative = sessionTokensValue;
        setSessionTokens(cumulative);
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(cumulative));
        } catch {
          // Storage is best-effort only.
        }
      } else if (typeof totalTokens === "number") {
        setSessionTokens((prev) => {
          const next = prev + totalTokens;
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(next));
          } catch {
            // Storage is best-effort only.
          }
          return next;
        });
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
      const orderedDoneActions = [...(doneToolActions ?? [])].sort(
        compareToolActionsByRound,
      );
      const finalActions =
        orderedDoneActions.length > 0
          ? orderedDoneActions
          : [...(snapshot?.toolActions ?? [])].sort(compareToolActionsByRound);
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
      const finalMsg: MessageItem = {
        id: newSessionId(),
        role: "assistant",
        text: legacyText,
        toolActions: legacyActions.length > 0 ? legacyActions : undefined,
        segments: doneSegments.length > 0 ? doneSegments : undefined,
      };
      setMessages((prev) => {
        // Terminal dedup stays batch-scoped: evict only placeholders whose batch overlaps this
        // turn's actions, plus generic waiting with no correlation. Other parked batches in the
        // same session keep their placeholders so completing one resume never wipes the other.
        const base = !isParked
          ? prev.filter((m) => {
              if (m.role !== "assistant") return true;
              const overlaps =
                finalActions.length > 0 &&
                (m.toolActions?.some((a) =>
                  finalActions.some(
                    (fa) => fa.callID && fa.callID === a.callID,
                  ),
                ) ??
                  false);
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
      turnSessionIDRef.current = null;
      setInFlightTurn(null);
      setPending(false);
    } else if (frameType === "error") {
      clearTurnTimeout();
      turnSessionIDRef.current = null;
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
    } else if (frameType === "run_completed") {
      // A parked run resuming in any tab means its approvals were decided;
      // reconcile with the authoritative inbox so the badge evicts without
      // waiting for a session switch.
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
      }
      refreshApprovals();
    }
  }, [armTurnTimeout, clearTurnTimeout, refreshApprovals]);

  const { sendMessage, isOpen } = useSharedWebSocket(handleWSMessage, handleWSClose);

  // Load active session messages on initial mount if existing
  useEffect(() => {
    let cancelled = false;
    const activeID = sessionID;
    // Hydrate the status bar from the cached cumulative total so a reload
    // does not reset a live session to zero; the next authoritative done
    // frame corrects it when the server has newer usage.
    setSessionTokens(loadSessionTokens(activeID));
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

  const handleKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void send();
    }
  };

  // Manual cancel stays immediate even with the longer liveness budget: the
  // user action clears the timer and aborts the server turn without waiting
  // for the inactivity window to expire.
  async function handleCancel() {
    if (!pending) return;
    cancelledRef.current = true;
    clearTurnTimeout();
    turnSessionIDRef.current = null;
    try {
      if (isOpen()) {
        sendMessage({
          type: "cancel",
          sessionID,
        });
      }
      await cancelChat(sessionID);
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

    setMessages((prev) => [...prev, userMessage].slice(-MAX_MESSAGES));
    setInput("");
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }

    setInFlightTurn({ toolActions: [], text: "", segments: [] });
    // Remember the owning session so timeout/close cancels this turn even
    // when the user switches sessions before the terminal frame arrives.
    turnSessionIDRef.current = sessionID;

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
      const total = response.totalTokens;
      if (typeof total === "number") {
        setLastTurnTokens(total);
      }
      if (typeof response.sessionTokens === "number") {
        setSessionTokens(response.sessionTokens);
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(response.sessionTokens));
        } catch {
          // Storage is best-effort only.
        }
      } else if (typeof total === "number") {
        setSessionTokens((prev) => {
          const next = prev + total;
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(next));
          } catch {
            // Storage is best-effort only.
          }
          return next;
        });
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
      const assistantMessage: MessageItem = {
        id: newSessionId(),
        role: "assistant",
        text: restFlatText,
        toolActions: restFlat.length > 0 ? restFlat : undefined,
        segments: restSegments.length > 0 ? restSegments : undefined,
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
      setError(message);
    } finally {
      // Mirror every streaming terminal path: a heartbeat-armed timer must not
      // outlive the REST turn and fire a spurious cancel after completion.
      clearTurnTimeout();
      turnSessionIDRef.current = null;
      setInFlightTurn(null);
      setPending(false);
    }
  }

  function handleNewSession() {
    if (pending) {
      void handleCancel();
    }
    const nextID = newSessionId();
    knownDraftIDRef.current = nextID;
    setSessionID(nextID);
    setMessages([]);
    setInFlightTurn(null);
    setError(null);
    // Banners belong to their session, so switching drafts never carries
    // another conversation's skipped-tool lines into the fresh view.
    setTurnWarnings([]);
    setLastTurnTokens(null);
    setSessionTokens(loadSessionTokens(nextID));
  }

  function handleSelectSession(id: string) {
    if (normalizeSessionID(id) === normalizeSessionID(sessionID)) return;
    if (pending) {
      void handleCancel();
    }
    knownDraftIDRef.current = null;
    setSessionID(id);
    setInFlightTurn(null);
    setError(null);
    setTurnWarnings([]);
    setLastTurnTokens(null);
    setSessionTokens(loadSessionTokens(id));
  }

  const usedPercent =
    contextLimit > 0
      ? Math.round((sessionTokens / contextLimit) * 100)
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
                onDecide={(id, approved, duration) =>
                  void handleDecideApproval(id, approved, duration)
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
              placeholder="Message Rune Weaver… (Shift+Return for newline)"
              value={input}
              onChange={handleInputChange}
              onKeyDown={handleKeyDown}
              disabled={pending}
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              data-lpignore="true"
              data-1p-ignore="true"
              data-form-type="other"
            />
            {pending ? (
              <button
                type="button"
                className="chat-cancel-btn"
                onClick={() => void handleCancel()}
                aria-label="Cancel turn"
              >
                Cancel
              </button>
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
              <span className="status-bar-label">Session:</span>
              <span
                className={`status-bar-value ${
                  usedPercent > 100 ? "status-warning" : ""
                }`}
              >
                {sessionTokens.toLocaleString()} /{" "}
                {contextLimit.toLocaleString()} tokens ({usedPercent}%)
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
