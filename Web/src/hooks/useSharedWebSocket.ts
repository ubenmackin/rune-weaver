// Shared WebSocket client connecting to /ws with multi-subscriber support.
// Keeps a single persistent connection across the entire dashboard to avoid duplicate connections.

import { useCallback, useEffect, useMemo, useRef } from "react";
import {
  isValidToolIDs,
  parseToolProgress,
  subscribeAuthState,
  toNonNegativeInt,
} from "../api";
import type { Goal, PermissionRequest, ToolAction, ToolResult } from "../api";
import { isApprovalFrame, isRecord } from "../approvalsSession";
import { sanitizeWarnings } from "../warnings";

// Typed inbound frames mirroring the engine wire shapes so dashboard views narrow a parsed payload
// with a typed union.
export interface WSStreamDelta {
  type: "delta";
  delta: string;
  sessionID?: string;
}

export interface WSStreamReasoningDelta {
  type: "reasoning_delta";
  delta: string;
  sessionID?: string;
}

export interface WSToolStartFrame {
  type: "tool_start";
  toolName: string;
  callID: string;
  argumentsJSON: string;
  sessionID?: string;
  // Zero-based LLM round that produced this call, oldest first. Mirrors the
  // engine frame so live timelines interleave like history reloads; absent on
  // older engines where live ordering falls back to arrival order.
  roundIndex?: number;
}

export interface WSToolEndFrame {
  type: "tool_end";
  toolName: string;
  callID: string;
  result: ToolResult;
  sessionID?: string;
  // Chronological round mirroring the start frame so resumed batches rejoin
  // the same timeline instead of collapsing; absent on older engines.
  roundIndex?: number;
}

export interface WSStreamDone {
  type: "done";
  // Terminal text may be omitted when streamed deltas already delivered the
  // reply; views fall back to the accumulated snapshot instead of dropping
  // the turn, so the field stays optional for back-compat.
  text?: string;
  sessionID: string;
  toolActions?: ToolAction[];
  // Highest round index in this turn, when any tool ran. Mirrors the engine
  // terminal frame so clients learn the round count without scanning actions;
  // absent on older engines or text-only turns.
  roundIndex?: number;
  totalTokens?: number;
  modelName?: string;
  contextLength?: number;
  sessionTokens?: number;
  // Active context window tokens used in the latest round (KV cache occupancy).
  contextTokens?: number;
  // Per-turn parked flag mirroring the engine terminal frame: true when the
  // turn filed gated approvals and waits on the inbox, absent on older
  // engines where it defaults to not parked.
  isParked?: boolean;
  // Degraded-tool notices repeated from the terminal response so polling
  // clients agree with streaming ones. Absent on older engines where the
  // turn renders without a banner.
  warnings?: string[];
  // Completion time on the server clock for this turn. Optional because older
  // engines predate completion footers; absent renders no footer so live cards
  // agree with history reloads that derive the same instant from persistence.
  completedAt?: string | number | null;
  // Late steering still queued server-side at completion. Mirrors the engine
  // terminal frame so the view keeps exactly that many newest bubbles for the
  // next turn and releases the consumed ones answered here; absent on older
  // engines where the view clears consumed tracking as answered.
  retainedSteerCount?: number;
}

export interface WSCancelledFrame {
  type: "cancelled";
  sessionID?: string;
  // True when a running turn was aborted; false for idle cancels that
  // left no pending mark. Optional for back-compat with older engines.
  cancelled?: boolean;
}

// Mid-turn degraded-tool notice: the engine streams one frame per skipped
// tool so chat can surface the skip live, then repeats the lines on the
// terminal done frame for polling clients. Informational only, never fatal.
export interface WSWarningFrame {
  type: "warning";
  message: string;
  sessionID?: string;
}

// Session-tagged liveness heartbeat proving the engine is still processing a
// turn while prompt evaluation emits no deltas to render. Views re-arm their
// inactivity timer on it without touching message state; older dashboards that
// do not know this type drop it as an unknown frame. TypeScript mirror of
// RuneWeaverCore.WSTurnAliveFrame (Sources/RuneWeaverCore/WSWire.swift);
// update both sides together so the wire shape never drifts.
export interface WSTurnAliveFrame {
  type: "turn_alive";
  sessionID?: string;
}

