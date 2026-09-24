// Rune Weaver Dashboard — Component tests for ChatView turns, history drawer, and status footer.
//
// Covers sending turns and token display plus the handheld matrix: the session
// history drawer stays closed on narrow viewports and inline on wide ones,
// dismissing via backdrop, Escape, or session select, while the footer
// collapses to a glanceable line on mobile and expands to full metrics.

import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ChatView from "./ChatView";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";
import { jsonResponse } from "../test-utils/http";
import { installViewport } from "../test-utils/viewport";
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

    // Send button transforms into Cancel button while input stays enabled for steering
    const cancelBtn = await screen.findByRole("button", { name: "Cancel turn" });
    expect(cancelBtn).toBeInTheDocument();
    expect(screen.getByLabelText("Chat input")).not.toBeDisabled();

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

  it("preserves isError on assistant messages and retains associated tool actions", async () => {
    const { reconstructMessages, toolActionMap } = await import("./ChatView");
    const raw = [
      { role: "user", content: "get attachment" },
      {
        id: "m-tool",
        role: "assistant",
        content: 'Calling email.attachment [call-1]',
      },
      {
        id: "m-err",
        role: "assistant",
        content: "Error: context length exceeded",
        isError: true,
      },
    ];
    const structured = toolActionMap([
      {
        messageID: "m-tool",
        actions: [
          {
            toolName: "email.attachment",
            callID: "call-1",
            argumentsJSON: '{"id":"1"}',
            result: { toolCallID: "call-1", content: '{"ok":true}', isError: false },
          },
        ],
      },
    ]);

    const result = reconstructMessages(raw, structured);
    expect(result).toHaveLength(2);
    expect(result[0].role).toBe("user");
    expect(result[1].role).toBe("assistant");
    expect(result[1].isError).toBe(true);
    expect(result[1].toolActions).toHaveLength(1);
    expect(result[1].toolActions?.[0].toolName).toBe("email.attachment");
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

  it("chevron menu Allow with all targets passes widen: true", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApprovalsFetch([approval()]);
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: "Allow options for email.send" }),
    );
    await user.click(
      screen.getByRole("menuitem", { name: "Next hour (all targets)" }),
    );
    await waitFor(() => {
      expect(screen.queryByText("email.send")).not.toBeInTheDocument();
    });
    expect(decideCalls).toHaveLength(1);
    expect(JSON.parse(decideCalls[0].body)).toMatchObject({
      approved: true,
      duration: "oneHour",
      widen: true,
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

  it("preserves in-flight tool activity and renders error card when turn fails", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    render(<ChatView />);

    await waitFor(() => {
      expect(screen.getByPlaceholderText(/Message Rune Weaver/)).toBeInTheDocument();
    });

    await user.type(screen.getByLabelText("Chat input"), "download invoice attachment");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string }).sessionID;

    // Simulate tool activity during the turn
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.attachment",
      callID: "call-1",
      argumentsJSON: '{"id":"10"}',
      sessionID: turnSID,
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_end",
      toolName: "email.attachment",
      callID: "call-1",
      result: {
        toolCallID: "call-1",
        content: '{"downloaded":true}',
        isError: false,
      },
      sessionID: turnSID,
    });

    // An error frame arrives (e.g. context limit exceeded)
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "error",
      message: "request (568726 tokens) exceeds the available context size (128000 tokens)",
      sessionID: turnSID,
    });

    // Tool activity must STILL be visible, and error card must render
    await waitFor(() => {
      expect(screen.getByText(/Tool Activity/)).toBeInTheDocument();
      expect(screen.getByText(/email\.attachment/)).toBeInTheDocument();
      expect(
        screen.getByText(/Turn failed: request \(568726 tokens\) exceeds the available context size/),
      ).toBeInTheDocument();
    });
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

