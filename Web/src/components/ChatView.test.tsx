// Rune Weaver Dashboard — Component tests for ChatView sending turns and token display.

import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ChatView from "./ChatView";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";

describe("ChatView", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    // Each test stubs WebSocket with its own capture closure, so drop the
    // shared singleton's lingering OPEN handle; otherwise a later test
    // would reuse the earlier socket and never attach its own onmessage.
    resetSharedSocket();
    // Drop the shared poller's timer and cache for the same reason so one
    // test's interval never leaks into the next suite.
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("sends a message and renders the assistant reply", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ text: "hello back", sessionID: "s1", toolActions: [] }),
      ),
    );
    render(<ChatView />);
    await user.type(screen.getByLabelText("Chat input"), "hello");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("hello back")).toBeInTheDocument();
    });
    expect(screen.getByText("hello")).toBeInTheDocument();
  });

  it("starts a new session clearing messages", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ text: "reply", sessionID: "s1", toolActions: [] }),
      ),
    );
    render(<ChatView />);
    await user.type(screen.getByLabelText("Chat input"), "hi");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("reply")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "New session" }));
    expect(screen.queryByText("reply")).not.toBeInTheDocument();
  });

  it("does not fetch session from server when starting a new draft session", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (url: string) => {
      if (typeof url === "string" && url.includes("/sessions/")) {
        return jsonResponse({ reason: "Not found" }, 404);
      }
      return jsonResponse({ sessions: [], count: 0 });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<ChatView />);
    await user.click(screen.getByRole("button", { name: "New session" }));
    const sessionCalls = fetchMock.mock.calls.filter(([url]) =>
      typeof url === "string" && url.includes("/sessions/"),
    );
    expect(sessionCalls).toHaveLength(0);
  });

  it("mints a fresh session when the stored session was deleted server-side", async () => {
    localStorage.setItem("rw_active_session_id", "stale-session-id");
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.startsWith("/sessions/")) {
          return jsonResponse({ reason: "Unknown session" }, 404);
        }
        return jsonResponse({ sessions: [], count: 0 });
      }),
    );
    render(<ChatView />);
    // The stale UUID is replaced once instead of being resurrected on send.
    await waitFor(() => {
      const current = localStorage.getItem("rw_active_session_id");
      expect(current).not.toBe("stale-session-id");
      expect(current).toBeTruthy();
    });
    localStorage.removeItem("rw_active_session_id");
  });

  it("prevents browser autofill and supports Enter to send", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ text: "received", sessionID: "s1", toolActions: [] }),
      ),
    );
    render(<ChatView />);
    const inputEl = screen.getByLabelText("Chat input");
    expect(inputEl).toHaveAttribute("autoComplete", "off");
    expect(inputEl).toHaveAttribute("data-lpignore", "true");
    expect(inputEl).toHaveAttribute("data-1p-ignore", "true");
    expect(inputEl.tagName.toLowerCase()).toBe("textarea");

    await user.type(inputEl, "message with Enter{enter}");
    await waitFor(() => {
      expect(screen.getByText("received")).toBeInTheDocument();
    });
  });

  it("shows Cancel button when turn is pending and cancels on click", async () => {
    const user = userEvent.setup();
    let resolvePost: ((value: Response) => void) | undefined;
    const pendingPromise = new Promise<Response>((resolve) => {
      resolvePost = resolve;
    });

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/chat") {
          return pendingPromise;
        }
        if (input === "/chat/cancel") {
          return jsonResponse({ sessionID: "s1", cancelled: true });
        }
        return jsonResponse({});
      }),
    );

    render(<ChatView />);
    await user.type(screen.getByLabelText("Chat input"), "start long query");
    await user.click(screen.getByRole("button", { name: "Send" }));

    // Send button transforms into Cancel button
    const cancelBtn = await screen.findByRole("button", { name: "Cancel turn" });
    expect(cancelBtn).toBeInTheDocument();
    expect(screen.getByLabelText("Chat input")).toBeDisabled();

    // Click Cancel
    await user.click(cancelBtn);

    // Resolves/unlocks
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
      expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
    });

    // Cleanup promise
    await act(async () => {
      if (!resolvePost) {
        throw new Error("Expected pending turn resolver");
      }
      resolvePost(
        jsonResponse({ text: "nevermind", sessionID: "s1", toolActions: [] }),
      );
    });
  });

  it("prefers authoritative sessionTokens over local accumulation", async () => {
    const user = userEvent.setup();

    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "hello");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;

    // Authoritative cumulative total differs from the local sum on purpose:
    // the view must adopt it instead of adding the turn total.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "hi",
      sessionID: turnSID,
      toolActions: [],
      totalTokens: 150,
      sessionTokens: 1000,
    });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
    // Local accumulation would show 150; authoritative shows 1,000.
    expect(screen.getByText(/1,000/)).toBeInTheDocument();
  });

  it("ignores untagged session frames to prevent cross-session leakage", async () => {
    const user = userEvent.setup();

    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "hello");
    await user.click(screen.getByRole("button", { name: "Send" }));

    // Untagged tool and text frames must not touch the current view.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.search",
      callID: "call-untagged",
      argumentsJSON: "{}",
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "leaked text",
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "leaked done",
    });

    // The leaked text never renders and the turn stays pending.
    expect(screen.queryByText(/leaked/)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Cancel turn" })).toBeInTheDocument();
  });

  it("streams real-time tool events and text deltas over WebSocket", async () => {
    const user = userEvent.setup();

    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    // Wait for WS to connect
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "check email");
    await user.click(screen.getByRole("button", { name: "Send" }));

    expect(capture.sentFrames.length).toBe(1);
    expect(JSON.parse(capture.sentFrames[0])).toMatchObject({ text: "check email" });
    // Tag every frame with the owning turn so session scoping accepts them.
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;

    // 1. Tool starts
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.search",
      callID: "call-1",
      argumentsJSON: '{"limit": 1}',
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByText("email.search")).toBeInTheDocument();
      expect(screen.getByText("Running")).toBeInTheDocument();
    });

    // 2. Tool ends
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_end",
      toolName: "email.search",
      callID: "call-1",
      result: {
        toolCallID: "call-1",
        content: "1 email found",
        isError: false,
      },
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByText("Done")).toBeInTheDocument();
    });

    // 3. Text delta streaming
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "You have one ",
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByText(/You have one/)).toBeInTheDocument();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "new email from Alice.",
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(
        screen.getByText(/You have one new email from Alice\./),
      ).toBeInTheDocument();
    });

    // 4. Done frame completes turn
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "You have one new email from Alice.",
      sessionID: turnSID,
      toolActions: [
        {
          toolName: "email.search",
          callID: "call-1",
          argumentsJSON: '{"limit": 1}',
          result: {
            toolCallID: "call-1",
            content: "1 email found",
            isError: false,
          },
        },
      ],
      totalTokens: 150,
    });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
  });

  it("processes tool_start, delta, and done when server returns uppercase UUID matching lowercase client session", async () => {
    const user = userEvent.setup();

    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "check email");
    await user.click(screen.getByRole("button", { name: "Send" }));

    expect(capture.sentFrames.length).toBe(1);
    const clientSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;
    expect(clientSID).toBeDefined();
    if (clientSID === undefined) {
      throw new Error("Expected client session ID on the sent frame");
    }
    // Swift formats UUIDs as uppercase by default (e.g. 3ECB... vs 3ecb...)
    const serverSID = clientSID.toUpperCase();
    expect(serverSID).not.toBe(clientSID.toLowerCase());

    // 1. Tool starts with uppercase server session ID
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.search",
      callID: "call-case-1",
      argumentsJSON: '{"limit": 1}',
      sessionID: serverSID,
    });

    await waitFor(() => {
      expect(screen.getByText("email.search")).toBeInTheDocument();
      expect(screen.getByText("Running")).toBeInTheDocument();
    });

    // 2. Text delta streaming with uppercase server session ID
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "Found 1 matching email.",
      sessionID: serverSID,
    });

    await waitFor(() => {
      expect(screen.getByText(/Found 1 matching email\./)).toBeInTheDocument();
    });

    // 3. Done frame completes turn with uppercase server session ID
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "Found 1 matching email.",
      sessionID: serverSID,
      toolActions: [
        {
          toolName: "email.search",
          callID: "call-case-1",
          argumentsJSON: '{"limit": 1}',
          result: {
            toolCallID: "call-case-1",
            content: "1 email found",
            isError: false,
          },
        },
      ],
      totalTokens: 120,
    });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
  });

  it("completes a streamed turn with a single message when done omits text", async () => {
    // Terminal frames reuse the streamed snapshot taken outside any updater,
    // so a done frame without text still finalizes exactly one message with
    // the streamed content instead of duplicating under double-invoke.
    const user = userEvent.setup();

    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "stream me");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "streamed fallback text",
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByText(/streamed fallback text/)).toBeInTheDocument();
    });

    // Done carries no text, so the finalized message must reuse the streamed
    // snapshot and appear exactly once.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      sessionID: turnSID,
      totalTokens: 10,
    });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
    expect(screen.getAllByText(/streamed fallback text/)).toHaveLength(1);
  });
});