// Per-round token usage progress for the in-flight turn. The engine emits one
// frame after each LLM round that reports usage so the footer shows a running
// turn total and a live session estimate without waiting for done, which stays
// authoritative for reconciliation. Session-tagged like the heartbeat so
// multiplexed views only apply their own turn and older dashboards drop the
// unknown type. Counters stay required like the engine frame so a partial
// payload never renders as a zeroed sum. TypeScript mirror of
// RuneWeaverCore.WSTurnTokensFrame (Sources/RuneWeaverCore/WSWire.swift);
// update both sides together.
export interface WSTurnTokensFrame {
  type: "turn_tokens";
  sessionID?: string;
  // Zero-based LLM round that produced this usage, oldest first.
  roundIndex: number;
  // Billed tokens for this round alone.
  roundTokens: number;
  // Cumulative billed tokens for this turn so far.
  turnTotalTokens: number;
  // Estimated context-window occupancy at this round. Optional so older
  // engines that omit it still decode; dashboards keep prior value when absent.
  contextTokens?: number;
}

// Live per-tool progress for one executing call. The engine throttles these
// (~2 Hz) and tags them with the owning session so multiplexed views only apply
// their own turn; `current` is relative-only and optional. Counters stay
// required so a partial payload drops rather than rendering a zeroed tally.
// TypeScript mirror of the engine's `tool_progress` frame; update both sides
// together so the wire shape never drifts.
export interface WSToolProgressFrame {
  type: "tool_progress";
  callID: string;
  toolName: string;
  message: string;
  // Advisory broad-scope warning for `message`, when the engine supplies one.
  // Optional so older frames and narrow scans decode without a warning.
  warning?: string | null;
  scanned: number;
  matched: number;
  elapsedMs: number;
  current?: string | null;
  sessionID?: string;
}

export interface WSErrorFrame {
  type: "error";
  message: string;
  sessionID?: string;
}

// Non-terminal acknowledgement that a per-tool cancel found nothing to stop.
// The engine emits this instead of `error` because the view treats an owned
// `error` as a terminal turn failure; a miss must only clear the row's
// optimistic cancel mark. `callID` stays required so a partial frame can never
// clear an unrelated row. TypeScript mirror of the engine's `tool_cancel_miss`
// frame; update both sides together so the wire shape never drifts.
export interface WSToolCancelMissFrame {
  type: "tool_cancel_miss";
  callID: string;
  // Optional human-readable, non-terminal note for the miss.
  message?: string | null;
  sessionID?: string;
}

// Global goal-change broadcast emitted on create, plan-ready, step progress,
// status flips, and advancement turns so dashboards patch one row instead of
// refetching the list. The snapshot rides whole because the push is the
// refresh. Untagged rather than session-scoped: a goal outlives any single
// turn, so only the goal identity routes it. TypeScript mirror of
// RuneWeaverCore.WSGoalUpdatedFrame; update both sides together.
export interface WSGoalUpdatedFrame {
  type: "goal_updated";
  goal: Goal;
}

// Owner-visible nudge the engine volunteers outside any turn (a due goal, a
// parked wait). `kind` names the trigger family while `title` plus `headline`
// carry the one-line card; the optional session and goal links let a card
// deep-link without a second lookup. TypeScript mirror of
// RuneWeaverCore.WSProactiveMessageFrame; update both sides together.
export interface WSProactiveMessageFrame {
  type: "proactive_message";
  kind: string;
  title: string;
  headline: string;
  sessionID?: string;
  goalId?: string;
}

export interface WSApprovalFrame {
  type: "approval";
  request: PermissionRequest;
}

export interface WSFileAcceptedFrame {
  type: "file_accepted";
  path?: string;
  sessionID?: string;
}

export interface WSFileDiscardedFrame {
  type: "file_discarded";
  path?: string;
  sessionID?: string;
}

// Terminal broadcast for one resolved live write review. The optional state
// names which branch ran so a card reconciles without re-reading the ledger:
// `accepted` keeps the write, `reverted` restores the rollback copy, and
// `discarded` removes a newly created file. TypeScript mirror of the engine
// `live_resolved` frame (WSFileActionEvent); update both sides together so the
// wire shape never drifts.
export interface WSLiveResolvedFrame {
  type: "live_resolved";
  path?: string;
  state?: "accepted" | "reverted" | "discarded";
}

