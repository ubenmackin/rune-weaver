// Rune Weaver Dashboard — Component tests for ChatView sending turns and token display.

import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ChatView from "./ChatView";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
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
});
