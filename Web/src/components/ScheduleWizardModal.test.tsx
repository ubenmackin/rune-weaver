// Rune Weaver Dashboard — Component tests for the schedule wizard check interval and per-job tool budget.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent, { type UserEvent } from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import ScheduleWizardModal from "./ScheduleWizardModal";

async function advanceToPollInterval(user: UserEvent) {
  await user.type(screen.getByLabelText("Job Name"), "Evening check");
  await user.click(screen.getByText("Email Event Watcher"));
  await user.click(screen.getByRole("button", { name: "Continue" }));
  await screen.findByText("Configure Email Watcher");
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
  it("accepts a custom positive-integer interval", async () => {
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
    await advanceToPollInterval(user);
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

  it("rejects non-numeric intervals with an error", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    render(
      <ScheduleWizardModal
        sectionDefault={25}
        onSave={onSave}
        onClose={() => {}}
      />,
    );
    await advanceToPollInterval(user);
    const interval = screen.getByLabelText("Check Interval");
    await user.clear(interval);
    await user.type(interval, "abc");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText(
      "Check Interval must be a positive whole number of seconds.",
    );
    expect(onSave).not.toHaveBeenCalled();
  });
});

describe("ScheduleWizardModal per-job tool budget", () => {
  it("sends null budget keys when the tool budget is left blank", async () => {
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

