// Rune Weaver Dashboard — Schedule wizard selects, predicates, and budgets.
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent, { type UserEvent } from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ScheduleWizardModal from "./ScheduleWizardModal";
import { jsonResponse } from "../test-utils/http";

interface StubOptions {
  accounts?: string[];
  mailboxes?: Record<string, string[]>;
  mailboxFail?: string[];
  calendars?: Array<{ id: string; title: string }>;
  calendarFail?: boolean;
}

function stubFetch(opts: StubOptions = {}) {
  const accounts = opts.accounts ?? ["icloud"];
  const fetchMock = vi.fn(async (input: unknown) => {
    const path = typeof input === "string" ? input : String(input);
    if (path === "/settings") {
      return jsonResponse({
        emailAccounts: accounts.map((name) => ({
          name,
          type: "imap",
          host: "mail.example.com",
          port: 993,
          username: "user",
        })),
      });
    }
    if (path.startsWith("/email/accounts/") && path.endsWith("/mailboxes")) {
      const encoded = path.slice("/email/accounts/".length, -"/mailboxes".length);
      const account = decodeURIComponent(encoded);
      if (opts.mailboxFail?.includes(account)) {
        return jsonResponse({ error: "mailbox fetch failed" }, 502);
      }
      const list = opts.mailboxes?.[account] ?? ["INBOX", "Sent"];
      return jsonResponse({ mailboxes: list, delimiter: "/" });
    }
    if (path === "/calendars") {
      if (opts.calendarFail) {
        return jsonResponse({ reason: "calendar fetch failed" }, 502);
      }
      return jsonResponse({
        calendars: opts.calendars ?? [
          { id: "1", title: "Work" },
          { id: "2", title: "Personal" },
        ],
      });
    }
    return jsonResponse({ error: "unknown route" }, 404);
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

beforeEach(() => {
  vi.unstubAllGlobals();
  window.localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  window.localStorage.clear();
});

async function advanceToEmailConfig(user: UserEvent) {
  await user.type(screen.getByLabelText("Job Name"), "Evening check");
  await user.click(screen.getByText("Email Event Watcher"));
  await user.click(screen.getByRole("button", { name: "Continue" }));
  await screen.findByText("Configure Email Watcher");
}

async function selectAccountAndMailbox(
  user: UserEvent,
  account: string,
  mailbox: string,
) {
  const accountSelect = screen.getByLabelText("Mail Account");
  await user.selectOptions(accountSelect, account);
  const mailboxSelect = screen.getByLabelText("Mailbox");
  await waitFor(() => {
    const options = within(mailboxSelect as HTMLElement).getAllByRole("option");
    expect(options.map((o) => (o as HTMLOptionElement).value)).toContain(mailbox);
  });
  await user.selectOptions(mailboxSelect, mailbox);
}

async function advanceCronToPrompt(user: UserEvent) {
  await user.type(screen.getByLabelText("Job Name"), "Morning digest");
  await user.click(screen.getByRole("button", { name: "Continue" }));
  await screen.findByText("Choose Recurring Schedule");
  await user.click(screen.getByRole("button", { name: "Continue" }));
  await screen.findByLabelText("Agent Task Instructions");
}

async function fillPromptAndContinue(user: UserEvent, prompt: string) {
  await user.type(screen.getByLabelText("Agent Task Instructions"), prompt);
  await user.click(screen.getByRole("button", { name: "Continue" }));
  await screen.findByText("Review Schedule Details");
}

describe("ScheduleWizardModal check interval", () => {
  it("accepts a custom interval with selects and predicates", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    const onClose = vi.fn();
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={onClose}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    const interval = screen.getByLabelText("Check Interval");
    await user.clear(interval);
    await user.type(interval, "600");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await user.type(
      screen.getByLabelText("Agent Task Instructions"),
      "Summarize inbox",
    );
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/every 600s/);
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({ pollIntervalSeconds: 600, schedule: "" }),
      undefined,
    );
  });

  it("rejects out-of-range intervals with a Check Interval error", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    const interval = screen.getByLabelText("Check Interval");
    await user.clear(interval);
    await user.type(interval, "10");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Check Interval must be between 60 and 86400 seconds\./);
    expect(onSave).not.toHaveBeenCalled();
  });
});