describe("reconstructMessages with structured tool actions", () => {
  it("prefers structured records when arguments contain brackets", async () => {
    const { reconstructMessages, toolActionMap } = await import("./ChatView");
    const raw = [
      { id: "u1", role: "user", content: "check mail" },
      {
        id: "m1",
        role: "assistant",
        content: 'Calling email.search {"filter":"a]b"} [call_brackets]',
      },
      {
        role: "tool",
        content: "1 found",
        toolCallID: "call_brackets",
      },
      { id: "m2", role: "assistant", content: "You have one match." },
    ];
    const structured = toolActionMap([
      {
        messageID: "m1",
        actions: [
          {
            toolName: "email.search",
            callID: "call_brackets",
            argumentsJSON: '{"filter":"a]b"}',
            result: {
              toolCallID: "call_brackets",
              content: "1 found",
              isError: false,
            },
          },
        ],
      },
    ]);
    const result = reconstructMessages(raw, structured);
    const assistant = result.find((m) => m.role === "assistant");
    const actions = assistant?.toolActions;
    expect(actions).toHaveLength(1);
    expect(actions?.[0]?.toolName).toBe("email.search");
    expect(actions?.[0]?.argumentsJSON).toBe('{"filter":"a]b"}');
    expect(actions?.[0]?.result?.content).toBe("1 found");
  });

  it("keeps uncovered lines visible without synthesizing tool actions", async () => {
    const { reconstructMessages } = await import("./ChatView");
    const raw = [
      { role: "user", content: "check mail" },
      {
        role: "assistant",
        content: 'Calling email.search {"limit":1} [call_9]',
      },
      { role: "tool", content: "none", toolCallID: "call_9" },
      { role: "assistant", content: "Nothing new." },
    ];
    const result = reconstructMessages(raw);
    // Without a server record the client never guesses the placeholder
    // shape, so the raw line stays visible and no actions are invented.
    const assistants = result.filter((m) => m.role === "assistant");
    expect(assistants).toHaveLength(2);
    expect(assistants[0].text).toContain("Calling email.search");
    expect(assistants[0].toolActions).toBeUndefined();
    expect(assistants[1].text).toBe("Nothing new.");
    expect(assistants[1].toolActions).toBeUndefined();
  });

  it("ignores structured entries for unknown message IDs without synthesizing", async () => {
    const { reconstructMessages, toolActionMap } = await import("./ChatView");
    const raw = [
      { role: "user", content: "hi" },
      {
        id: "m-unknown",
        role: "assistant",
        content: 'Calling email.search {"limit":1} [call_7]',
      },
      { role: "tool", content: "none", toolCallID: "call_7" },
      { role: "assistant", content: "Done." },
    ];
    const structured = toolActionMap([
      {
        messageID: "other",
        actions: [
          {
            toolName: "other.tool",
            callID: "unrelated",
            argumentsJSON: "{}",
            result: null,
          },
        ],
      },
    ]);
    const result = reconstructMessages(raw, structured);
    // The record covers another message, so the uncovered line stays
    // visible as prose and no unrelated actions attach.
    const assistants = result.filter((m) => m.role === "assistant");
    expect(assistants).toHaveLength(2);
    expect(assistants[0].text).toContain("Calling email.search");
    expect(assistants[0].toolActions).toBeUndefined();
    expect(assistants[1].text).toBe("Done.");
    expect(assistants[1].toolActions).toBeUndefined();
  });

  it("indexes groups by message ID", async () => {
    const { toolActionMap } = await import("./ChatView");
    const map = toolActionMap([
      {
        messageID: "m1",
        actions: [
          {
            toolName: "a",
            callID: "c1",
            argumentsJSON: "{}",
            result: null,
          },
        ],
      },
    ]);
    const actions = map.get("m1");
    expect(actions).toHaveLength(1);
    expect(actions?.[0]?.toolName).toBe("a");
    expect(map.get("missing")).toBeUndefined();
    expect(toolActionMap(undefined).size).toBe(0);
  });

  it("deduplicates interim waiting message when a parked turn resumes and completes via WS", async () => {
    resetSharedSocket();
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "download file");
    await user.click(screen.getByRole("button", { name: "Send" }));

    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string }).sessionID;

    // Turn parks waiting for approval
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      isParked: true,
      text: "Waiting for approval to run email.attachment. Approve in the approvals inbox to continue.",
      toolActions: [
        {
          toolName: "email.attachment",
          callID: "call-att-1",
          argumentsJSON: "{}",
          result: null,
        },
      ],
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(
        screen.getByText(/Waiting for approval to run email.attachment/),
      ).toBeInTheDocument();
      expect(screen.getByText("Pending")).toBeInTheDocument();
    });

    // Approval is granted and tool starts
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval_decided",
      id: "app-1",
      approved: true,
      sessionID: turnSID,
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.attachment",
      callID: "call-att-1",
      argumentsJSON: "{}",
      sessionID: turnSID,
    });

    // Tool completes
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_end",
      toolName: "email.attachment",
      callID: "call-att-1",
      result: {
        toolCallID: "call-att-1",
        content: "File downloaded",
        isError: false,
      },
      sessionID: turnSID,
    });

    // Resume turn finishes with final synthesis
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      isParked: false,
      text: "The attachment has been successfully downloaded.",
      toolActions: [
        {
          toolName: "email.attachment",
          callID: "call-att-1",
          argumentsJSON: "{}",
          result: {
            toolCallID: "call-att-1",
            content: "File downloaded",
            isError: false,
          },
        },
      ],
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(
        screen.getByText("The attachment has been successfully downloaded."),
      ).toBeInTheDocument();
    });

    // Old waiting text should be gone
    expect(
      screen.queryByText(/Waiting for approval to run email.attachment/),
    ).not.toBeInTheDocument();
    // Only one "Done" tool pill should exist, and no "Pending" tool pill
    expect(screen.queryByText("Pending")).not.toBeInTheDocument();
    expect(screen.getByText("Done")).toBeInTheDocument();
  });
});

