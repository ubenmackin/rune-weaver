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

  it("hides browser.navigate summary when collapsed and reveals it when expanded (card)", async () => {
    const user = userEvent.setup();
    const navigateAction = {
      toolName: "browser.navigate",
      callID: "call-nav-1",
      argumentsJSON: '{"url":"https://developer.apple.com/xcode/"}',
      result: {
        toolCallID: "call-nav-1",
        content: JSON.stringify({
          final_url: "https://developer.apple.com/xcode/",
          title: "Xcode - Apple Developer",
          redirect_count: 0,
        }),
        isError: false,
      },
    };

    render(<ToolActionRow action={navigateAction} variant="card" />);
    // Collapsed: summary row should not be rendered
    expect(screen.queryByTestId("browser-final-url")).not.toBeInTheDocument();

    // Expanded: summary row is rendered
    await user.click(screen.getByRole("button"));
    expect(screen.getByTestId("browser-final-url")).toBeInTheDocument();
    expect(screen.getByText("https://developer.apple.com/xcode/")).toBeInTheDocument();
  });

  it("hides browser.navigate summary when collapsed and reveals it when expanded (chat pill)", async () => {
    const user = userEvent.setup();
    const navigateAction = {
      toolName: "browser.navigate",
      callID: "call-nav-2",
      argumentsJSON: '{"url":"https://developer.apple.com/xcode/"}',
      result: {
        toolCallID: "call-nav-2",
        content: JSON.stringify({
          final_url: "https://developer.apple.com/xcode/",
          title: "Xcode - Apple Developer",
          redirect_count: 0,
        }),
        isError: false,
      },
    };

    render(<ToolActionRow action={navigateAction} variant="chat" />);
    // Collapsed: summary row should not be rendered
    expect(screen.queryByTestId("browser-final-url")).not.toBeInTheDocument();

    // Expanded: summary row is rendered
    await user.click(screen.getByRole("button"));
    expect(screen.getByTestId("browser-final-url")).toBeInTheDocument();
    expect(screen.getByText("https://developer.apple.com/xcode/")).toBeInTheDocument();
  });
});