describe("Mid-turn steering", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("unlocks input while pending and sends steer message over WebSocket", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    // Start turn
    await user.type(screen.getByLabelText("Chat input"), "start long task");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });

    // Input stays enabled during turn
    const inputEl = screen.getByLabelText("Chat input");
    expect(inputEl).not.toBeDisabled();

    // Cancel button shows when input is empty
    expect(screen.getByRole("button", { name: "Cancel turn" })).toBeInTheDocument();

    // Type steering message
    await user.type(inputEl, "please focus on tests");

    // Steer button appears
    const steerBtn = screen.getByRole("button", { name: "Steer turn" });
    expect(steerBtn).toBeInTheDocument();

    // Click Steer
    await user.click(steerBtn);

    // Steer frame sent over WebSocket
    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(2);
    });
    const steerFrame = JSON.parse(capture.sentFrames[1]);
    expect(steerFrame.text).toBe("please focus on tests");
    expect(steerFrame.steer).toBe(true);

    // Input is cleared and user message is rendered
    expect(inputEl).toHaveValue("");
    expect(screen.getByText("please focus on tests")).toBeInTheDocument();
  });

  it("renders pre-steer assistant tool activity above the steer bubble so steer stays at the bottom", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    // Start turn
    await user.type(screen.getByLabelText("Chat input"), "find attachments");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string }).sessionID;

    // Simulate tool activity mid-turn
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "mailbox_search",
      callID: "call-1",
      argumentsJSON: '{"query":"inbox"}',
      sessionID: turnSID,
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_end",
      toolName: "mailbox_search",
      callID: "call-1",
      result: { ok: true, value: "found 1 message" },
      sessionID: turnSID,
    });

    await waitFor(() => {
      expect(screen.getByText(/mailbox_search/)).toBeInTheDocument();
    });

    // Type steering message
    const inputEl = screen.getByLabelText("Chat input");
    await user.type(inputEl, "make sure to move mail back");
    const steerBtn = screen.getByRole("button", { name: "Steer turn" });
    await user.click(steerBtn);

    // Verify both messages are in the document and steer bubble is below tool activity
    expect(screen.getByText("make sure to move mail back")).toBeInTheDocument();

    // Order by rendered text rather than layout classes so the assertion
    // follows reading order instead of coupling to CSS structure or indexes.
    const promptEl = screen.getByText("find attachments");
    const toolEl = screen.getByText(/mailbox_search/);
    const steerEl = screen.getByText("make sure to move mail back");
    expect(
      promptEl.compareDocumentPosition(toolEl) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
    expect(
      toolEl.compareDocumentPosition(steerEl) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("prevents accidental cancellation within 500ms of clicking steer", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    // Pin the clock so the debounce window is deterministic instead of
    // relying on real wall-time between two clicks.
    const nowSpy = vi.spyOn(Date, "now");
    let now = 1_000_000;
    nowSpy.mockReturnValue(now);

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await user.type(screen.getByLabelText("Chat input"), "start job");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });

    const inputEl = screen.getByLabelText("Chat input");
    await user.type(inputEl, "steer command");
    const steerBtn = screen.getByRole("button", { name: "Steer turn" });
    await user.click(steerBtn);

    expect(capture.sentFrames.length).toBe(2);

    // Still inside the guard: advancing only 100ms keeps the cancel blocked.
    now += 100;
    nowSpy.mockReturnValue(now);
    const cancelBtn = screen.getByRole("button", { name: "Cancel turn" });
    await user.click(cancelBtn);

    // Cancel frame should NOT have been sent because it occurred within 500ms
    expect(capture.sentFrames.length).toBe(2);

    // Past the guard a deliberate cancel goes through.
    now += 600;
    nowSpy.mockReturnValue(now);
    await user.click(cancelBtn);
    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(3);
    });
    nowSpy.mockRestore();
  });
});

describe("Token metrics status bar", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("renders Turn, Context, and Session tokens distinctly", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    const sessionID = localStorage.getItem("rw_active_session_id") || "s1";

    await user.type(screen.getByLabelText("Chat input"), "hello");
    await user.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      sessionID,
      text: "hello there",
      totalTokens: 150,
      sessionTokens: 130000,
      contextTokens: 4800,
      contextLength: 32768,
    });

    await waitFor(() => {
      expect(screen.getByText("hello there")).toBeInTheDocument();
    });

    // Check status bar items
    expect(screen.getByText("150 tokens")).toBeInTheDocument();
    expect(screen.getByText("4,800 / 32,768 tokens (15%)")).toBeInTheDocument();
    expect(screen.getByText("130,000 tokens")).toBeInTheDocument();
  });
});