describe("reconstructMessages", () => {
  it("reconstructs assistant tool actions from the server record", async () => {
    const { reconstructMessages, toolActionMap } = await import("./ChatView");
    const raw = [
      { role: "user", content: "can you check my last email?" },
      {
        id: "m-tools",
        role: "assistant",
        content: 'Calling email.search {"account":"volcrypt","limit":1} [call_123]',
      },
      {
        role: "tool",
        content: '{"account":"Volcrypt","count":1,"messages":[{"subject":"Security alert"}]}',
        toolCallID: "call_123",
      },
      {
        role: "assistant",
        content: 'Your most recent email has subject "Security alert".',
      },
    ];
    const structured = toolActionMap([
      {
        messageID: "m-tools",
        actions: [
          {
            toolName: "email.search",
            callID: "call_123",
            argumentsJSON: '{"account":"volcrypt","limit":1}',
            result: {
              toolCallID: "call_123",
              content: '{"account":"Volcrypt","count":1,"messages":[{"subject":"Security alert"}]}',
              isError: false,
            },
          },
        ],
      },
    ]);

    const result = reconstructMessages(raw, structured);
    expect(result).toHaveLength(2);
    expect(result[0].role).toBe("user");
    expect(result[0].text).toBe("can you check my last email?");

    expect(result[1].role).toBe("assistant");
    expect(result[1].text).toBe('Your most recent email has subject "Security alert".');
    const toolActions = result[1].toolActions;
    expect(toolActions).toHaveLength(1);
    expect(toolActions?.[0]?.toolName).toBe("email.search");
    expect(toolActions?.[0]?.callID).toBe("call_123");
    expect(toolActions?.[0]?.result?.content).toContain("Security alert");
  });

  it("handles standalone conversational messages without tools", async () => {
    const { reconstructMessages } = await import("./ChatView");
    const raw = [
      { role: "user", content: "hi" },
      { role: "assistant", content: "Hello! How can I help?" },
    ];
    const result = reconstructMessages(raw);
    expect(result).toHaveLength(2);
    expect(result[1].toolActions).toBeUndefined();
    expect(result[1].text).toBe("Hello! How can I help?");
  });

  it("skips interim waiting placeholders when the turn subsequently resumed", async () => {
    const { reconstructMessages, toolActionMap } = await import("./ChatView");
    const raw = [
      { role: "user", content: "download attachment" },
      {
        id: "m-note",
        role: "assistant",
        content: 'Calling email.attachment {"id":"123"} [call_att]',
      },
      {
        id: "m-wait",
        role: "assistant",
        content: "Waiting for approval to run email.attachment. Approve in the approvals inbox to continue.",
      },
      {
        role: "tool",
        content: '{"downloaded":true}',
        toolCallID: "call_att",
      },
      {
        id: "m-final",
        role: "assistant",
        content: "The attachment has been downloaded successfully.",
      },
    ];
    const structured = toolActionMap([
      {
        messageID: "m-note",
        actions: [
          {
            toolName: "email.attachment",
            callID: "call_att",
            argumentsJSON: '{"id":"123"}',
            result: {
              toolCallID: "call_att",
              content: '{"downloaded":true}',
              isError: false,
            },
          },
        ],
      },
    ]);

    const result = reconstructMessages(raw, structured);
    expect(result).toHaveLength(2);
    expect(result[0].role).toBe("user");
    expect(result[1].role).toBe("assistant");
    expect(result[1].text).toBe("The attachment has been downloaded successfully.");
    expect(result[1].toolActions).toHaveLength(1);
    expect(result[1].toolActions?.[0]?.toolName).toBe("email.attachment");
    expect(result[1].toolActions?.[0]?.result?.content).toBe('{"downloaded":true}');
  });

  it("keeps interim waiting placeholder when the turn is still parked and awaiting approval", async () => {
    const { reconstructMessages, toolActionMap } = await import("./ChatView");
    const raw = [
      { role: "user", content: "download attachment" },
      {
        id: "m-note",
        role: "assistant",
        content: 'Calling email.attachment {"id":"123"} [call_att]',
      },
      {
        id: "m-wait",
        role: "assistant",
        content: "Waiting for approval to run email.attachment. Approve in the approvals inbox to continue.",
      },
    ];
    const structured = toolActionMap([
      {
        messageID: "m-note",
        actions: [
          {
            toolName: "email.attachment",
            callID: "call_att",
            argumentsJSON: '{"id":"123"}',
            result: null,
          },
        ],
      },
    ]);

    const result = reconstructMessages(raw, structured);
    expect(result).toHaveLength(2);
    expect(result[0].role).toBe("user");
    expect(result[1].role).toBe("assistant");
    expect(result[1].text).toBe("Waiting for approval to run email.attachment. Approve in the approvals inbox to continue.");
    expect(result[1].toolActions).toHaveLength(1);
    expect(result[1].toolActions?.[0]?.result).toBeNull();
  });
});

