// Shared WebSocket client connecting to /ws with multi-subscriber support.
// Keeps a single persistent connection across the entire dashboard to avoid duplicate connections.

import { useEffect, useRef } from "react";
import type { PermissionRequest, ToolAction, ToolResult } from "../api";
import { isApprovalFrame, isRecord } from "../approvalsSession";
import { sanitizeWarnings } from "../warnings";

// Typed inbound frames mirroring the engine wire shapes so dashboard views narrow a parsed payload
// with a typed union.
export interface WSStreamDelta {
  type: "delta";
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
}

export interface WSErrorFrame {
  type: "error";
  message: string;
  sessionID?: string;
}

export interface WSApprovalFrame {
  type: "approval";
  request: PermissionRequest;
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
  | WSToolStartFrame
  | WSToolEndFrame
  | WSStreamDone
  | WSCancelledFrame
  | WSErrorFrame
  | WSWarningFrame
  | WSApprovalFrame
  | WSTurnAliveFrame
  | WSTurnTokensFrame;

export type MessageHandler = (data: WSIncomingFrame) => void;

// Validates an inbound payload before it reaches typed handlers so malformed engine frames never
// enter view state.
function isWSIncomingFrame(value: unknown): value is WSIncomingFrame {
  if (!isRecord(value)) return false;
  if (typeof value.type !== "string") return false;
  switch (value.type) {
    case "delta":
      return typeof value.delta === "string";
    case "tool_start":
      return (
        typeof value.toolName === "string" &&
        typeof value.callID === "string" &&
        typeof value.argumentsJSON === "string"
      );
    case "tool_end":
      return (
        typeof value.toolName === "string" &&
        typeof value.callID === "string" &&
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
        typeof value.roundIndex === "number" &&
        Number.isInteger(value.roundIndex) &&
        value.roundIndex >= 0 &&
        typeof value.roundTokens === "number" &&
        Number.isFinite(value.roundTokens) &&
        Number.isInteger(value.roundTokens) &&
        value.roundTokens >= 0 &&
        typeof value.turnTotalTokens === "number" &&
        Number.isFinite(value.turnTotalTokens) &&
        Number.isInteger(value.turnTotalTokens) &&
        value.turnTotalTokens >= 0
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

  return {
    sendMessage: (payload: unknown) => sharedWebSocket.send(payload),
    isOpen: () => sharedWebSocket.isOpen(),
  };
}
