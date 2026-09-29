// Rune Weaver Dashboard — Tests for the proactive goal-notification path.
//
// Pins the contract that a `proactive_message` goal nudge always raises the
// goals attention badge while the native Web Notification is best-effort: it
// fires exactly once when permission is granted and is skipped entirely when
// permission is not, leaving the visual signal intact either way. Frames travel
// through the real shared socket singleton so the test exercises the same
// message path a mounted dashboard uses.

import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useWebNotifications } from "./useWebNotifications";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

// Minimal Notification double that records every construction and lets each
// case pin the permission the hook observes at mount.
class MockNotification {
  static permission: NotificationPermission = "granted";
  static instances: MockNotification[] = [];

  title: string;
  options?: NotificationOptions;

  constructor(title: string, options?: NotificationOptions) {
    this.title = title;
    this.options = options;
    MockNotification.instances.push(this);
  }
}

async function mountWithSocket() {
  const capture = createMockWebSocketCapture();
  vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  const hook = renderHook(() => useWebNotifications());
  await waitFor(() => {
    expect(capture.onMessage).not.toBeNull();
  });
  return { hook, capture };
}

describe("useWebNotifications goals attention", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    MockNotification.permission = "granted";
    MockNotification.instances = [];
    vi.stubGlobal("Notification", MockNotification);
  });

  it("fires exactly one notification and bumps the badge when permission is granted", async () => {
    const { hook, capture } = await mountWithSocket();
    expect(hook.result.current.goalsAttention).toBe(0);

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "goalNeedsInput",
      title: "field guide",
      headline: "Waiting on your input",
    });

    await waitFor(() => {
      expect(hook.result.current.goalsAttention).toBe(1);
    });
    expect(MockNotification.instances).toHaveLength(1);
    expect(MockNotification.instances[0].title).toBe("Rune Weaver: field guide");
    expect(MockNotification.instances[0].options?.body).toBe(
      "Waiting on your input",
    );

    // The badge clears on navigation acknowledgment without touching server
    // state, mirroring the runs clear-on-open contract.
    act(() => {
      hook.result.current.clearGoalsAttention();
    });
    expect(hook.result.current.goalsAttention).toBe(0);
  });

  it("bumps the badge without notifying when permission is not granted", async () => {
    MockNotification.permission = "denied";
    const { hook, capture } = await mountWithSocket();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "goalNeedsInput",
      title: "field guide",
      headline: "Waiting on your input",
    });

    await waitFor(() => {
      expect(hook.result.current.goalsAttention).toBe(1);
    });
    expect(MockNotification.instances).toHaveLength(0);
  });

  it("bumps the goals badge when a proactive idea is proposed", async () => {
    const { hook, capture } = await mountWithSocket();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "idea_proposed",
      title: "Try a shorter loop",
      headline: "Run 2km instead of 5km.",
    });

    // Ideas ride the same proactive frame as parked goals, so the shared
    // attention badge rises without a second transport.
    await waitFor(() => {
      expect(hook.result.current.goalsAttention).toBe(1);
    });
    expect(MockNotification.instances).toHaveLength(1);
    expect(MockNotification.instances[0].title).toBe(
      "Rune Weaver: Try a shorter loop",
    );
  });

  it("ignores proactive messages that are not goal needs-input nudges", async () => {
    const { hook, capture } = await mountWithSocket();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "schedulerError",
      title: "nightly digest",
      headline: "The run failed",
    });

    expect(hook.result.current.goalsAttention).toBe(0);
    expect(MockNotification.instances).toHaveLength(0);
  });
});