describe("ChatView mobile history drawer", () => {
  let originalMatchMedia: typeof window.matchMedia | undefined;

  function stubEmptyFetch(): void {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({})),
    );
  }

  function stubSessionsFetch(sessionID: string, title: string): void {
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({
            sessions: [
              {
                id: sessionID,
                title,
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
          return jsonResponse({ sessionID, actions: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionID,
            title,
            messages: [],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        return jsonResponse({});
      }),
    );
  }

  beforeEach(() => {
    originalMatchMedia = (window as unknown as { matchMedia?: typeof window.matchMedia })
      .matchMedia;
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  afterEach(() => {
    if (originalMatchMedia === undefined) {
      Reflect.deleteProperty(window as unknown as Record<string, unknown>, "matchMedia");
    } else {
      Object.defineProperty(window, "matchMedia", {
        writable: true,
        configurable: true,
        value: originalMatchMedia,
      });
    }
  });

  it("starts with the drawer closed and no backdrop on a 375px phone", async () => {
    installViewport(375);
    stubEmptyFetch();
    render(<ChatView />);
    // Mount-pinned closed state keeps the conversation visible on handheld;
    // the History trigger is the single entry point while closed.
    expect(await screen.findByRole("button", { name: "History" })).toBeInTheDocument();
    expect(screen.queryByTestId("sidebar-backdrop")).toBeNull();
    expect(document.querySelector(".session-sidebar.collapsed")).not.toBeNull();
  });

  it("starts with the inline sidebar open and the backdrop mounted but CSS-hidden on a 1024px desktop", async () => {
    installViewport(1024);
    stubEmptyFetch();
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).toBeInTheDocument();
    });
    // Desktop keeps history inline with no trigger; the backdrop mounts
    // whenever open while the wide query keeps it hidden, so visibility stays
    // CSS-owned instead of hook-gated.
    expect(screen.queryByRole("button", { name: "History" })).toBeNull();
    expect(screen.getByTestId("sidebar-backdrop")).toBeInTheDocument();
    expect(document.querySelector(".session-sidebar.open")).not.toBeNull();
  });

  it("opens on History and dismisses through the backdrop with focus return", async () => {
    installViewport(375);
    stubEmptyFetch();
    const user = userEvent.setup();
    render(<ChatView />);
    await user.click(await screen.findByRole("button", { name: "History" }));
    expect(await screen.findByTestId("sidebar-backdrop")).toBeInTheDocument();
    await user.click(screen.getByTestId("sidebar-backdrop"));
    await waitFor(() => {
      expect(screen.queryByTestId("sidebar-backdrop")).toBeNull();
    });
    // Close-only dismissal never reopens: the trigger returns for keyboard users.
    const trigger = await screen.findByRole("button", { name: "History" });
    expect(trigger).toBeInTheDocument();
    await waitFor(() => {
      expect(document.activeElement).toBe(trigger);
    });
  });

  it("closes the drawer on Escape without toggling it back open", async () => {
    installViewport(375);
    stubEmptyFetch();
    const user = userEvent.setup();
    render(<ChatView />);
    await user.click(await screen.findByRole("button", { name: "History" }));
    expect(await screen.findByTestId("sidebar-backdrop")).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => {
      expect(screen.queryByTestId("sidebar-backdrop")).toBeNull();
    });
    expect(await screen.findByRole("button", { name: "History" })).toBeInTheDocument();
  });

  it("closes on session select on mobile but keeps the sidebar open on desktop", async () => {
    const sessionID = "drawer-session-0001";
    // Mobile branch: selecting a row dismisses the fixed drawer.
    installViewport(375);
    stubSessionsFetch(sessionID, "Drawer Session");
    localStorage.setItem("rw_active_session_id", "drawer-draft-mobile");
    const user = userEvent.setup();
    const { unmount } = render(<ChatView />);
    await user.click(await screen.findByRole("button", { name: "History" }));
    expect(await screen.findByTestId("sidebar-backdrop")).toBeInTheDocument();
    const row = await screen.findByText("Drawer Session");
    const clickable = row.closest(".session-item");
    if (!clickable) throw new Error("Expected session row");
    await user.click(clickable);
    await waitFor(() => {
      expect(screen.queryByTestId("sidebar-backdrop")).toBeNull();
    });
    unmount();

    // Desktop branch: the static sidebar survives selection while the
    // backdrop stays mounted but CSS-hidden on wide viewports.
    installViewport(1024);
    stubSessionsFetch(sessionID, "Drawer Session");
    localStorage.setItem("rw_active_session_id", "drawer-draft-desktop");
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("Drawer Session")).toBeInTheDocument();
    });
    expect(screen.getByTestId("sidebar-backdrop")).toBeInTheDocument();
    const desktopRow = screen.getByText("Drawer Session").closest(".session-item");
    if (!desktopRow) throw new Error("Expected desktop session row");
    await user.click(desktopRow);
    expect(screen.getByTestId("sidebar-backdrop")).toBeInTheDocument();
    expect(document.querySelector(".session-sidebar.open")).not.toBeNull();
  });

  it("ignores invalid session tokens in the URL instead of adopting them", async () => {
    installViewport(1024);
    stubEmptyFetch();
    // Fail-closed routing accepts only canonical UUIDs; anything else must
    // never become state or persist to the active session slot.
    window.history.pushState({}, "", "/?session=not-a-valid-uuid");
    localStorage.removeItem("rw_active_session_id");
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).toBeInTheDocument();
    });
    const stored = localStorage.getItem("rw_active_session_id");
    expect(stored).toBeTruthy();
    expect(stored).not.toBe("not-a-valid-uuid");
    window.history.pushState({}, "", "/");
  });

  it("ignores invalid chat hash fragments instead of adopting them", async () => {
    installViewport(1024);
    stubEmptyFetch();
    window.history.pushState({}, "", "/#chat/not-a-uuid!!!");
    localStorage.removeItem("rw_active_session_id");
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).toBeInTheDocument();
    });
    const stored = localStorage.getItem("rw_active_session_id");
    expect(stored).toBeTruthy();
    expect(stored).not.toContain("not-a-uuid");
    window.history.pushState({}, "", "/");
  });
});

