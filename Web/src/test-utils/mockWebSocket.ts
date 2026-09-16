// Rune Weaver Dashboard — Shared WebSocket stub and frame dispatch helpers.

import { act } from "@testing-library/react";
import { resetSharedSocket as resetProdSharedSocket } from "../hooks/useSharedWebSocket";

// Mutable capture shared between the stubbed socket and the test body: the
// stub records its message handler and outbound frames here for assertions
// and frame injection.
export interface MockWebSocketCapture {
  onMessage: ((e: MessageEvent) => void) | null;
  sentFrames: string[];
}

// Creates a fresh capture so each test owns its handler slot and outbound
// frames instead of sharing module state across suites.
export function createMockWebSocketCapture(): MockWebSocketCapture {
  return { onMessage: null, sentFrames: [] };
}

// Builds the stub WebSocket class bound to one capture. The constructor attaches asynchronously to
// mirror real connection timing, and send/close mirror the minimal surface the shared client probes
// (readyState, onopen, onclose, onmessage).
export function createMockWebSocket(capture: MockWebSocketCapture): new () => unknown {
  return class MockWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;
    readyState = 1;
    onopen: (() => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onmessage: ((e: MessageEvent) => void) | null = null;

    constructor() {
      setTimeout(() => {
        capture.onMessage = this.onmessage;
        this.onopen?.();
      }, 5);
    }

    send(data: string): void {
      capture.sentFrames.push(data);
    }

    close(): void {
      this.onclose?.();
    }
  };
}

// Dispatches one inbound frame through a nullable handler, throwing when the
// socket never attached instead of force-invoking a null handler. Payloads
// are encoded here so call sites pass plain objects without casting events.
export async function dispatchFrameOrThrow(
  handler: ((e: MessageEvent) => void) | null,
  payload: unknown,
): Promise<void> {
  if (handler === null) {
    throw new Error("Expected WebSocket message handler to be attached");
  }
  const frameHandler: (e: MessageEvent) => void = handler;
  await act(async () => {
    frameHandler({ data: JSON.stringify(payload) } as MessageEvent);
  });
}

// Canonical test-only reset location so suites detach the shared singleton through test utilities
// instead of importing test hooks from the production bundle directly. Delegates to the gated
// shared-client reset, which no-ops outside the test bundle.
export function resetSharedSocket(): void {
  resetProdSharedSocket();
}
