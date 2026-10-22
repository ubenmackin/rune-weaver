// Rune Weaver Dashboard — Onboarding finish flow fail-closed schedule tests.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as api from "../../api";
import {
  ensureOnboardingEmailSchedule,
  finishOnboardingFlow,
} from "./onboardingSchedule";
import {
  INDEX_SEED_PROMPT,
  ONBOARDING_EMAIL_DIGEST_PROMPT,
  ONBOARDING_EMAIL_SCHEDULE_CRON,
  ONBOARDING_EMAIL_SCHEDULE_NAME,
  type OnboardingStatus,
} from "./seedPrompt";
import { jsonResponse } from "../../test-utils/http";

vi.mock("../../api", async (importOriginal) => {
  const actual = await importOriginal<typeof api>();
  return {
    ...actual,
    listJobs: vi.fn(),
    createJob: vi.fn(),
    updateJob: vi.fn(),
    updateSettings: vi.fn(),
  };
});

function makeStatus(overrides: Partial<OnboardingStatus> = {}): OnboardingStatus {
  return {
    completedAt: null,
    skippedSteps: [],
    checklistDismissed: false,
    seedPromptUsed: null,
    calendarStatus: "denied",
    emailAccounts: [],
    indexEnabled: false,
    indexWatermark: null,
    personaSet: false,
    policyAcked: false,
    pendingPermission: false,
    ...overrides,
  };
}

function makeJob(overrides: Partial<Awaited<ReturnType<typeof api.createJob>>> = {}) {
  return {
    id: "job-1",
    name: ONBOARDING_EMAIL_SCHEDULE_NAME,
    schedule: ONBOARDING_EMAIL_SCHEDULE_CRON,
    prompt: ONBOARDING_EMAIL_DIGEST_PROMPT,
    enabled: true,
    createdAt: "2026-10-01T00:00:00Z",
    updatedAt: "2026-10-01T00:00:00Z",
    ...overrides,
  } as Awaited<ReturnType<typeof api.createJob>>;
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.unstubAllGlobals();
  window.sessionStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  window.sessionStorage.clear();
});

describe("ensureOnboardingEmailSchedule", () => {
  it("creates the digest when no matching name exists", async () => {
    const job = makeJob({ id: "job-new" });
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
    vi.mocked(api.createJob).mockResolvedValue(job);
    const id = await ensureOnboardingEmailSchedule();
    expect(id).toBe("job-new");
    expect(vi.mocked(api.createJob)).toHaveBeenCalledWith({
      name: ONBOARDING_EMAIL_SCHEDULE_NAME,
      schedule: ONBOARDING_EMAIL_SCHEDULE_CRON,
      prompt: ONBOARDING_EMAIL_DIGEST_PROMPT,
      enabled: true,
    });
  });

  it("throws when creation yields no id and no winner appears", async () => {
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
    vi.mocked(api.createJob).mockResolvedValue(
      {} as unknown as Awaited<ReturnType<typeof api.createJob>>,
    );
    await expect(ensureOnboardingEmailSchedule()).rejects.toThrow(
      "Failed to ensure onboarding email schedule",
    );
  });

  it("repairs a drifted disabled row to the canonical digest", async () => {
    const drifted = makeJob({
      id: "job-drifted",
      schedule: "0 0 * * *",
      prompt: "stale",
      enabled: false,
    });
    const repaired = makeJob({ id: "job-drifted" });
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [drifted], count: 1 });
    vi.mocked(api.updateJob).mockResolvedValue(repaired);
    const id = await ensureOnboardingEmailSchedule();
    expect(id).toBe("job-drifted");
    expect(vi.mocked(api.updateJob)).toHaveBeenCalledWith("job-drifted", {
      schedule: ONBOARDING_EMAIL_SCHEDULE_CRON,
      prompt: ONBOARDING_EMAIL_DIGEST_PROMPT,
      enabled: true,
    });
  });
});

describe("finishOnboardingFlow", () => {
  it("ensures the inbox schedule and lands on schedules", async () => {
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
    vi.mocked(api.createJob).mockResolvedValue(makeJob({ id: "job-inbox" }));
    const complete = vi.fn(async () => {});
    const status = makeStatus({
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
    });
    const result = await finishOnboardingFlow({ status, goal: "inbox", complete });
    expect(result.destination).toEqual({ kind: "schedules" });
    expect(complete).toHaveBeenCalledTimes(1);
  });

  it("blocks finish when the inbox ensure fails", async () => {
    vi.mocked(api.listJobs).mockResolvedValue({ jobs: [], count: 0 });
    vi.mocked(api.createJob).mockResolvedValue(
      {} as unknown as Awaited<ReturnType<typeof api.createJob>>,
    );
    const complete = vi.fn(async () => {});
    const status = makeStatus({
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
    });
    await expect(
      finishOnboardingFlow({ status, goal: "inbox", complete }),
    ).rejects.toThrow("Failed to ensure onboarding email schedule");
    expect(complete).not.toHaveBeenCalled();
  });

  it("enables the index and lands on indexing after a verified reread", async () => {
    vi.mocked(api.updateSettings).mockResolvedValue(
      {} as unknown as Awaited<ReturnType<typeof api.updateSettings>>,
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse(
          makeStatus({ indexEnabled: true, indexWatermark: "2026-10-01T00:00:00Z" }),
        ),
      ),
    );
    const complete = vi.fn(async () => {});
    const result = await finishOnboardingFlow({
      status: makeStatus({ indexEnabled: false, indexWatermark: null }),
      goal: "remember",
      complete,
    });
    expect(vi.mocked(api.updateSettings)).toHaveBeenCalledWith({
      index: { enabled: true },
    });
    expect(result.destination).toEqual({ kind: "indexing", highlightRun: true });
    expect(result.prompt).toBe(INDEX_SEED_PROMPT);
    expect(complete).toHaveBeenCalledTimes(1);
  });

  it("blocks finish when the index enable fails", async () => {
    vi.mocked(api.updateSettings).mockRejectedValue(new Error("index enable failed"));
    const complete = vi.fn(async () => {});
    await expect(
      finishOnboardingFlow({
        status: makeStatus({ indexEnabled: false, indexWatermark: null }),
        goal: "remember",
        complete,
      }),
    ).rejects.toThrow("index enable failed");
    expect(complete).not.toHaveBeenCalled();
  });

  it("holds indexing when the enable succeeds but the reread fails", async () => {
    vi.mocked(api.updateSettings).mockResolvedValue(
      {} as unknown as Awaited<ReturnType<typeof api.updateSettings>>,
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("reread boom");
      }),
    );
    const complete = vi.fn(async () => {});
    const result = await finishOnboardingFlow({
      status: makeStatus({ indexEnabled: false, indexWatermark: null }),
      goal: "remember",
      complete,
    });
    expect(result.destination).toEqual({ kind: "indexing", highlightRun: true });
    expect(complete).toHaveBeenCalledTimes(1);
  });
});