describe("ChatView mobile footer", () => {
  let originalMatchMedia: typeof window.matchMedia | undefined;

  const HEALTH_BASE = {
    status: "ok",
    engine: "Rune Weaver",
    version: "0.1.0",
    model: "footer-model-test",
  };

  async function renderWithDoneTokens(options: {
    width: number;
    contextTokens: number;
    contextLength: number;
    sessionTokens: number;
    totalTokens: number;
  }): Promise<void> {
    installViewport(options.width);
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({})),
    );
    const user = userEvent.setup();
    render(
      <ChatView
        health={{ ...HEALTH_BASE, contextLength: options.contextLength } as never}
      />,
    );
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await user.type(screen.getByLabelText("Chat input"), "hello footer");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string }).sessionID;
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "footer reply",
      sessionID: turnSID,
      toolActions: [],
      totalTokens: options.totalTokens,
      sessionTokens: options.sessionTokens,
      contextTokens: options.contextTokens,
      contextLength: options.contextLength,
    });
    await waitFor(() => {
      expect(screen.getByText("footer reply")).toBeInTheDocument();
    });
  }

  beforeEach(() => {
    originalMatchMedia = (window as unknown as { matchMedia?: typeof window.matchMedia })
      .matchMedia;
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  afterEach(() => {
    if (originalMatchMedia === undefined) {
      Reflect.deleteProperty(window as unknown as Record<string, unknown>, "matchMedia");
    } else {
      Object.defineProperty(window, "matchMedia", {
        writable: true,
        configurable: true,
        value: originalMatchMedia,
      });
    }
  });

  it("collapses to the glanceable Ctx plus session line with a Details toggle on mobile", async () => {
    installViewport(375);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({})),
    );
    render(<ChatView health={{ ...HEALTH_BASE, contextLength: 100 } as never} />);
    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).toBeInTheDocument();
    });
    // Empty sessions degrade to zero instead of NaN so a fresh draft shows
    // the collapsed baseline immediately.
    expect(screen.getByText("Ctx 0%")).toBeInTheDocument();
    expect(screen.getByText("0 sess")).toBeInTheDocument();
    const toggle = screen.getByRole("button", { name: "Details" });
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    // Collapsed toggle omits the dangling reference until the detail mounts.
    expect(toggle.getAttribute("aria-controls")).toBeNull();
    // Both branches stay mounted while the stylesheet owns visibility: the
    // desktop metrics sit in the DOM handheld with the wide query hiding the
    // mobile summary on desktop and the handheld query hiding desktop metrics.
    expect(screen.getByText("footer-model-test")).toBeInTheDocument();
  });

  it("expands the mobile footer to Turn plus full Context and Session usage", async () => {
    await renderWithDoneTokens({
      width: 375,
      contextTokens: 15,
      contextLength: 100,
      sessionTokens: 500,
      totalTokens: 150,
    });
    expect(screen.getByText("Ctx 15%")).toBeInTheDocument();
    expect(screen.getByText("500 sess")).toBeInTheDocument();
    const user = userEvent.setup();
    const toggle = screen.getByRole("button", { name: "Details" });
    // Collapsed toggle carries no controls reference while the detail is out.
    expect(toggle.getAttribute("aria-controls")).toBeNull();
    await user.click(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(toggle.getAttribute("aria-controls")).toBe("footer-detail");
    // Both footer branches stay mounted while the stylesheet owns visibility,
    // so the desktop metrics duplicate the Turn/Context values in the DOM
    // handheld. Scope the mobile assertions to the expanded detail block.
    const footerDetail = document.getElementById("footer-detail");
    expect(footerDetail).not.toBeNull();
    expect(within(footerDetail as HTMLElement).getByText("150 tokens")).toBeInTheDocument();
    expect(
      within(footerDetail as HTMLElement).getByText("15 / 100 tokens (15%)"),
    ).toBeInTheDocument();
    // The expanded handheld detail exposes the full locale-grouped session
    // total so mobile readers can see the exact value without a desktop.
    expect(
      within(footerDetail as HTMLElement).getByText("500 tokens"),
    ).toBeInTheDocument();
    const desktopMetrics = document.querySelector(".status-bar-desktop-metrics");
    expect(desktopMetrics).not.toBeNull();
    expect(
      within(desktopMetrics as HTMLElement).getByText("footer-model-test"),
    ).toBeInTheDocument();
  });

  it.each([
    { contextTokens: 0, label: "Ctx 0%", warned: false },
    { contextTokens: 79, label: "Ctx 79%", warned: false },
    { contextTokens: 80, label: "Ctx 80%", warned: true },
    { contextTokens: 100, label: "Ctx 100%", warned: true },
  ])(
    "covers the $contextTokens pct edge with amber at 80 and above",
    async ({ contextTokens, label, warned }) => {
      await renderWithDoneTokens({
        width: 375,
        contextTokens,
        contextLength: 100,
        sessionTokens: 10,
        totalTokens: 5,
      });
      const summary = screen.getByText(label);
      if (warned) {
        expect(summary.className).toContain("status-warning");
      } else {
        expect(summary.className).not.toContain("status-warning");
      }
    },
  );

  it("renders all four desktop metrics alongside the CSS-hidden mobile summary on wide viewports", async () => {
    await renderWithDoneTokens({
      width: 1024,
      contextTokens: 4800,
      contextLength: 32768,
      sessionTokens: 130000,
      totalTokens: 150,
    });
    expect(screen.getByText("footer-model-test")).toBeInTheDocument();
    expect(screen.getByText("150 tokens")).toBeInTheDocument();
    expect(screen.getByText("4,800 / 32,768 tokens (15%)")).toBeInTheDocument();
    expect(screen.getByText("130,000 tokens")).toBeInTheDocument();
    // The mobile summary stays mounted on desktop with the wide query hiding
    // it; the collapsed toggle carries no controls reference until expanded.
    const toggle = screen.getByRole("button", { name: "Details" });
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(toggle.getAttribute("aria-controls")).toBeNull();
  });

  it("flags the desktop context value amber once occupancy reaches 80 percent", async () => {
    await renderWithDoneTokens({
      width: 1024,
      contextTokens: 80,
      contextLength: 100,
      sessionTokens: 10,
      totalTokens: 5,
    });
    expect(screen.getByText("80 / 100 tokens (80%)").className).toContain("status-warning");
  });

  it("exposes the full session total in the expanded handheld detail for large values", async () => {
    await renderWithDoneTokens({
      width: 375,
      contextTokens: 4800,
      contextLength: 32768,
      sessionTokens: 130000,
      totalTokens: 150,
    });
    // Collapsed line stays compact while the expanded detail carries the
    // exact locale-grouped total desktop readers see.
    expect(screen.getByText("130k sess")).toBeInTheDocument();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Details" }));
    const footerDetail = document.getElementById("footer-detail");
    expect(footerDetail).not.toBeNull();
    expect(
      within(footerDetail as HTMLElement).getByText("130,000 tokens"),
    ).toBeInTheDocument();
  });

  it("promotes rounding-carried k values to M instead of rendering 1000k", async () => {
    await renderWithDoneTokens({
      width: 375,
      contextTokens: 10,
      contextLength: 100,
      sessionTokens: 999999,
      totalTokens: 5,
    });
    // 999999 / 1000 rounds to 1000.0k without the promotion; the compact
    // line must read 1M like the mega branch.
    expect(screen.getByText("1M sess")).toBeInTheDocument();
    expect(screen.queryByText("1000k sess")).toBeNull();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Details" }));
    const footerDetail = document.getElementById("footer-detail");
    expect(footerDetail).not.toBeNull();
    expect(
      within(footerDetail as HTMLElement).getByText("999,999 tokens"),
    ).toBeInTheDocument();
  });
});

