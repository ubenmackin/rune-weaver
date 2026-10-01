// Rune Weaver Dashboard — Component tests for honest pending indicators.
// Covers approvals filtering by session, the session/run pending badges, the
// no-ghost-chip narration rule, debug identifiers in the run detail modal, and
// the run detail's surface-batched write-review hydration (one review-status
// request per rendered card set, with each card reading its own entry).

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ChatView, { approvalsForSession } from "./ChatView";
import RunLogViewer, { runPendingApprovals } from "./RunLogViewer";
import RunDetailModal from "./RunDetailModal";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
} from "../test-utils/mockWebSocket";
import type { PermissionRequest, RunLogEntry, ToolAction } from "../api";

describe("approvals filtering by session", () => {
  it("keeps only approvals owned by the session", () => {
    // Typed fixtures keep the inbox contract honest: mismatched shapes fail
    // typecheck instead of hiding behind a cast.
    const approvals: PermissionRequest[] = [
      {
        id: "a1",
        toolName: "email.send",
        description: "Send",
        input: { toolName: "email.send", argumentsJSON: "{}", callID: "c1" },
        suggestedDurations: ["thisTime"],
        sessionID: "Session-ABC",
      },
      {
        id: "a2",
        toolName: "email.send",
        description: "Send",
        input: { toolName: "email.send", argumentsJSON: "{}", callID: "c2" },
        suggestedDurations: ["thisTime"],
        sessionID: "other-session",
      },
      {
        id: "a3",
        toolName: "email.send",
        description: "Send",
        input: { toolName: "email.send", argumentsJSON: "{}", callID: "c3" },
        suggestedDurations: ["thisTime"],
      },
    ];
    // Matching is case-insensitive so uppercase engine IDs still correlate.
    const matched = approvalsForSession(approvals, "session-abc");
    expect(matched.map((item) => item.id)).toEqual(["a1"]);
    expect(approvalsForSession(approvals, "missing")).toEqual([]);
  });

  it("matches runs by session or overlapping call identifiers", () => {
    const run: RunLogEntry = {
      id: "run-1",
      kind: "chat",
      status: "ok",
      message: "hi",
      timestamp: new Date(0).toISOString(),
      sessionID: "sess-1",
      toolActions: [
        {
          toolName: "email.send",
          callID: "call-gated",
          argumentsJSON: "{}",
          result: null,
        },
      ],
    };
    const bySession: PermissionRequest[] = [
      {
        id: "ap-1",
        toolName: "email.send",
        description: "",
        input: { toolName: "email.send", argumentsJSON: "{}", callID: "other" },
        suggestedDurations: [],
        sessionID: "sess-1",
      },
    ];
    const byCall: PermissionRequest[] = [
      {
        id: "ap-2",
        toolName: "email.send",
        description: "",
        input: { toolName: "email.send", argumentsJSON: "{}", callID: "call-gated" },
        suggestedDurations: [],
      },
    ];
    const unrelated: PermissionRequest[] = [
      {
        id: "ap-3",
        toolName: "email.send",
        description: "",
        input: { toolName: "email.send", argumentsJSON: "{}", callID: "nope" },
        suggestedDurations: [],
        sessionID: "other",
      },
    ];
    expect(runPendingApprovals(run, bySession)).toHaveLength(1);
    expect(runPendingApprovals(run, byCall)).toHaveLength(1);
    expect(runPendingApprovals(run, unrelated)).toHaveLength(0);
  });
});