// Terminal broadcast for one pending staged write review that a live write
// superseded. A superseding live write resolves the staged ledger row inside
// the write tool rather than a route, so the frame carries the canonical live
// path plus the staged row's terminal state. TypeScript mirror of the engine
// `file_superseded` frame (WSFileActionEvent); update both sides together so
// the wire shape never drifts.
export interface WSFileSupersededFrame {
  type: "file_superseded";
  path?: string;
  state?: "superseded";
}

export interface WSRunFrame {
  type: "run_started" | "run_completed";
  run?: unknown;
  sessionID?: string;
}

export interface WSApprovalLifecycleFrame {
  type:
    | "approval_decided"
    | "approval_resolved"
    | "approval_removed"
    | "approval_deleted"
    | "approval_completed"
    | "approval_cancelled";
  sessionID?: string;
  id?: string;
  approvalID?: string;
  approvalId?: string;
  request?: unknown;
  approval?: unknown;
  approved?: boolean;
}

export interface WSGenericFrame {
  type: string;
  sessionID?: string;
  [key: string]: unknown;
}

// Kept outside the discriminated union on purpose: an index-signature member
// would overlap every literal `type` and break narrowing, so unknown event
// shapes are handled via an explicit `WSGenericFrame` cast instead.
export type WSIncomingFrame =
  | WSStreamDelta
  | WSStreamReasoningDelta
  | WSToolStartFrame
  | WSToolEndFrame
  | WSStreamDone
  | WSCancelledFrame
  | WSErrorFrame
  | WSWarningFrame
  | WSApprovalFrame
  | WSTurnAliveFrame
  | WSTurnTokensFrame
  | WSToolProgressFrame
  | WSToolCancelMissFrame
  | WSGoalUpdatedFrame
  | WSProactiveMessageFrame
  | WSRunFrame
  | WSApprovalLifecycleFrame
  | WSFileAcceptedFrame
  | WSFileDiscardedFrame
  | WSLiveResolvedFrame
  | WSFileSupersededFrame;

export type MessageHandler = (data: WSIncomingFrame) => void;

// Index runs may omit the tool name on older engines, so a progress frame
// with a blank or missing tool name still passes when its message and
// counters are otherwise valid. The index panel adopts such frames during any
// run in flight, while chat keeps dropping them at its own parser.
function isIndexProgressWithoutToolName(value: Record<string, unknown>): boolean {
  if (!(value.sessionID === undefined || typeof value.sessionID === "string")) {
    return false;
  }
  const rawToolName: unknown = value.toolName;
  const omitted =
    rawToolName === undefined ||
    rawToolName === null ||
    (typeof rawToolName === "string" && rawToolName.trim().length === 0);
  if (!omitted) return false;
  if (typeof value.message !== "string") return false;
  if (toNonNegativeInt(value.scanned) === undefined) return false;
  if (toNonNegativeInt(value.matched) === undefined) return false;
  if (toNonNegativeInt(value.elapsedMs) === undefined) return false;
  if (typeof value.callID !== "string" || value.callID.trim().length === 0) {
    return false;
  }
  const rawCurrent: unknown = value.current;
  if (rawCurrent !== undefined && rawCurrent !== null && typeof rawCurrent !== "string") {
    return false;
  }
  // The tail is only type-checked here; the panel re-sanitizes it separately
  // before display, so a handcrafted absolute or traversal tail never renders
  // as a filesystem path.
  return true;
}

