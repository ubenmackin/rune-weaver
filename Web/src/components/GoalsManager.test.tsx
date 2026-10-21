// Rune Weaver Dashboard — Component tests for GoalsManager.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import GoalsManager from "./GoalsManager";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

const GOAL_ID = "11111111-1111-1111-1111-111111111111";
const STEP_ID = "22222222-2222-2222-2222-222222222222";
const IDEA_ID = "44444444-4444-4444-4444-444444444444";
const DISMISSED_IDEA_ID = "55555555-5555-5555-5555-555555555555";

// Full goal row shared by the cases; each test overrides only the field under
// scrutiny so a failure isolates one behavior.
function goal(overrides: Record<string, unknown> = {}) {
  return {
    id: GOAL_ID,
    title: "field guide",
    statement: "Publish the field guide",
    status: "active",
    progress: { done: 1, total: 4 },
    stepIntervalMinutes: 1440,
    nextDueAt: new Date(Date.now() + 3_600_000).toISOString(),
    originSessionId: null,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    ...overrides,
  };
}

function step(overrides: Record<string, unknown> = {}) {
  return {
    id: STEP_ID,
    goalId: GOAL_ID,
    ordinal: 0,
    title: "Outline chapters",
    status: "pending",
    notes: null,
    lastRunId: null,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    ...overrides,
  };
}

// Full idea row shared by the cases; each test overrides only the field under
// scrutiny so a failure isolates one behavior.
function idea(overrides: Record<string, unknown> = {}) {
  return {
    id: IDEA_ID,
    kind: "plan_adjustment",
    title: "Try a shorter loop",
    body: "Run 2km instead of 5km.",
    goalId: GOAL_ID,
    status: "proposed",
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    ...overrides,
  };
}

// Installs a stubbed shared socket and returns its capture so a case that needs
// live frames can dispatch through the real shared-client message path.
function installSocket() {
  const capture = createMockWebSocketCapture();
  vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  return capture;
}

