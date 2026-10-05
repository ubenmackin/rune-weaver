// Rune Weaver Dashboard — Component tests for ChatView turns, history drawer, and status footer.
//
// Covers sending turns and token display plus the handheld matrix: the session
// history drawer stays closed on narrow viewports and inline on wide ones,
// dismissing via backdrop, Escape, or session select, while the footer
// collapses to a glanceable line on mobile and expands to full metrics. Also
// pins the transcript's batched write-review hydration: every rendered
// files.write card hydrates through one review-status request per card set.
// The persona describe pins the text-only identity header contract (muted name
// with no avatar image when a persona exists, today's UI otherwise) and
// ChatView's single-writer claim over the avatar activity clock and working
// flag.

import { act, fireEvent, render, renderHook, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ChatView, { messageListHasActiveSelection } from "./ChatView";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { resetSharedRunsForTesting, useRunningRuns } from "../hooks/useRunningRuns";
import {
  peekPersonaSignals,
  publishPersonaFromSettings,
  resetPersonaSignalsForTesting,
} from "./PersonaAvatar";
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

  it("returns false for null or empty lists with no active selection", async () => {
    // Null lists and empty containers never count as an active selection,
    // and collapsed or out-of-list ranges stay non-suppressing.
    window.getSelection()?.removeAllRanges();
    expect(messageListHasActiveSelection(null)).toBe(false);
    const empty = document.createElement("div");
    document.body.appendChild(empty);
    try {
      expect(messageListHasActiveSelection(empty)).toBe(false);
      const caret = document.createRange();
      caret.selectNodeContents(empty);
      caret.collapse(true);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(caret);
      expect(messageListHasActiveSelection(empty)).toBe(false);
    } finally {
      window.getSelection()?.removeAllRanges();
      empty.remove();
    }
    const list = document.createElement("div");
    const outside = document.createElement("div");
    outside.textContent = "outside text";
    document.body.appendChild(list);
    document.body.appendChild(outside);
    try {
      const outer = document.createRange();
      outer.selectNodeContents(outside);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(outer);
      expect(messageListHasActiveSelection(list)).toBe(false);
      list.textContent = "   ";
      const whitespace = document.createRange();
      whitespace.selectNodeContents(list);
      sel?.removeAllRanges();
      sel?.addRange(whitespace);
      expect(messageListHasActiveSelection(list)).toBe(false);
    } finally {
      window.getSelection()?.removeAllRanges();
      list.remove();
      outside.remove();
    }
  });

  it("suppresses auto-scroll across 20 rapid deltas while a selection is active", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await user.type(screen.getByLabelText("Chat input"), "selection lock");
      await user.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => {
        expect(capture.sentFrames.length).toBe(1);
      });
      const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
        .sessionID;
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "delta",
        delta: "streaming base text ",
        sessionID: turnSID,
      });
      await waitFor(() => {
        expect(screen.getByText(/streaming base text/)).toBeInTheDocument();
      });
      const list = document.querySelector(".message-list") as HTMLElement;
      expect(list).not.toBeNull();
      const target =
        screen.getByText(/streaming base text/).closest(".message-text") ?? list;
      const range = document.createRange();
      range.selectNodeContents(target as Node);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
      expect(messageListHasActiveSelection(list)).toBe(true);
      scrollSpy.mockClear();
      for (let i = 0; i < 20; i++) {
        await dispatchFrameOrThrow(capture.onMessage, {
          type: "delta",
          delta: ` chunk-${i} `,
          sessionID: turnSID,
        });
      }
      expect(scrollSpy).not.toHaveBeenCalled();
      const afterSel = window.getSelection();
      expect(afterSel?.rangeCount).toBe(1);
      expect(afterSel?.isCollapsed).toBe(false);
      expect(list.contains(afterSel?.anchorNode ?? null)).toBe(true);
      expect(list.contains(afterSel?.focusNode ?? null)).toBe(true);
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
  });

  it("allows auto-scroll when the caret is collapsed", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await user.type(screen.getByLabelText("Chat input"), "caret check");
      await user.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => {
        expect(capture.sentFrames.length).toBe(1);
      });
      const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
        .sessionID;
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "delta",
        delta: "caret base text ",
        sessionID: turnSID,
      });
      await waitFor(() => {
        expect(screen.getByText(/caret base text/)).toBeInTheDocument();
      });
      const list = document.querySelector(".message-list") as HTMLElement;
      const caret = document.createRange();
      caret.selectNodeContents(list);
      caret.collapse(true);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(caret);
      expect(messageListHasActiveSelection(list)).toBe(false);
      scrollSpy.mockClear();
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "delta",
        delta: " more after caret ",
        sessionID: turnSID,
      });
      await waitFor(() => {
        expect(screen.getByText(/more after caret/)).toBeInTheDocument();
      });
      expect(scrollSpy).toHaveBeenCalled();
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
  });

  it("preserves the scrolled-up lock without a selection", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await user.type(screen.getByLabelText("Chat input"), "history review");
      await user.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => {
        expect(capture.sentFrames.length).toBe(1);
      });
      const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
        .sessionID;
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "delta",
        delta: "history base ",
        sessionID: turnSID,
      });
      await waitFor(() => {
        expect(screen.getByText(/history base/)).toBeInTheDocument();
      });
      const list = document.querySelector(".message-list") as HTMLElement;
      window.getSelection()?.removeAllRanges();
      expect(messageListHasActiveSelection(list)).toBe(false);
      Object.defineProperty(list, "scrollHeight", {
        value: 2000,
        configurable: true,
      });
      Object.defineProperty(list, "scrollTop", { value: 0, configurable: true });
      Object.defineProperty(list, "clientHeight", {
        value: 500,
        configurable: true,
      });
      fireEvent.scroll(list);
      scrollSpy.mockClear();
      for (let i = 0; i < 5; i++) {
        await dispatchFrameOrThrow(capture.onMessage, {
          type: "delta",
          delta: ` locked-${i} `,
          sessionID: turnSID,
        });
      }
      expect(scrollSpy).not.toHaveBeenCalled();
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
  });

  it("lands own sends in view after a scrolled-up lock", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      const list = document.querySelector(".message-list") as HTMLElement;
      Object.defineProperty(list, "scrollHeight", {
        value: 2000,
        configurable: true,
      });
      Object.defineProperty(list, "scrollTop", { value: 0, configurable: true });
      Object.defineProperty(list, "clientHeight", {
        value: 500,
        configurable: true,
      });
      fireEvent.scroll(list);
      scrollSpy.mockClear();
      window.getSelection()?.removeAllRanges();
      await user.type(screen.getByLabelText("Chat input"), "own send lands");
      await user.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => {
        expect(screen.getByText("own send lands")).toBeInTheDocument();
      });
      expect(scrollSpy).toHaveBeenCalled();
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
  });

  it("keeps the selection range alive across live updates with stable keys", async () => {
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await user.type(screen.getByLabelText("Chat input"), "stable keys");
      await user.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => {
        expect(capture.sentFrames.length).toBe(1);
      });
      const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
        .sessionID;
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "delta",
        delta: "stable base text ",
        sessionID: turnSID,
      });
      await waitFor(() => {
        expect(screen.getByText(/stable base text/)).toBeInTheDocument();
      });
      const list = document.querySelector(".message-list") as HTMLElement;
      const liveTextBefore = document.querySelector(
        ".streaming-bubble .message-text",
      );
      expect(liveTextBefore).not.toBeNull();
      const beforeText = (liveTextBefore as HTMLElement).textContent;
      const range = document.createRange();
      range.selectNodeContents(liveTextBefore as Node);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
      const selectedBefore = window.getSelection()?.toString();
      expect(selectedBefore?.trim().length).toBeGreaterThan(0);
      scrollSpy.mockClear();
      for (let i = 0; i < 5; i++) {
        await dispatchFrameOrThrow(capture.onMessage, {
          type: "delta",
          delta: ` live-${i} `,
          sessionID: turnSID,
        });
      }
      expect(scrollSpy).not.toHaveBeenCalled();
      const liveTextAfter = document.querySelector(
        ".streaming-bubble .message-text",
      );
      expect(liveTextAfter).toBe(liveTextBefore);
      expect((liveTextAfter as HTMLElement).textContent).toContain(
        (beforeText ?? "").trim().slice(0, 6),
      );
      const afterSel = window.getSelection();
      expect(afterSel?.rangeCount).toBe(1);
      expect(list.contains(afterSel?.anchorNode ?? null)).toBe(true);
      expect(afterSel?.toString().trim().length).toBeGreaterThan(0);
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
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
    // The centered toast is the only signal that live updates paused while
    // drafts stay usable, so a dropped socket must surface it without locking
    // input or shifting the header layout.
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
    const toast = screen.getByTestId("chat-reconnecting");
    expect(toast).toHaveClass("connection-toast");
    expect(toast).toHaveAttribute("role", "alert");
    expect(toast).toHaveAttribute("aria-live", "assertive");
    expect(
      within(toast).getByText(
        "Live updates paused — reconnecting to server… Chat still sends; streaming will resume.",
      ),
    ).toBeInTheDocument();
    expect(screen.getByTestId("chat-reconnect-retry")).toBeInTheDocument();
    expect(screen.getByTestId("chat-reconnect-dismiss")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Retry now" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Dismiss" })).toBeInTheDocument();
    expect(screen.getByLabelText("Chat input")).not.toBeDisabled();
    // The header keeps its compact title row while the outage is surfaced as
    // a fixed overlay, so no inline pill may remain inside the title.
    expect(
      document.querySelector(".chat-panel-title .connection-status-pill"),
    ).toBeNull();
    expect(
      document.querySelector(".chat-panel-header [data-testid='chat-reconnecting']"),
    ).toBeNull();
  });

  it("retry forces an immediate redial and clears the banner on open", async () => {
    // A visible retry must bypass the idle backoff so the view rejoins live
    // without waiting out the scheduled timer, and recovery clears the toast
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
    expect(screen.getByTestId("chat-reconnecting")).toHaveClass(
      "connection-toast",
    );

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
    // Dismiss is a per-outage snooze: it hides the toast for the current drop
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
    // Wait for the toast to mount before dismissing so the click never races
    // the close notification.
    await screen.findByTestId("chat-reconnecting");
    expect(screen.getByTestId("chat-reconnecting")).toHaveClass(
      "connection-toast",
    );
    expect(screen.getByTestId("chat-reconnect-dismiss")).toBeInTheDocument();

    await user.click(screen.getByTestId("chat-reconnect-dismiss"));
    await waitFor(() => {
      expect(screen.queryByTestId("chat-reconnecting")).not.toBeInTheDocument();
    });

    // A fresh drop resets the snooze, so the toast returns for the next outage.
    await act(async () => {
      instances[0].close();
    });
    await screen.findByTestId("chat-reconnecting");
    expect(screen.getByTestId("chat-reconnecting")).toBeInTheDocument();
    expect(screen.getByTestId("chat-reconnecting")).toHaveClass(
      "connection-toast",
    );
  });

  it("renders the reconnect notice outside the header as a centered toast", async () => {
    // The title row must keep its compact shape during an outage, so the
    // notice mounts as a fixed overlay sibling before the message list with
    // no inline pill left behind in the header.
    const { capture, instances, CountingSocket } = makeCountingSocket();
    vi.stubGlobal("WebSocket", CountingSocket);
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));

    render(<ChatView />);

    await waitFor(() => expect(capture.onMessage).not.toBeNull());

    await act(async () => {
      instances[0].close();
    });
    await screen.findByTestId("chat-reconnecting");

    const toast = screen.getByTestId("chat-reconnecting");
    expect(toast.tagName.toLowerCase()).toBe("div");
    expect(toast).toHaveClass("connection-toast");
    expect(
      within(toast).getByText(
        "Live updates paused — reconnecting to server… Chat still sends; streaming will resume.",
      ),
    ).toBeInTheDocument();
    expect(document.querySelector(".connection-status-pill")).toBeNull();
    const header = document.querySelector(".chat-panel-header");
    expect(header).not.toBeNull();
    expect(
      within(header as HTMLElement).queryByTestId("chat-reconnecting"),
    ).toBeNull();
    const messageList = document.querySelector(".message-list");
    expect(messageList).not.toBeNull();
    expect(
      toast.compareDocumentPosition(messageList as Node) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
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

  it("restores persisted history plus session messages after reload", async () => {
    // A reload must merge the stored stack with the server user texts so prior
    // sends stay recallable without resending; the merged order stays
    // oldest-first with the newest server text on the first Up.
    const sessionID = "reload-history-aaaa-1111";
    localStorage.setItem("rw_active_session_id", sessionID);
    localStorage.setItem(
      `rw_input_history_${sessionID}`,
      JSON.stringify(["persisted older"]),
    );
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({ sessions: [], count: 0 });
        }
        if (typeof input === "string" && input.endsWith("/tool-actions")) {
          return jsonResponse({ sessionID, actions: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionID,
            title: "Reload Session",
            messages: [
              { id: "u1", role: "user", content: "server older", createdAt: now },
              { id: "a1", role: "assistant", content: "ack older", createdAt: now },
              { id: "u2", role: "user", content: "server newer", createdAt: now },
              { id: "a2", role: "assistant", content: "ack newer", createdAt: now },
            ],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          return jsonResponse({ runs: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("server newer")).toBeInTheDocument();
    });
    const inputEl = screen.getByLabelText("Chat input") as HTMLTextAreaElement;
    expect(inputEl).toHaveValue("");
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("server newer");
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("server older");
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("persisted older");
  });

  it("records steered inputs in the recall stack", async () => {
    // Steering feeds the same recall stack as sends so mid-turn guidance stays
    // recallable after the turn settles; the newest entry must be the steer.
    const user = userEvent.setup();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await user.type(screen.getByLabelText("Chat input"), "start long task");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(1);
    });
    const turnSID = (JSON.parse(capture.sentFrames[0]) as { sessionID?: string })
      .sessionID;
    const inputEl = screen.getByLabelText("Chat input") as HTMLTextAreaElement;
    await user.type(inputEl, "please focus on tests");
    await user.click(screen.getByRole("button", { name: "Steer turn" }));
    await waitFor(() => {
      expect(capture.sentFrames.length).toBe(2);
    });
    expect(inputEl).toHaveValue("");
    expect(screen.getByText("please focus on tests")).toBeInTheDocument();
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "steered done",
      sessionID: turnSID,
      toolActions: [],
      totalTokens: 10,
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
    fireEvent.keyDown(inputEl, { key: "ArrowUp" });
    expect(inputEl).toHaveValue("please focus on tests");
  });

  it("degrades a corrupt persisted payload to empty without throwing", async () => {
    // A tampered history key must degrade to an empty stack so recall stays
    // inert instead of throwing or surfacing stale text.
    const sessionID = "corrupt-history-aaaa-1111";
    localStorage.setItem("rw_active_session_id", sessionID);
    localStorage.setItem(`rw_input_history_${sessionID}`, "not-json{{{");
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({ sessions: [], count: 0 });
        }
        if (typeof input === "string" && input.endsWith("/tool-actions")) {
          return jsonResponse({ sessionID, actions: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionID,
            title: "Corrupt Session",
            messages: [],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          return jsonResponse({ runs: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).toBeInTheDocument();
    });
    const inputEl = screen.getByLabelText("Chat input") as HTMLTextAreaElement;
    expect(inputEl).toHaveValue("");
    expect(() => fireEvent.keyDown(inputEl, { key: "ArrowUp" })).not.toThrow();
    expect(inputEl).toHaveValue("");
  });
});