describe("session pending badge", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    localStorage.clear();
  });

  it("shows an amber pending indicator for the active session only", async () => {
    const sessionID = "11111111-1111-4111-8111-111111111111";
    localStorage.setItem("rw_active_session_id", sessionID);
    const approvalsPayload = {
      approvals: [
        {
          id: "22222222-2222-4222-8222-222222222222",
          toolName: "email.send",
          description: "Send email",
          input: {
            toolName: "email.send",
            argumentsJSON: "{}",
            callID: "call-pending-1",
          },
          suggestedDurations: ["thisTime"],
          sessionID,
        },
      ],
      count: 1,
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.startsWith("/approvals")) {
          return jsonResponse(approvalsPayload);
        }
        if (typeof url === "string" && url.startsWith("/sessions/")) {
          return jsonResponse({ messages: [] });
        }
        if (typeof url === "string" && url.startsWith("/sessions")) {
          return jsonResponse({ sessions: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByTestId("session-pending-badge")).toBeInTheDocument();
    });
    expect(screen.getByText(/Pending approval/)).toBeInTheDocument();
  });

  it("hides the badge when approvals belong to another session", async () => {
    const sessionID = "33333333-3333-4333-8333-333333333333";
    localStorage.setItem("rw_active_session_id", sessionID);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.startsWith("/approvals")) {
          return jsonResponse({
            approvals: [
              {
                id: "44444444-4444-4444-8444-444444444444",
                toolName: "email.send",
                description: "",
                input: { toolName: "email.send", argumentsJSON: "{}", callID: "c9" },
                suggestedDurations: [],
                sessionID: "different-session",
              },
            ],
            count: 1,
          });
        }
        if (typeof url === "string" && url.startsWith("/sessions")) {
          return jsonResponse({ sessions: [], count: 0, messages: [] });
        }
        return jsonResponse({});
      }),
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByLabelText("Chat input")).toBeInTheDocument();
    });
    expect(screen.queryByTestId("session-pending-badge")).not.toBeInTheDocument();
    expect(screen.queryByText(/Pending approval/)).not.toBeInTheDocument();
  });
});

describe("no ghost chips from narration", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    localStorage.clear();
  });

  it("renders narration as prose without a running chip", async () => {
    const { reconstructMessages } = await import("./ChatView");
    const raw = [
      { role: "user", content: "check mail" },
      {
        role: "assistant",
        content: 'Calling email.search {"limit":1} [call_nostore]',
      },
      { role: "tool", content: "none", toolCallID: "call_nostore" },
      { role: "assistant", content: "Nothing new." },
    ];
    // Without a structured record the narration stays visible as text and
    // yields no tool actions, so no chip can claim to be running.
    const result = reconstructMessages(raw);
    const first = result.find((item) => item.text.includes("Calling email.search"));
    expect(first).toBeDefined();
    expect(first?.toolActions).toBeUndefined();
  });

  it("never shows Running for a completed result-less entry", async () => {
    const sessionID = "55555555-5555-4555-8555-555555555555";
    localStorage.setItem("rw_active_session_id", sessionID);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.includes("/tool-actions")) {
          return jsonResponse({
            sessionID,
            actions: [
              {
                messageID: "m1",
                actions: [
                  {
                    toolName: "email.search",
                    callID: "call-resultless",
                    argumentsJSON: "{}",
                    result: null,
                  },
                ],
              },
            ],
            count: 1,
          });
        }
        if (typeof url === "string" && url.startsWith("/sessions/")) {
          return jsonResponse({
            id: sessionID,
            messages: [
              { id: "u1", role: "user", content: "hi" },
              {
                id: "m1",
                role: "assistant",
                content: "Calling email.search {} [call-resultless]",
              },
            ],
          });
        }
        if (typeof url === "string" && url.startsWith("/sessions")) {
          return jsonResponse({ sessions: [], count: 0 });
        }
        if (typeof url === "string" && url.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    render(<ChatView />);
    await waitFor(() => {
      expect(screen.getByText("email.search")).toBeInTheDocument();
    });
    expect(screen.getByText("Pending")).toBeInTheDocument();
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });
});

