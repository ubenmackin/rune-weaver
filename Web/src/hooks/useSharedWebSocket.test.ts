// Rune Weaver Dashboard — Direct tests for the shared WebSocket client's
// `tool_progress` inbound guard.
//
// Every live view multiplexes over one `/ws` connection, so a malformed or
// drifted frame must be dropped at the hub before it reaches typed view
// handlers; otherwise a partial payload could render a zeroed or
// mis-attributed progress line. These tests drive the real singleton through a
// stubbed socket so the guard's counter and owner-tag checks are exercised on
// the actual message path rather than through a pre-sanitized object.

import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  resetSharedSocket,
  useSharedWebSocket,
} from "./useSharedWebSocket";
import type { WSIncomingFrame } from "./useSharedWebSocket";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";
import { clearAuthToken, setAuthToken } from "../api";

// Minimal valid frame reused across cases; each test overrides only the field
// under scrutiny so a failure isolates one guard condition.
const validFrame = {
  type: "tool_progress",
  callID: "call-1",
  toolName: "files.glob",
  message: "Find *.txt in ~",
  scanned: 42,
  matched: 3,
  elapsedMs: 4200,
  current: "Documents/notes.txt",
  sessionID: "s1",
};

// Mounts the shared-client hook against a fresh stub and returns the capture
// plus the frames the subscriber actually received, so each test reads the
// post-guard stream instead of the raw socket.
async function mountSharedSocket(): Promise<{
  capture: ReturnType<typeof createMockWebSocketCapture>;
  received: WSIncomingFrame[];
}> {
  const capture = createMockWebSocketCapture();
  vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  const received: WSIncomingFrame[] = [];
  renderHook(() => useSharedWebSocket((frame) => received.push(frame)));
  await waitFor(() => expect(capture.onMessage).not.toBeNull());
  return { capture, received };
}

// Builds a stub socket class that records every dialed instance alongside its
// capture, so retry tests can count redials on the real singleton path
// instead of asserting on timers.
function makeCountingSocket(): {
  capture: ReturnType<typeof createMockWebSocketCapture>;
  instances: WebSocket[];
  CountingSocket: new (url?: string) => WebSocket;
} {
  const capture = createMockWebSocketCapture();
  const BaseSocket = createMockWebSocket(capture) as unknown as new (
    url?: string,
  ) => WebSocket;
  const instances: WebSocket[] = [];
  class CountingSocket extends BaseSocket {
    constructor(url?: string) {
      super(url);
      instances.push(this);
    }
  }
  return { capture, instances, CountingSocket };
}

describe("shared WebSocket tool_progress guard", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("connects directly to /ws without exposing token in query parameters", async () => {
    setAuthToken("secret-token-123");
    const { capture } = await mountSharedSocket();
    expect(capture.url).toBe("ws://localhost:3000/ws");
    expect(capture.url).not.toContain("?token=");
    clearAuthToken();
  });

  it("forwards a well-formed frame, including its optional warning", async () => {
    const { capture, received } = await mountSharedSocket();
    await dispatchFrameOrThrow(capture.onMessage, {
      ...validFrame,
      warning: "entire home folder",
    });
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({
      type: "tool_progress",
      callID: "call-1",
      warning: "entire home folder",
    });
  });

  it("drops a frame missing a required counter", async () => {
    const { capture, received } = await mountSharedSocket();
    // `matched` is required so a partial payload never renders a zeroed tally.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "call-1",
      toolName: "files.glob",
      message: "Find *.txt in ~",
      scanned: 42,
      elapsedMs: 4200,
    });
    expect(received).toHaveLength(0);
  });

  it("drops a frame whose counter is negative or fractional", async () => {
    const { capture, received } = await mountSharedSocket();
    await dispatchFrameOrThrow(capture.onMessage, {
      ...validFrame,
      scanned: -1,
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      ...validFrame,
      matched: 1.5,
    });
    expect(received).toHaveLength(0);
  });

  it("drops a frame with a non-string session tag", async () => {
    const { capture, received } = await mountSharedSocket();
    await dispatchFrameOrThrow(capture.onMessage, {
      ...validFrame,
      sessionID: 7,
    });
    expect(received).toHaveLength(0);
  });

  it("drops a frame with blank or missing identity", async () => {
    const { capture, received } = await mountSharedSocket();
    await dispatchFrameOrThrow(capture.onMessage, { ...validFrame, callID: "  " });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      toolName: "files.glob",
      message: "Find *.txt in ~",
      scanned: 1,
      matched: 1,
      elapsedMs: 1,
    });
    expect(received).toHaveLength(0);
  });

  it("keeps a valid frame when the optional warning is absent or drifted", async () => {
    const { capture, received } = await mountSharedSocket();
    await dispatchFrameOrThrow(capture.onMessage, validFrame);
    // A non-string warning is optional, so it degrades to absent rather than
    // dropping an otherwise complete progress line.
    await dispatchFrameOrThrow(capture.onMessage, { ...validFrame, warning: 7 });
    expect(received).toHaveLength(2);
  });

  it("redials immediately when retryConnection is called after a close", async () => {
    // A user-triggered retry must bypass the idle backoff so a visible retry
    // affordance rejoins live without waiting out the scheduled timer.
    const { capture, instances, CountingSocket } = makeCountingSocket();
    vi.stubGlobal("WebSocket", CountingSocket);
    const { result, unmount } = renderHook(() =>
      useSharedWebSocket(() => {}),
    );
    await waitFor(() => expect(instances.length).toBe(1));
    await act(async () => {
      instances[0].close();
    });
    const dialedBeforeRetry = instances.length;
    await act(async () => {
      result.current.retryConnection();
    });
    expect(instances.length).toBe(dialedBeforeRetry + 1);
    expect(capture.url).toBe("ws://localhost:3000/ws");
    unmount();
  });

  it("reports isOpen false after close and true after open", async () => {
    // Views derive their reconnecting notice from the shared open probe, so the
    // probe must track the live handle across a drop and the forced redial.
    const { instances, CountingSocket } = makeCountingSocket();
    vi.stubGlobal("WebSocket", CountingSocket);
    const { result, unmount } = renderHook(() =>
      useSharedWebSocket(() => {}),
    );
    await waitFor(() => expect(result.current.isOpen()).toBe(true));
    await act(async () => {
      instances[0].close();
    });
    expect(result.current.isOpen()).toBe(false);
    await act(async () => {
      result.current.retryConnection();
    });
    await waitFor(() => expect(result.current.isOpen()).toBe(true));
    unmount();
  });
});