describe("Inline approval pending assessment", () => {
  const pendingSessionID = "pending-assessment-session-1";
  const pendingID = "approval-pending-chat-1";

  function pendingApproval(): Record<string, unknown> {
    return {
      id: pendingID,
      toolName: "email.send",
      description: "Send email to ops",
      intent: "Notifying ops of deploy",
      assessment: null,
      input: {
        toolName: "email.send",
        argumentsJSON: '{"to":"ops@example.com"}',
        callID: "call-pending-chat-1",
      },
      suggestedDurations: ["thisTime"],
      sessionID: pendingSessionID,
    };
  }

  function stubPendingApprovalsFetch(
    approvals: Array<Record<string, unknown>>,
  ): void {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, _init?: RequestInit) => {
        if (typeof input === "string" && input.includes("/decide")) {
          return jsonResponse({ id: pendingID, approved: true, duration: "thisTime" });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals, count: approvals.length });
        }
        return jsonResponse({});
      }),
    );
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
    localStorage.setItem("rw_active_session_id", pendingSessionID);
  });

  it("renders pending badge with spinner copy and enabled controls", async () => {
    stubPendingApprovalsFetch([pendingApproval()]);
    render(<ChatView />);
    await waitFor(() => {
      expect(
        screen.getByTestId(`approval-assessment-pending-${pendingID}`),
      ).toBeInTheDocument();
    });
    const pending = screen.getByTestId(`approval-assessment-pending-${pendingID}`);
    expect(pending).toHaveTextContent("Checking safety…");
    expect(
      pending.querySelector(
        ".approval-assessment-pending, .approval-assessment-pending-spinner",
      ),
    ).not.toBeNull();
    // Valued badge, outcome, and warnings stay hidden while pending.
    expect(
      screen.queryByTestId(`approval-severity-${pendingID}`),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Notifying ops of deploy")).toBeInTheDocument();
    expect(screen.getByText("View arguments")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeEnabled();
  });

  it("upserts identical-id approval frames so enrichment swaps pending for valued", async () => {
    stubPendingApprovalsFetch([pendingApproval()]);
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    render(<ChatView />);
    await waitFor(() => {
      expect(
        screen.getByTestId(`approval-assessment-pending-${pendingID}`),
      ).toBeInTheDocument();
    });
    const allowBefore = screen.getByRole("button", { name: "Allow" });
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    // Enrichment rebroadcast for the identical id replaces the stored pending
    // entry: no duplicate banner, pending swaps for the valued copy, and the
    // Allow control persists without remounting.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval",
      request: {
        id: pendingID,
        toolName: "email.send",
        description: "Send email to ops",
        intent: "Notifying ops of deploy",
        assessment: {
          severity: "moderate",
          outcome: "Sends deploy notice to ops",
          warnings: ["External recipient"],
        },
        input: {
          toolName: "email.send",
          argumentsJSON: '{"to":"ops@example.com"}',
          callID: "call-pending-chat-1",
        },
        suggestedDurations: ["thisTime"],
        sessionID: pendingSessionID,
      },
    });
    await waitFor(() => {
      expect(
        screen.getByTestId(`approval-severity-${pendingID}`),
      ).toBeInTheDocument();
    });
    expect(
      screen.queryByTestId(`approval-assessment-pending-${pendingID}`),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Sends deploy notice to ops")).toBeInTheDocument();
    expect(screen.getByText(/External recipient/)).toBeInTheDocument();
    // Static description stays hidden once valued.
    expect(screen.queryByText("Send email to ops")).not.toBeInTheDocument();
    expect(screen.getAllByText("email.send")).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Allow" })).toBe(allowBefore);
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeEnabled();
  });
});