describe("Inline session approval banner", () => {
  const sessionID = "inline-session-1";

  function approval(
    overrides: Record<string, unknown> = {},
  ): Record<string, unknown> {
    return {
      id: "approval-inline-1",
      toolName: "email.send",
      description: "Send email to ops",
      input: {
        toolName: "email.send",
        argumentsJSON: '{"to":"ops@example.com"}',
        callID: "call-inline-1",
      },
      suggestedDurations: ["thisTime"],
      sessionID,
      ...overrides,
    };
  }

  function stubApprovalsFetch(
    approvals: Array<Record<string, unknown>>,
    onDecide?: (path: string, body: string) => void,
  ): { decideCalls: Array<{ path: string; body: string }>; decided: { value: boolean } } {
    // After a successful decision the server inbox empties, so later polls
    // must return no rows; otherwise the locally evicted banner would
    // reappear and the test could not observe the instant removal.
    const decideCalls: Array<{ path: string; body: string }> = [];
    const decided = { value: false };
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (typeof input === "string" && input.includes("/decide")) {
          const body = String(init?.body ?? "");
          decideCalls.push({ path: input, body });
          onDecide?.(input, body);
          decided.value = true;
          let parsed: { approved?: boolean; duration?: string } = {};
          try {
            parsed = JSON.parse(body) as {
              approved?: boolean;
              duration?: string;
            };
          } catch {
            parsed = {};
          }
          return jsonResponse({
            id: "approval-inline-1",
            approved: parsed.approved ?? true,
            duration: parsed.duration ?? "thisTime",
          });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          if (decided.value) {
            return jsonResponse({ approvals: [], count: 0 });
          }
          return jsonResponse({ approvals, count: approvals.length });
        }
        return jsonResponse({});
      }),
    );
    return { decideCalls, decided };
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
    localStorage.setItem("rw_active_session_id", sessionID);
  });

  it("shows only same-session approvals inline and keeps input usable", async () => {
    stubApprovalsFetch([
      approval(),
      approval({
        id: "approval-other",
        toolName: "files.write",
        description: "Other session write",
        sessionID: "other-session",
      }),
      approval({
        id: "approval-unattributed",
        toolName: "browser.click",
        description: "Unattributed click",
        sessionID: undefined,
      }),
    ]);
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    expect(screen.getByText("Send email to ops")).toBeInTheDocument();
    // Foreign and unattributed entries stay in the global inbox only.
    expect(screen.queryByText("files.write")).not.toBeInTheDocument();
    expect(screen.queryByText("browser.click")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
  });

  it("one-click Allow defaults to thisTime and evicts the row", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApprovalsFetch([approval()]);
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.queryByText("email.send")).not.toBeInTheDocument();
    });
    expect(decideCalls).toHaveLength(1);
    expect(JSON.parse(decideCalls[0].body)).toMatchObject({
      approved: true,
      duration: "thisTime",
    });
  });

  it("chevron menu Allow passes the chosen duration", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApprovalsFetch([approval()]);
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: "Allow options for email.send" }),
    );
    await user.click(screen.getByRole("menuitem", { name: "Next hour" }));
    await waitFor(() => {
      expect(screen.queryByText("email.send")).not.toBeInTheDocument();
    });
    expect(decideCalls).toHaveLength(1);
    expect(JSON.parse(decideCalls[0].body)).toMatchObject({
      approved: true,
      duration: "oneHour",
    });
  });

  it("Deny decides with thisTime and evicts the row", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApprovalsFetch([approval()]);
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Deny" }));
    await waitFor(() => {
      expect(screen.queryByText("email.send")).not.toBeInTheDocument();
    });
    expect(decideCalls).toHaveLength(1);
    expect(JSON.parse(decideCalls[0].body)).toMatchObject({
      approved: false,
      duration: "thisTime",
    });
  });
});

