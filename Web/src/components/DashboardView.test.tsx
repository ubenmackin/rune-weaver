// Rune Weaver Dashboard — Unit and integration tests for DashboardView and dashboard components.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import DashboardView from "./DashboardView";
import DashboardPromptBar from "./dashboard/DashboardPromptBar";
import MorningRecommendations from "./dashboard/MorningRecommendations";
import NeedsActionQueue from "./dashboard/NeedsActionQueue";
import GoalsCockpit from "./dashboard/GoalsCockpit";
import WorkingNowStream from "./dashboard/WorkingNowStream";
import UpcomingSchedules from "./dashboard/UpcomingSchedules";
import SystemPulseCard from "./dashboard/SystemPulseCard";
import RecentReports, { getReportRunKind } from "./dashboard/RecentReports";
import { clearSharedRecentRunsForTesting } from "./dashboard/sharedRuns";
import * as api from "../api";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

vi.mock("../api", async (importOriginal) => {
  const actual = await importOriginal<typeof api>();
  return {
    ...actual,
    listIdeas: vi.fn(),
    acceptIdea: vi.fn(),
    dismissIdea: vi.fn(),
    listApprovals: vi.fn(),
    decideApproval: vi.fn(),
    listGoals: vi.fn(),
    advanceGoal: vi.fn(),
    listRuns: vi.fn(),
    cancelRun: vi.fn(),
    listJobs: vi.fn(),
    runJobNow: vi.fn(),
  };
});

// The shared runs fetcher caches across widgets in module state, so every
// dashboard test starts from an empty cache; otherwise one test's payload
// would leak into the next through the fresh-cache fast path.
beforeEach(() => {
  clearSharedRecentRunsForTesting();
});

describe("DashboardPromptBar", () => {
  it("submits prompt on Enter and clear", async () => {
    const user = userEvent.setup();
    const onSubmit = vi.fn();
    render(<DashboardPromptBar onSubmitPrompt={onSubmit} />);

    const input = screen.getByPlaceholderText(/Ask RuneWeaver anything/i);
    await user.type(input, "Investigate test failures{enter}");

    expect(onSubmit).toHaveBeenCalledWith("Investigate test failures");
  });

  it("submits when clicking quick suggestion chip", async () => {
    const user = userEvent.setup();
    const onSubmit = vi.fn();
    render(<DashboardPromptBar onSubmitPrompt={onSubmit} />);

    const chip = screen.getByRole("button", { name: /Review staged git changes/i });
    await user.click(chip);

    expect(onSubmit).toHaveBeenCalledWith("Review staged git changes");
  });
});

describe("MorningRecommendations", () => {
  const mockIdea = {
    id: "idea-123",
    kind: "flaky_test",
    title: "Fix flaky tests in CI",
    body: "Found 3 flaky tests in RuneWeaverCore",
    goalId: null,
    status: "proposed",
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders proposed ideas and handles accept", async () => {
    const user = userEvent.setup();
    vi.mocked(api.listIdeas).mockResolvedValue({
      ideas: [mockIdea],
      count: 1,
    });
    vi.mocked(api.acceptIdea).mockResolvedValue({
      ...mockIdea,
      status: "accepted",
    });

    const onAccepted = vi.fn();
    render(<MorningRecommendations onIdeaAccepted={onAccepted} />);

    await waitFor(() => {
      expect(screen.getByText("Fix flaky tests in CI")).toBeInTheDocument();
    });

    const acceptBtn = screen.getByRole("button", { name: /Accept idea: Fix flaky tests in CI/i });
    await user.click(acceptBtn);

    expect(api.acceptIdea).toHaveBeenCalledWith("idea-123");
    await waitFor(() => {
      expect(onAccepted).toHaveBeenCalled();
    });
  });

  it("handles dismiss idea", async () => {
    const user = userEvent.setup();
    vi.mocked(api.listIdeas).mockResolvedValue({
      ideas: [mockIdea],
      count: 1,
    });
    vi.mocked(api.dismissIdea).mockResolvedValue({
      ...mockIdea,
      status: "dismissed",
    });

    render(<MorningRecommendations />);

    await waitFor(() => {
      expect(screen.getByText("Fix flaky tests in CI")).toBeInTheDocument();
    });

    const dismissBtn = screen.getByRole("button", { name: /Dismiss idea: Fix flaky tests in CI/i });
    await user.click(dismissBtn);

    expect(api.dismissIdea).toHaveBeenCalledWith("idea-123");
    await waitFor(() => {
      expect(screen.queryByText("Fix flaky tests in CI")).not.toBeInTheDocument();
    });
  });

  it("refetches proposed ideas when receiving a proactive idea_proposed WebSocket frame", async () => {
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    resetSharedSocket();

    vi.mocked(api.listIdeas).mockResolvedValueOnce({
      ideas: [mockIdea],
      count: 1,
    });

    render(<MorningRecommendations />);

    await waitFor(() => {
      expect(screen.getByText("Fix flaky tests in CI")).toBeInTheDocument();
    });

    const secondIdea: api.Idea = {
      ...mockIdea,
      id: "idea-456",
      title: "Add concurrency benchmarks",
    };
    vi.mocked(api.listIdeas).mockResolvedValueOnce({
      ideas: [mockIdea, secondIdea],
      count: 2,
    });

    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "proactive_message",
      kind: "idea_proposed",
      title: "Add concurrency benchmarks",
      headline: "A fresh suggestion",
    });

    await waitFor(() => {
      expect(screen.getByText("Add concurrency benchmarks")).toBeInTheDocument();
    });

    vi.unstubAllGlobals();
    resetSharedSocket();
  });
});