describe("Reloaded-tab reattach without cancel", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  // Shared stub for the reload shape: persisted history plus the run log plus
  // an empty inbox. The run rows drive adoption while history stays the only
  // source for visible messages, so the helper keeps both explicit.
  function stubReloadFetch(
    sessionID: string,
    runs: Array<Record<string, unknown>>,
    messages: Array<Record<string, unknown>>,
    seenFetch: string[],
  ): void {
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        seenFetch.push(typeof input === "string" ? input : String(input));
        if (input === "/sessions") {
          return jsonResponse({
            sessions: [
              {
                id: sessionID,
                title: "Reload Session",
                messageCount: messages.length,
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
            title: "Reload Session",
            messages,
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          return jsonResponse({ runs, count: runs.length });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        if (typeof input === "string" && input === "/chat/cancel") {
          return jsonResponse({ sessionID, cancelled: true });
        }
        return jsonResponse({});
      }),
    );
  }

  it("adopts a running row on reload with zero cancel traffic", async () => {
    // A tab that reloads mid-turn starts idle, yet the server still owns the
    // turn. Adoption must light the pending affordance from run-log evidence
    // alone, without fabricating a reply and without cancelling the owner.
    const sessionA = "reload-adopt-aaaa-1111";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    const seenFetch: string[] = [];
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    stubReloadFetch(
      sessionA,
      [
        {
          id: "run-adopt-1",
          kind: "chat",
          status: "running",
          message: "stuck prompt",
          sessionID: sessionA,
          timestamp: now,
        },
      ],
      [{ id: "u1", role: "user", content: "stuck prompt", createdAt: now }],
      seenFetch,
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: "Cancel turn" }),
      ).toBeInTheDocument();
    });
    expect(screen.getByText("stuck prompt")).toBeInTheDocument();
    // Reattach never dials: no outbound socket frame and no REST cancel for a
    // turn the server still owns.
    expect(capture.sentFrames).toHaveLength(0);
    expect(
      seenFetch.filter((url) => url.includes("/chat/cancel")),
    ).toHaveLength(0);
  });

  it("rebuilds the timeline from broadcast deltas after adoption", async () => {
    // Deltas that arrive after adoption belong to the same server turn, so
    // they must extend the adopted shell instead of starting a second bubble.
    const sessionA = "reload-delta-aaaa-2222";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    const seenFetch: string[] = [];
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    stubReloadFetch(
      sessionA,
      [
        {
          id: "run-delta-1",
          kind: "chat",
          status: "running",
          message: "resume me",
          sessionID: sessionA,
          timestamp: now,
        },
      ],
      [{ id: "u1", role: "user", content: "resume me", createdAt: now }],
      seenFetch,
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: "Cancel turn" }),
      ).toBeInTheDocument();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_start",
      toolName: "email.search",
      callID: "call-reload-1",
      argumentsJSON: '{"limit":1}',
      sessionID: sessionA,
    });
    await waitFor(() => {
      expect(screen.getByText("email.search")).toBeInTheDocument();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "resumed progress ",
      sessionID: sessionA,
    });
    await waitFor(() => {
      expect(screen.getByText(/resumed progress/)).toBeInTheDocument();
    });
    // Still live and still silent on cancel: rebuilding never aborts the owner.
    expect(
      screen.getByRole("button", { name: "Cancel turn" }),
    ).toBeInTheDocument();
    expect(capture.sentFrames).toHaveLength(0);
  });

  it("completes an adopted turn normally on its terminal frame", async () => {
    // The terminal broadcast settles the adopted shell exactly once, leaving
    // one finished message and a free input like any locally started turn.
    const sessionA = "reload-done-aaaa-3333";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    const seenFetch: string[] = [];
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    stubReloadFetch(
      sessionA,
      [
        {
          id: "run-done-1",
          kind: "chat",
          status: "running",
          message: "finish me",
          sessionID: sessionA,
          timestamp: now,
        },
      ],
      [{ id: "u1", role: "user", content: "finish me", createdAt: now }],
      seenFetch,
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: "Cancel turn" }),
      ).toBeInTheDocument();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "halfway ",
      sessionID: sessionA,
    });
    await waitFor(() => {
      expect(screen.getByText(/halfway/)).toBeInTheDocument();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "done",
      text: "halfway done",
      sessionID: sessionA,
      toolActions: [],
      totalTokens: 10,
    });
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
    expect(screen.getByText("halfway done")).toBeInTheDocument();
    expect(screen.getAllByText(/halfway done/)).toHaveLength(1);
    expect(capture.sentFrames).toHaveLength(0);
  });

  it("loads persisted history without adopting when no running row remains", async () => {
    // A turn that finished while away leaves only settled rows, so the reload
    // must render history idly instead of resurrecting a live bubble.
    const sessionA = "reload-settled-aaaa-4444";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    const seenFetch: string[] = [];
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    stubReloadFetch(
      sessionA,
      [
        {
          id: "run-settled-1",
          kind: "chat",
          status: "ok",
          message: "earlier prompt",
          sessionID: sessionA,
          timestamp: now,
          response: "earlier reply",
        },
      ],
      [
        { id: "u1", role: "user", content: "earlier prompt", createdAt: now },
        { id: "a1", role: "assistant", content: "earlier reply", createdAt: now },
      ],
      seenFetch,
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await waitFor(() => {
      expect(screen.getByText("earlier reply")).toBeInTheDocument();
    });
    expect(screen.getByText("earlier prompt")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Cancel turn" }),
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    expect(capture.sentFrames).toHaveLength(0);
    expect(
      seenFetch.filter((url) => url.includes("/chat/cancel")),
    ).toHaveLength(0);
  });

  it("keeps other sessions running turns out of the active view", async () => {
    // Run rows and live frames carry their owner, so a foreign turn must badge
    // elsewhere instead of lighting this session or leaking its deltas here.
    const sessionA = "reload-active-aaaa-5555";
    const sessionB = "reload-other-bbbb-6666";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    const seenFetch: string[] = [];
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    stubReloadFetch(
      sessionA,
      [
        {
          id: "run-other-1",
          kind: "chat",
          status: "running",
          message: "foreign prompt",
          sessionID: sessionB,
          timestamp: now,
        },
      ],
      [{ id: "u1", role: "user", content: "own prompt", createdAt: now }],
      seenFetch,
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await waitFor(() => {
      expect(screen.getByText("own prompt")).toBeInTheDocument();
    });
    // Foreign running evidence never adopts the active view.
    expect(
      screen.queryByRole("button", { name: "Cancel turn" }),
    ).not.toBeInTheDocument();
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "delta",
      delta: "foreign progress",
      sessionID: sessionB,
    });
    expect(screen.queryByText(/foreign progress/)).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Cancel turn" }),
    ).not.toBeInTheDocument();
    expect(capture.sentFrames).toHaveLength(0);
  });

  it("lets explicit cancel abort an adopted turn", async () => {
    // Adoption locks the input like a local send, so the visible Cancel must
    // still reach the same session instead of stranding the adopted owner.
    const user = userEvent.setup();
    const sessionA = "reload-cancel-aaaa-7777";
    localStorage.setItem("rw_active_session_id", sessionA);
    const now = new Date().toISOString();
    const seenFetch: string[] = [];
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    stubReloadFetch(
      sessionA,
      [
        {
          id: "run-cancel-1",
          kind: "chat",
          status: "running",
          message: "abort me",
          sessionID: sessionA,
          timestamp: now,
        },
      ],
      [{ id: "u1", role: "user", content: "abort me", createdAt: now }],
      seenFetch,
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    const cancelBtn = await screen.findByRole("button", {
      name: "Cancel turn",
    });
    await user.click(cancelBtn);
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).toBeInTheDocument();
    });
    // The explicit gesture is the one path allowed to cancel the owner.
    const outbound = capture.sentFrames.map((raw) => {
      try {
        return JSON.parse(raw) as Record<string, unknown>;
      } catch {
        return {};
      }
    });
    expect(outbound.some((frame) => frame.type === "cancel")).toBe(true);
  });
});