describe("Chat reconnecting banner", () => {
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

  beforeEach(() => {
    vi.unstubAllGlobals();
    // Each case stubs WebSocket with its own capture closure, so drop the
    // shared singleton's lingering handle; otherwise a later case would reuse
    // the earlier socket and never attach its own close listener.
    resetSharedSocket();
    // Drop the shared poller's timer and cache for the same reason so one
    // case's interval never leaks into the next.
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("shows the reconnecting banner when the shared socket closes", async () => {
    // The header pill is the only signal that live updates paused while drafts
    // stay usable, so a dropped socket must surface it without locking input.
    const { capture, instances, CountingSocket } = makeCountingSocket();
    vi.stubGlobal("WebSocket", CountingSocket);
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    expect(screen.queryByTestId("chat-reconnecting")).not.toBeInTheDocument();

    await act(async () => {
      instances[0].close();
    });

    await waitFor(() => {
      expect(screen.getByTestId("chat-reconnecting")).toBeInTheDocument();
    });
    expect(screen.getByTestId("chat-reconnect-retry")).toBeInTheDocument();
    expect(screen.getByTestId("chat-reconnect-dismiss")).toBeInTheDocument();
    expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
  });

  it("retry forces an immediate redial and clears the banner on open", async () => {
    // A visible retry must bypass the idle backoff so the view rejoins live
    // without waiting out the scheduled timer, and recovery clears the pill
    // on the socket open instead of leaving it stuck.
    const user = userEvent.setup();
    const { capture, instances, CountingSocket } = makeCountingSocket();
    vi.stubGlobal("WebSocket", CountingSocket);
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => expect(capture.onMessage).not.toBeNull());

    await act(async () => {
      instances[0].close();
    });
    await waitFor(() => {
      expect(screen.getByTestId("chat-reconnecting")).toBeInTheDocument();
    });

    const dialedBeforeRetry = instances.length;
    await user.click(screen.getByTestId("chat-reconnect-retry"));
    // The redial lands synchronously on click, ahead of the new socket's
    // async open, so the count proves the gesture dialed immediately.
    expect(instances.length).toBe(dialedBeforeRetry + 1);

    await waitFor(() => {
      expect(screen.queryByTestId("chat-reconnecting")).not.toBeInTheDocument();
    });
  });

  it("dismiss hides the banner until the next close", async () => {
    // Dismiss is a per-outage snooze: it hides the pill for the current drop
    // while the next close resets it, so a fresh outage never stays silent.
    const user = userEvent.setup();
    const { capture, instances, CountingSocket } = makeCountingSocket();
    vi.stubGlobal("WebSocket", CountingSocket);
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => expect(capture.onMessage).not.toBeNull());

    await act(async () => {
      instances[0].close();
    });
    // Wait for the pill to mount before dismissing so the click never races
    // the close notification.
    await screen.findByTestId("chat-reconnecting");
    expect(screen.getByTestId("chat-reconnect-dismiss")).toBeInTheDocument();

    await user.click(screen.getByTestId("chat-reconnect-dismiss"));
    await waitFor(() => {
      expect(screen.queryByTestId("chat-reconnecting")).not.toBeInTheDocument();
    });

    // A fresh drop resets the snooze, so the pill returns for the next outage.
    await act(async () => {
      instances[0].close();
    });
    await screen.findByTestId("chat-reconnecting");
    expect(screen.getByTestId("chat-reconnecting")).toBeInTheDocument();
  });
});