describe("NeedsActionQueue", () => {
  const mockApproval: api.PermissionRequest = {
    id: "appr-1",
    toolName: "git.push",
    description: "Push changes to origin/main",
    input: {
      toolName: "git.push",
      argumentsJSON: "branch: main, force: false",
      callID: "call-1",
    },
    suggestedDurations: ["thisTime"],
    sessionID: "session-abc",
    assessment: {
      severity: "dangerous",
      outcome: "Modifies remote repository",
    },
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
  });

  it("renders pending approval card and approves it", async () => {
    const user = userEvent.setup();
    vi.mocked(api.listApprovals).mockResolvedValue({
      approvals: [mockApproval],
      count: 1,
    });
    vi.mocked(api.decideApproval).mockResolvedValue({
      id: "appr-1",
      approved: true,
      duration: "thisTime",
    });

    render(<NeedsActionQueue />);

    await waitFor(() => {
      expect(screen.getByText("git.push")).toBeInTheDocument();
      expect(screen.getByText("Push changes to origin/main")).toBeInTheDocument();
    });

    const approveBtn = screen.getByRole("button", { name: /Approve git.push/i });
    await user.click(approveBtn);

    expect(api.decideApproval).toHaveBeenCalledWith("appr-1", true);
  });

  it("renders all-clear state when there are no approvals or blocked goals", async () => {
    vi.mocked(api.listApprovals).mockResolvedValue({
      approvals: [],
      count: 0,
    });
    vi.mocked(api.listGoals).mockResolvedValue({
      goals: [],
      count: 0,
    });

    render(<NeedsActionQueue />);

    await waitFor(() => {
      expect(screen.getByText("All Caught Up")).toBeInTheDocument();
    });
  });

  it("renders continuation approval with specialized Continue and Stop labels", async () => {
    const user = userEvent.setup();
    const mockContinuation: api.PermissionRequest = {
      id: "cont-1",
      toolName: "engine.continue",
      description: "The agent has completed 10 tool rounds and is requesting continuation.",
      input: {
        toolName: "engine.continue",
        argumentsJSON: "{\"rounds\":10}",
        callID: "call-cont-1",
      },
      suggestedDurations: ["thisTime"],
      sessionID: "session-goal-xyz",
      assessment: {
        severity: "moderate",
        outcome: "Allows the agent to proceed with additional tool execution rounds.",
      },
    };

    vi.mocked(api.listApprovals).mockResolvedValue({
      approvals: [mockContinuation],
      count: 1,
    });
    vi.mocked(api.decideApproval).mockResolvedValue({
      id: "cont-1",
      approved: true,
      duration: "thisTime",
    });

    render(<NeedsActionQueue />);

    await waitFor(() => {
      expect(screen.getByText("Continuation")).toBeInTheDocument();
      expect(screen.getByText("The agent has completed 10 tool rounds and is requesting continuation.")).toBeInTheDocument();
    });

    const continueBtn = screen.getByRole("button", { name: /Continue execution/i });
    expect(continueBtn).toHaveTextContent("Continue");
    const stopBtn = screen.getByRole("button", { name: /Stop execution/i });
    expect(stopBtn).toHaveTextContent("Stop");

    await user.click(continueBtn);
    expect(api.decideApproval).toHaveBeenCalledWith("cont-1", true);
  });

  it("renders arguments inside expandable disclosure with View arguments summary", async () => {
    vi.mocked(api.listApprovals).mockResolvedValue({
      approvals: [mockApproval],
      count: 1,
    });

    render(<NeedsActionQueue />);

    await waitFor(() => {
      expect(screen.getByText("View arguments")).toBeInTheDocument();
      expect(screen.getByText("branch: main, force: false")).toBeInTheDocument();
    });
  });
});