describe("Poll-tick selection survival", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
  });

  it("preserves two-line selection across three run-log poll ticks", async () => {
    // Idle history stays selectable while background polls land.
    const sessionID = "poll-tick-selection-aaaa-1111";
    localStorage.setItem("rw_active_session_id", sessionID);
    const now = new Date().toISOString();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({
            sessions: [
              {
                id: sessionID,
                title: "Poll Session",
                messageCount: 2,
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
            title: "Poll Session",
            messages: [
              {
                id: "u1",
                role: "user",
                content: "history prompt",
                createdAt: now,
              },
              {
                id: "a1",
                role: "assistant",
                content: "Alpha line one\n\nBeta line two",
                createdAt: now,
              },
            ],
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
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await waitFor(() => {
        expect(screen.getByText(/Alpha line one/)).toBeInTheDocument();
      });
      expect(screen.getByText(/Beta line two/)).toBeInTheDocument();
      const list = document.querySelector(".message-list") as HTMLElement;
      expect(list).not.toBeNull();
      const messageText = screen
        .getByText(/Alpha line one/)
        .closest(".message-text") as HTMLElement;
      expect(messageText).not.toBeNull();
      expect(messageText.textContent).toContain("Beta line two");
      const range = document.createRange();
      range.selectNodeContents(messageText);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
      expect(messageListHasActiveSelection(list)).toBe(true);
      const selectedBefore = window.getSelection()?.toString() ?? "";
      expect(selectedBefore).toContain("Alpha line one");
      expect(selectedBefore).toContain("Beta line two");
      const paraBefore = document.querySelector("p.chat-p");
      expect(paraBefore).not.toBeNull();
      scrollSpy.mockClear();
      for (let i = 0; i < 3; i++) {
        await dispatchFrameOrThrow(capture.onMessage, {
          type: "run_completed",
          run: {
            id: `run-poll-${i}`,
            kind: "chat",
            status: "ok",
            message: "background work",
            sessionID: `other-session-${i}`,
            timestamp: new Date().toISOString(),
          },
        });
        await act(async () => {
          await Promise.resolve();
        });
      }
      await waitFor(() => {
        expect(screen.getByText(/Alpha line one/)).toBeInTheDocument();
      });
      const selectedAfter = window.getSelection()?.toString() ?? "";
      expect(selectedAfter).toBe(selectedBefore);
      expect(selectedAfter).toContain("Alpha line one");
      expect(selectedAfter).toContain("Beta line two");
      expect(scrollSpy).not.toHaveBeenCalled();
      const paraAfter = document.querySelector("p.chat-p");
      expect(paraAfter).toBe(paraBefore);
      const afterSel = window.getSelection();
      expect(afterSel?.rangeCount).toBe(1);
      expect(afterSel?.isCollapsed).toBe(false);
      expect(list.contains(afterSel?.anchorNode ?? null)).toBe(true);
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
  });

  it("preserves selection string across three identical run-log ticks", async () => {
    // Identical polls keep the cached snapshot with no notify, so an idle
    // history selection never re-renders while background ticks land.
    const sessionID = "poll-identical-aaaa-2222";
    localStorage.setItem("rw_active_session_id", sessionID);
    const now = new Date().toISOString();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/sessions") {
          return jsonResponse({
            sessions: [
              {
                id: sessionID,
                title: "Poll Session",
                messageCount: 2,
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
            title: "Poll Session",
            messages: [
              {
                id: "u1",
                role: "user",
                content: "history prompt",
                createdAt: now,
              },
              {
                id: "a1",
                role: "assistant",
                content: "Alpha line one\n\nBeta line two",
                createdAt: now,
              },
            ],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          // Fresh object per tick with identical values so equality comes
          // from content, never from shared references.
          return jsonResponse({
            runs: [
              {
                id: "run-identical-1",
                kind: "chat",
                status: "ok",
                message: "earlier prompt",
                sessionID: "other-session-identical",
                timestamp: now,
                response: "earlier reply",
                totalTokens: 12,
                durationMs: 345,
              },
            ],
            count: 1,
          });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    const scrollSpy = vi.fn();
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    try {
      render(<ChatView />);
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await waitFor(() => {
        expect(screen.getByText(/Alpha line one/)).toBeInTheDocument();
      });
      expect(screen.getByText(/Beta line two/)).toBeInTheDocument();
      // Settle the shared run cache before selecting so the measured ticks
      // are purely identical with no initial population mixed in.
      const { result } = renderHook(() => useRunningRuns());
      await waitFor(() => {
        expect(result.current.runs).toHaveLength(1);
      });
      const list = document.querySelector(".message-list") as HTMLElement;
      expect(list).not.toBeNull();
      const messageText = screen
        .getByText(/Alpha line one/)
        .closest(".message-text") as HTMLElement;
      expect(messageText).not.toBeNull();
      expect(messageText.textContent).toContain("Beta line two");
      const range = document.createRange();
      range.selectNodeContents(messageText);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
      expect(messageListHasActiveSelection(list)).toBe(true);
      const selectedBefore = window.getSelection()?.toString() ?? "";
      expect(selectedBefore).toContain("Alpha line one");
      expect(selectedBefore).toContain("Beta line two");
      const paraBefore = document.querySelector("p.chat-p");
      expect(paraBefore).not.toBeNull();
      scrollSpy.mockClear();
      // Drive three identical poll ticks through the shared poller; each
      // refresh fetches the same run row with fresh identities.
      const snapshotBefore = result.current.runs;
      const refresh = result.current.refresh;
      for (let i = 0; i < 3; i++) {
        await act(async () => {
          refresh();
          await Promise.resolve();
        });
        await act(async () => {
          await new Promise((resolve) => setTimeout(resolve, 0));
        });
      }
      await waitFor(() => {
        expect(screen.getByText(/Alpha line one/)).toBeInTheDocument();
      });
      // Identical ticks never swap the snapshot, so the view never re-renders.
      expect(result.current.runs).toBe(snapshotBefore);
      const selectedAfter = window.getSelection()?.toString() ?? "";
      expect(selectedAfter).toBe(selectedBefore);
      expect(selectedAfter).toContain("Alpha line one");
      expect(selectedAfter).toContain("Beta line two");
      expect(scrollSpy).not.toHaveBeenCalled();
      const paraAfter = document.querySelector("p.chat-p");
      expect(paraAfter).toBe(paraBefore);
      const afterSel = window.getSelection();
      expect(afterSel?.rangeCount).toBe(1);
      expect(afterSel?.isCollapsed).toBe(false);
      expect(list.contains(afterSel?.anchorNode ?? null)).toBe(true);
    } finally {
      window.getSelection()?.removeAllRanges();
      delete (window.HTMLElement.prototype as unknown as Record<string, unknown>)
        .scrollIntoView;
    }
  });
});

describe("ChatView goal chip", () => {
  const GOAL_ID = "11111111-1111-1111-1111-111111111111";
  const SESSION_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";

  function goalSnapshot(overrides: Record<string, unknown> = {}) {
    return {
      id: GOAL_ID,
      title: "field guide",
      statement: "Publish the field guide",
      status: "active",
      progress: { done: 1, total: 4 },
      stepIntervalMinutes: 1440,
      nextDueAt: null,
      originSessionId: null,
      createdAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(),
      ...overrides,
    };
  }

  // Routes the session detail, tool-actions, goal detail, and linked-run reads
  // a mounted ChatView issues so each case only overrides what it probes.
  function installFetch(sessionGoalId: string | null) {
    const fetchMock = vi.fn(async (input: string) => {
      if (input === `/sessions/${SESSION_ID}`) {
        return jsonResponse({
          id: SESSION_ID,
          title: "goal chat",
          messages: [],
          goalId: sessionGoalId,
        });
      }
      if (input.includes("/tool-actions")) {
        return jsonResponse({ sessionID: SESSION_ID, actions: [], count: 0 });
      }
      if (input === `/goals/${GOAL_ID}`) {
        return jsonResponse({
          goal: goalSnapshot(),
          steps: [],
          events: [],
        });
      }
      if (input.startsWith("/runs")) {
        return jsonResponse({ runs: [], count: 0 });
      }
      return jsonResponse({ sessions: [], count: 0 });
    });
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
    // A stored active id keeps the mount out of the local-draft branch so the
    // session detail (and its goal link) is actually fetched.
    localStorage.setItem("rw_active_session_id", SESSION_ID);
  });

  it("hides the goal chip when the active session has no goal link", async () => {
    const fetchMock = installFetch(null);
    render(<ChatView />);
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url]) => url === `/sessions/${SESSION_ID}`,
        ),
      ).toBe(true);
    });
    expect(screen.queryByTestId("session-goal-chip")).not.toBeInTheDocument();
  });

  it("shows the goal chip when the active session carries a goal link", async () => {
    installFetch(GOAL_ID);
    render(<ChatView />);
    const chip = await screen.findByTestId("session-goal-chip");
    expect(chip).toHaveTextContent("Goal Tracker");
    expect(chip).toHaveAttribute("title", expect.stringContaining("field guide"));
    expect(chip).toHaveTextContent("1/4");
  });

  it("refreshes the chip progress on a matching goal_updated frame", async () => {
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    installFetch(GOAL_ID);
    render(<ChatView />);
    const chip = await screen.findByTestId("session-goal-chip");
    expect(chip).toHaveTextContent("1/4");
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "goal_updated",
      goal: goalSnapshot({ progress: { done: 2, total: 4 } }),
    });
    await waitFor(() => {
      expect(screen.getByTestId("session-goal-chip")).toHaveTextContent("2/4");
    });
  });

  it("opens the goal drawer from the chip and restores focus on Escape", async () => {
    installFetch(GOAL_ID);
    const user = userEvent.setup();
    render(<ChatView />);
    const chip = await screen.findByTestId("session-goal-chip");
    await user.click(chip);
    expect(await screen.findByTestId("goal-drawer")).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => {
      expect(screen.queryByTestId("goal-drawer")).not.toBeInTheDocument();
    });
    expect(document.activeElement).toBe(chip);
  });
});