describe("Input history recall", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("Up on empty recalls last send and repeated Up walks older sends", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ text: "reply", sessionID: "s1", toolActions: [] }),
      ),
    );
    render(<ChatView />);
    const inputEl = screen.getByLabelText("Chat input") as HTMLTextAreaElement;

    await user.type(inputEl, "first send");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("first send")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });

    await user.type(inputEl, "second send");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("second send")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });

    expect(inputEl).toHaveValue("");
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("second send");
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("first send");
  });

  it("Up at first line recalls while Up at second line keeps native movement", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ text: "reply", sessionID: "s1", toolActions: [] }),
      ),
    );
    render(<ChatView />);
    const inputEl = screen.getByLabelText("Chat input") as HTMLTextAreaElement;

    await user.type(inputEl, "history entry");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("history entry")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });

    fireEvent.change(inputEl, { target: { value: "line1\nline2" } });
    expect(inputEl).toHaveValue("line1\nline2");

    // Caret on the second line keeps native movement with no recall.
    inputEl.selectionStart = 8;
    inputEl.selectionEnd = 8;
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("line1\nline2");

    // Caret on the first line recalls the last send.
    inputEl.selectionStart = 2;
    inputEl.selectionEnd = 2;
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("history entry");
  });

  it("Down walks newer and restores pre-recall draft", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ text: "reply", sessionID: "s1", toolActions: [] }),
      ),
    );
    render(<ChatView />);
    const inputEl = screen.getByLabelText("Chat input") as HTMLTextAreaElement;

    await user.type(inputEl, "old msg");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("old msg")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });

    await user.type(inputEl, "new msg");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("new msg")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });

    await user.type(inputEl, "my draft");
    expect(inputEl).toHaveValue("my draft");
    inputEl.selectionStart = inputEl.value.length;
    inputEl.selectionEnd = inputEl.value.length;

    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("new msg");
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("old msg");
    fireEvent.keyDown(inputEl, { key: "ArrowDown" });
    expect(inputEl).toHaveValue("new msg");
    fireEvent.keyDown(inputEl, { key: "ArrowDown" });
    expect(inputEl).toHaveValue("my draft");
  });
});

