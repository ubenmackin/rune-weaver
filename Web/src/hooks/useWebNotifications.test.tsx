// Rune Weaver Dashboard — Tests for silent WebSocket attention badges in useWebNotifications.

import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useWebNotifications } from "./useWebNotifications";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

// Spy Notification constructor verifying zero OS-level browser notifications ever fire.
class MockNotification {
  static permission: NotificationPermission = "granted";
  static instances: MockNotification[] = [];
  static requestPermission = vi.fn(async () => "granted" as NotificationPermission);

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

describe("useWebNotifications silent badge tracking", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    window.localStorage.clear();
    window.location.hash = "#dashboard";
    MockNotification.permission = "granted";
    MockNotification.instances = [];
    MockNotification.requestPermission.mockClear();
    vi.stubGlobal("Notification", MockNotification);
  });

  it("bumps goalsAttention on goalNeedsInput without instantiating browser Notification", async () => {
    const { hook, capture } = await mountWithSocket();
    expect(hook.result.current.goalsAttention).toBe(0);
    expect(hook.result.current.notificationsEnabled).toBe(false);

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

    act(() => {
      hook.result.current.clearGoalsAttention();
    });
    expect(hook.result.current.goalsAttention).toBe(0);
  });

  it("bumps goalsAttention when a proactive idea is proposed without instantiating Notification", async () => {
    const { hook, capture } = await mountWithSocket();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "idea_proposed",
      title: "Try a shorter loop",
      headline: "Run 2km instead of 5km.",
    });

    await waitFor(() => {
      expect(hook.result.current.goalsAttention).toBe(1);
    });
    expect(MockNotification.instances).toHaveLength(0);
  });

  it("ignores proactive messages that are not goalNeedsInput or idea_proposed", async () => {
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

  it("ignores routine ok run_completed frames and never fires browser Notification", async () => {
    const { hook, capture } = await mountWithSocket();

    for (const kind of ["index", "scheduler", "goal", "chat"]) {
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "run_completed",
        run: {
          id: `run-${kind}-1`,
          kind,
          status: "ok",
          message: "Completed",
        },
      });
    }

    expect(hook.result.current.runsBadge).toBe(0);
    expect(MockNotification.instances).toHaveLength(0);
  });

  it("increments runsBadge on error, failed, and budget_exceeded without browser Notification", async () => {
    const { hook, capture } = await mountWithSocket();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: { id: "run-err-1", kind: "scheduler", status: "error", message: "Job failed" },
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: { id: "run-err-2", kind: "index", status: "failed", message: "Indexing crashed" },
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: { id: "run-err-3", kind: "chat", status: "budget_exceeded", message: "Budget exceeded" },
    });

    await waitFor(() => {
      expect(hook.result.current.runsBadge).toBe(3);
    });
    expect(MockNotification.instances).toHaveLength(0);

    act(() => {
      hook.result.current.clearRunsBadge();
    });
    expect(hook.result.current.runsBadge).toBe(0);
  });

  it("deduplicates approval enrichment rebroadcasts and decrements on decision without browser Notification", async () => {
    const { hook, capture } = await mountWithSocket();

    // Initial unenriched filing
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval",
      request: {
        id: "req-1",
        toolName: "bash",
        description: "Run command",
        input: { toolName: "bash", argumentsJSON: "{}", callID: "call-1" },
      },
    });
    // Enrichment rebroadcast with identical filing ID
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval",
      request: {
        id: "req-1",
        toolName: "bash",
        description: "Run command",
        severity: "high",
        input: { toolName: "bash", argumentsJSON: "{}", callID: "call-1" },
      },
    });

    await waitFor(() => {
      expect(hook.result.current.approvalsBadge).toBe(1);
    });
    expect(MockNotification.instances).toHaveLength(0);

    // Resolution frame decrements once even if repeated
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval_decided",
      id: "req-1",
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval_decided",
      id: "req-1",
    });

    await waitFor(() => {
      expect(hook.result.current.approvalsBadge).toBe(0);
    });
    expect(MockNotification.instances).toHaveLength(0);
  });

  it("tracks deduplicated warnings when off-chat without browser Notification", async () => {
    window.localStorage.setItem("rw_active_session_id", "session-1");
    window.location.hash = "#approvals";
    const { hook, capture } = await mountWithSocket();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "warning",
      sessionID: "session-1",
      message: "Sandbox skipped web.fetch",
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "warning",
      sessionID: "session-1",
      message: "Sandbox skipped web.fetch",
    });

    await waitFor(() => {
      expect(hook.result.current.warningsBadge).toBe(1);
    });
    expect(MockNotification.instances).toHaveLength(0);

    act(() => {
      hook.result.current.clearWarningsBadge();
    });
    expect(hook.result.current.warningsBadge).toBe(0);
  });

  it("returns unsupported from deprecated requestPermission shim without prompting browser", async () => {
    const { hook } = await mountWithSocket();
    const result = await hook.result.current.requestPermission();
    expect(result).toBe("unsupported");
    expect(MockNotification.requestPermission).not.toHaveBeenCalled();
  });
});
