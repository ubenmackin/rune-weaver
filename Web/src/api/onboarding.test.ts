// Rune Weaver Dashboard — Onboarding client and status hook tests.
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  completeOnboarding,
  dismissChecklist,
  getOnboardingStatus,
  isOnboardingStepId,
  MAX_SEED_PROMPT_CHARS,
  neverStartedOnboardingStatus,
  ONBOARDING_STEP_IDS,
  parseOnboardingStatus,
  reopenOnboarding,
  skipOnboardingStep,
  truncateSeedPromptUsed,
} from "./onboarding";
import { ApiError, clearAuthToken, setAuthToken } from "./http";
import { jsonResponse } from "../test-utils/http";
import { useOnboardingStatus } from "../hooks/useOnboardingStatus";

function freshPayload() {
  return {
    completed: false,
    completedAt: null,
    skippedSteps: [],
    checklistDismissed: false,
    seedPromptUsed: null,
    items: [
      { id: "brain", completed: false, skipped: false },
      { id: "persona", completed: false, skipped: false },
      { id: "connect", completed: false, skipped: false },
      { id: "protect", completed: false, skipped: false },
    ],
  };
}

function completedPayload() {
  return {
    completed: true,
    completedAt: "2026-01-02T03:04:05Z",
    skippedSteps: ["brain"],
    checklistDismissed: false,
    seedPromptUsed: "hello",
    items: [
      { id: "brain", completed: false, skipped: true },
      { id: "persona", completed: true, skipped: false },
      { id: "connect", completed: true, skipped: false },
      { id: "protect", completed: true, skipped: false },
    ],
  };
}

describe("onboarding status parse", () => {
  it("parses the camelCase status shape", () => {
    const parsed = parseOnboardingStatus(freshPayload());
    expect(parsed?.completed).toBe(false);
    expect(parsed?.skippedSteps).toEqual([]);
    expect(parsed?.checklistDismissed).toBe(false);
    expect(parsed?.items).toHaveLength(4);
  });

  it("parses the snake_case row with an integer dismissed flag", () => {
    const parsed = parseOnboardingStatus({
      completed_at: null,
      skipped_steps: ["persona"],
      checklist_dismissed: 1,
      seed_prompt_used: "seed",
      items: [
        { id: "persona", completed: false, skipped: true },
        { id: "brain", completed: true, skipped: false },
      ],
    });
    expect(parsed?.skippedSteps).toEqual(["persona"]);
    expect(parsed?.checklistDismissed).toBe(true);
    expect(parsed?.seedPromptUsed).toBe("seed");
  });

  it("drops unknown step ids instead of entering view state", () => {
    const parsed = parseOnboardingStatus({
      completed: false,
      completedAt: null,
      skippedSteps: ["brain", "nope"],
      checklistDismissed: false,
      seedPromptUsed: null,
      items: [
        { id: "brain", completed: false, skipped: true },
        { id: "nope", completed: true, skipped: false },
      ],
    });
    expect(parsed?.skippedSteps).toEqual(["brain"]);
    expect((parsed?.items ?? []).map((item) => item.id).sort()).toEqual([
      "brain",
      "connect",
      "persona",
      "protect",
    ]);
  });

  it("reads an absent row as never-started", () => {
    expect(parseOnboardingStatus(null)).toEqual(neverStartedOnboardingStatus());
    expect(parseOnboardingStatus(undefined)).toEqual(neverStartedOnboardingStatus());
    const parsed = parseOnboardingStatus(freshPayload());
    expect(parsed?.completed).toBe(false);
  });

  it("rejects drifted shapes fail-closed", () => {
    expect(parseOnboardingStatus(42)).toBeNull();
    expect(parseOnboardingStatus("done")).toBeNull();
    expect(parseOnboardingStatus([])).toBeNull();
  });

  it("pins the four-value step union", () => {
    expect([...ONBOARDING_STEP_IDS].sort()).toEqual([
      "brain",
      "connect",
      "persona",
      "protect",
    ]);
    expect(isOnboardingStepId("brain")).toBe(true);
    expect(isOnboardingStepId("unknown")).toBe(false);
    expect(isOnboardingStepId(42)).toBe(false);
  });

  it("parses verified evidence alongside legacy readiness flags", () => {
    const parsed = parseOnboardingStatus({
      ...freshPayload(),
      brainReady: true,
      personaSet: true,
      emailReady: false,
      calendarReady: false,
      indexReady: false,
      policyAcked: false,
      calendarStatus: "granted",
      emailAccounts: [{ address: "owner@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-01-01T00:00:00Z",
    });
    expect(parsed?.brainReady).toBe(true);
    expect(parsed?.calendarStatus).toBe("granted");
    expect(parsed?.emailAccounts).toEqual([
      { address: "owner@example.com", fetchSucceeded: true },
    ]);
    expect(parsed?.indexEnabled).toBe(true);
    expect(parsed?.indexWatermark).toBe("2026-01-01T00:00:00Z");
  });

  it("defaults verified evidence fail-closed when absent", () => {
    const parsed = parseOnboardingStatus(freshPayload());
    expect(parsed?.calendarStatus).toBeNull();
    expect(parsed?.emailAccounts).toEqual([]);
    expect(parsed?.indexEnabled).toBe(false);
    expect(parsed?.indexWatermark).toBeNull();
  });
});

describe("onboarding client", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("fetches status from the single status endpoint", async () => {
    const fetchMock = vi.fn(async () => jsonResponse(freshPayload()));
    vi.stubGlobal("fetch", fetchMock);
    const status = await getOnboardingStatus();
    expect(status.completed).toBe(false);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/onboarding/status");
  });

  it("truncates an overlong seed prompt with an ellipsis", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    const long = "x".repeat(MAX_SEED_PROMPT_CHARS + 50);
    await completeOnboarding(long);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/onboarding/complete");
    expect(init.method).toBe("POST");
    const body = JSON.parse(init.body as string) as { seedPromptUsed: string };
    expect(body.seedPromptUsed.length).toBeLessThanOrEqual(MAX_SEED_PROMPT_CHARS);
    expect(body.seedPromptUsed.endsWith("…")).toBe(true);
    expect(truncateSeedPromptUsed("short")).toBe("short");
  });

  it("sends only the allowlisted step id on skip", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    await skipOnboardingStep("connect");
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/onboarding/skip");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({ step: "connect" });
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("rejects an unknown step before touching the wire", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    await expect(
      skipOnboardingStep("unknown" as unknown as "brain"),
    ).rejects.toBeInstanceOf(ApiError);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("dismisses and reopens through their single endpoints", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    await dismissChecklist();
    await reopenOnboarding();
    const paths = fetchMock.mock.calls.map(
      (call) => (call as unknown as [string])[0],
    );
    expect(paths).toEqual(["/onboarding/dismiss", "/onboarding/reopen"]);
  });

  it("surfaces 401 as an ApiError for the hook needs-auth state", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reason: "unauthorized" }, 401)),
    );
    const failure = await getOnboardingStatus().catch((err) => err);
    expect(failure).toBeInstanceOf(ApiError);
    expect((failure as ApiError).status).toBe(401);
  });

  it("surfaces the 400 unknown_step message verbatim", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reason: "unknown_step: wat" }, 400)),
    );
    const failure = await skipOnboardingStep("brain").catch((err) => err);
    expect(failure).toBeInstanceOf(ApiError);
    expect((failure as ApiError).status).toBe(400);
    expect((failure as ApiError).message).toContain("unknown_step: wat");
  });
});

