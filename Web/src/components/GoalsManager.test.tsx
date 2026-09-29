// Rune Weaver Dashboard — Component tests for GoalsManager.
//
// Drives the goal list, the create-form validation gate, the manual-advance
// contention path, plan-step toggling, the Ideas panel (list, dismiss, accept,
// and honest conflict copy), and the live WebSocket refreshes (goal_updated
// list refresh). The needs-input attention count is shell-owned, so these tests
// pin that the panel renders the passed count without counting the same
// proactive frames a second time; frames travel through the real shared socket
// singleton so the tests exercise the same message path a mounted dashboard
// uses rather than a pre-sanitized handler.

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

  it("disables create submit while the title is blank", async () => {
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
    await user.type(screen.getByLabelText("Goal Title"), "field guide");
    expect(submit).toBeEnabled();
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
    await user.click(screen.getByRole("button", { name: "Advance now" }));
    await waitFor(() => {
      expect(
        screen.getByText(/is already running — wait for the current advancement/i),
      ).toBeInTheDocument();
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
});
