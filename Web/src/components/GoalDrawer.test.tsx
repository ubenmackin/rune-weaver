// Rune Weaver Dashboard — Component tests for the chat goal drawer.
//
// Drives the drawer's single-goal detail render, the plan checklist moves, the
// manual-advance contention path, and the Escape dismissal with focus return so
// the panel's keyboard contract stays pinned alongside its data flow.

import { createRef } from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import GoalDrawer from "./GoalDrawer";
import { jsonResponse } from "../test-utils/http";
import { resetSharedSocket } from "../test-utils/mockWebSocket";

const GOAL_ID = "11111111-1111-1111-1111-111111111111";
const STEP_ID = "22222222-2222-2222-2222-222222222222";

// Full goal row shared by the cases; each test overrides only the field under
// scrutiny so one failure isolates one behavior.
function goal(overrides: Record<string, unknown> = {}) {
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

// One routed fetch double so each case only overrides the response it probes;
// the shared goal detail path is reused by both the initial read and the
// post-mutation refetch.
function installFetch(
  overrides: Record<string, (input: string, init?: RequestInit) => Response> = {},
) {
  const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
    if (overrides[input]) return overrides[input](input, init);
    if (input === `/goals/${GOAL_ID}` && !init?.method) {
      return jsonResponse({
        goal: goal(),
        steps: [step()],
        events: [
          {
            id: 1,
            goalId: GOAL_ID,
            kind: "plan_ready",
            message: "Plan drafted",
            createdAt: new Date(0).toISOString(),
          },
        ],
      });
    }
    if (input.startsWith("/runs")) {
      return jsonResponse({
        runs: [
          {
            id: "run-1",
            goalId: GOAL_ID,
            kind: "goal",
            status: "ok",
            message: "advanced",
            response: "step done",
            timestamp: new Date(0).toISOString(),
            durationMs: 1500,
          },
        ],
        count: 1,
      });
    }
    return jsonResponse({});
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

describe("GoalDrawer", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("renders the header, plan, activity, and linked runs for one goal", async () => {
    installFetch();
    render(<GoalDrawer goalId={GOAL_ID} onClose={vi.fn()} />);
    await waitFor(() => {
      expect(screen.getByText("field guide")).toBeInTheDocument();
    });
    expect(screen.getByText("1/4 steps")).toBeInTheDocument();
    expect(screen.getByText("Outline chapters")).toBeInTheDocument();
    expect(screen.getByText("Plan drafted")).toBeInTheDocument();
    // The linked-run duration renders in the same compact shape as the
    // scheduler history so the two run surfaces read identically.
    expect(screen.getByText("• 1.5s")).toBeInTheDocument();
  });

  it("moves a plan step to done and skip through PATCH", async () => {
    const patches: Array<{ path: string; body: string }> = [];
    installFetch({
      [`/goals/${GOAL_ID}/steps/${STEP_ID}`]: (_input, init) => {
        patches.push({ path: `/goals/${GOAL_ID}/steps/${STEP_ID}`, body: String(init?.body ?? "") });
        return jsonResponse(step({ status: "done" }));
      },
    });
    const user = userEvent.setup();
    render(<GoalDrawer goalId={GOAL_ID} onClose={vi.fn()} />);
    const checkbox = await screen.findByRole("checkbox", {
      name: "Toggle Outline chapters",
    });
    await user.click(checkbox);
    await waitFor(() => expect(patches).toHaveLength(1));
    expect(JSON.parse(patches[0].body)).toMatchObject({ status: "done" });

    await waitFor(() => expect(checkbox).not.toBeDisabled());
    await user.click(screen.getByRole("button", { name: "Skip Outline chapters" }));
    await waitFor(() => expect(patches).toHaveLength(2));
    expect(JSON.parse(patches[1].body)).toMatchObject({ status: "skipped" });
  });

  it("shows honest already-running copy when advance answers 409", async () => {
    installFetch({
      [`/goals/${GOAL_ID}/advance`]: () =>
        jsonResponse({ reason: `Goal ${GOAL_ID} is already running` }, 409),
    });
    const user = userEvent.setup();
    render(<GoalDrawer goalId={GOAL_ID} onClose={vi.fn()} />);
    await screen.findByText("field guide");
    await user.click(screen.getByRole("button", { name: "Advance now" }));
    await waitFor(() => {
      expect(
        screen.getByText(/is already running — wait for the current advancement/i),
      ).toBeInTheDocument();
    });
  });

  it("closes on Escape and returns focus to the opener", async () => {
    installFetch();
    const chipRef = createRef<HTMLButtonElement>();
    const onClose = vi.fn();
    render(
      <>
        <button type="button" ref={chipRef}>
          Goal chip
        </button>
        <GoalDrawer goalId={GOAL_ID} onClose={onClose} returnFocusRef={chipRef} />
      </>,
    );
    await screen.findByText("field guide");
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(chipRef.current);
  });
});