describe("useOnboardingStatus", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns never-started on a fresh backend", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(freshPayload())));
    const { result, unmount } = renderHook(() => useOnboardingStatus());
    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });
    expect(result.current.status?.completed).toBe(false);
    expect(result.current.isCompleted).toBe(false);
    expect(result.current.needsAuth).toBe(false);
    unmount();
  });

  it("surfaces needs-auth on 401 with no cached row", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reason: "unauthorized" }, 401)),
    );
    const { result, unmount } = renderHook(() => useOnboardingStatus());
    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });
    expect(result.current.needsAuth).toBe(true);
    expect(result.current.status).toBeNull();
    expect(result.current.isCompleted).toBe(false);
    unmount();
  });

  it("refreshes on window focus", async () => {
    let payload: unknown = freshPayload();
    const fetchMock = vi.fn(async () => jsonResponse(payload));
    vi.stubGlobal("fetch", fetchMock);
    const { result, unmount } = renderHook(() => useOnboardingStatus());
    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });
    expect(result.current.status?.completed).toBe(false);
    const callsBefore = fetchMock.mock.calls.length;
    payload = completedPayload();
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    await waitFor(() => {
      expect(fetchMock.mock.calls.length).toBeGreaterThan(callsBefore);
    });
    await waitFor(() => {
      expect(result.current.status?.completed).toBe(true);
    });
    expect(result.current.isCompleted).toBe(true);
    unmount();
  });

  it("re-reads after every mutation", async () => {
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string) => {
      seen.push(input);
      if (input === "/onboarding/status") return jsonResponse(freshPayload());
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    const { result, unmount } = renderHook(() => useOnboardingStatus());
    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });
    const statusCallsBefore = seen.filter((path) => path === "/onboarding/status").length;
    await act(async () => {
      await result.current.complete("hello");
    });
    await act(async () => {
      await result.current.skip("brain");
    });
    await act(async () => {
      await result.current.dismiss();
    });
    await act(async () => {
      await result.current.reopen();
    });
    const statusCallsAfter = seen.filter((path) => path === "/onboarding/status").length;
    expect(statusCallsAfter).toBeGreaterThan(statusCallsBefore);
    expect(seen).toContain("/onboarding/complete");
    expect(seen).toContain("/onboarding/skip");
    expect(seen).toContain("/onboarding/dismiss");
    expect(seen).toContain("/onboarding/reopen");
    unmount();
  });

  it("drops the cache across an auth change", async () => {
    const fetchMock = vi.fn(async (input: string) => {
      if (typeof input === "string" && input.startsWith("/auth/")) {
        return jsonResponse({});
      }
      return jsonResponse(freshPayload());
    });
    vi.stubGlobal("fetch", fetchMock);
    const { result, unmount } = renderHook(() => useOnboardingStatus());
    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });
    expect(result.current.status?.completed).toBe(false);
    const callsBefore = fetchMock.mock.calls.length;
    await act(async () => {
      setAuthToken("owner-token");
      await Promise.resolve();
    });
    await waitFor(() => {
      expect(fetchMock.mock.calls.length).toBeGreaterThan(callsBefore);
    });
    await waitFor(() => {
      expect(result.current.status?.completed).toBe(false);
    });
    unmount();
    clearAuthToken();
  });
});