// The chat transcript hydrates every rendered write card through one batched
// review-status read per card set, so a transcript with several write cards
// never performs one request per card.
describe("ChatView batched write-review hydration", () => {
  const SESSION_ID = "batch-write-session-1";
  const FIRST_PATH = "/tmp/batch-first.txt";
  const SECOND_PATH = "/tmp/batch-second.txt";

  function stagedWriteAction(
    callID: string,
    path: string,
  ): Record<string, unknown> {
    return {
      toolName: "files.write",
      callID,
      argumentsJSON: "{}",
      result: {
        toolCallID: callID,
        content: JSON.stringify({
          status: "staged",
          path,
          backupPath: null,
          diff: "@@ -1 +1 @@\n-old\n+new\n",
          additions: 1,
          deletions: 1,
          message: "staged",
        }),
        isError: false,
      },
    };
  }

  // Routes the session detail, tool-actions, review-status, and sibling reads
  // a mounted ChatView issues, returning the fetch mock so each case can count
  // the batch requests. Explicit input/init params keep mock.calls typed as a
  // 2-tuple so the request-body assertion below typechecks.
  function installFetch() {
    const fetchMock = vi.fn(async (input: string, _init?: RequestInit) => {
      if (input === "/sessions") {
        return jsonResponse({ sessions: [], count: 0 });
      }
      if (input.endsWith("/tool-actions")) {
        return jsonResponse({
          sessionID: SESSION_ID,
          actions: [
            {
              messageID: "m-write",
              actions: [
                stagedWriteAction("call-write-1", FIRST_PATH),
                stagedWriteAction("call-write-2", SECOND_PATH),
              ],
            },
          ],
          count: 1,
        });
      }
      if (input === `/sessions/${SESSION_ID}`) {
        return jsonResponse({
          id: SESSION_ID,
          title: "batch session",
          messages: [
            {
              id: "m-write",
              role: "assistant",
              content: "wrote two files",
              createdAt: new Date().toISOString(),
            },
          ],
        });
      }
      if (input === "/files/review-status") {
        return jsonResponse({
          stagedStates: { [FIRST_PATH]: "accepted", [SECOND_PATH]: "pending" },
          liveStates: {},
        });
      }
      if (input.startsWith("/approvals")) {
        return jsonResponse({ approvals: [], count: 0 });
      }
      if (input.startsWith("/runs")) {
        return jsonResponse({ runs: [], count: 0 });
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    localStorage.clear();
    localStorage.setItem("rw_active_session_id", SESSION_ID);
  });

  it("hydrates every write card with one batched review-status request", async () => {
    const fetchMock = installFetch();
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("batch-first.txt")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });

    // Both kind/path entries rode one request for this surface's card set.
    const reviewCalls = fetchMock.mock.calls.filter(
      ([url]) => url === "/files/review-status",
    );
    expect(reviewCalls).toHaveLength(1);
    const body = JSON.parse(
      String(reviewCalls[0][1]?.body),
    ) as { paths: string[] };
    expect([...body.paths].sort()).toEqual([FIRST_PATH, SECOND_PATH].sort());

    // Each card read its own entry from the shared response: the accepted card
    // settles with no controls while the pending sibling stays actionable.
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "Accept" })).toHaveLength(1);
    expect(screen.getAllByRole("button", { name: "Discard" })).toHaveLength(1);
  });
});

