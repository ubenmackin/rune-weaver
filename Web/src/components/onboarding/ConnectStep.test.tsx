// Rune Weaver Dashboard — Tests for onboarding connect, protect, and seed selection.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ConnectStep from "./ConnectStep";
import ProtectStep from "./ProtectStep";
import {
  CALENDAR_SEED_PROMPT,
  EMAIL_SEED_PROMPT,
  GENERIC_SEED_PROMPT,
  INDEX_SEED_PROMPT,
  parseOnboardingStatus,
  selectSeedPrompt,
  type OnboardingStatus,
} from "./seedPrompt";
import { jsonResponse } from "../../test-utils/http";

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

describe("selectSeedPrompt", () => {
  it("returns the calendar prompt only when calendars are granted", () => {
    const status = makeStatus({
      calendarStatus: "granted",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(selectSeedPrompt(status)).toBe(CALENDAR_SEED_PROMPT);
  });

  it("returns the email prompt only when a fetch succeeded without granted calendars", () => {
    const status = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(selectSeedPrompt(status)).toBe(EMAIL_SEED_PROMPT);
  });

  it("returns the index prompt only when email is unverified but the index is ready", () => {
    const status = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: false }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(selectSeedPrompt(status)).toBe(INDEX_SEED_PROMPT);
  });

  it("returns the generic briefing prompt otherwise, seeding no unverified capability", () => {
    const status = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [],
      indexEnabled: false,
      indexWatermark: null,
    });
    const seed = selectSeedPrompt(status);
    expect(seed).toBe(GENERIC_SEED_PROMPT);
    expect(seed).toContain("What can you help me with");
    expect(seed).toContain("Morning briefing");
    expect(seed).not.toBe(CALENDAR_SEED_PROMPT);
    expect(seed).not.toBe(EMAIL_SEED_PROMPT);
    expect(seed).not.toBe(INDEX_SEED_PROMPT);
  });

  it("treats absent status as never-started generic without a capability turn", () => {
    expect(selectSeedPrompt(null)).toBe(GENERIC_SEED_PROMPT);
    expect(selectSeedPrompt(undefined)).toBe(GENERIC_SEED_PROMPT);
    expect(parseOnboardingStatus(null).calendarStatus).toBeNull();
  });
});

describe("ConnectStep", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("shows three cards in goal order with live badges", () => {
    const status = makeStatus({
      calendarStatus: "granted",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    const { container } = render(
      <ConnectStep status={status} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    const cards = Array.from(
      container.querySelectorAll('[data-testid^="connect-"][data-testid$="-card"]'),
    );
    expect(cards.map((card) => card.getAttribute("data-testid"))).toEqual([
      "connect-email-card",
      "connect-calendar-card",
      "connect-index-card",
    ]);
    expect(screen.getByTestId("connect-email-badge")).toHaveTextContent("Ready");
    expect(screen.getByTestId("connect-calendar-badge")).toHaveTextContent("Ready");
    expect(screen.getByTestId("connect-index-badge")).toHaveTextContent("Ready");
  });

  it("maps badges to Ready, Not connected, and Needs permission", () => {
    const status = makeStatus({
      calendarStatus: "notDetermined",
      emailAccounts: [],
      indexEnabled: false,
      indexWatermark: null,
    });
    render(
      <ConnectStep status={status} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    expect(screen.getByTestId("connect-email-badge")).toHaveTextContent("Not connected");
    expect(screen.getByTestId("connect-calendar-badge")).toHaveTextContent("Needs permission");
    expect(screen.getByTestId("connect-index-badge")).toHaveTextContent("Not connected");
  });

  it("shows the permission detour only for unverified calendars", () => {
    const unverified = makeStatus({ calendarStatus: "denied" });
    const { rerender } = render(
      <ConnectStep status={unverified} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    const explainer = screen.getByTestId("calendar-permission-explainer");
    expect(explainer).toHaveTextContent("Rune Weaver needs Calendars in System Settings");
    expect(
      within(explainer).getByRole("link", { name: /Open Permissions/i }),
    ).toBeInTheDocument();
    expect(
      within(explainer).getByRole("button", { name: /Check Again/i }),
    ).toBeInTheDocument();
    expect(
      within(explainer).getByRole("button", { name: /Skip connect for now/i }),
    ).toBeInTheDocument();

    rerender(
      <ConnectStep
        status={makeStatus({ calendarStatus: "granted" })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    expect(screen.queryByTestId("calendar-permission-explainer")).toBeNull();
  });

  it("re-reads live status through Check Again", async () => {
    const user = userEvent.setup();
    const refresh = vi.fn();
    render(
      <ConnectStep status={makeStatus()} refresh={refresh} onSkipCalendar={() => {}} />,
    );
    await user.click(screen.getByRole("button", { name: /Check Again/i }));
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("records a calendar skip through the skip action", async () => {
    const user = userEvent.setup();
    const onSkipCalendar = vi.fn();
    render(
      <ConnectStep status={makeStatus()} refresh={() => {}} onSkipCalendar={onSkipCalendar} />,
    );
    await user.click(
      screen.getByRole("button", { name: /Skip connect for now/i }),
    );
    expect(onSkipCalendar).toHaveBeenCalledTimes(1);
  });

  it("posts the calendar skip into skipped steps when uncontrolled", async () => {
    const user = userEvent.setup();
    const seen: Array<{ path: string; body: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        const method = (init?.method ?? "GET").toUpperCase();
        if (path === "/onboarding/status" && method === "GET") {
          return jsonResponse(makeStatus({ calendarStatus: "denied" }));
        }
        if (path === "/onboarding/skip" && method === "POST") {
          seen.push({ path, body: String(init?.body ?? "") });
          return jsonResponse(
            makeStatus({ calendarStatus: "denied", skippedSteps: ["connect"] }),
          );
        }
        return jsonResponse({});
      }),
    );
    render(<ConnectStep />);
    await user.click(
      await screen.findByRole("button", { name: /Skip connect for now/i }),
    );
    await waitFor(() => expect(seen).toHaveLength(1));
    expect(seen[0].path).toBe("/onboarding/skip");
    expect(seen[0].body).toContain("connect");
  });
});

describe("ProtectStep", () => {
  it("renders the three read-only bullets with a Settings Access link", () => {
    render(
      <ProtectStep policyAcked={false} onPolicyAckedChange={() => {}} onFinish={() => {}} />,
    );
    expect(screen.getByText(/Reads freely, writes ask first/i)).toBeInTheDocument();
    expect(screen.getByText(/Allowlist-only network/i)).toBeInTheDocument();
    expect(screen.getByText(/Secrets never in prompts/i)).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: /Settings Access/i }),
    ).toHaveAttribute("href", "#settings/access");
  });

  it("maps the checkbox to the policy acknowledgement without gating Finish", async () => {
    const user = userEvent.setup();
    const onPolicyAckedChange = vi.fn();
    const onFinish = vi.fn();
    render(
      <ProtectStep
        policyAcked={false}
        onPolicyAckedChange={onPolicyAckedChange}
        onFinish={onFinish}
      />,
    );
    const checkbox = screen.getByRole("checkbox", {
      name: /I understand writes need approval/i,
    });
    expect(checkbox).not.toBeChecked();
    await user.click(checkbox);
    expect(onPolicyAckedChange).toHaveBeenCalledWith(true);

    const finish = screen.getByRole("button", { name: /^Finish$/ });
    expect(finish).toBeEnabled();
    await user.click(finish);
    expect(onFinish).toHaveBeenCalledTimes(1);
  });
});