describe("WorkingNowStream", () => {
  const mockRunningRun: api.RunLogEntry = {
    id: "run-active-1",
    kind: "goal",
    status: "running",
    message: "Executing migration step 2",
    timestamp: Date.now() - 5000,
    sessionID: "sess-1",
    toolActions: [],
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders running tasks and handles stop", async () => {
    const user = userEvent.setup();
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [mockRunningRun],
      count: 1,
    });
    vi.mocked(api.cancelRun).mockResolvedValue({
      cancelled: true,
      scope: "run",
    });

    render(<WorkingNowStream />);

    await waitFor(() => {
      expect(screen.getByText("Executing migration step 2")).toBeInTheDocument();
    });

    const stopBtn = screen.getByRole("button", { name: /Stop task: run-active-1/i });
    await user.click(stopBtn);

    expect(api.cancelRun).toHaveBeenCalledWith("run-active-1");
  });

  it("renders idle state when no active runs exist", async () => {
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [],
      count: 0,
    });

    render(<WorkingNowStream />);

    await waitFor(() => {
      expect(screen.getByText("All Systems Idle")).toBeInTheDocument();
    });
  });
});

describe("GoalsCockpit", () => {
  const mockGoal: api.Goal = {
    id: "goal-1",
    title: "Harness v1.2 Release",
    statement: "Deliver dashboard and companion workflows",
    status: "active",
    progress: { done: 3, total: 6 },
    stepIntervalMinutes: 60,
    nextDueAt: Date.now() + 1800000,
    originSessionId: null,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders active goal with progress bar and advances on click", async () => {
    const user = userEvent.setup();
    vi.mocked(api.listGoals).mockResolvedValue({
      goals: [mockGoal],
      count: 1,
    });
    vi.mocked(api.advanceGoal).mockResolvedValue({
      runID: "run-10",
      sessionID: "sess-10",
      goalId: "goal-1",
    });

    render(<GoalsCockpit />);

    await waitFor(() => {
      expect(screen.getByText("Harness v1.2 Release")).toBeInTheDocument();
      expect(screen.getByText("Step 3 of 6")).toBeInTheDocument();
      expect(screen.getByText("50%")).toBeInTheDocument();
      const statusPill = screen.getByText("Active");
      expect(statusPill).toHaveClass("status-pill", "running");
      expect(statusPill).not.toHaveClass("pill-running");
    });

    const advanceBtn = screen.getByRole("button", { name: /Advance goal now: Harness v1.2 Release/i });
    await user.click(advanceBtn);

    expect(api.advanceGoal).toHaveBeenCalledWith("goal-1");
  });
});