describe("ScheduleWizardModal per-job tool budget", () => {
  it("sends null budget keys when the tool budget is left blank", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceCronToPrompt(user);
    await fillPromptAndContinue(user, "Summarize mail");
    await screen.findByText("Uses schedule default (25)");
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        maxToolIterations: null,
        onToolLimit: null,
      }),
      undefined,
    );
  });

  it("sends numeric rounds plus park and shows the live review line", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceCronToPrompt(user);
    const rounds = screen.getByLabelText(
      "Max tool rounds (blank uses schedule default)",
    );
    await user.clear(rounds);
    await user.type(rounds, "40");
    await user.selectOptions(screen.getByLabelText("On tool limit"), "park");
    await fillPromptAndContinue(user, "Summarize mail");
    await screen.findByText(/40 rounds/);
    await screen.findByText(/parks/);
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        maxToolIterations: 40,
        onToolLimit: "park",
      }),
      undefined,
    );
  });

  it("blocks submit with an error when tool rounds are out of range", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceCronToPrompt(user);
    const rounds = screen.getByLabelText(
      "Max tool rounds (blank uses schedule default)",
    );
    await user.clear(rounds);
    await user.type(rounds, "200");
    await fillPromptAndContinue(user, "Summarize mail");
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await screen.findByText("Max tool rounds must be between 1 and 100.");
    expect(onSave).not.toHaveBeenCalled();
  });

  it("prefills the budget controls from the job being edited", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    const jobToEdit = {
      id: "edit-id",
      name: "Evening digest",
      schedule: "0 8 * * *",
      prompt: "Summarize mail",
      enabled: true,
      pollAccount: null,
      pollQuery: null,
      pollMailbox: null,
      pollIntervalSeconds: null,
      pollLimit: null,
      maxToolIterations: 45,
      onToolLimit: "park",
      createdAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(),
    };
    render(
      <ScheduleWizardModal
        jobToEdit={jobToEdit}
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Choose Recurring Schedule");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByLabelText("Agent Task Instructions");
    expect(
      (screen.getByLabelText(
        "Max tool rounds (blank uses schedule default)",
      ) as HTMLInputElement).value,
    ).toBe("45");
    expect(
      (screen.getByLabelText("On tool limit") as HTMLSelectElement).value,
    ).toBe("park");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/45 rounds/);
    await screen.findByText(/parks/);
  });

  it("sends clearToolBudget when editing a budgeted job back to blank", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    const jobToEdit = {
      id: "edit-id",
      name: "Evening digest",
      schedule: "0 8 * * *",
      prompt: "Summarize mail",
      enabled: true,
      pollAccount: null,
      pollQuery: null,
      pollMailbox: null,
      pollIntervalSeconds: null,
      pollLimit: null,
      maxToolIterations: 45,
      onToolLimit: "park",
      createdAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(),
    };
    render(
      <ScheduleWizardModal
        jobToEdit={jobToEdit}
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Choose Recurring Schedule");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByLabelText("Agent Task Instructions");
    const rounds = screen.getByLabelText(
      "Max tool rounds (blank uses schedule default)",
    );
    await user.clear(rounds);
    await user.selectOptions(screen.getByLabelText("On tool limit"), "");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Uses schedule default (25)");
    await user.click(screen.getByRole("button", { name: "Update Schedule" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        maxToolIterations: null,
        onToolLimit: null,
        clearToolBudget: true,
      }),
      "edit-id",
    );
  });
});