describe("Degraded tool warnings and fatal errors", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("renders degraded warnings as an amber banner without locking input", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "check mail");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;

    // Live degraded notice surfaces immediately without failing the turn.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "warning",
      message: "Tool broken.tool was disabled for this turn: invalid input schema",
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByTestId("turn-warnings-banner")).toBeInTheDocument();
    });
    expect(
      screen.getByText(
        "Tool broken.tool was disabled for this turn: invalid input schema",
      ),
    ).toBeInTheDocument();

    // Terminal frame repeats the notice and completes normally.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "Checked what I could.",
      sessionID: turnSID,
      toolActions: [],
      totalTokens: 10,
      warnings: [
        "Tool broken.tool was disabled for this turn: invalid input schema",
      ],
    });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });

    // Amber banner stays informational: one row, amber class distinct from fatal error, input usable.
    const banner = screen.getByTestId("turn-warnings-banner");
    expect(banner).toHaveTextContent("A tool was skipped for this turn");
    expect(banner.className).toContain("turn-warnings-banner");
    expect(banner.className).not.toContain("chat-error");
    expect(screen.getByText("Checked what I could.")).toBeInTheDocument();
    expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
    expect(screen.queryByText("Chat turn failed")).not.toBeInTheDocument();
  });

  it("renders fatal turn errors in red without the amber banner", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();

    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "check mail");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "error",
      message: "Chat turn failed",
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByText("Chat turn failed")).toBeInTheDocument();
    });

    // Fatal errors use the red error class, never the amber warnings banner.
    const errorEl = screen.getByText("Chat turn failed");
    expect(errorEl.className).toContain("error");
    expect(errorEl.className).toContain("chat-error");
    expect(
      screen.queryByTestId("turn-warnings-banner"),
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
  });
});