describe("GoalsManager", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("lists goals and hides abandoned ones under the default filter", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({
          goals: [
            goal(),
            goal({ id: "33333333-3333-3333-3333-333333333333", title: "dropped", status: "abandoned" }),
          ],
          count: 2,
        }),
      ),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    // The default Current filter hides the tombstoned row but counts only what
    // is visible, so the header tally stays honest.
    expect(screen.queryByText("dropped")).not.toBeInTheDocument();
    expect(screen.getByText("1 goals")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "All" }));
    expect(screen.getByText("dropped")).toBeInTheDocument();
    expect(screen.getByText("2 goals")).toBeInTheDocument();
  });

  it("renders friendly cadence, work-session, and done-looks-like copy", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ goals: [goal({ stepIntervalMinutes: 1440 })], count: 1 }),
      ),
    );
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    // The card translates the raw interval into everyday language so the
    // cadence reads as a habit rather than a timer value.
    expect(screen.getByText(/Daily/)).toBeInTheDocument();
    expect(screen.getByText(/next work session/i)).toBeInTheDocument();
    expect(screen.getByText("Done looks like:")).toBeInTheDocument();
  });

  it("disables create submit until the title and what-done-looks-like are filled", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ goals: [], count: 0 })),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("No goals yet")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "New Goal" }));
    const submit = screen.getByRole("button", { name: /create goal/i });
    expect(submit).toBeDisabled();
    // The title control must carry the shared text styling and sit inside its
    // layout wrapper so the label stays on its own line above a full-width
    // control.
    const titleInput = screen.getByLabelText("What do you want to get done?");
    expect(titleInput).toHaveAttribute("type", "text");
    expect(titleInput.closest(".form-group")).not.toBeNull();
    await user.type(titleInput, "field guide");
    // A title alone still leaves the submit gated until done is described.
    expect(submit).toBeDisabled();
    await user.type(
      screen.getByLabelText("What does done look like?"),
      "The guide is done",
    );
    expect(submit).toBeEnabled();
  });

  it("creates a goal with trimmed title, statement, and cadence", async () => {
    installSocket();
    const posts: Array<{ path: string; body: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [], count: 0 });
        }
        if (input === "/goals" && init?.method === "POST") {
          posts.push({ path: input, body: String(init.body ?? "") });
          const parsed = JSON.parse(String(init.body ?? "{}"));
          return jsonResponse({
            goal: goal({
              title: parsed.title,
              statement: parsed.statement,
              stepIntervalMinutes: parsed.stepIntervalMinutes,
            }),
            steps: [],
            events: [],
          });
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("No goals yet")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "New Goal" }));
    // Surrounding whitespace is owner sloppiness, not intent, so the request
    // carries the trimmed values the engine stores.
    await user.type(
      screen.getByLabelText("What do you want to get done?"),
      "  field guide  ",
    );
    await user.type(
      screen.getByLabelText("What does done look like?"),
      "  The guide is done  ",
    );
    await user.selectOptions(
      screen.getByLabelText("How often should I work on it?"),
      "240",
    );
    await user.click(screen.getByRole("button", { name: /create goal/i }));
    await waitFor(() => {
      expect(posts).toHaveLength(1);
    });
    expect(posts[0].path).toBe("/goals");
    expect(JSON.parse(posts[0].body)).toMatchObject({
      title: "field guide",
      statement: "The guide is done",
      stepIntervalMinutes: 240,
    });
  });

  it("shows honest already-running copy when advance answers 409", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal()], count: 1 });
        }
        if (input.endsWith("/advance")) {
          return jsonResponse({ reason: `Goal ${GOAL_ID} is already running` }, 409);
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Work on it now" }));
    await waitFor(() => {
      expect(
        screen.getByText(/is already running\. Wait for the current run/i),
      ).toBeInTheDocument();
    });
  });

  it("disables advance and keeps resume enabled for a paused goal", async () => {
    installSocket();
    const advanceCalls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal({ status: "paused" })], count: 1 });
        }
        if (input.endsWith("/advance")) {
          advanceCalls.push(input);
          return jsonResponse({ runID: "run-1", sessionID: "session-1", goalId: GOAL_ID });
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    const resume = screen.getByRole("button", { name: "Resume" });
    expect(resume).toBeEnabled();
    expect(resume).not.toHaveAttribute("disabled");
    expect(resume).toHaveClass("status-toggle-btn");
    expect(resume).toHaveClass("is-resume");
    const work = screen.getByRole("button", { name: "Work on it now" });
    expect(work).toBeDisabled();
    expect(work).toHaveAttribute("title", "Resume this goal before working on it now.");
    await user.click(work);
    expect(advanceCalls).toHaveLength(0);
  });

  it("enables advance and pause for an active goal", async () => {
    installSocket();
    const advanceCalls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal({ status: "active" })], count: 1 });
        }
        if (input.endsWith("/advance") && init?.method === "POST") {
          advanceCalls.push(input);
          return jsonResponse({ runID: "run-1", sessionID: "session-1", goalId: GOAL_ID });
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    const pause = screen.getByRole("button", { name: "Pause" });
    expect(pause).toBeEnabled();
    expect(pause).not.toHaveAttribute("disabled");
    expect(pause).toHaveClass("is-pause");
    const work = screen.getByRole("button", { name: "Work on it now" });
    expect(work).toBeEnabled();
    await user.click(work);
    await waitFor(() => {
      expect(advanceCalls).toHaveLength(1);
    });
  });

  it("issues a step PATCH when a plan checkbox is toggled", async () => {
    installSocket();
    const patches: Array<{ path: string; body: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal()], count: 1 });
        }
        if (input.includes("/steps/") && init?.method === "PATCH") {
          patches.push({ path: input, body: String(init.body ?? "") });
          return jsonResponse(step({ status: "done" }));
        }
        if (/^\/goals\/[^/]+$/.test(input) && !init?.method) {
          return jsonResponse({ goal: goal(), steps: [step()], events: [] });
        }
        if (input.startsWith("/runs")) {
          return jsonResponse({ runs: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Show Plan & Activity" }));
    const checkbox = await screen.findByRole("checkbox", {
      name: "Toggle Outline chapters",
    });
    await user.click(checkbox);
    await waitFor(() => {
      expect(patches).toHaveLength(1);
    });
    expect(patches[0].path).toBe(`/goals/${GOAL_ID}/steps/${STEP_ID}`);
    expect(JSON.parse(patches[0].body)).toMatchObject({ status: "done" });
  });

  it("refreshes the list when a goal_updated frame arrives", async () => {
    const capture = installSocket();
    let listCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          listCalls += 1;
          return listCalls === 1
            ? jsonResponse({ goals: [goal()], count: 1 })
            : jsonResponse({ goals: [goal({ title: "updated pursuit" })], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "goal_updated",
      goal: goal({ title: "updated pursuit" }),
    });
    await waitFor(() => {
      expect(screen.getByText("updated pursuit")).toBeInTheDocument();
    });
  });

  it("refreshes the ideas list when an idea_proposed proactive frame arrives", async () => {
    const capture = installSocket();
    let ideasCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          ideasCalls += 1;
          return ideasCalls === 1
            ? jsonResponse({ ideas: [], count: 0 })
            : jsonResponse({
                ideas: [idea({ title: "Announced idea" })],
                count: 1,
              });
        }
        return jsonResponse({});
      }),
    );
    render(<GoalsManager />);
    // Wait for the first ideas read to settle before dispatching the frame so
    // the assertion proves the frame triggered a second read.
    await waitFor(() => {
      expect(screen.getByText("0 ideas")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "idea_proposed",
      title: "Announced idea",
      headline: "A fresh suggestion",
    });
    await waitFor(() => {
      expect(screen.getByText("Announced idea")).toBeInTheDocument();
    });
  });

  it("renders the shell-owned attention count without re-counting frames", async () => {
    const capture = installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal()], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    render(<GoalsManager attentionCount={2} />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    expect(screen.getByTestId("goals-attention-badge")).toHaveTextContent(
      "2 goals need input",
    );

    // The shell already counts proactive nudges; the panel must not add a
    // second source by counting the same frame.
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "goalNeedsInput",
      title: "field guide",
      headline: "Waiting on your input",
    });
    expect(screen.getByTestId("goals-attention-badge")).toHaveTextContent(
      "2 goals need input",
    );
  });

  it("hides the attention badge when the shell count is zero", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ goals: [goal()], count: 1 }),
      ),
    );
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    expect(
      screen.queryByTestId("goals-attention-badge"),
    ).not.toBeInTheDocument();
  });

  it("lists proposed ideas and hides dismissed ones under the default filter", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({
            ideas: [
              idea(),
              idea({
                id: DISMISSED_IDEA_ID,
                title: "Old suggestion",
                status: "dismissed",
              }),
            ],
            count: 2,
          });
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("Try a shorter loop")).toBeInTheDocument();
    });
    // The body renders through the sanitized Markdown path, so the text is
    // present without any raw HTML injection.
    expect(screen.getByText("Run 2km instead of 5km.")).toBeInTheDocument();
    expect(screen.queryByText("Old suggestion")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "All" }));
    expect(screen.getByText("Old suggestion")).toBeInTheDocument();
  });

  it("accepts a proposed idea through POST", async () => {
    installSocket();
    const calls: Array<{ path: string; method?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal()], count: 1 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [idea()], count: 1 });
        }
        if (input === `/ideas/${IDEA_ID}/accept`) {
          calls.push({ path: input, method: init?.method });
          return jsonResponse(idea({ status: "accepted" }));
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("Try a shorter loop")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: "Accept Try a shorter loop" }),
    );
    await waitFor(() => {
      expect(calls).toHaveLength(1);
    });
    expect(calls[0].path).toBe(`/ideas/${IDEA_ID}/accept`);
    expect(calls[0].method).toBe("POST");
  });

  it("surfaces the honest conflict message when accept is refused", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [goal()], count: 1 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [idea()], count: 1 });
        }
        if (input === `/ideas/${IDEA_ID}/accept`) {
          return jsonResponse(
            {
              reason: `Linked goal ${GOAL_ID} is not active (status achieved).`,
            },
            409,
          );
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("Try a shorter loop")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: "Accept Try a shorter loop" }),
    );
    await waitFor(() => {
      expect(screen.getByText(/is not active/i)).toBeInTheDocument();
    });
  });

  it("dismisses a proposed idea through POST", async () => {
    installSocket();
    const calls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [idea()], count: 1 });
        }
        if (input === `/ideas/${IDEA_ID}/dismiss`) {
          calls.push(input);
          return jsonResponse(idea({ status: "dismissed" }));
        }
        return jsonResponse({});
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("Try a shorter loop")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: "Dismiss Try a shorter loop" }),
    );
    await waitFor(() => {
      expect(calls).toEqual([`/ideas/${IDEA_ID}/dismiss`]);
    });
    // Dismissal hides the card under the default filter.
    await waitFor(() => {
      expect(screen.queryByText("Try a shorter loop")).not.toBeInTheDocument();
    });
  });

  it("teaches goals at first contact with examples and a schedules footnote", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ goals: [], count: 0 })),
    );
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("No goals yet")).toBeInTheDocument();
    });
    // The explainer stays visible while the enabled UI answers, so the shared
    // stub doubles for GET /settings without an extra branch.
    expect(screen.getByText("Publish the field guide")).toBeInTheDocument();
    expect(
      screen.getByText("Dig into 5 papers on a topic"),
    ).toBeInTheDocument();
    expect(
      screen.getByText("Get ready for the conference talk"),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        "Need the same task repeated on a schedule instead? Use Schedules.",
      ),
    ).toBeInTheDocument();
  });

  it("prefills the create form from an example card without creating", async () => {
    installSocket();
    const posts: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (init?.method === "POST") posts.push(input);
        return jsonResponse({ goals: [], count: 0 });
      }),
    );
    const user = userEvent.setup();
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("No goals yet")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: /Publish the field guide/ }),
    );
    // The modal opens with the example's title, statement, and cadence while
    // no POST leaves the client, so the card is a prefill rather than a
    // shortcut create.
    expect(
      screen.getByLabelText("What do you want to get done?"),
    ).toHaveValue("Publish the field guide");
    expect(screen.getByLabelText("What does done look like?")).toHaveValue(
      "The guide is written, reviewed, and shared with the team.",
    );
    expect(screen.getByLabelText("How often should I work on it?")).toHaveValue(
      "10080",
    );
    expect(posts).toHaveLength(0);
  });

  it("gates creation when settings turn goals off", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({ goals: { enabled: false } });
        }
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    render(<GoalsManager />);
    await waitFor(() => {
      expect(screen.getByText("Goals are turned off")).toBeInTheDocument();
    });
    // Disabled mode offers the settings note instead of examples, and the
    // header create stays visibly gated.
    expect(screen.getByRole("button", { name: "New Goal" })).toBeDisabled();
    // The disable reason is visible header text beside the controls, not a
    // hover-only tooltip on the disabled button.
    expect(
      screen.getByText("Goals are turned off in Settings"),
    ).toBeInTheDocument();
    // The body names the real enablement control verbatim — the Enable goal
    // pursuit checkbox under Goals & Proactivity — so the empty state points
    // at Settings, never at the Autonomous Goals tool-toggles category card.
    expect(
      screen.getByText(
        "Goals are turned off in Settings. Turn on Enable goal pursuit under Goals & Proactivity to have the agent plan and work on longer projects.",
      ),
    ).toBeInTheDocument();
    expect(
      screen.queryByText("Publish the field guide"),
    ).not.toBeInTheDocument();
  });

  it("keeps creation available when the settings read fails", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          throw new Error("settings unreachable");
        }
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    render(<GoalsManager />);
    // A transient settings failure must not gate creation: the enabled
    // explainer stays up and the engine still fails closed on submit.
    await waitFor(() => {
      expect(screen.getByText("No goals yet")).toBeInTheDocument();
    });
    expect(screen.getByText("Publish the field guide")).toBeInTheDocument();
  });

  it("asks the shell to open settings from the disabled empty state", async () => {
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({ goals: { enabled: false } });
        }
        if (input === "/goals" && !init?.method) {
          return jsonResponse({ goals: [], count: 0 });
        }
        if (input === "/ideas" && !init?.method) {
          return jsonResponse({ ideas: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );
    const onOpenSettings = vi.fn();
    const user = userEvent.setup();
    render(<GoalsManager onOpenSettings={onOpenSettings} />);
    await waitFor(() => {
      expect(screen.getByText("Goals are turned off")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Open Settings" }));
    expect(onOpenSettings).toHaveBeenCalledTimes(1);
  });
});