// Validates an inbound payload before it reaches typed handlers so malformed engine frames never
// enter view state.
function isWSIncomingFrame(value: unknown): value is WSIncomingFrame {
  if (!isRecord(value)) return false;
  if (typeof value.type !== "string") return false;
  switch (value.type) {
    case "delta":
    case "reasoning_delta":
      return typeof value.delta === "string";
    case "tool_start":
      return (
        isValidToolIDs(value.toolName, value.callID) &&
        typeof value.argumentsJSON === "string"
      );
    case "tool_end":
      return (
        isValidToolIDs(value.toolName, value.callID) &&
        (value.result == null || isRecord(value.result))
      );
    case "done":
      // Text and the parked flag are both optional for back-compat: older engines omit them when
      // streamed deltas already carry the reply or when the turn was never parked, and the view
      // finalizes from its accumulated snapshot while treating a missing flag as not parked.
      // Terminal warnings degrade to absent via the shared sanitizer so a drifted shape never
      // drops an otherwise complete turn.
      if (
        !(value.text === undefined || typeof value.text === "string") ||
        typeof value.sessionID !== "string" ||
        !(value.isParked === undefined || typeof value.isParked === "boolean")
      ) {
        return false;
      }
      // Probe the shared sanitizer so done-frame validation never drifts from the banner path.
      sanitizeWarnings(value.warnings);
      return true;
    case "cancelled":
      return (
        value.sessionID === undefined || typeof value.sessionID === "string"
      );
    case "error":
      return typeof value.message === "string";
    case "warning":
      // Degraded-tool notices are informational: a preformatted line plus an
      // optional owner, so the guard only requires the line like error frames.
      return typeof value.message === "string";
    case "turn_alive":
      // Liveness heartbeats are session-tagged with no payload to render; the
      // guard only checks the owner so malformed tags drop before re-arming.
      return (
        value.sessionID === undefined || typeof value.sessionID === "string"
      );
    case "tool_progress":
      // Per-tool progress rides the shared non-negative integer contract; the
      // guard reuses the API parser so a drifted shape drops here exactly as it
      // would at the keyed-map writer instead of validating twice.
      if (
        (value.sessionID === undefined ||
          typeof value.sessionID === "string") &&
        parseToolProgress(value) !== null
      ) {
        return true;
      }
      return isIndexProgressWithoutToolName(value);
    case "tool_cancel_miss":
      // A miss carries the call to clear and an optional non-terminal note. The
      // call identity stays required so a partial frame never clears the wrong
      // row, matching the engine decoder which throws on a missing key.
      return (
        (value.sessionID === undefined ||
          typeof value.sessionID === "string") &&
        typeof value.callID === "string" &&
        value.callID.trim().length > 0 &&
        (value.message === undefined ||
          value.message === null ||
          typeof value.message === "string")
      );
    case "turn_tokens":
      // Token counters are required like the engine frame: a frame missing any
      // counter drops here so dashboards never render a partial sum as zeroed
      // progress, matching the engine decoder which throws on missing keys.
      // Counters stay non-negative integers like the round-index and engine
      // Int contract so a drifted engine cannot smuggle a negative or
      // fractional sum into live footers.
      return (
        (value.sessionID === undefined ||
          typeof value.sessionID === "string") &&
        toNonNegativeInt(value.roundIndex) !== undefined &&
        toNonNegativeInt(value.roundTokens) !== undefined &&
        toNonNegativeInt(value.turnTotalTokens) !== undefined
      );
    case "goal_updated":
      // The snapshot is parsed leniently at the goal handler, but the frame
      // still has to carry a goal object for the union to hold; only the
      // container is checked here so a drifted field degrades downstream.
      return isRecord(value.goal);
    case "proactive_message":
      // Card text stays required like the engine decoder so a partial nudge
      // never surfaces as an empty notification; optional deep-link ids are
      // not type-checked here because handlers tolerate their absence.
      return (
        typeof value.kind === "string" &&
        typeof value.title === "string" &&
        typeof value.headline === "string"
      );
    case "approval":
      return isApprovalFrame(value);
    default:
      return true;
  }
}

class SharedWebSocketClient {
  private ws: WebSocket | null = null;
  private listeners: Set<MessageHandler> = new Set();
  private closeListeners: Set<() => void> = new Set();
  // Open subscribers learn when the socket recovers so views waiting on a
  // dropped connection can clear their reconnecting notice without polling.
  // Kept beside the close set so open/close stay symmetric for every viewer.
  private openListeners: Set<() => void> = new Set();
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private isConnecting = false;
  // Named platform wake handlers so they can be removed on dispose and test
  // reset. Anonymous closures would leak across HMR and test re-runs because
  // removeEventListener would have nothing to match.
  private readonly handleOnline = (): void => {
    this.scheduleReconnect();
  };
  private readonly handleVisibilityChange = (): void => {
    if (
      typeof document !== "undefined" &&
      document.visibilityState === "visible"
    ) {
      this.scheduleReconnect();
    }
  };
  private platformListenersAttached = false;

  constructor() {
    // The socket follows the owner-auth gate: a login or rotation must present
    // the new token at the next upgrade, and a logout or uniform 401 must drop a
    // socket the engine no longer honors. The subscription reports changes only,
    // so construction stays side-effect free.
    subscribeAuthState((authenticated) => {
      this.handleAuthStateChange(authenticated);
    });
    // A laptop that sleeps or drops offline must re-arm the shared dial as soon
    // as connectivity returns, so platform wake signals re-enter the pending
    // backoff instead of waiting for the next poll tick.
    this.attachPlatformListeners();
  }

