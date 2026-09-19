// Rune Weaver Dashboard — Tests pinning the inline approval banner's allow
// options to the shared trust-duration tiers.

import { describe, expect, it, vi } from "vitest";
import { splitAllowOptions } from "./InlineApprovalBanner";
import { trustDurationOptions, type PermissionRequest } from "../api";

describe("InlineApprovalBanner allow options", () => {
  it("mirrors every shared trust duration in the base option set", () => {
    const base = splitAllowOptions.filter((option) => !option.widen);
    // Base values and labels must come from trustDurationOptions verbatim so a
    // new or renamed tier can never be omitted from the inline banner while
    // the inbox and engine still offer it.
    expect(base.map((option) => option.value)).toEqual(
      trustDurationOptions.map((option) => option.value),
    );
    for (const tier of trustDurationOptions) {
      expect(base.find((option) => option.value === tier.value)?.label).toBe(
        tier.label,
      );
    }
  });

  it("offers an all-targets variant for every non-one-shot tier", () => {
    const widen = splitAllowOptions.filter((option) => option.widen);
    // The one-shot `thisTime` grant persists nothing, so it must never appear
    // as a widenable option; every other tier gets exactly one widen variant.
    const expected = trustDurationOptions.filter(
      (option) => option.value !== "thisTime",
    );
    expect(widen.map((option) => option.value)).toEqual(
      expected.map((option) => option.value),
    );
    for (const tier of expected) {
      expect(widen.find((option) => option.value === tier.value)?.label).toBe(
        `${tier.label} (all targets)`,
      );
    }
  });
});

describe("InlineApprovalBanner continuation approval", () => {
  it("renders continuation banner with Continue and Stop buttons", async () => {
    const { render, screen } = await import("@testing-library/react");
    const userEvent = (await import("@testing-library/user-event")).default;
    const InlineApprovalBanner = (await import("./InlineApprovalBanner")).default;
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-cont-1",
      toolName: "engine.continue",
      description: "The agent has completed 10 tool rounds. Continue?",
      input: { toolName: "engine.continue", argumentsJSON: "{}", callID: "c-cont" },
      suggestedDurations: ["thisTime"],
    };

    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText("Continuation")).toBeInTheDocument();
    expect(
      screen.getByText("The agent has completed 10 tool rounds. Continue?"),
    ).toBeInTheDocument();
    const continueBtn = screen.getByRole("button", { name: "Continue" });
    const stopBtn = screen.getByRole("button", { name: "Stop" });
    expect(continueBtn).toBeInTheDocument();
    expect(stopBtn).toBeInTheDocument();

    await user.click(continueBtn);
    expect(onDecide).toHaveBeenCalledWith("app-cont-1", true, "thisTime", false);

    await user.click(stopBtn);
    expect(onDecide).toHaveBeenCalledWith("app-cont-1", false, "thisTime", false);
  });
});

