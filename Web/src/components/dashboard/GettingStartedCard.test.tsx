// Rune Weaver Dashboard — Getting started checklist progress, dismiss, and seed tests.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import GettingStartedCard, {
  CHECKLIST_TOTAL,
  countCompletedItems,
  deriveChecklistItems,
} from "./GettingStartedCard";
import DashboardView, { DEMO_GOAL_TITLE } from "../DashboardView";
import * as api from "../../api";
import { jsonResponse } from "../../test-utils/http";
import {
  CALENDAR_SEED_PROMPT,
  EMAIL_SEED_PROMPT,
  GENERIC_SEED_PROMPT,
  INDEX_SEED_PROMPT,
} from "../onboarding/seedPrompt";
import { clearSharedRecentRunsForTesting } from "./sharedRuns";
import { resetPersonaSignalsForTesting } from "../PersonaAvatar";

vi.mock("../../api", async (importOriginal) => {
  const actual = await importOriginal<typeof api>();
  return {
    ...actual,
    listApprovals: vi.fn(),
    decideApproval: vi.fn(),
    listGoals: vi.fn(),
    createGoal: vi.fn(),
    deleteGoal: vi.fn(),
    advanceGoal: vi.fn(),
    listRuns: vi.fn(),
    cancelRun: vi.fn(),
    listJobs: vi.fn(),
    runJobNow: vi.fn(),
    listIdeas: vi.fn(),
    acceptIdea: vi.fn(),
    dismissIdea: vi.fn(),
    listSessions: vi.fn(),
  };
});

function emptyOnboarding() {
  return {
    completedAt: null,
    completed_at: null,
    skippedSteps: [],
    checklistDismissed: false,
    checklist_dismissed: 0,
    seedPromptUsed: null,
    brainReady: false,
    personaSet: false,
    emailReady: false,
    calendarReady: false,
    indexReady: false,
    policyAcked: false,
  };
}

function stubOnboardingFetch(payload: unknown, seen: string[]) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      if (path === "/onboarding/status" && method === "GET") {
        return jsonResponse(payload);
      }
      if (path === "/onboarding/dismiss") {
        seen.push(path);
        return jsonResponse({ ...(payload as object), checklistDismissed: true });
      }
      if (path === "/onboarding/reopen") {
        seen.push(path);
        return jsonResponse(payload);
      }
      return jsonResponse({});
    }),
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.unstubAllGlobals();
  clearSharedRecentRunsForTesting();
  resetPersonaSignalsForTesting();
  vi.mocked(api.listApprovals).mockResolvedValue({ approvals: [], count: 0 });
  vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
  vi.mocked(api.listRuns).mockResolvedValue({ runs: [], count: 0 });
  vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
  vi.mocked(api.listIdeas).mockResolvedValue({ ideas: [], count: 0 });
  vi.mocked(api.listSessions).mockResolvedValue({ sessions: [], count: 0 });
});

describe("GettingStartedCard progress", () => {
  it("pins five rows and reports Setup N of 5", () => {
    expect(CHECKLIST_TOTAL).toBe(5);
    const items = deriveChecklistItems({
      brainReady: true,
      personaSet: true,
      emailReady: false,
      calendarReady: false,
      indexReady: false,
      policyAcked: false,
      firstChatSent: false,
    });
    expect(items).toHaveLength(5);
    expect(countCompletedItems(items)).toBe(2);
    render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: true,
          emailReady: false,
          calendarReady: false,
          indexReady: false,
          policyAcked: false,
          firstChatSent: false,
        }}
      />,
    );
    expect(screen.getByText("Getting started")).toBeInTheDocument();
    expect(screen.getByTestId("getting-started-progress")).toHaveTextContent(
      "Setup 2 of 5",
    );
  });

  it("shows Done only from live event state per row", () => {
    const { unmount } = render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: false,
          emailReady: false,
          calendarReady: false,
          indexReady: false,
          policyAcked: false,
          firstChatSent: false,
        }}
      />,
    );
    expect(screen.getByTestId("getting-started-status-brain")).toHaveTextContent("Done");
    expect(screen.getByTestId("getting-started-start-persona")).toBeInTheDocument();
    expect(screen.queryByTestId("getting-started-status-persona")).toBeNull();
    unmount();

    render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: false,
          calendarReady: true,
          emailReady: false,
          indexReady: false,
          policyAcked: true,
          firstChatSent: true,
        }}
      />,
    );
    expect(screen.getByTestId("getting-started-status-connect")).toHaveTextContent("Done");
    expect(screen.getByTestId("getting-started-status-policy")).toHaveTextContent("Done");
    expect(screen.getByTestId("getting-started-status-chat")).toHaveTextContent("Done");
    expect(screen.getByText("Brain ready")).toBeInTheDocument();
    expect(screen.getByText("Persona set")).toBeInTheDocument();
    expect(screen.getByText("Email/Calendar/Index connected")).toBeInTheDocument();
    expect(screen.getByText("Policy reviewed")).toBeInTheDocument();
    expect(screen.getByText("First chat sent")).toBeInTheDocument();
  });

  it("verifies connect from calendar, email, and index live shapes", () => {
    const calendar = deriveChecklistItems({ calendarStatus: "granted" });
    expect(calendar.find((row) => row.id === "connect")?.completed).toBe(true);
    const email = deriveChecklistItems({
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
    });
    expect(email.find((row) => row.id === "connect")?.completed).toBe(true);
    const index = deriveChecklistItems({
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(index.find((row) => row.id === "connect")?.completed).toBe(true);
    const none = deriveChecklistItems({
      calendarStatus: "denied",
      emailAccounts: [],
      indexEnabled: false,
      indexWatermark: null,
    });
    expect(none.find((row) => row.id === "connect")?.completed).toBe(false);
  });

  it("never completes rows from clicks alone", async () => {
    const user = userEvent.setup();
    const onStart = vi.fn();
    render(
      <GettingStartedCard
        status={{
          brainReady: false,
          personaSet: false,
          emailReady: false,
          calendarReady: false,
          indexReady: false,
          policyAcked: false,
          firstChatSent: false,
        }}
        onStart={onStart}
      />,
    );
    await user.click(screen.getByTestId("getting-started-start-brain"));
    expect(onStart).toHaveBeenCalledWith("brain");
    expect(screen.queryByTestId("getting-started-status-brain")).toBeNull();
    expect(screen.getByTestId("getting-started-progress")).toHaveTextContent("Setup 0 of 5");
  });

  it("removes the card permanently at 5 of 5 verified", () => {
    const { container } = render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: true,
          emailReady: true,
          calendarReady: false,
          indexReady: false,
          policyAcked: true,
          firstChatSent: true,
        }}
      />,
    );
    expect(screen.queryByTestId("getting-started-card")).toBeNull();
    expect(screen.queryByTestId("getting-started-pill")).toBeNull();
    expect(container).toBeEmptyDOMElement();
  });
});