describe("run pending badge and debug data", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("flags runs with unresolved approvals for their session", async () => {
    const runID = "66666666-6666-4666-8666-666666666666";
    const sessionID = "77777777-7777-4777-8777-777777777777";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.startsWith("/approvals")) {
          return jsonResponse({
            approvals: [
              {
                id: "88888888-8888-4888-8888-888888888888",
                toolName: "files.write",
                description: "",
                input: { toolName: "files.write", argumentsJSON: "{}", callID: "c-run" },
                suggestedDurations: [],
                sessionID,
              },
            ],
            count: 1,
          });
        }
        return jsonResponse({
          runs: [
            {
              id: runID,
              sessionID,
              jobID: null,
              kind: "chat",
              status: "ok",
              message: "blocked turn",
              timestamp: new Date(0).toISOString(),
            },
          ],
          count: 1,
        });
      }),
    );
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("blocked turn")).toBeInTheDocument();
    });
    expect(screen.getByTestId(`run-pending-${runID}`)).toBeInTheDocument();
    expect(screen.getByText(/Pending approval/)).toBeInTheDocument();
  });

  it("surfaces session and tool call identifiers in the detail view", async () => {
    const user = userEvent.setup();
    const runID = "99999999-9999-4999-8999-999999999999";
    const sessionID = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
    const callID = "call-full-identifier-42";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.startsWith("/approvals")) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        return jsonResponse({
          runs: [
            {
              id: runID,
              sessionID,
              jobID: null,
              kind: "chat",
              status: "ok",
              message: "debug turn",
              timestamp: new Date(0).toISOString(),
              response: "done",
              toolActions: [
                {
                  toolName: "email.search",
                  callID,
                  argumentsJSON: "{}",
                  result: { toolCallID: callID, content: "ok", isError: false },
                },
              ],
            },
          ],
          count: 1,
        });
      }),
    );
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("debug turn")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Details" }));
    expect(screen.getByLabelText("Run details")).toBeInTheDocument();
    // Full debug identifiers are present without truncation.
    expect(screen.getByText(sessionID)).toBeInTheDocument();
    expect(screen.getByText(runID)).toBeInTheDocument();
    expect(screen.getByText(callID)).toBeInTheDocument();
  });

  it("renders identifiers directly in the modal", () => {
    const run: RunLogEntry = {
      id: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
      sessionID: "cccccccc-cccc-4ccc-cccc-cccccccccccc",
      jobID: null,
      kind: "chat",
      status: "ok",
      message: "prompt",
      timestamp: new Date(0).toISOString(),
      response: "answer",
      toolActions: [
        {
          toolName: "browser.open",
          callID: "call-modal-7",
          argumentsJSON: "{}",
          result: null,
        },
      ],
    };
    render(<RunDetailModal run={run} onClose={() => {}} />);
    expect(screen.getByText("cccccccc-cccc-4ccc-cccc-cccccccccccc")).toBeInTheDocument();
    expect(screen.getByText("bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb")).toBeInTheDocument();
    expect(screen.getByText("call-modal-7")).toBeInTheDocument();
    // A completed entry without a result is pending, never running.
    expect(screen.getByText("Pending")).toBeInTheDocument();
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });
});

// The run detail hydrates every write card the run carries through one batched
// review-status read, prepared before any collapsed row is expanded.
describe("run detail batched write-review hydration", () => {
  const FIRST_PATH = "/tmp/run-batch-first.txt";
  const SECOND_PATH = "/tmp/run-batch-second.txt";

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  function stagedWriteAction(callID: string, path: string): ToolAction {
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

  it("hydrates every write card with one batched review-status request", async () => {
    const user = userEvent.setup();
    const run: RunLogEntry = {
      id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      sessionID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      jobID: null,
      kind: "chat",
      status: "ok",
      message: "two writes",
      timestamp: new Date(0).toISOString(),
      response: "done",
      toolActions: [
        stagedWriteAction("call-run-1", FIRST_PATH),
        stagedWriteAction("call-run-2", SECOND_PATH),
      ],
    };
    // Explicit input/init params keep mock.calls typed as a 2-tuple so the
    // request-body assertion below typechecks.
    const fetchMock = vi.fn(async (input: string, _init?: RequestInit) => {
      if (input === "/files/review-status") {
        return jsonResponse({
          stagedStates: { [FIRST_PATH]: "superseded", [SECOND_PATH]: "pending" },
          liveStates: {},
        });
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal(
      "WebSocket",
      createMockWebSocket(createMockWebSocketCapture()),
    );

    render(<RunDetailModal run={run} onClose={() => {}} />);

    // The surface batches hydration for the whole run, not per mounted card;
    // the read starts even while both cards are still collapsed.
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) => url === "/files/review-status"),
      ).toHaveLength(1);
    });
    const reviewCalls = fetchMock.mock.calls.filter(
      ([url]) => url === "/files/review-status",
    );
    const body = JSON.parse(String(reviewCalls[0][1]?.body)) as {
      paths: string[];
    };
    expect([...body.paths].sort()).toEqual([FIRST_PATH, SECOND_PATH].sort());

    // Expanding each row mounts its card, which adopts its own batch entry:
    // the superseded row settles terminally with no controls while the pending
    // sibling stays actionable.
    const rowButtons = screen.getAllByRole("button", { name: /files\.write/ });
    expect(rowButtons).toHaveLength(2);
    await user.click(rowButtons[0]);
    await user.click(rowButtons[1]);
    expect(await screen.findByText("Superseded")).toBeInTheDocument();
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();
    // Only the pending sibling keeps its review controls.
    expect(screen.getAllByRole("button", { name: "Accept" })).toHaveLength(1);
    expect(screen.getAllByRole("button", { name: "Discard" })).toHaveLength(1);
  });
});
