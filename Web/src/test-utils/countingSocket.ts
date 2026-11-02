// Rune Weaver Dashboard — Shared counting WebSocket stub for chat lifecycle tests.

import {
  createMockWebSocket,
  createMockWebSocketCapture,
} from "./mockWebSocket";

// Builds a stub WebSocket that records every instance, so tests asserting
// reconnect, settle, and reload behavior share one socket factory.
export function makeCountingSocket() {
  const capture = createMockWebSocketCapture();
  const BaseSocket = createMockWebSocket(capture) as unknown as new (url?: string) => WebSocket;
  const instances: WebSocket[] = [];
  class CountingSocket extends BaseSocket {
    constructor(url?: string) { super(url); instances.push(this); }
  }
  return { capture, instances, CountingSocket };
}
