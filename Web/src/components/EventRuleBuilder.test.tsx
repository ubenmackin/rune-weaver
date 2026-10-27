// Rune Weaver Dashboard — Component tests for the compact event rule list.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent, { type UserEvent } from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import EventRuleBuilder from "./EventRuleBuilder";
import type { EventRule } from "../api";

function makeEmailRules(): EventRule[] {
  return [
    {
      id: "rule-1",
      name: "VIP Alerts",
      enabled: true,
      condition: {
        senderContains: ["boss@company.com"],
        subjectContains: ["Urgent"],
        contentContains: ["invoice total"],
        matchAll: true,
      },
      action: { type: "agentPrompt", prompt: "Summarize the event." },
      stopProcessing: true,
    },
    {
      id: "rule-2",
      name: "Receipts",
      enabled: false,
      condition: {
        senderContains: [],
        subjectContains: ["Receipt"],
        contentContains: [],
        matchAll: false,
      },
      action: { type: "directTool", toolName: "email.move", argumentsJSON: "{}" },
      stopProcessing: false,
    },
  ];
}

async function openEditorFor(user: UserEvent, namePattern: RegExp) {
  await user.click(screen.getByRole("button", { name: namePattern }));
  await screen.findByText("Edit Rule");
}

describe("EventRuleBuilder compact list", () => {
  it("renders one compact row per rule with summary chips", () => {
    const onChange = vi.fn();
    const { container } = render(
      <EventRuleBuilder source="email" rules={makeEmailRules()} onChange={onChange} />,
    );
    expect(container.querySelectorAll(".rule-row")).toHaveLength(2);
    expect(container.querySelector(".rule-rows")).not.toBeNull();
    expect(container.querySelector(".rule-chips")).not.toBeNull();
    expect(screen.getByText("VIP Alerts")).toBeTruthy();
    expect(screen.getByText("Receipts")).toBeTruthy();
    expect(screen.getByText(/from: boss@company\.com/i)).toBeTruthy();
    expect(screen.getByText(/subject: Urgent/i)).toBeTruthy();
    expect(screen.getByText(/body: invoice total/i)).toBeTruthy();
    expect(screen.getByText("match-all")).toBeTruthy();
    expect(screen.getByText("match-any")).toBeTruthy();
    // Compact rows carry no inline condition editors until Edit opens.
    expect(screen.queryByPlaceholderText(/@school\.org/)).toBeNull();
    // Tool action shows its wrench plus tool name; prompt rows show the glyph.
    expect(screen.getByText("email.move")).toBeTruthy();
    expect(screen.getByText("Prompt")).toBeTruthy();
  });

  it("binds the enable toggle to the shared tool-switch", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    const { container } = render(
      <EventRuleBuilder source="email" rules={makeEmailRules()} onChange={onChange} />,
    );
    const inputs = container.querySelectorAll(".tool-switch-input");
    expect(inputs).toHaveLength(2);
    const tracks = container.querySelectorAll(".tool-switch-track");
    expect(tracks).toHaveLength(2);
    expect(tracks[0].getAttribute("data-on")).toBe("true");
    expect(tracks[1].getAttribute("data-on")).toBe("false");
    await user.click(screen.getByLabelText("Enable rule VIP Alerts"));
    await waitFor(() => expect(onChange).toHaveBeenCalledTimes(1));
    expect(onChange).toHaveBeenCalledWith(
      expect.arrayContaining([expect.objectContaining({ enabled: false })]),
    );
  });

  it("duplicates a rule with a copy suffix inserted after the source", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <EventRuleBuilder source="email" rules={makeEmailRules().slice(0, 1)} onChange={onChange} />,
    );
    await user.click(screen.getByRole("button", { name: /duplicate vip alerts/i }));
    await waitFor(() => expect(onChange).toHaveBeenCalledTimes(1));
    const next = onChange.mock.calls[0][0] as EventRule[];
    expect(next).toHaveLength(2);
    expect(next[0].name).toBe("VIP Alerts");
    expect(next[1].name).toBe("VIP Alerts copy");
    expect(next[1].id).not.toBe(next[0].id);
  });

  it("reorders rules while preserving order", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <EventRuleBuilder source="email" rules={makeEmailRules()} onChange={onChange} />,
    );
    await user.click(screen.getByRole("button", { name: /move vip alerts down/i }));
    await waitFor(() => expect(onChange).toHaveBeenCalledTimes(1));
    const next = onChange.mock.calls[0][0] as EventRule[];
    expect(next.map((rule) => rule.name)).toEqual(["Receipts", "VIP Alerts"]);
  });

  it("deletes a rule from the list", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <EventRuleBuilder source="email" rules={makeEmailRules()} onChange={onChange} />,
    );
    await user.click(screen.getByRole("button", { name: /delete receipts/i }));
    await waitFor(() => expect(onChange).toHaveBeenCalledTimes(1));
    const next = onChange.mock.calls[0][0] as EventRule[];
    expect(next).toHaveLength(1);
    expect(next[0].name).toBe("VIP Alerts");
  });
});

describe("EventRuleBuilder editor modal", () => {
  it("saves edited fields back to the list", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <EventRuleBuilder source="email" rules={makeEmailRules().slice(0, 1)} onChange={onChange} />,
    );
    await openEditorFor(user, /edit vip alerts/i);
    const nameInput = screen.getByLabelText("Rule Name");
    await user.clear(nameInput);
    await user.type(nameInput, "VIP Renamed");
    const promptInput = screen.getByLabelText("Agent Prompt Instructions");
    await user.clear(promptInput);
    await user.type(promptInput, "Summarize urgently.");
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(onChange).toHaveBeenCalledTimes(1));
    const next = onChange.mock.calls[0][0] as EventRule[];
    expect(next[0].name).toBe("VIP Renamed");
    expect(next[0].action).toEqual(
      expect.objectContaining({ type: "agentPrompt", prompt: "Summarize urgently." }),
    );
  });

  it(
    "blocks saving an empty prompt with a validation error",
    { timeout: 15000 },
    async () => {
      const user = userEvent.setup();
      const onChange = vi.fn();
      render(
        <EventRuleBuilder source="email" rules={makeEmailRules().slice(0, 1)} onChange={onChange} />,
      );
      await openEditorFor(user, /edit vip alerts/i);
      // Synchronous change avoids user-event clear timing flakes on the modal textarea.
      fireEvent.change(screen.getByLabelText("Agent Prompt Instructions"), {
        target: { value: "" },
      });
      fireEvent.click(screen.getByRole("button", { name: "Save" }));
      await screen.findByText(/prompt must not be empty/i, undefined, {
        timeout: 10000,
      });
      expect(onChange).not.toHaveBeenCalled();
    },
  );
});