describe("GettingStartedCard dismiss", () => {
  it("persists Dismiss and collapses to the Setup pill", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    stubOnboardingFetch(emptyOnboarding(), seen);
    const onDismiss = vi.fn();
    render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: false,
          emailReady: false,
          calendarReady: false,
          indexReady: false,
          policyAcked: false,
          firstChatSent: false,
        }}
        onDismiss={onDismiss}
      />,
    );
    await user.click(screen.getByTestId("getting-started-dismiss"));
    await waitFor(() => expect(seen).toContain("/onboarding/dismiss"));
    await waitFor(() => expect(onDismiss).toHaveBeenCalledTimes(1));
    vi.unstubAllGlobals();
  });

  it("renders the slim pill with progress when dismissed", () => {
    render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: true,
          emailReady: false,
          calendarReady: false,
          indexReady: false,
          policyAcked: false,
          firstChatSent: false,
        }}
        dismissed
      />,
    );
    expect(screen.getByTestId("getting-started-pill")).toBeInTheDocument();
    expect(screen.getByTestId("getting-started-pill-progress")).toHaveTextContent(
      "Setup 2 of 5",
    );
    expect(screen.queryByTestId("getting-started-card")).toBeNull();
  });
});

describe("Dashboard seed landing and demo goal", () => {
  function mockDashboardBasics() {
    vi.mocked(api.listApprovals).mockResolvedValue({ approvals: [], count: 0 });
    vi.mocked(api.listRuns).mockResolvedValue({ runs: [], count: 0 });
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
    vi.mocked(api.listIdeas).mockResolvedValue({ ideas: [], count: 0 });
    vi.mocked(api.listSessions).mockResolvedValue({ sessions: [], count: 0 });
  }

  it("finishes with the calendar prompt when calendars are granted", async () => {
    const user = userEvent.setup();
    mockDashboardBasics();
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
    vi.mocked(api.createGoal).mockResolvedValue({
      goal: {
        id: "goal-demo-1",
        title: DEMO_GOAL_TITLE,
        statement: "demo",
        status: "active",
        progress: { done: 0, total: 0 },
        stepIntervalMinutes: 1440,
        nextDueAt: null,
        originSessionId: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      },
      steps: [],
      events: [],
    });
    const seen: string[] = [];
    stubOnboardingFetch(
      {
        ...emptyOnboarding(),
        brainReady: true,
        personaSet: true,
        calendarReady: true,
        emailReady: false,
        indexReady: false,
        policyAcked: false,
      },
      seen,
    );
    const onOpenChatWithPrompt = vi.fn();
    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={vi.fn()}
        onOpenChatWithPrompt={onOpenChatWithPrompt}
      />,
    );
    const finish = await screen.findByTestId("getting-started-finish");
    await user.click(finish);
    await waitFor(() => expect(onOpenChatWithPrompt).toHaveBeenCalledTimes(1));
    expect(onOpenChatWithPrompt).toHaveBeenCalledWith(CALENDAR_SEED_PROMPT);
    await waitFor(() => expect(api.createGoal).toHaveBeenCalledTimes(1));
    const input = vi.mocked(api.createGoal).mock.calls[0][0] as {
      title: string;
    };
    expect(input.title).toBe("Morning briefing");
    expect(input.title.length).toBeLessThanOrEqual(64);
    vi.unstubAllGlobals();
  });

  it("matches the seed prompt to the granted capability", async () => {
    const user = userEvent.setup();
    async function finishWithPayload(payload: unknown): Promise<string> {
      mockDashboardBasics();
      vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
      vi.mocked(api.createGoal).mockResolvedValue({
        goal: {
          id: "goal-demo-x",
          title: DEMO_GOAL_TITLE,
          statement: "demo",
          status: "active",
          progress: { done: 0, total: 0 },
          stepIntervalMinutes: 1440,
          nextDueAt: null,
          originSessionId: null,
          createdAt: Date.now(),
          updatedAt: Date.now(),
        },
        steps: [],
        events: [],
      });
      const seen: string[] = [];
      stubOnboardingFetch(payload, seen);
      const onOpenChatWithPrompt = vi.fn();
      const { unmount } = render(
        <DashboardView
          health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
          onSelectTab={vi.fn()}
          onOpenChatWithPrompt={onOpenChatWithPrompt}
        />,
      );
      const finish = await screen.findByTestId("getting-started-finish");
      await user.click(finish);
      await waitFor(() => expect(onOpenChatWithPrompt).toHaveBeenCalledTimes(1));
      const prompt = onOpenChatWithPrompt.mock.calls[0][0] as string;
      unmount();
      vi.unstubAllGlobals();
      return prompt;
    }

    const emailPrompt = await finishWithPayload({
      ...emptyOnboarding(),
      emailReady: true,
      calendarReady: false,
      indexReady: false,
    });
    expect(emailPrompt).toBe(EMAIL_SEED_PROMPT);

    const indexPrompt = await finishWithPayload({
      ...emptyOnboarding(),
      emailReady: false,
      calendarReady: false,
      indexReady: true,
    });
    expect(indexPrompt).toBe(INDEX_SEED_PROMPT);

    const genericPrompt = await finishWithPayload({ ...emptyOnboarding() });
    expect(genericPrompt).toBe(GENERIC_SEED_PROMPT);
  });

  it("creates the Morning briefing demo goal only when goals are empty", async () => {
    const user = userEvent.setup();
    mockDashboardBasics();
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
    vi.mocked(api.createGoal).mockResolvedValue({
      goal: {
        id: "goal-demo-once",
        title: DEMO_GOAL_TITLE,
        statement: "demo",
        status: "active",
        progress: { done: 0, total: 0 },
        stepIntervalMinutes: 1440,
        nextDueAt: null,
        originSessionId: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      },
      steps: [],
      events: [],
    });
    const seen: string[] = [];
    stubOnboardingFetch(emptyOnboarding(), seen);
    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={vi.fn()}
        onOpenChatWithPrompt={vi.fn()}
      />,
    );
    const finish = await screen.findByTestId("getting-started-finish");
    await user.click(finish);
    await waitFor(() => expect(api.createGoal).toHaveBeenCalledTimes(1));

    vi.mocked(api.createGoal).mockClear();
    vi.mocked(api.listGoals).mockResolvedValue({
      goals: [
        {
          id: "goal-real-1",
          title: "Ship the release",
          statement: "done",
          status: "active",
          progress: { done: 0, total: 1 },
          stepIntervalMinutes: 1440,
          nextDueAt: null,
          originSessionId: null,
          createdAt: Date.now(),
          updatedAt: Date.now(),
        },
      ],
      count: 1,
    });
    await user.click(finish);
    await waitFor(() =>
      expect(screen.getByTestId("getting-started-finish")).toBeInTheDocument(),
    );
    expect(vi.mocked(api.createGoal)).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });

  it("purges only the demo goal when the first real goal lands", async () => {
    mockDashboardBasics();
    const demo = {
      id: "goal-demo-purge",
      title: DEMO_GOAL_TITLE,
      statement: "demo",
      status: "active",
      progress: { done: 0, total: 0 },
      stepIntervalMinutes: 1440,
      nextDueAt: null,
      originSessionId: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const real = {
      id: "goal-real-purge",
      title: "Ship the release",
      statement: "done",
      status: "active",
      progress: { done: 0, total: 1 },
      stepIntervalMinutes: 1440,
      nextDueAt: null,
      originSessionId: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [demo, real], count: 2 });
    vi.mocked(api.deleteGoal).mockResolvedValue(undefined);
    const seen: string[] = [];
    stubOnboardingFetch(emptyOnboarding(), seen);
    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={vi.fn()}
      />,
    );
    await waitFor(() => expect(api.deleteGoal).toHaveBeenCalled());
    expect(vi.mocked(api.deleteGoal)).toHaveBeenCalledWith("goal-demo-purge", true);
    const calls = vi.mocked(api.deleteGoal).mock.calls;
    expect(calls.every(([id]) => id === "goal-demo-purge")).toBe(true);
    vi.unstubAllGlobals();
  });
});