describe("ScheduleWizardModal event watcher triggers", () => {
  it("creates a Messages Watcher with custom rules", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await user.type(screen.getByLabelText("Job Name"), "Messages Filter");
    await user.click(screen.getByText("Messages Watcher"));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Configure Messages Watcher");

    // Add a rule
    await user.click(screen.getByRole("button", { name: "+ Add Rule" }));
    const ruleName = screen.getByLabelText("Rule Name");
    await user.clear(ruleName);
    await user.type(ruleName, "VIP Rule");

    // Select group filter to directOnly
    await user.selectOptions(screen.getByLabelText("Chat Scope"), "directOnly");

    // Persist the draft rule before leaving the watcher step.
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(screen.queryByLabelText("Rule Name")).toBeNull();
    });

    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Fallback Agent Prompt/);
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Review Schedule Details");
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        name: "Messages Filter",
        watcherSource: "messages",
        schedule: "",
        rules: expect.arrayContaining([
          expect.objectContaining({
            name: "VIP Rule",
            condition: expect.objectContaining({
              groupChatFilter: "directOnly",
            }),
          }),
        ]),
      }),
      undefined,
    );
  });

  it("creates a Calendar Watcher with lead time and rules", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await user.type(screen.getByLabelText("Job Name"), "Meeting Prep Watcher");
    await user.click(screen.getByText("Calendar Watcher"));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Configure Calendar Watcher");

    // Change lead time
    const leadTime = screen.getByLabelText("Meeting Lead Time");
    await user.clear(leadTime);
    await user.type(leadTime, "30");

    // Add a rule
    await user.click(screen.getByRole("button", { name: "+ Add Rule" }));
    const calRuleName = screen.getByLabelText("Rule Name");
    await user.clear(calRuleName);
    await user.type(calRuleName, "1:1 Meeting Brief");

    // Persist the draft rule before leaving the watcher step.
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(screen.queryByLabelText("Rule Name")).toBeNull();
    });

    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Fallback Agent Prompt/);
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Review Schedule Details");
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        name: "Meeting Prep Watcher",
        watcherSource: "calendar",
        calendarLeadTimeMinutes: 30,
        schedule: "",
        rules: expect.arrayContaining([
          expect.objectContaining({
            name: "1:1 Meeting Brief",
          }),
        ]),
      }),
      undefined,
    );
  });
});

describe("ScheduleWizardModal email selects and cache", () => {
  it("greys the email card when zero accounts exist", async () => {
    stubFetch({ accounts: [] });
    const user = userEvent.setup();
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={vi.fn(async () => {})}
        onClose={() => {}}
      />,
    );
    await user.type(screen.getByLabelText("Job Name"), "No accounts");
    const card = screen.getByText("Email Event Watcher").closest(".trigger-card");
    expect(card).not.toBeNull();
    await waitFor(() => {
      expect(card).toHaveAttribute("aria-disabled", "true");
    });
    expect(card).toHaveAttribute("data-disabled", "true");
    expect(card?.querySelector(".infotip-trigger")).not.toBeNull();
  });

  it("clears the mailbox when the account changes", async () => {
    stubFetch({
      accounts: ["gmail", "icloud"],
      mailboxes: { icloud: ["INBOX"], gmail: ["INBOX", "Archive"] },
    });
    const user = userEvent.setup();
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={vi.fn(async () => {})}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await screen.findByRole("option", { name: "icloud" });
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    expect((screen.getByLabelText("Mailbox") as HTMLSelectElement).value).toBe(
      "INBOX",
    );
    await user.selectOptions(screen.getByLabelText("Mail Account"), "gmail");
    await waitFor(() => {
      expect((screen.getByLabelText("Mailbox") as HTMLSelectElement).value).toBe(
        "",
      );
    });
  });

  it("requires a mailbox selection before advancing", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await screen.findByRole("option", { name: "icloud" });
    await user.selectOptions(screen.getByLabelText("Mail Account"), "icloud");
    await screen.findByRole("option", { name: "INBOX" });
    expect(screen.getByLabelText("Mailbox").tagName).toBe("SELECT");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Mailbox is required\. Select a mailbox\./);
    expect(onSave).not.toHaveBeenCalled();
  });

  it("blocks advance when the mailbox list fails without cache", async () => {
    stubFetch({ accounts: ["icloud"], mailboxFail: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await screen.findByRole("option", { name: "icloud" });
    await user.selectOptions(screen.getByLabelText("Mail Account"), "icloud");
    await screen.findByRole("button", { name: "Retry" });
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Mailbox list is unavailable/);
    expect(onSave).not.toHaveBeenCalled();
  });

  it("sorts account options with All accounts first", async () => {
    stubFetch({ accounts: ["zeta", "alpha"] });
    const user = userEvent.setup();
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={vi.fn(async () => {})}
        onClose={() => {}}
      />,
    );
    await user.type(screen.getByLabelText("Job Name"), "Sorted");
    await user.click(screen.getByText("Email Event Watcher"));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Configure Email Watcher");
    await screen.findByRole("option", { name: "alpha" });
    const accountSelect = screen.getByLabelText("Mail Account");
    const options = within(accountSelect as HTMLElement).getAllByRole("option");
    expect(options.map((o) => (o as HTMLOptionElement).value)).toEqual([
      "*",
      "alpha",
      "zeta",
    ]);
    expect(options[0]).toHaveTextContent("All accounts");
  });
});