describe("ChatView dashboard integration props", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
  });

  it("switches session when targetSessionId prop is passed", async () => {
    const targetId = "11111111-2222-3333-4444-555555555555";
    const onClearTarget = vi.fn();

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes(`/sessions/${targetId}`)) {
        return jsonResponse({
          id: targetId,
          messages: [
            {
              id: "msg-1",
              role: "user",
              content: "Existing session text",
              createdAt: "2026-10-03T10:00:00Z",
            },
          ],
        });
      }
      return jsonResponse({ sessions: [], messages: [] });
    });
    vi.stubGlobal("fetch", fetchMock);

    const { rerender } = render(
      <ChatView targetSessionId={null} onClearTargetSessionId={onClearTarget} />,
    );

    rerender(
      <ChatView
        targetSessionId={targetId}
        onClearTargetSessionId={onClearTarget}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Existing session text")).toBeInTheDocument();
      expect(onClearTarget).toHaveBeenCalled();
    });
  });

  it("auto-starts new session and dispatches when initialPrompt prop is passed", async () => {
    const onClearPrompt = vi.fn();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "/chat") {
        return jsonResponse({
          text: "Response to prompt",
          sessionID: "auto-started-sess",
          totalTokens: 100,
        });
      }
      return jsonResponse({ sessions: [], messages: [] });
    });
    vi.stubGlobal("fetch", fetchMock);

    render(
      <ChatView
        initialPrompt="Ask RuneWeaver to fix bugs"
        onClearInitialPrompt={onClearPrompt}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Ask RuneWeaver to fix bugs")).toBeInTheDocument();
      expect(onClearPrompt).toHaveBeenCalled();
    });
  });

  it("does not inherit previous session tokens when auto-starting with initialPrompt", async () => {
    const onClearPrompt = vi.fn();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({ sessions: [], messages: [] })));

    // Seed prior session with tokens
    localStorage.setItem("rw_active_session_id", "prior-session");
    localStorage.setItem("rw_session_tokens_prior-session", "50000");

    const { rerender } = render(
      <ChatView
        initialPrompt=""
        onClearInitialPrompt={onClearPrompt}
      />,
    );

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    // Pass initialPrompt to trigger handleStartNewSessionWithPrompt
    rerender(
      <ChatView
        initialPrompt="Analyze codebase"
        onClearInitialPrompt={onClearPrompt}
      />,
    );

    await waitFor(() => {
      expect(capture.sentFrames.length).toBeGreaterThan(0);
    });

    const sentFrame = JSON.parse(capture.sentFrames[capture.sentFrames.length - 1]) as {
      text?: string;
      sessionID?: string;
    };
    expect(sentFrame.text).toBe("Analyze codebase");
    const freshSessionID = sentFrame.sessionID;
    expect(freshSessionID).not.toBe("prior-session");

    // Simulate streaming turn_tokens for the new session
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "turn_tokens",
      sessionID: freshSessionID,
      turnTotalTokens: 42,
      roundIndex: 0,
      roundTokens: 42,
    });

    // Verify session tokens renders 42 tokens (fresh session base 0 + turn 42), NOT 50,042
    await waitFor(() => {
      const sessionMetric = document.querySelector(".status-bar-item--session") as HTMLElement;
      expect(sessionMetric).not.toBeNull();
      expect(within(sessionMetric).getByText("42 tokens")).toBeInTheDocument();
      expect(screen.queryByText(/50,?042/)).not.toBeInTheDocument();
    });
  });
});

