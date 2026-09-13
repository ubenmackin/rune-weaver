// Rune Weaver Dashboard — Component tests for the schedule wizard check interval.
// Covers custom positive-integer seconds and rejection of non-numeric input.

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

describe("ScheduleWizardModal check interval", () => {
  it("accepts a custom positive-integer interval", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn(async () => {});
    const onClose = vi.fn();
    render(<ScheduleWizardModal onSave={onSave} onClose={onClose} />);
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
    render(<ScheduleWizardModal onSave={onSave} onClose={() => {}} />);
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