describe("UpcomingSchedules", () => {
  const mockJob: api.SchedulerJob = {
    id: "job-1",
    name: "PR Watcher",
    schedule: "0 * * * *",
    prompt: "Check open PRs",
    enabled: true,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders active scheduled jobs and handles Run Now", async () => {
    const user = userEvent.setup();
    vi.mocked(api.listJobs).mockResolvedValue({
      jobs: [mockJob],
      count: 1,
    });
    vi.mocked(api.runJobNow).mockResolvedValue({
      text: "Started",
      sessionID: "sess-1",
      toolActions: [],
    });

    render(<UpcomingSchedules />);

    await waitFor(() => {
      expect(screen.getByText("PR Watcher")).toBeInTheDocument();
      expect(screen.getByText("0 * * * *")).toBeInTheDocument();
    });

    const runNowBtn = screen.getByRole("button", { name: /Run schedule now: PR Watcher/i });
    await user.click(runNowBtn);

    expect(api.runJobNow).toHaveBeenCalledWith("job-1");
  });
});

describe("SystemPulseCard", () => {
  it("renders operational engine health and model", () => {
    const health: api.HealthResponse = {
      status: "ok",
      engine: "RuneWeaver",
      version: "1.2.0",
      model: "claude-3-5-sonnet",
      provider: "Anthropic",
    };

    render(<SystemPulseCard health={health} stagedFilesCount={2} />);

    expect(screen.getByText("Operational")).toBeInTheDocument();
    expect(screen.getByText(/claude-3-5-sonnet/i)).toBeInTheDocument();
    expect(screen.getByText("2 files")).toBeInTheDocument();
  });
});

describe("RecentReports", () => {
  const mockCompletedRun: api.RunLogEntry = {
    id: "run-done-1",
    kind: "scheduler",
    status: "ok",
    message: "Morning Inbox Triage",
    response: "Processed 12 emails and flagged 2 PRs.",
    timestamp: Date.now() - 60000,
    durationMs: 4200,
    totalTokens: 1450,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders completed report card", async () => {
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [mockCompletedRun],
      count: 1,
    });

    render(<RecentReports />);

    await waitFor(() => {
      expect(screen.getByText("Morning Inbox Triage")).toBeInTheDocument();
      expect(screen.getByText(/Processed 12 emails/i)).toBeInTheDocument();
      expect(screen.getByText("OK")).toBeInTheDocument();
      expect(screen.getByText("1,450 tokens")).toBeInTheDocument();
    });
  });

  it("renders completed report card and handles open session", async () => {
    const user = userEvent.setup();
    const onOpenSession = vi.fn();
    const runWithSession: api.RunLogEntry = {
      ...mockCompletedRun,
      sessionID: "sess-run-456",
    };
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [runWithSession],
      count: 1,
    });

    render(<RecentReports onOpenSession={onOpenSession} />);

    await waitFor(() => {
      expect(screen.getByText("Morning Inbox Triage")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Thread/i })).toBeInTheDocument();
    });

    const threadBtn = screen.getByRole("button", { name: /Thread/i });
    await user.click(threadBtn);

    expect(onOpenSession).toHaveBeenCalledWith("sess-run-456");
  });

  it("hides the Thread button for index runs even if a sessionID is present", async () => {
    const indexRun: api.RunLogEntry = {
      id: "run-index-1",
      kind: "index",
      status: "ok",
      message: "Indexed 150 documents",
      timestamp: Date.now() - 30000,
      sessionID: "sess-index-ignore",
    };
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [indexRun],
      count: 1,
    });

    render(<RecentReports onOpenSession={vi.fn()} />);

    await waitFor(() => {
      expect(screen.getByText("Indexed 150 documents")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Inspect Run/i })).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /Thread/i })).not.toBeInTheDocument();
    });
  });

  it("classifies run kinds accurately via getReportRunKind", () => {
    expect(getReportRunKind({ id: "1", goalId: "g-1", kind: "chat", status: "ok", message: "", timestamp: 0 })).toEqual({
      kind: "goal",
      label: "Goal",
      className: "kind-goal",
    });
    expect(getReportRunKind({ id: "2", jobID: "j-1", kind: "chat", status: "ok", message: "", timestamp: 0 })).toEqual({
      kind: "schedule",
      label: "Scheduled",
      className: "kind-schedule",
    });
    expect(getReportRunKind({ id: "3", kind: "index", status: "ok", message: "", timestamp: 0 })).toEqual({
      kind: "index",
      label: "Index",
      className: "kind-index",
    });
    expect(getReportRunKind({ id: "4", kind: "fanout", status: "ok", message: "", timestamp: 0 })).toEqual({
      kind: "fanout",
      label: "Fan-out",
      className: "kind-fanout",
    });
    expect(getReportRunKind({ id: "5", kind: "fanout_worker", status: "ok", message: "", timestamp: 0 })).toEqual({
      kind: "fanout_worker",
      label: "Worker",
      className: "kind-worker",
    });
    expect(getReportRunKind({ id: "6", kind: "chat", status: "ok", message: "", timestamp: 0 })).toEqual({
      kind: "chat",
      label: "Chat",
      className: "kind-chat",
    });
  });

  it("renders run kind badge and metric separator between duration and tokens", async () => {
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [mockCompletedRun],
      count: 1,
    });

    render(<RecentReports />);

    await waitFor(() => {
      const badge = screen.getByTestId("report-kind-badge");
      expect(badge).toHaveTextContent("Scheduled");
      expect(badge).toHaveClass("kind-schedule");
      // Check duration, tokens, and bullet separator
      expect(screen.getByText("4.2s")).toBeInTheDocument();
      expect(screen.getByText("1,450 tokens")).toBeInTheDocument();
      expect(screen.getByText("•")).toBeInTheDocument();
    });
  });
});

