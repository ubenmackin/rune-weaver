// Rune Weaver Dashboard — AdvancedDisclosure static trigger coverage.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { AdvancedDisclosure } from "./AdvancedDisclosure";

describe("AdvancedDisclosure", () => {
  it("renders a static trigger with no count and no chip", async () => {
    const user = userEvent.setup();
    render(
      <AdvancedDisclosure tabName="Engine" testId="advanced-engine">
        <div>advanced body</div>
      </AdvancedDisclosure>
    );

    const trigger = screen.getByTestId("advanced-engine-trigger");
    expect(trigger.textContent).toBe("Advanced Engine settings");
    expect(trigger.textContent).not.toMatch(/\d/);
    expect(trigger.textContent).not.toMatch(/changed/i);
    expect(screen.queryByTestId("advanced-engine-chip")).toBeNull();

    await user.click(trigger);
    await waitFor(() => {
      expect(
        (screen.getByTestId("advanced-engine") as HTMLDetailsElement).open
      ).toBe(true);
    });
    expect(screen.getByTestId("advanced-engine-trigger").textContent).toBe(
      "Advanced Engine settings"
    );
    expect(screen.queryByTestId("advanced-engine-chip")).toBeNull();
  });

  it("keeps the Reset advanced button when open", async () => {
    const onReset = vi.fn();
    const user = userEvent.setup();
    render(
      <AdvancedDisclosure
        tabName="Voice"
        testId="advanced-voice"
        defaultOpen
        onReset={onReset}
      >
        <div>advanced body</div>
      </AdvancedDisclosure>
    );

    const reset = screen.getByTestId("advanced-voice-reset");
    expect(reset.textContent).toBe("Reset advanced");
    await user.click(reset);
    expect(onReset).toHaveBeenCalledTimes(1);
  });

  it("force-opens on a matching validation error and focuses it", async () => {
    render(
      <AdvancedDisclosure
        tabName="Engine"
        testId="advanced-engine"
        validationError="Invalid compaction threshold"
        errorKeywords={["compaction"]}
      >
        <div>advanced body</div>
      </AdvancedDisclosure>
    );

    await waitFor(() => {
      expect(
        (screen.getByTestId("advanced-engine") as HTMLDetailsElement).open
      ).toBe(true);
    });
    expect(screen.getByTestId("advanced-engine-error").textContent).toContain(
      "Invalid compaction threshold"
    );
    await waitFor(() => {
      expect(document.activeElement?.id).toBe("advanced-engine-error");
    });
  });
});