  // Attaches the online/visibility re-arm exactly once so repeated resets
  // never stack duplicate wake signals. Marks attached only when a listener
  // was actually installed so a render without window/document can still
  // attach later on hydration instead of staying permanently detached.
  private attachPlatformListeners(): void {
    if (this.platformListenersAttached) return;
    let attached = false;
    if (typeof window !== "undefined") {
      window.addEventListener("online", this.handleOnline);
      attached = true;
    }
    if (typeof document !== "undefined") {
      document.addEventListener(
        "visibilitychange",
        this.handleVisibilityChange,
      );
      attached = true;
    }
    if (attached) {
      this.platformListenersAttached = true;
    }
  }

  // Detaches the platform wake signals so HMR disposal and test resets leave
  // no orphaned listeners behind.
  private detachPlatformListeners(): void {
    if (typeof window !== "undefined") {
      window.removeEventListener("online", this.handleOnline);
    }
    if (typeof document !== "undefined") {
      document.removeEventListener(
        "visibilitychange",
        this.handleVisibilityChange,
      );
    }
    this.platformListenersAttached = false;
  }

  // Releases platform wake signals plus any pending reconnect and the cached
  // socket so module replacement leaves no orphaned listeners, timers, or
  // sockets behind. Subscribers stay owned by their mounted views: the next
  // subscribe re-dials on demand, while a stale timer or socket must never
  // outlive the module and dial after replacement.
  public dispose(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    const closing = this.ws;
    this.ws = null;
    this.isConnecting = false;
    if (closing) {
      try {
        closing.close();
      } catch {
        // Teardown is best-effort; a stubbed socket may throw on close.
      }
    }
    this.detachPlatformListeners();
  }

  public connect() {
    if (typeof window === "undefined" || typeof WebSocket === "undefined") return;
    // Never dial for an idle client: a direct connect with no subscribers
    // would resurrect a socket the last unsubscribe just released.
    if (!this.hasSubscribers()) return;
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }
    if (this.isConnecting) return;
    this.isConnecting = true;

    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const host = window.location.host;
    // The browser automatically attaches same-origin cookies (including the HttpOnly rw_session
    // cookie) to the WebSocket upgrade request. We do not place credentials in the URL query string
    // to prevent token exposure in server logs, proxy logs, browser history, and Referer headers.
    const wsUrl = `${protocol}//${host}/ws`;