describe("ChatView message copy buttons", () => {
  it("renders copy button on both human and agent chat bubbles and copies text", async () => {
    const user = userEvent.setup();
    const sessionID = "session-copy-test";
    const now = new Date().toISOString();

    const writeTextMock = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: {
        writeText: writeTextMock,
      },
      writable: true,
      configurable: true,
    });

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (typeof input === "string" && input.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionID,
            title: "Copy Test Session",
            messages: [
              { id: "msg-user-1", role: "user", content: "How do I build the app?", createdAt: now },
              { id: "msg-agent-1", role: "assistant", content: "Run `make build` to compile.", createdAt: now },
            ],
            createdAt: now,
            updatedAt: now,
            source: "chat",
          });
        }
        if (typeof input === "string" && input.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        if (typeof input === "string" && input.startsWith("/runs")) {
          return jsonResponse({ runs: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );

    render(<ChatView targetSessionId={sessionID} />);

    await waitFor(() => {
      expect(screen.getByText("How do I build the app?")).toBeInTheDocument();
      expect(screen.getByText("make build")).toBeInTheDocument();
    });

    const copyBtns = screen.getAllByRole("button", { name: "Copy message" });
    expect(copyBtns.length).toBe(2);

    await user.click(copyBtns[0]);
    expect(writeTextMock).toHaveBeenCalledWith("How do I build the app?");
    expect(screen.getByRole("button", { name: "Copied message to clipboard" })).toBeInTheDocument();
    expect(screen.getByText("Copied")).toBeInTheDocument();

    await user.click(copyBtns[1]);
    expect(writeTextMock).toHaveBeenCalledWith("Run `make build` to compile.");
  });
});