describe("Background turns across sessions", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("parks a running turn on switch, badges it, and restores without duplicating done", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));

    // Pin the starting session so the sidebar history can name it; the fresh
    // draft after New Session mints its own identifier.
    const sessionA = "park-session-aaaa-1111";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({
            sessions: [
              {
                id: sessionA,
                title: "Session A",
                messageCount: 1,
                createdAt: now,
                updatedAt: now,
                source: "chat",
              },
            ],
            count: 1,
          });
        }
        if (typeof input === "string" && input.endsWith("/tool-actions")) {
          return jsonResponse({ sessionID: sessionA, actions: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionA,
            title: "Session A",
            messages: [],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "background task");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "partial progress ",
      sessionID: sessionA,
    });

    await waitFor(() => {
      expect(screen.getByText(/partial progress/)).toBeInTheDocument();
    });

    // Leaving parks the live timeline but keeps the server turn alive; the
    // input unlocks for the fresh draft while the badge marks the old row.
    await user.click(screen.getByRole("button", { name: "New session" }));

    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
    });
    expect(screen.queryByText(/partial progress/)).not.toBeInTheDocument();
    expect(await screen.findByTestId("session-running-badge")).toBeInTheDocument();

    // Frames for the hidden session grow only its parked timeline.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "more while away",
      sessionID: sessionA,
    });

    // Returning restores the combined live timeline without a reload.
    const sessionRow = screen.getByText("Session A").closest(".session-item");
    if (!sessionRow) throw new Error("Expected parked session row");
    await user.click(sessionRow);

    await waitFor(() => {
      expect(screen.getByText(/partial progress/)).toBeInTheDocument();
    });
    expect(screen.getByText(/more while away/)).toBeInTheDocument();

    // The terminal frame finalizes exactly one message.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "partial progress more while away",
      sessionID: sessionA,
      toolActions: [],
      totalTokens: 10,
    });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
    expect(
      screen.getAllByText(/partial progress more while away/),
    ).toHaveLength(1);
  });
});

