// Rune Weaver Dashboard — Getting started checklist progress, dismiss, resume, and seed tests.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import GettingStartedCard, {
  CHECKLIST_TOTAL,
  countCompletedItems,
  deriveChecklistItems,
} from "./GettingStartedCard";
import DashboardView from "../DashboardView";
import * as api from "../../api";
import { jsonResponse } from "../../test-utils/http";
import { GENERIC_SEED_PROMPT } from "../onboarding/seedPrompt";
import { clearSharedRecentRunsForTesting } from "./sharedRuns";
import { resetPersonaSignalsForTesting } from "../PersonaAvatar";
import {
  clearWizardSnooze,
  isWizardSnoozed,
  snoozeWizard,
} from "../onboarding/wizardSnooze";

vi.mock("../../api", async (importOriginal) => {
  const actual = await importOriginal<typeof api>();
  return {
    ...actual,
    listApprovals: vi.fn(),
    decideApproval: vi.fn(),
    listGoals: vi.fn(),
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
  window.localStorage.clear();
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
          calendarReady: false,
          calendarStatus: "granted",
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
          emailReady: false,
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
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

describe("GettingStartedCard resume", () => {
  it("hides Resume setup when not snoozed", () => {
    clearWizardSnooze();
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
      />,
    );
    expect(screen.queryByTestId("getting-started-resume")).toBeNull();
  });

  it("shows Resume setup only while snoozed and incomplete", () => {
    snoozeWizard();
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
    expect(screen.getByTestId("getting-started-resume")).toHaveTextContent("Resume setup");
    unmount();
    clearWizardSnooze();
  });

  it("shows Resume setup in the dismissed pill while snoozed", () => {
    snoozeWizard();
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
        dismissed
      />,
    );
    expect(screen.getByTestId("getting-started-pill")).toBeInTheDocument();
    expect(screen.getByTestId("getting-started-resume")).toHaveTextContent("Resume setup");
    clearWizardSnooze();
  });

  it("clicking Resume clears snooze and refreshes", async () => {
    const user = userEvent.setup();
    snoozeWizard();
    const onExpand = vi.fn();
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
        onExpand={onExpand}
      />,
    );
    await user.click(screen.getByTestId("getting-started-resume"));
    expect(isWizardSnoozed()).toBe(false);
    expect(onExpand).toHaveBeenCalledTimes(1);
    expect(screen.queryByTestId("getting-started-resume")).toBeNull();
  });

  it("clears snooze on dismiss and expand", async () => {
    const user = userEvent.setup();
    const seenDismiss: string[] = [];
    stubOnboardingFetch(emptyOnboarding(), seenDismiss);
    snoozeWizard();
    const onDismiss = vi.fn();
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
        onDismiss={onDismiss}
      />,
    );
    await user.click(screen.getByTestId("getting-started-dismiss"));
    await waitFor(() => expect(seenDismiss).toContain("/onboarding/dismiss"));
    expect(isWizardSnoozed()).toBe(false);
    unmount();
    vi.unstubAllGlobals();

    const seenExpand: string[] = [];
    stubOnboardingFetch(emptyOnboarding(), seenExpand);
    snoozeWizard();
    const onExpand = vi.fn();
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
        dismissed
        onExpand={onExpand}
      />,
    );
    await user.click(screen.getByTestId("getting-started-expand"));
    await waitFor(() => expect(seenExpand).toContain("/onboarding/reopen"));
    expect(isWizardSnoozed()).toBe(false);
    vi.unstubAllGlobals();
  });

  it("clears snooze on Finish", async () => {
    const user = userEvent.setup();
    snoozeWizard();
    const onFinish = vi.fn();
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
        onFinish={onFinish}
      />,
    );
    await user.click(screen.getByTestId("getting-started-finish"));
    expect(isWizardSnoozed()).toBe(false);
    expect(onFinish).toHaveBeenCalledTimes(1);
  });

  it("hides Resume once verified complete", async () => {
    snoozeWizard();
    const { container } = render(
      <GettingStartedCard
        status={{
          brainReady: true,
          personaSet: true,
          emailReady: false,
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
          calendarReady: false,
          indexReady: false,
          policyAcked: true,
          firstChatSent: true,
        }}
      />,
    );
    await waitFor(() => expect(isWizardSnoozed()).toBe(false));
    expect(screen.queryByTestId("getting-started-resume")).toBeNull();
    expect(container).toBeEmptyDOMElement();
  });
});