describe("ScheduleWizardModal predicates", () => {
  it("adds, previews, and removes predicate rows", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={vi.fn(async () => {})}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    await user.click(screen.getByRole("button", { name: "Add predicate" }));
    expect(screen.getByLabelText("Predicate 1 operator")).toBeInTheDocument();
    await user.selectOptions(
      screen.getByLabelText("Predicate 1 operator"),
      "from",
    );
    await user.type(screen.getByLabelText("Predicate 1 value"), "boss@example.com");
    await screen.findByText(/From "boss@example.com"/);
    await user.click(screen.getByRole("button", { name: "Add predicate" }));
    expect(screen.getByLabelText("Predicate 2 operator")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Remove predicate 2" }));
    expect(screen.queryByLabelText("Predicate 2 operator")).toBeNull();
  });

  it("rejects empty predicate values with a Predicate error", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    await user.click(screen.getByRole("button", { name: "Add predicate" }));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Predicate 1.*must not be empty/);
    expect(onSave).not.toHaveBeenCalled();
  });

  it("rejects out-of-range Since-days with a Predicate error", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    await user.click(screen.getByRole("button", { name: "Add predicate" }));
    await user.selectOptions(
      screen.getByLabelText("Predicate 1 operator"),
      "sinceDays",
    );
    const days = screen.getByLabelText("Predicate 1 days");
    await user.clear(days);
    await user.type(days, "91");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Predicate 1.*between 1 and 90/);
    expect(onSave).not.toHaveBeenCalled();
  });

  it("saves structured fields and mirrors Contains into pollQuery", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    await user.click(screen.getByRole("button", { name: "Add predicate" }));
    await user.type(screen.getByLabelText("Predicate 1 value"), "invoice");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await user.type(screen.getByLabelText("Agent Task Instructions"), "Summarize");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1));
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        pollContains: "invoice",
        pollQuery: "invoice",
        pollMailbox: "INBOX",
      }),
      undefined,
    );
  });
});

describe("ScheduleWizardModal budgets and tips", () => {
  it("rejects a Batch Limit outside 1 to 50", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await selectAccountAndMailbox(user, "icloud", "INBOX");
    const limit = screen.getByLabelText("Batch Limit");
    await user.clear(limit);
    await user.type(limit, "99");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(/Batch Limit must be between 1 and 50\./);
    expect(onSave).not.toHaveBeenCalled();
  });

  it("renders an InfoTip for every labeled field", async () => {
    stubFetch({ accounts: ["icloud"], mailboxes: { icloud: ["INBOX"] } });
    const user = userEvent.setup();
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={vi.fn(async () => {})}
        onClose={() => {}}
      />,
    );
    await advanceToEmailConfig(user);
    await screen.findByRole("option", { name: "icloud" });
    for (const label of ["Mail Account", "Mailbox", "Check Interval", "Batch Limit"]) {
      const control = screen.getByLabelText(label);
      const wrapper = control.closest(".form-label");
      expect(wrapper?.querySelector(".infotip-trigger")).not.toBeNull();
    }
  });

  it("maps unchecked calendars to null on save", async () => {
    stubFetch({ accounts: ["icloud"] });
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await user.type(screen.getByLabelText("Job Name"), "Cal all");
    await user.click(screen.getByText("Calendar Watcher"));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Configure Calendar Watcher");
    await screen.findByRole("checkbox", { name: "Work" });
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await user.type(screen.getByLabelText("Agent Task Instructions"), "Prep");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("All calendars");
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1));
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({ calendarNames: null }),
      undefined,
    );
  });
});
