// Rune Weaver Dashboard — Component tests for honest tool status display.
// Covers the pending-versus-running distinction so completed turns with no
// recorded output never claim to be executing.

import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import ToolActionRow from "./ToolActionRow";

const baseAction = {
  toolName: "email.search",
  callID: "call-debug-123",
  argumentsJSON: '{"limit":1}',
};

describe("ToolActionRow honest status", () => {
  it("shows Running only for live result-less actions", () => {
    const { unmount } = render(
      <ToolActionRow action={{ ...baseAction, result: null }} isLive />,
    );
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.queryByText("Pending")).not.toBeInTheDocument();
    unmount();
  });

  it("shows Pending instead of Running for completed result-less entries", () => {
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        variant="card"
      />,
    );
    expect(screen.getByText("Pending")).toBeInTheDocument();
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
    // Full debug identifier stays in the DOM for correlation.
    expect(screen.getByText("call-debug-123")).toBeInTheDocument();
  });

  it("shows Pending in chat history without claiming to run", () => {
    render(<ToolActionRow action={{ ...baseAction, result: null }} />);
    expect(screen.getByText("Pending")).toBeInTheDocument();
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });

  it("reveals the full call identifier when expanded", async () => {
    const user = userEvent.setup();
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        variant="card"
      />,
    );
    await user.click(screen.getByRole("button"));
    expect(screen.getAllByText("call-debug-123").length).toBeGreaterThan(0);
  });
});
