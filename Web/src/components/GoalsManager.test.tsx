// Rune Weaver Dashboard — Component tests for GoalsManager.
//
// Drives the goal list, the create-form validation gate, the manual-advance
// contention path, plan-step toggling, and the live WebSocket refreshes
// (goal_updated list refresh). The needs-input attention count is shell-owned,
// so these tests pin that the panel renders the passed count without counting
// the same proactive frames a second time; frames travel through the real
// shared socket singleton so the tests exercise the same message path a mounted
// dashboard uses rather than a pre-sanitized handler.

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
});
