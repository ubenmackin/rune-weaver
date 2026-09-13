// Shared WebSocket client connecting to /ws with multi-subscriber support.
// Keeps a single persistent connection across the entire dashboard to avoid duplicate connections.

import { useEffect, useRef } from "react";
import type { PermissionRequest, ToolAction, ToolResult } from "../api";

// Typed inbound frames mirroring the engine wire shapes so dashboard views
// narrow a parsed payload with a typed union. The generic member keeps
// forward-compatible event types (run lifecycle) typed while run and request
// nests stay explicit per view.
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
  text: string;
  sessionID: string;
  toolActions?: ToolAction[];
  totalTokens?: number;
  modelName?: string;
  contextLength?: number;
  sessionTokens?: number;
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

export type WSIncomingFrame =
  | WSStreamDelta
  | WSToolStartFrame
  | WSToolEndFrame
  | WSStreamDone
  | WSCancelledFrame
  | WSErrorFrame
  | WSApprovalFrame
  | WSGenericFrame;

export type MessageHandler = (data: WSIncomingFrame) => void;

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
          const data = JSON.parse(event.data) as unknown as WSIncomingFrame;
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
    if (!this.ws || this.ws.readyState === WebSocket.CLOSED) {
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
}

export const sharedWebSocket = new SharedWebSocketClient();

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