describe("ChatView persona header", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    resetSharedRunsForTesting();
    // The persona store is a module singleton; every identity test starts from
    // a detached snapshot so the fallback checks prove real absence.
    resetPersonaSignalsForTesting();
    localStorage.clear();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ sessions: [], count: 0 })),
    );
  });

  it("shows the persona name as text identity with no avatar image", async () => {
    publishPersonaFromSettings({
      assistant_name: "Zephyra",
      tone: "concise",
      style: "",
      user_name: "",
      avatar: "cyan",
    });
    render(<ChatView />);
    const identity = await screen.findByTestId("chat-persona-identity");
    expect(within(identity).getByText("Zephyra")).toBeInTheDocument();
    // Text identity only: the greeting cluster owns the app's sole avatar
    // image, so the chat header carries the muted name span alone.
    expect(identity.querySelector("img")).toBeNull();
    expect(identity.querySelector(".persona-avatar")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
    // The session title stays primary; the identity sits beside it, not over it.
    expect(screen.getByRole("heading", { name: "Chat" })).toBeInTheDocument();
  });

  it("renders today's header verbatim when the persona is absent", async () => {
    publishPersonaFromSettings(undefined);
    render(<ChatView />);
    await screen.findByRole("heading", { name: "Chat" });
    expect(screen.queryByTestId("chat-persona-identity")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
  });

  it("is the single activity writer: a REST turn completion advances the shared clock", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/chat") {
          return jsonResponse({
            text: "done",
            sessionID: "s1",
            toolActions: [],
          });
        }
        return jsonResponse({ sessions: [], count: 0 });
      }),
    );
    expect(peekPersonaSignals().lastActivityAtMs).toBe(0);
    render(<ChatView />);
    await user.type(screen.getByLabelText("Chat input"), "hi");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("done")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(peekPersonaSignals().lastActivityAtMs).toBeGreaterThan(0);
    });
    // The turn settled, so the working mirror clears with it.
    expect(peekPersonaSignals().working).toBe(false);
  });

  it("advances the activity clock on WS run frames, including other sessions' runs", async () => {
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    expect(peekPersonaSignals().lastActivityAtMs).toBe(0);
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: {
        id: "r1",
        kind: "goal",
        status: "ok",
        sessionID: "other-session",
      },
    });
    // A run frame from any session is agent traffic: the clock moves before
    // the ownership routing below can ignore the frame.
    expect(peekPersonaSignals().lastActivityAtMs).toBeGreaterThan(0);
  });

  it("publishes the working flag while a run is in flight and clears it when it settles", async () => {
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    render(<ChatView />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_started",
      run: {
        id: "r1",
        kind: "goal",
        status: "running",
        sessionID: "other-session",
      },
    });
    await waitFor(() => {
      expect(peekPersonaSignals().working).toBe(true);
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: {
        id: "r1",
        kind: "goal",
        status: "ok",
        sessionID: "other-session",
      },
    });
    await waitFor(() => {
      expect(peekPersonaSignals().working).toBe(false);
    });
  });
});

