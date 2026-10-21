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
  emailBadge,
  indexBadge,
  isConnectReady,
  isEmailReady,
  isIndexReady,
  parseOnboardingStatus,
  selectSeedPrompt,
  type OnboardingStatus,
} from "./seedPrompt";
import { jsonResponse } from "../../test-utils/http";
import {
  clearWizardSnooze,
  isWizardSnoozed,
} from "./wizardSnooze";

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

  it("prefers the goal capability when ready", () => {
    const status = makeStatus({
      calendarStatus: "granted",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(selectSeedPrompt(status, "inbox")).toBe(EMAIL_SEED_PROMPT);
    expect(selectSeedPrompt(status, "day")).toBe(CALENDAR_SEED_PROMPT);
    expect(selectSeedPrompt(status, "remember")).toBe(INDEX_SEED_PROMPT);
  });

  it("falls back to fixed priority when the goal capability is not ready", () => {
    const indexOnly = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(selectSeedPrompt(indexOnly, "inbox")).toBe(INDEX_SEED_PROMPT);
    const calendarOnly = makeStatus({
      calendarStatus: "granted",
      emailAccounts: [],
      indexEnabled: false,
      indexWatermark: null,
    });
    expect(selectSeedPrompt(calendarOnly, "remember")).toBe(CALENDAR_SEED_PROMPT);
    expect(selectSeedPrompt(calendarOnly, null)).toBe(CALENDAR_SEED_PROMPT);
  });

  it("keeps single-arg behavior unchanged for legacy callers", () => {
    const status = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    expect(selectSeedPrompt(status)).toBe(EMAIL_SEED_PROMPT);
    expect(selectSeedPrompt(status, undefined)).toBe(EMAIL_SEED_PROMPT);
  });
});

describe("status honesty badges", () => {
  it("marks email Ready only when a fetch succeeded", () => {
    expect(
      emailBadge(
        makeStatus({
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
        }),
      ),
    ).toBe("Ready");
    expect(
      emailBadge(
        makeStatus({
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
          emailReady: true,
        }),
      ),
    ).toBe("Ready");
  });

  it("marks email Configured when accounts exist without a fetch", () => {
    expect(
      emailBadge(
        makeStatus({
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: false }],
        }),
      ),
    ).toBe("Configured");
  });

  it("marks email Not connected when no accounts exist", () => {
    expect(emailBadge(makeStatus({ emailAccounts: [] }))).toBe(
      "Not connected",
    );
    expect(emailBadge(null)).toBe("Not connected");
    expect(emailBadge(undefined)).toBe("Not connected");
  });

  it("marks index Configured when enabled without a watermark", () => {
    expect(
      indexBadge(
        makeStatus({ indexEnabled: true, indexWatermark: null }),
      ),
    ).toBe("Configured");
    expect(
      indexBadge(
        makeStatus({
          indexEnabled: true,
          indexWatermark: "2026-10-01T00:00:00Z",
        }),
      ),
    ).toBe("Ready");
    expect(indexBadge(makeStatus())).toBe("Not connected");
    expect(indexBadge(null)).toBe("Not connected");
  });

  it("keeps readiness booleans unchanged by Configured states", () => {
    expect(
      isEmailReady(
        makeStatus({
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: false }],
        }),
      ),
    ).toBe(false);
    expect(
      isIndexReady(makeStatus({ indexEnabled: true, indexWatermark: null })),
    ).toBe(false);
    expect(
      isConnectReady(makeStatus({ emailAccounts: [], indexEnabled: false })),
    ).toBe(false);
    expect(
      isConnectReady(
        makeStatus({
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
        }),
      ),
    ).toBe(true);
  });
});