describe("Dashboard seed landing", () => {
  function mockDashboardBasics() {
    vi.mocked(api.listApprovals).mockResolvedValue({ approvals: [], count: 0 });
    vi.mocked(api.listRuns).mockResolvedValue({ runs: [], count: 0 });
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
    vi.mocked(api.listIdeas).mockResolvedValue({ ideas: [], count: 0 });
    vi.mocked(api.listSessions).mockResolvedValue({ sessions: [], count: 0 });
  }

  it("finishes to dashboard destination with prefill without auto-send when calendars are granted", async () => {
    const user = userEvent.setup();
    mockDashboardBasics();
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
    const seen: string[] = [];
    stubOnboardingFetch(
      {
        ...emptyOnboarding(),
        brainReady: true,
        personaSet: true,
        calendarStatus: "granted",
        emailAccounts: [],
        indexEnabled: false,
        indexWatermark: null,
        policyAcked: false,
      },
      seen,
    );
    const onFinished = vi.fn();
    const onOpenChatWithPrompt = vi.fn();
    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={vi.fn()}
        onOpenChatWithPrompt={onOpenChatWithPrompt}
        onFinished={onFinished}
      />,
    );
    const finish = await screen.findByTestId("getting-started-finish");
    await user.click(finish);
    await waitFor(() => expect(onFinished).toHaveBeenCalledTimes(1));
    expect(onFinished).toHaveBeenCalledWith({
      kind: "dashboard",
      prompt: GENERIC_SEED_PROMPT,
    });
    expect(onOpenChatWithPrompt).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });

  it("falls back to generic dashboard destination across capabilities without auto-send", async () => {
    const user = userEvent.setup();
    async function finishWithPayload(payload: unknown): Promise<string> {
      mockDashboardBasics();
      vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
      const seen: string[] = [];
      stubOnboardingFetch(payload, seen);
      const onFinished = vi.fn();
      const onOpenChatWithPrompt = vi.fn();
      const { unmount } = render(
        <DashboardView
          health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
          onSelectTab={vi.fn()}
          onOpenChatWithPrompt={onOpenChatWithPrompt}
          onFinished={onFinished}
        />,
      );
      const finish = await screen.findByTestId("getting-started-finish");
      await user.click(finish);
      await waitFor(() => expect(onFinished).toHaveBeenCalledTimes(1));
      const destination = onFinished.mock.calls[0][0] as { kind: string; prompt: string };
      expect(destination.kind).toBe("dashboard");
      expect(onOpenChatWithPrompt).not.toHaveBeenCalled();
      const prompt = destination.prompt;
      unmount();
      vi.unstubAllGlobals();
      return prompt;
    }

    const calendarPrompt = await finishWithPayload({
      ...emptyOnboarding(),
      emailAccounts: [],
      calendarStatus: "granted",
      indexEnabled: false,
      indexWatermark: null,
    });
    expect(calendarPrompt).toBe(GENERIC_SEED_PROMPT);

    const indexPrompt = await finishWithPayload({
      ...emptyOnboarding(),
      emailAccounts: [],
      calendarStatus: "denied",
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(indexPrompt).toBe(GENERIC_SEED_PROMPT);

    const genericPrompt = await finishWithPayload({ ...emptyOnboarding() });
    expect(genericPrompt).toBe(GENERIC_SEED_PROMPT);
  });
});
