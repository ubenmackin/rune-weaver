// Shared WebSocket client connecting to /ws with multi-subscriber support.
// Keeps a single persistent connection across the entire dashboard to avoid duplicate connections.

import { useEffect, useRef } from "react";
import type { PermissionRequest, ToolAction, ToolResult } from "../api";
import { isApprovalFrame, isRecord } from "../approvalsSession";

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
}

export interface WSToolEndFrame {
  type: "tool_end";
  toolName: string;
  callID: string;
  result: ToolResult;
  sessionID?: string;
}

export interface WSStreamDone {
  type: "done";
  // Terminal text may be omitted when streamed deltas already delivered the
  // reply; views fall back to the accumulated snapshot instead of dropping
  // the turn, so the field stays optional for back-compat.
  text?: string;
  sessionID: string;
  toolActions?: ToolAction[];
  totalTokens?: number;
  modelName?: string;
  contextLength?: number;
  sessionTokens?: number;
  // Per-turn parked flag mirroring the engine terminal frame: true when the
  // turn filed gated approvals and waits on the inbox, absent on older
  // engines where it defaults to not parked.
  isParked?: boolean;
}

export interface WSCancelledFrame {
  type: "cancelled";
  sessionID?: string;
  // True when a running turn was aborted; false for idle cancels that
  // left no pending mark. Optional for back-compat with older engines.
  cancelled?: boolean;
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
  | WSApprovalFrame;

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
      return (
        (value.text === undefined || typeof value.text === "string") &&
        typeof value.sessionID === "string" &&
        (value.isParked === undefined || typeof value.isParked === "boolean")
      );
    case "cancelled":
      return (
        value.sessionID === undefined || typeof value.sessionID === "string"
      );
    case "error":
      return typeof value.message === "string";
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
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private isConnecting = false;

  public connect() {
    if (typeof window === "undefined" || typeof WebSocket === "undefined") return;
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
        this.ws = null;
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

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.listeners.size > 0) {
        this.connect();
      }
    }, 3000);
  }

  public subscribe(handler: MessageHandler, onClose?: () => void): () => void {
    this.listeners.add(handler);
    if (onClose) {
      this.closeListeners.add(onClose);
    }
    // A new subscriber arriving while the socket is closing must not wait
    // for the stale 3s reconnect: reconnect immediately so it joins live.
    if (
      !this.ws ||
      this.ws.readyState === WebSocket.CLOSED ||
      this.ws.readyState === WebSocket.CLOSING
    ) {
      this.connect();
    }
    return () => {
      this.listeners.delete(handler);
      if (onClose) {
        this.closeListeners.delete(onClose);
      }
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

export function useSharedWebSocket(onMessage?: MessageHandler, onClose?: () => void) {
  const handlerRef = useRef<MessageHandler | undefined>(onMessage);
  const closeRef = useRef<(() => void) | undefined>(onClose);

  // Keep refs behind effects so render stays pure; the subscription below
  // always reads the latest callbacks without mutating during render.
  useEffect(() => {
    handlerRef.current = onMessage;
  }, [onMessage]);

  useEffect(() => {
    closeRef.current = onClose;
  }, [onClose]);

  // Always subscribe through ref indirection: a mount with no handler yet
  // still registers a listener (keeping reconnects alive), and a later
  // handler attaches without resubscribing.
  useEffect(() => {
    const listener: MessageHandler = (data) => {
      handlerRef.current?.(data);
    };
    const closeListener = () => {
      closeRef.current?.();
    };
    const unsubscribe = sharedWebSocket.subscribe(listener, closeListener);
    return unsubscribe;
  }, []);

  return {
    sendMessage: (payload: unknown) => sharedWebSocket.send(payload),
    isOpen: () => sharedWebSocket.isOpen(),
  };
}