describe("ConnectStep", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearWizardSnooze();
    window.location.hash = "";
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    clearWizardSnooze();
    window.location.hash = "";
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
    const checks = screen.getAllByRole("button", { name: /Check Again/i });
    expect(checks.length).toBeGreaterThan(0);
    await user.click(checks[0]);
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("gives every panel its own Check Again refresh", () => {
    render(
      <ConnectStep status={makeStatus()} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    for (const cardId of [
      "connect-email-card",
      "connect-calendar-card",
      "connect-index-card",
    ]) {
      const card = screen.getByTestId(cardId);
      expect(
        within(card).getByRole("button", { name: /Check Again/i }),
      ).toBeInTheDocument();
    }
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

  it("shows Configured with an address row for an unfetched account", () => {
    render(
      <ConnectStep
        status={makeStatus({
          emailAccounts: [{ address: "ops@example.com", fetchSucceeded: false }],
        })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    expect(screen.getByTestId("connect-email-badge")).toHaveTextContent(
      "Configured",
    );
    expect(screen.getByTestId("connect-email-accounts")).toBeInTheDocument();
    expect(screen.getAllByTestId("connect-email-account")).toHaveLength(1);
    expect(screen.getByTestId("connect-email-account")).toHaveTextContent(
      "ops@example.com",
    );
    expect(screen.getByTestId("connect-email-account-pill")).toHaveTextContent(
      "Configured",
    );
    expect(screen.queryByTestId("connect-email-empty")).toBeNull();
  });

  it("shows Ready with per-account pills when any fetch succeeded", () => {
    render(
      <ConnectStep
        status={makeStatus({
          emailAccounts: [
            { address: "ops@example.com", fetchSucceeded: true },
            { address: "other@example.com", fetchSucceeded: false },
          ],
        })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    expect(screen.getByTestId("connect-email-badge")).toHaveTextContent("Ready");
    expect(screen.getAllByTestId("connect-email-account")).toHaveLength(2);
    expect(screen.getAllByTestId("connect-email-account-pill").map((pill) => pill.textContent)).toEqual([
      "Fetched",
      "Configured",
    ]);
  });

  it("shows Not connected with empty copy when no accounts exist", () => {
    render(
      <ConnectStep
        status={makeStatus({ emailAccounts: [] })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    expect(screen.getByTestId("connect-email-badge")).toHaveTextContent(
      "Not connected",
    );
    expect(screen.getByTestId("connect-email-empty")).toHaveTextContent(
      "No account yet",
    );
    expect(screen.queryByTestId("connect-email-accounts")).toBeNull();
  });

  it("shows Configured for an enabled index without a watermark", () => {
    render(
      <ConnectStep
        status={makeStatus({ indexEnabled: true, indexWatermark: null })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    expect(screen.getByTestId("connect-index-badge")).toHaveTextContent(
      "Configured",
    );
  });

  it("fails closed to Not connected with a detour for null status", () => {
    render(
      <ConnectStep status={null} loading={false} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    expect(screen.getByTestId("connect-email-badge")).toHaveTextContent(
      "Not connected",
    );
    expect(screen.getByTestId("connect-index-badge")).toHaveTextContent(
      "Not connected",
    );
    expect(screen.getByTestId("connect-email-empty")).toHaveTextContent(
      "No account yet",
    );
    expect(screen.getByTestId("calendar-permission-explainer")).toBeInTheDocument();
  });

  it("renders a dash placeholder with ellipsis and tooltip for blank or long addresses", () => {
    const longAddress = `${"a".repeat(120)}@example.com`;
    render(
      <ConnectStep
        status={makeStatus({
          emailAccounts: [
            { address: "   ", fetchSucceeded: false },
            { address: longAddress, fetchSucceeded: false },
          ],
        })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    const rows = screen.getAllByTestId("connect-email-account");
    expect(rows).toHaveLength(2);
    expect(within(rows[0]).getByText("—")).toBeInTheDocument();
    expect(within(rows[0]).getByText("—")).toHaveAttribute("title", "—");
    const longCell = within(rows[1]).getByText(longAddress);
    expect(longCell).toHaveAttribute("title", longAddress);
    // Ellipsis lives in CSS so assert the shared class plus tooltip.
    expect(longCell).toHaveClass("connect-account-address");
  });

  it("shows Email primary with echo plus accounts plus same-tab button for inbox", () => {
    const status = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: false,
      indexWatermark: null,
    });
    render(
      <ConnectStep
        goal="inbox"
        status={status}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    const primary = screen.getByTestId("connect-email-card");
    expect(within(primary).getByTestId("connect-goal-echo")).toHaveTextContent(
      /You chose/i,
    );
    expect(within(primary).getByTestId("connect-goal-echo")).toHaveTextContent(
      /Triage my inbox/i,
    );
    expect(within(primary).getByTestId("connect-email-accounts")).toBeInTheDocument();
    const link = within(primary).getByRole("button", { name: /Open Email settings/i });
    expect(link).toHaveAttribute("data-testid", "connect-email-settings-link");
    expect(link).not.toHaveAttribute("target");
    expect(link).not.toHaveAttribute("href");
    const disclosure = screen.getByTestId("connect-other-options");
    expect(within(disclosure).getByText(/Show other options/i)).toBeInTheDocument();
    const disclosed = within(disclosure).getAllByTestId(/connect-.*-card/);
    expect(disclosed.map((card) => card.getAttribute("data-testid"))).toEqual([
      "connect-calendar-card",
      "connect-index-card",
    ]);
  });

  it("shows Calendar primary with explainer for day", () => {
    render(
      <ConnectStep
        goal="day"
        status={makeStatus({ calendarStatus: "denied" })}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    const primary = screen.getByTestId("connect-calendar-card");
    expect(within(primary).getByTestId("connect-goal-echo")).toHaveTextContent(
      /Stay ahead of my day/i,
    );
    expect(
      within(primary).getByTestId("calendar-permission-explainer"),
    ).toBeInTheDocument();
    expect(
      within(primary).getByRole("link", { name: /Open Permissions/i }),
    ).not.toHaveAttribute("target", "_blank");
    const disclosure = screen.getByTestId("connect-other-options");
    const disclosed = within(disclosure).getAllByTestId(/connect-.*-card/);
    expect(disclosed.map((card) => card.getAttribute("data-testid"))).toEqual([
      "connect-email-card",
      "connect-index-card",
    ]);
  });

  it("shows Index primary with same-tab button for remember", () => {
    const status = makeStatus({
      calendarStatus: "denied",
      emailAccounts: [],
      indexEnabled: true,
      indexWatermark: null,
    });
    render(
      <ConnectStep
        goal="remember"
        status={status}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    const primary = screen.getByTestId("connect-index-card");
    expect(within(primary).getByTestId("connect-goal-echo")).toHaveTextContent(
      /Remember things for me/i,
    );
    const link = within(primary).getByRole("button", {
      name: /Open Indexing settings/i,
    });
    expect(link).toHaveAttribute("data-testid", "connect-index-settings-link");
    expect(link).not.toHaveAttribute("target");
    expect(link).not.toHaveAttribute("href");
    const disclosure = screen.getByTestId("connect-other-options");
    const disclosed = within(disclosure).getAllByTestId(/connect-.*-card/);
    expect(disclosed.map((card) => card.getAttribute("data-testid"))).toEqual([
      "connect-email-card",
      "connect-calendar-card",
    ]);
  });

  it("renders all three in default order with no disclosure for null goal", () => {
    const status = makeStatus({
      calendarStatus: "granted",
      emailAccounts: [{ address: "ops@example.com", fetchSucceeded: true }],
      indexEnabled: true,
      indexWatermark: "2026-10-01T00:00:00Z",
    });
    const { container } = render(
      <ConnectStep status={status} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    expect(screen.queryByTestId("connect-goal-echo")).toBeNull();
    expect(screen.queryByTestId("connect-other-options")).toBeNull();
    const cards = Array.from(
      container.querySelectorAll('[data-testid^="connect-"][data-testid$="-card"]'),
    );
    expect(cards.map((card) => card.getAttribute("data-testid"))).toEqual([
      "connect-email-card",
      "connect-calendar-card",
      "connect-index-card",
    ]);
  });

  it("navigates settings links same-tab with hash targets and no popup", async () => {
    const user = userEvent.setup();
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null);
    render(
      <ConnectStep
        goal="remember"
        status={makeStatus()}
        refresh={() => {}}
        onSkipCalendar={() => {}}
      />,
    );
    const emailLink = screen.getByTestId("connect-email-settings-link");
    const indexLink = screen.getByTestId("connect-index-settings-link");
    for (const link of [emailLink, indexLink]) {
      expect(link).not.toHaveAttribute("target");
      expect(link).not.toHaveAttribute("href");
    }
    await user.click(emailLink);
    expect(isWizardSnoozed()).toBe(true);
    expect(window.location.hash).toContain("#settings/email");
    expect(openSpy).not.toHaveBeenCalled();
    clearWizardSnooze();
    window.location.hash = "";
    await user.click(indexLink);
    expect(isWizardSnoozed()).toBe(true);
    expect(window.location.hash).toContain("#settings/indexing");
    expect(openSpy).not.toHaveBeenCalled();
    openSpy.mockRestore();
  });

  it("snoozes the wizard before navigating same-tab to Email settings", async () => {
    const user = userEvent.setup();
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null);
    render(
      <ConnectStep status={makeStatus()} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    expect(isWizardSnoozed()).toBe(false);
    await user.click(screen.getByTestId("connect-email-settings-link"));
    expect(isWizardSnoozed()).toBe(true);
    expect(window.location.hash).toContain("#settings/email");
    expect(openSpy).not.toHaveBeenCalled();
    openSpy.mockRestore();
  });

  it("snoozes the wizard before navigating same-tab to Indexing settings", async () => {
    const user = userEvent.setup();
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null);
    render(
      <ConnectStep status={makeStatus()} refresh={() => {}} onSkipCalendar={() => {}} />,
    );
    expect(isWizardSnoozed()).toBe(false);
    await user.click(screen.getByTestId("connect-index-settings-link"));
    expect(isWizardSnoozed()).toBe(true);
    expect(window.location.hash).toContain("#settings/indexing");
    expect(openSpy).not.toHaveBeenCalled();
    openSpy.mockRestore();
  });
});

describe("ProtectStep", () => {
  it("renders the three read-only bullets with a same-tab Settings Access link", () => {
    render(<ProtectStep policyAcked={false} onPolicyAckedChange={() => {}} />);
    expect(screen.getByText(/Reads freely, writes ask first/i)).toBeInTheDocument();
    expect(screen.getByText(/Allowlist-only network/i)).toBeInTheDocument();
    expect(screen.getByText(/Secrets never in prompts/i)).toBeInTheDocument();
    const link = screen.getByRole("link", { name: /Settings Access/i });
    expect(link).not.toHaveAttribute("target");
    expect(link.getAttribute("href")).toContain("#settings/access");
    expect(screen.getByTestId("protect-step").querySelector(".protect-bullets")).not.toBeNull();
    expect(screen.queryByRole("button", { name: /^Finish$/ })).toBeNull();
    expect(document.querySelector(".protect-actions")).toBeNull();
  });

  it("maps the checkbox to the policy acknowledgement without gating Finish", async () => {
    const user = userEvent.setup();
    const onPolicyAckedChange = vi.fn();
    render(<ProtectStep policyAcked={false} onPolicyAckedChange={onPolicyAckedChange} />);
    const checkbox = screen.getByRole("checkbox", {
      name: /I understand writes need approval/i,
    });
    expect(checkbox).not.toBeChecked();
    await user.click(checkbox);
    expect(onPolicyAckedChange).toHaveBeenCalledWith(true);
    expect(screen.getByTestId("protect-step").querySelector(".protect-ack-row")).not.toBeNull();
    expect(screen.queryByRole("button", { name: /^Finish$/ })).toBeNull();
  });

  it("snoozes the wizard before same-tab navigation to Settings Access", async () => {
    const user = userEvent.setup();
    clearWizardSnooze();
    window.location.hash = "";
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null);
    render(<ProtectStep policyAcked={false} onPolicyAckedChange={() => {}} />);
    expect(isWizardSnoozed()).toBe(false);
    await user.click(screen.getByRole("link", { name: /Settings Access/i }));
    expect(isWizardSnoozed()).toBe(true);
    expect(window.location.hash).toContain("#settings/access");
    expect(openSpy).not.toHaveBeenCalled();
    openSpy.mockRestore();
    clearWizardSnooze();
    window.location.hash = "";
  });
});