    try {
      const ws = new WebSocket(wsUrl);
      this.ws = ws;

      ws.onopen = () => {
        this.isConnecting = false;
        if (this.reconnectTimer) {
          clearTimeout(this.reconnectTimer);
          this.reconnectTimer = null;
        }
        // Notify after clearing the timer so a view that just recovered
        // never observes a stale reconnect schedule alongside the open event.
        for (const onOpen of this.openListeners) {
          try {
            onOpen();
          } catch {
            // A failing open listener must not break the rest.
          }
        }
      };

      ws.onmessage = (event) => {
        try {
          // Parse as unknown first so arbitrary payloads stay untyped until
          // the discriminated guard below proves the shape; malformed frames
          // drop at the hub instead of flowing into typed view handlers.
          const parsed: unknown = JSON.parse(event.data);
          if (!isWSIncomingFrame(parsed)) return;
          const data: WSIncomingFrame = parsed;
          for (const listener of this.listeners) {
            listener(data);
          }
        } catch {
          // Ignore non-JSON
        }
      };

      ws.onclose = () => {
        this.isConnecting = false;
        // Only release when the closing handle is still current: an idle close
        // followed by an immediate resubscribe replaces the handle first, and
        // the stale close must not null the fresh socket behind its owner.
        if (this.ws === ws) {
          this.ws = null;
        }
        // Notify subscribers (e.g. a chat view with a turn in flight)
        // before scheduling the reconnect so they can recover.
        for (const onClose of this.closeListeners) {
          try {
            onClose();
          } catch {
            // A failing close listener must not break the rest.
          }
        }
        this.scheduleReconnect();
      };

      ws.onerror = () => {
        this.isConnecting = false;
        ws.close();
      };
    } catch {
      this.isConnecting = false;
      this.scheduleReconnect();
    }
  }

  // Reports whether any view still needs the shared socket. Message, close,
  // and open subscribers all count so a liveness-only viewer keeps the
  // connection while a fully detached dashboard releases it.
  private hasSubscribers(): boolean {
    return (
      this.listeners.size > 0 ||
      this.closeListeners.size > 0 ||
      this.openListeners.size > 0
    );
  }

  // Releases the idle loopback socket once the last subscriber leaves. An
  // unclosed idle socket would pin the connection forever after every view
  // unmounts, so teardown cancels a pending reconnect and closes the handle;
  // the close callback sees no subscribers and schedules nothing further.
  private closeIdleConnection(): void {
    if (this.hasSubscribers()) return;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      try {
        // Closing an OPEN socket fires onclose, which re-checks subscribers
        // before scheduling, so an idle close never resurrects itself. A
        // CONNECTING socket aborts the same way instead of lingering. The
        // reference drops immediately so isOpen flips without waiting for the
        // async close event; the stale onclose is identity-guarded and cannot
        // null a fresh socket dialed by the next subscriber.
        if (
          this.ws.readyState === WebSocket.OPEN ||
          this.ws.readyState === WebSocket.CONNECTING
        ) {
          const closing = this.ws;
          closing.close();
        }
        // CLOSED/CLOSING and unknown states need no close call; dropping the
        // reference lets the next subscriber dial fresh instead of joining a
        // stale close.
        // Single release point for every state above: re-check subscribers
        // after the close because a view may have resubscribed while the
        // close was in flight, and that fresh interest must keep the handle.
        if (!this.hasSubscribers()) {
          this.ws = null;
        }
      } catch {
        // Teardown is best-effort; a stubbed socket may throw on close.
        this.ws = null;
      }
    }
    this.isConnecting = false;
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    // An idle close must stay closed: only a live subscriber justifies the
    // next dial, so an unsubscribed shutdown never re-arms itself here.
    if (!this.hasSubscribers()) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.hasSubscribers()) {
        this.connect();
      }
    }, 3000);
  }

  // Reacts to an authentication transition by releasing a socket the engine
  // would now reject or redialing with a newly adopted credential. A rotation
  // swaps the token while the old socket is still open server-side, so the
  // socket is closed and redialed rather than left running on a stale upgrade.
  private handleAuthStateChange(authenticated: boolean): void {
    if (!authenticated) {
      if (this.reconnectTimer) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = null;
      }
      const closing = this.ws;
      this.ws = null;
      this.isConnecting = false;
      if (closing) {
        try {
          closing.close();
        } catch {
          // Teardown is best-effort; a stubbed socket may throw on close.
        }
      }
      return;
    }
    // A login with no live interest stays idle, matching connect()'s
    // subscriber gate instead of resurrecting a released socket.
    if (!this.hasSubscribers()) return;
    this.reconnectNow();
  }

  // Forces a fresh upgrade so the new token is presented immediately. The old
  // handle is detached before close so its asynchronous onclose cannot clobber
  // the replacement socket. Private forced-redial primitive; views reach it
  // only through the single public retryConnection entry below.
  private reconnectNow(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    const closing = this.ws;
    this.ws = null;
    this.isConnecting = false;
    if (closing) {
      try {
        closing.close();
      } catch {
        // Teardown is best-effort; a stubbed socket may throw on close.
      }
    }
    this.connect();
  }

  // Sole public retry entry for views: delegates to the private forced redial
  // so hook consumers never reach into the reconnect primitive directly and a
  // user gesture dials immediately instead of waiting out the backoff timer.
  public retryConnection(): void {
    this.reconnectNow();
  }

  public subscribe(
    handler?: MessageHandler,
    onClose?: () => void,
    onOpen?: () => void,
  ): () => void {
    // A registration with no callback holds no interest in the socket, so it
    // adds nothing and dials nothing; without this guard a mounted view with
    // no handler yet would pin the loopback connection forever.
    if (handler) {
      this.listeners.add(handler);
    }
    if (onClose) {
      this.closeListeners.add(onClose);
    }
    if (onOpen) {
      this.openListeners.add(onOpen);
    }
    // A new subscriber arriving while the socket is closing must not wait
    // for the stale 3s reconnect: reconnect immediately so it joins live.
    // Idle callers with no callbacks skip the dial so they never resurrect a
    // released socket.
    if (this.hasSubscribers()) {
      if (
        !this.ws ||
        this.ws.readyState === WebSocket.CLOSED ||
        this.ws.readyState === WebSocket.CLOSING
      ) {
        this.connect();
      }
    }
    return () => {
      if (handler) {
        this.listeners.delete(handler);
      }
      if (onClose) {
        this.closeListeners.delete(onClose);
      }
      if (onOpen) {
        this.openListeners.delete(onOpen);
      }
      // The last unsubscribe releases the loopback handle instead of leaving
      // an idle OPEN socket pinned after every view unmounts.
      this.closeIdleConnection();
    };
  }

  public send(payload: unknown): boolean {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(typeof payload === "string" ? payload : JSON.stringify(payload));
      return true;
    }
    return false;
  }

  public isOpen(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  // Test-only reset that clears subscribers and drops the cached socket so suites start from a
  // detached singleton without reaching into privates. Gated to the test bundle so production never
  // tears down the shared connection; outside tests this is a no-op.
  public resetForTesting(): void {
    // Guard test-only surface: production must never reset the shared socket.
    if (import.meta.env.MODE !== "test") return;
    this.listeners.clear();
    this.closeListeners.clear();
    this.openListeners.clear();
    try {
      this.ws?.close?.();
    } catch {
      // Teardown is best-effort; a stubbed socket may throw on close.
    }
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws = null;
    this.isConnecting = false;
    // Clear the platform wake signals so repeated resets never stack
    // duplicates across HMR and test re-runs, then re-arm exactly one copy
    // so online/visible redial keeps working after the reset.
    this.detachPlatformListeners();
    this.attachPlatformListeners();
  }
}

