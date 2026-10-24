// Rune Weaver Dashboard — Unit tests for chatTimeline and mid-turn reload/approval-resume state helpers.

import { describe, expect, it } from "vitest";
import type { ChatSegment, ToolAction } from "../../api";
import {
  appendToolStartToSegments,
  buildCancelledMessageItem,
  buildDoneSegments,
  removeResumedCallFromMessages,
} from "./chatTimeline";
import {
  mergeLiveSnapshotIntoInFlightTurn,
  mergePersistedMessagesIntoInFlightTurn,
} from "./useChatHistoryLoader";
import type { InFlightTurn, MessageItem } from "./chatTypes";

describe("chatTimeline approval resume and mid-turn reload ordering", () => {
  it("buildDoneSegments prepends pre-refresh tool rounds before post-refresh streamed rounds and text", () => {
    const preRefreshRound0: ToolAction = {
      toolName: "browser.navigate",
      callID: "call-r0",
      argumentsJSON: '{"url":"https://www.amazon.com"}',
      roundIndex: 0,
      result: { toolCallID: "call-r0", content: "ok", isError: false },
    };
    const preRefreshRound1: ToolAction = {
      toolName: "browser.act",
      callID: "call-r1",
      argumentsJSON: '{"action":"fill","ref":"e4"}',
      roundIndex: 1,
      result: { toolCallID: "call-r1", content: "ok", isError: false },
    };
    const postRefreshRound2: ToolAction = {
      toolName: "browser.act",
      callID: "call-r2",
      argumentsJSON: '{"action":"click","ref":"e12"}',
      roundIndex: 2,
      result: { toolCallID: "call-r2", content: "ok", isError: false },
    };

    // Snapshot only saw post-refresh round 2 plus final assistant prose
    const snapshotSegments: ChatSegment[] = [
      { kind: "tools", actions: [postRefreshRound2] },
      { kind: "text", text: "Added the item to your cart." },
    ];

    const doneSegments = buildDoneSegments(
      snapshotSegments,
      [preRefreshRound0, preRefreshRound1, postRefreshRound2],
      "Added the item to your cart.",
      "Added the item to your cart.",
    );

    expect(doneSegments.map((s) => s.kind)).toEqual([
      "tools",
      "tools",
      "tools",
      "text",
    ]);
    const toolRoundCallIDs = doneSegments
      .filter((s): s is Extract<ChatSegment, { kind: "tools" }> => s.kind === "tools")
      .map((s) => s.actions.map((a) => a.callID));
    expect(toolRoundCallIDs).toEqual([["call-r0"], ["call-r1"], ["call-r2"]]);
  });

  it("removeResumedCallFromMessages strips the pending callID and waiting text when resumed", () => {
    const parkedSingle: MessageItem[] = [
      {
        id: "m-user",
        role: "user",
        text: "buy filters",
      },
      {
        id: "m-parked",
        role: "assistant",
        text: "Waiting for approval to run browser.act. Approve in the approvals inbox to continue.",
        toolActions: [
          {
            toolName: "browser.act",
            callID: "fY1I0CawqnXtZxh862ubbHjBEkwGBma0",
            argumentsJSON: "{}",
            result: undefined,
          },
        ],
        segments: [
          {
            kind: "text",
            text: "Waiting for approval to run browser.act. Approve in the approvals inbox to continue.",
          },
          {
            kind: "tools",
            actions: [
              {
                toolName: "browser.act",
                callID: "fY1I0CawqnXtZxh862ubbHjBEkwGBma0",
                argumentsJSON: "{}",
                result: undefined,
              },
            ],
          },
        ],
      },
    ];

    const afterSingle = removeResumedCallFromMessages(
      parkedSingle,
      "fY1I0CawqnXtZxh862ubbHjBEkwGBma0",
    );
    expect(afterSingle).toHaveLength(1);
    expect(afterSingle[0].id).toBe("m-user");

    // When the parked message also had an earlier completed round, keep the completed round
    const parkedMulti: MessageItem[] = [
      {
        id: "m-parked-multi",
        role: "assistant",
        text: "Waiting for approval to run browser.act.",
        toolActions: [
          {
            toolName: "browser.navigate",
            callID: "call-nav-0",
            argumentsJSON: "{}",
            result: { toolCallID: "call-nav-0", content: "ok", isError: false },
          },
          {
            toolName: "browser.act",
            callID: "fY1I0CawqnXtZxh862ubbHjBEkwGBma0",
            argumentsJSON: "{}",
            result: undefined,
          },
        ],
        segments: [
          {
            kind: "tools",
            actions: [
              {
                toolName: "browser.navigate",
                callID: "call-nav-0",
                argumentsJSON: "{}",
                result: { toolCallID: "call-nav-0", content: "ok", isError: false },
              },
            ],
          },
          {
            kind: "tools",
            actions: [
              {
                toolName: "browser.act",
                callID: "fY1I0CawqnXtZxh862ubbHjBEkwGBma0",
                argumentsJSON: "{}",
                result: undefined,
              },
            ],
          },
        ],
      },
    ];

    const afterMulti = removeResumedCallFromMessages(
      parkedMulti,
      "fY1I0CawqnXtZxh862ubbHjBEkwGBma0",
    );
    expect(afterMulti).toHaveLength(1);
    expect(afterMulti[0].toolActions?.map((a) => a.callID)).toEqual([
      "call-nav-0",
    ]);
  });

  it("appendToolStartToSegments deduplicates in place when callID already exists", () => {
    const initial: ChatSegment[] = [
      {
        kind: "tools",
        actions: [
          {
            toolName: "browser.act",
            callID: "call-1",
            argumentsJSON: "{}",
            result: undefined,
          },
        ],
      },
    ];
    const updated = appendToolStartToSegments(initial, {
      toolName: "browser.act",
      callID: "call-1",
      argumentsJSON: '{"ref":"e4"}',
      roundIndex: 1,
    });
    expect(updated).toHaveLength(1);
    expect(updated[0].kind === "tools" && updated[0].actions).toHaveLength(1);
  });

  it("mergeLiveSnapshotIntoInFlightTurn and mergePersistedMessagesIntoInFlightTurn preserve pre-refresh rounds", () => {
    const streamedCurrent: InFlightTurn = {
      toolActions: [
        {
          toolName: "browser.act",
          callID: "call-r2",
          argumentsJSON: "{}",
          roundIndex: 2,
          result: undefined,
        },
      ],
      text: "",
      held: "",
      segments: [
        {
          kind: "tools",
          actions: [
            {
              toolName: "browser.act",
              callID: "call-r2",
              argumentsJSON: "{}",
              roundIndex: 2,
              result: undefined,
            },
          ],
        },
      ],
    };

    const mergedLive = mergeLiveSnapshotIntoInFlightTurn(streamedCurrent, {
      reasoning: "Checking search results",
      toolActions: [
        {
          toolName: "browser.navigate",
          callID: "call-r0",
          argumentsJSON: "{}",
          roundIndex: 0,
          result: { toolCallID: "call-r0", content: "ok", isError: false },
        },
        {
          toolName: "browser.act",
          callID: "call-r2",
          argumentsJSON: "{}",
          roundIndex: 2,
          result: { toolCallID: "call-r2", content: "done", isError: false },
        },
      ],
    });

    expect(mergedLive.toolActions.map((a) => a.callID)).toEqual([
      "call-r0",
      "call-r2",
    ]);
    expect(mergedLive.toolActions[1].result?.content).toBe("done");
    expect(mergedLive.segments.map((s) => s.kind)).toEqual([
      "thought",
      "tools",
      "tools",
    ]);

    const fromPersisted = mergePersistedMessagesIntoInFlightTurn(null, [
      {
        id: "trailing_1",
        role: "assistant",
        text: "Opening Amazon now.",
        toolActions: [
          {
            toolName: "browser.navigate",
            callID: "call-r0",
            argumentsJSON: "{}",
            roundIndex: 0,
            result: { toolCallID: "call-r0", content: "ok", isError: false },
          },
        ],
        segments: [
          { kind: "text", text: "Opening Amazon now." },
          {
            kind: "tools",
            actions: [
              {
                toolName: "browser.navigate",
                callID: "call-r0",
                argumentsJSON: "{}",
                roundIndex: 0,
                result: { toolCallID: "call-r0", content: "ok", isError: false },
              },
            ],
          },
        ],
      },
    ]);
    expect(fromPersisted.toolActions.map((a) => a.callID)).toEqual(["call-r0"]);
    expect(fromPersisted.text).toBe("Opening Amazon now.");
  });

  it("buildCancelledMessageItem preserves in-flight text and tool actions on cancellation", () => {
    expect(buildCancelledMessageItem(null)).toBeNull();
    expect(
      buildCancelledMessageItem({
        text: "   ",
        held: "",
        segments: [],
        toolActions: [],
      }),
    ).toBeNull();

    const textOnly = buildCancelledMessageItem(
      {
        text: "I found 3 results on Amazon for you:",
        held: "",
        segments: [{ kind: "text", text: "I found 3 results on Amazon for you:" }],
        toolActions: [],
      },
      "msg-cancel-1",
    );
    expect(textOnly).not.toBeNull();
    expect(textOnly?.role).toBe("assistant");
    expect(textOnly?.text).toBe(
      "I found 3 results on Amazon for you:\n\n*(Turn cancelled by user)*",
    );

    const withTools = buildCancelledMessageItem(
      {
        text: "",
        held: "",
        segments: [],
        toolActions: [
          {
            toolName: "browser.navigate",
            callID: "call-nav",
            argumentsJSON: "{}",
            result: { toolCallID: "call-nav", content: "ok", isError: false },
          },
        ],
      },
      "msg-cancel-2",
    );
    expect(withTools).not.toBeNull();
    expect(withTools?.text).toBe("*(Turn cancelled by user)*");
    expect(withTools?.toolActions).toHaveLength(1);
    expect(withTools?.toolActions?.[0].callID).toBe("call-nav");
  });
});