describe("DashboardView integration", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(api.listIdeas).mockResolvedValue({ ideas: [], count: 0 });
    vi.mocked(api.listApprovals).mockResolvedValue({ approvals: [], count: 0 });
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });
    vi.mocked(api.listRuns).mockResolvedValue({ runs: [], count: 0 });
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
  });

  it("mounts full dashboard with welcome header and sections", async () => {
    const onSelectTab = vi.fn();
    const onPromptSubmit = vi.fn();

    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={onSelectTab}
        onOpenChatWithPrompt={onPromptSubmit}
      />,
    );

    await waitFor(() => {
      expect(screen.getByRole("region", { name: "Executive Operations Dashboard" })).toBeInTheDocument();
      expect(screen.getByText(/Operator/i)).toBeInTheDocument();
      expect(screen.getByPlaceholderText(/Ask RuneWeaver anything/i)).toBeInTheDocument();
    });
  });

  it("forwards onOpenSession from child components", async () => {
    const user = userEvent.setup();
    const onOpenSession = vi.fn();
    vi.mocked(api.listRuns).mockResolvedValue({
      runs: [
        {
          id: "run-recent-99",
          kind: "interactive",
          status: "ok",
          message: "Check build health",
          sessionID: "session-target-777",
          timestamp: Date.now(),
        },
      ],
      count: 1,
    });

    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={vi.fn()}
        onOpenSession={onOpenSession}
      />,
    );

    await waitFor(() => {
      expect(screen.getByRole("button", { name: /Thread/i })).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: /Thread/i }));
    expect(onOpenSession).toHaveBeenCalledWith("session-target-777");
  });

  it("refreshes goals when an idea is accepted", async () => {
    const user = userEvent.setup();
    const mockIdea = {
      id: "idea-refresh-1",
      kind: "maintenance",
      title: "Clean build artifacts",
      body: "Clean temporary build files",
      status: "proposed",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    vi.mocked(api.listIdeas).mockResolvedValue({ ideas: [mockIdea as any], count: 1 });
    vi.mocked(api.acceptIdea).mockResolvedValue({ ...mockIdea, status: "accepted" } as any);
    vi.mocked(api.listGoals).mockResolvedValue({ goals: [], count: 0 });

    render(
      <DashboardView
        health={{ status: "ok", engine: "RuneWeaver", version: "1.0.0" }}
        onSelectTab={vi.fn()}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Clean build artifacts")).toBeInTheDocument();
    });

    const initialGoalCalls = vi.mocked(api.listGoals).mock.calls.length;

    const acceptBtn = screen.getByRole("button", { name: /Accept idea: Clean build artifacts/i });
    await user.click(acceptBtn);

    await waitFor(() => {
      expect(vi.mocked(api.listGoals).mock.calls.length).toBeGreaterThan(initialGoalCalls);
    });
  });
});