describe("Tool end attribution without call identity", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("attributes one unmatched end frame to at most the first pending same-tool call", async () => {
    // Two executions of one tool pend at once; an end frame with no call
    // identity must complete only the first pending row so one result never
    // fans out across sibling executions.
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "search twice");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.search",
      callID: "call-fanout-1",
      argumentsJSON: '{"limit": 1}',
      sessionID: turnSID,
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.search",
      callID: "call-fanout-2",
      argumentsJSON: '{"limit": 1}',
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getAllByText("Running")).toHaveLength(2);
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_end",
      toolName: "email.search",
      callID: "call-unknown-no-identity",
      result: {
        toolCallID: "call-unknown-no-identity",
        content: "single result",
        isError: false,
      },
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getAllByText("Done")).toHaveLength(1);
    });
    expect(screen.getAllByText("Running")).toHaveLength(1);
  });
});

describe("Concurrent turn cap follows the health advertisement", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("refuses a new send once parked plus active turns reach the advertised cap", async () => {
    // The dashboard refuses through the server advertisement, never a local
    // constant: with a cap of one, a parked background turn already fills the
    // single slot so the next send explains the busy house instead of
    // dialing a turn the engine would immediately reject.
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    const sessionA = "cap-session-aaaa-1111";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({
            sessions: [
              {
                id: sessionA,
                title: "Session A",
                messageCount: 1,
                createdAt: now,
                updatedAt: now,
                source: "chat",
              },
            ],
            count: 1,
          });
        }
        if (typeof input === "string" && input.endsWith("/tool-actions")) {
          return jsonResponse({ sessionID: sessionA, actions: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionA,
            title: "Session A",
            messages: [],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );

    render(
      <ChatView
        health={{
          status: "ok",
          engine: "Rune Weaver",
          version: "0.1.0",
          maxConcurrentChatTurns: 1,
        }}
      />,
    );

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "first turn");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "working ",
      sessionID: sessionA,
    });

    await waitFor(() => {
      expect(screen.getByText(/working/)).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "New session" }));

    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
    });

    await user.type(screen.getByLabelText("Chat input"), "second turn");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(screen.getByText(/Already running 1 chat turns/)).toBeInTheDocument();
    });
    expect(capture.sentFrames).toHaveLength(1);
  });
});