export const sharedWebSocket = new SharedWebSocketClient();

// Test-only reset owned by the shared client module so suites detach the
// singleton without casting into its private fields. Gated to the test
// bundle so production callers hit the early return with no side effects.
export function resetSharedSocket(): void {
  if (import.meta.env.MODE !== "test") return;
  sharedWebSocket.resetForTesting();
}

export function useSharedWebSocket(onMessage?: MessageHandler, onClose?: () => void, onOpen?: () => void) {
  const handlerRef = useRef<MessageHandler | undefined>(onMessage);
  const closeRef = useRef<(() => void) | undefined>(onClose);
  const openRef = useRef<(() => void) | undefined>(onOpen);

  // Keep refs behind effects so render stays pure; the subscription below
  // always reads the latest callbacks without mutating during render.
  useEffect(() => {
    handlerRef.current = onMessage;
  }, [onMessage]);

  useEffect(() => {
    closeRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    openRef.current = onOpen;
  }, [onOpen]);

  // Subscribes only the callbacks the caller actually wants so a mounted view
  // with no handler holds no socket interest and never pins an idle loopback
  // connection. Presence (not identity) drives resubscription: ref indirection
  // keeps forwarding the latest callbacks without churning the shared socket,
  // while a handler that arrives after mount still dials instead of waiting
  // for a stale reconnect. Unmount releases the last hold via the client's
  // idle close instead of leaving an OPEN socket behind.
  const wantsMessage = onMessage != null;
  const wantsClose = onClose != null;
  const wantsOpen = onOpen != null;
  useEffect(() => {
    if (!wantsMessage && !wantsClose && !wantsOpen) return;
    const listener: MessageHandler = (data) => {
      handlerRef.current?.(data);
    };
    const closeListener = () => {
      closeRef.current?.();
    };
    const openListener = () => {
      openRef.current?.();
    };
    const unsubscribe = sharedWebSocket.subscribe(
      wantsMessage ? listener : undefined,
      wantsClose ? closeListener : undefined,
      wantsOpen ? openListener : undefined,
    );
    return unsubscribe;
  }, [wantsMessage, wantsClose, wantsOpen]);

  // Memoized against the singleton so hook consumers see stable identities
  // across renders; fresh closures here would churn isOpen/retryConnection
  // and re-trigger poll and reconnect effects every render.
  const sendMessage = useCallback(
    (payload: unknown) => sharedWebSocket.send(payload),
    [],
  );
  const isOpen = useCallback(() => sharedWebSocket.isOpen(), []);
  const retryConnection = useCallback(
    () => sharedWebSocket.retryConnection(),
    [],
  );

  return useMemo(
    () => ({ sendMessage, isOpen, retryConnection }),
    [sendMessage, isOpen, retryConnection],
  );
}
