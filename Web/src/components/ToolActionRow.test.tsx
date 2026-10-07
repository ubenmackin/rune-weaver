// Rune Weaver Dashboard — Component tests for honest tool status display.
// Covers the pending-versus-running distinction so completed turns with no
// recorded output never claim to be executing, plus live per-tool progress,
// broad-scope warnings, and the per-call cancel reason wiring.

import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
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

  it("renders Unknown Tool badge when errorKind is invalid_tool", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Unknown tool",
            isError: true,
            errorKind: "invalid_tool",
          },
        }}
      />,
    );
    const badge = screen.getByText("Unknown Tool");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("invalid-tool");
  });

  it("renders Invalid Syntax badge when errorKind is invalid_syntax", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Invalid syntax",
            isError: true,
            errorKind: "invalid_syntax",
          },
        }}
      />,
    );
    const badge = screen.getByText("Invalid Syntax");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("invalid-syntax");
  });

  it("renders Error badge when errorKind is execution_error or unspecified", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Execution failed",
            isError: true,
            errorKind: "execution_error",
          },
        }}
      />,
    );
    const badge = screen.getByText("Error");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("error");
  });

  it("renders Done badge when result succeeded", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Success",
            isError: false,
          },
        }}
      />,
    );
    const badge = screen.getByText("Done");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("ok");
  });
});

// The card variant shares the errorKind classification with the chat pill but
// renders its own prefixed class namespace, so it needs its own coverage to
// catch a drift between the two surfaces.
describe("ToolActionRow card variant badges", () => {
  it("renders Unknown Tool badge when errorKind is invalid_tool", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Unknown tool",
            isError: true,
            errorKind: "invalid_tool",
          },
        }}
        variant="card"
      />,
    );
    const badge = screen.getByText("Unknown Tool");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("tool-badge-invalid-tool");
  });

  it("renders Invalid Syntax badge when errorKind is invalid_syntax", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Invalid syntax",
            isError: true,
            errorKind: "invalid_syntax",
          },
        }}
        variant="card"
      />,
    );
    const badge = screen.getByText("Invalid Syntax");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("tool-badge-invalid-syntax");
  });

  it("renders Error badge on generic failure", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Execution failed",
            isError: true,
            errorKind: "execution_error",
          },
        }}
        variant="card"
      />,
    );
    const badge = screen.getByText("Error");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("tool-badge-error");
  });

  it("renders Done badge when result succeeded", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: "Success",
            isError: false,
          },
        }}
        variant="card"
      />,
    );
    const badge = screen.getByText("Done");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("tool-badge-ok");
  });

  it("shows Running for a live result-less card", () => {
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        variant="card"
        isLive
      />,
    );
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.queryByText("Pending")).not.toBeInTheDocument();
  });

  it("shows Pending instead of Running for a completed result-less card", () => {
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        variant="card"
      />,
    );
    expect(screen.getByText("Pending")).toBeInTheDocument();
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });
});

const progressAction = {
  toolName: "files.glob",
  callID: "call-progress-1",
  argumentsJSON: '{"pattern":"*.txt"}',
};

describe("ToolActionRow live progress", () => {
  it("renders scope, counters, relative tail, and an indeterminate shimmer while live", () => {
    render(
      <ToolActionRow
        action={{ ...progressAction, result: null }}
        isLive
        progress={{
          callID: "call-progress-1",
          toolName: "files.glob",
          message: "Find *.txt in ~",
          scanned: 42,
          matched: 3,
          elapsedMs: 4200,
          current: "Documents/notes.txt",
        }}
      />,
    );
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByTestId("tool-progress")).toBeInTheDocument();
    expect(screen.getByTestId("tool-progress-stats")).toHaveTextContent(
      "42 files checked · 3 matched · 4.2s",
    );
    expect(screen.getByTestId("tool-progress-current")).toHaveTextContent(
      "current: Documents/notes.txt",
    );
    // Indeterminate: the engine never publishes a percentage, so the row proves
    // liveness with a shimmer rather than a fabricated fraction.
    expect(screen.getByTestId("tool-progress-shimmer")).toBeInTheDocument();
  });

  it("pluralizes a single scanned file honestly", () => {
    render(
      <ToolActionRow
        action={{ ...progressAction, result: null }}
        isLive
        progress={{
          callID: "call-progress-1",
          toolName: "files.glob",
          message: "Find notes.txt in ~",
          scanned: 1,
          matched: 1,
          elapsedMs: 900,
        }}
      />,
    );
    expect(screen.getByTestId("tool-progress-stats")).toHaveTextContent(
      "1 file checked · 1 matched · 0.9s",
    );
    // A missing relative tail renders no tail line instead of an empty one.
    expect(screen.queryByTestId("tool-progress-current")).not.toBeInTheDocument();
  });

  it("renders a dedicated broad-scope warning beside the scope line", () => {
    render(
      <ToolActionRow
        action={{ ...progressAction, result: null }}
        isLive
        progress={{
          callID: "call-progress-1",
          toolName: "files.glob",
          message: "Find *.txt in ~",
          warning: "entire home folder",
          scanned: 120,
          matched: 7,
          elapsedMs: 12_000,
        }}
      />,
    );
    const warning = screen.getByTestId("tool-progress-scope-warning");
    expect(warning).toHaveTextContent("— entire home folder");
    // The scope description stays on the same line rather than a second banner.
    expect(screen.getByText("Find *.txt in ~")).toBeInTheDocument();
  });

  it("keeps a separator inside the scope message instead of inventing a warning", () => {
    render(
      <ToolActionRow
        action={{ ...progressAction, result: null }}
        isLive
        progress={{
          callID: "call-progress-1",
          toolName: "files.grep",
          // A pattern containing the old delimiter must render verbatim; only
          // the dedicated warning field may raise a warning span.
          message: "Search foo — bar in ~",
          scanned: 12,
          matched: 1,
          elapsedMs: 900,
        }}
      />,
    );
    expect(screen.getByText("Search foo — bar in ~")).toBeInTheDocument();
    expect(
      screen.queryByTestId("tool-progress-scope-warning"),
    ).not.toBeInTheDocument();
  });

  it("hides progress once the call has a result even when the turn is live", () => {
    render(
      <ToolActionRow
        action={{
          ...progressAction,
          result: {
            toolCallID: "call-progress-1",
            content: "done",
            isError: false,
          },
        }}
        isLive
        progress={{
          callID: "call-progress-1",
          toolName: "files.glob",
          message: "Find *.txt in ~",
          scanned: 42,
          matched: 3,
          elapsedMs: 4200,
        }}
      />,
    );
    expect(screen.getByText("Done")).toBeInTheDocument();
    expect(screen.queryByTestId("tool-progress")).not.toBeInTheDocument();
  });
});

describe("ToolActionRow tool cancel", () => {
  it("passes the optional reason through when cancelling", async () => {
    const user = userEvent.setup();
    const onCancelTool = vi.fn();
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        isLive
        onCancelTool={onCancelTool}
      />,
    );
    await user.click(
      screen.getByRole("button", { name: "Cancel tool email.search" }),
    );
    await user.type(screen.getByLabelText("Cancel reason"), "wrong folder");
    await user.click(
      screen.getByRole("button", { name: "Confirm cancel tool email.search" }),
    );
    expect(onCancelTool).toHaveBeenCalledWith("call-debug-123", "wrong folder");
  });

  it("omits the reason when the popover is submitted blank", async () => {
    const user = userEvent.setup();
    const onCancelTool = vi.fn();
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        isLive
        onCancelTool={onCancelTool}
      />,
    );
    await user.click(
      screen.getByRole("button", { name: "Cancel tool email.search" }),
    );
    await user.click(
      screen.getByRole("button", { name: "Confirm cancel tool email.search" }),
    );
    expect(onCancelTool).toHaveBeenCalledWith("call-debug-123", undefined);
  });

  it("marks the row Cancelling… after a cancel is requested", () => {
    render(
      <ToolActionRow
        action={{ ...baseAction, result: null }}
        isLive
        cancelling
        onCancelTool={() => {}}
      />,
    );
    expect(screen.getByTestId("tool-cancelling")).toHaveTextContent(
      "Cancelling…",
    );
    expect(
      screen.queryByRole("button", { name: "Cancel tool email.search" }),
    ).not.toBeInTheDocument();
  });

  it("offers no cancel affordance without a handler", () => {
    render(<ToolActionRow action={{ ...baseAction, result: null }} isLive />);
    expect(
      screen.queryByRole("button", { name: "Cancel tool email.search" }),
    ).not.toBeInTheDocument();
  });
});

// Bash-only envelope evidence splits command failure from tool failure, so the
// pill stays honest while retry plus audit plus run-log behavior never moves.
describe("ToolActionRow bash envelope status", () => {
  const bashAction = {
    toolName: "bash.exec",
    callID: "call-bash-1",
    argumentsJSON: '{"command":"ls"}',
  };

  it("reads denied bash results as Denied", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({ denied: true, kill_reason: "denied" }),
            isError: true,
          },
        }}
      />,
    );
    const badge = screen.getByText("Denied");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("error");
  });

  it("reads wall_timeout kills as Timed out", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({
              denied: false,
              kill_reason: "wall_timeout",
              exitCode: 0,
            }),
            isError: true,
          },
        }}
      />,
    );
    const badge = screen.getByText("Timed out");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("error");
  });

  it("reads resource_limit kills as Resource limit", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({
              denied: false,
              kill_reason: "resource_limit",
              exitCode: 0,
            }),
            isError: true,
          },
        }}
      />,
    );
    const badge = screen.getByText("Resource limit");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("error");
  });

  it("reads clean non-zero exits as amber Exited N in the chat pill", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({
              command: "ls",
              stdout: "hello",
              stderr: "",
              exitCode: 1,
              denied: false,
              kill_reason: "clean",
            }),
            isError: true,
          },
        }}
      />,
    );
    const badge = screen.getByText("Exited 1");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("warning");
  });

  it("reads clean non-zero exits as amber in the card variant with stdout preserved", async () => {
    const user = userEvent.setup();
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({
              command: "ls",
              stdout: "hello",
              stderr: "",
              exitCode: 2,
              denied: false,
              kill_reason: "clean",
            }),
            isError: true,
          },
        }}
        variant="card"
      />,
    );
    const badge = screen.getByText("Exited 2");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("tool-badge-warning");
    await user.click(screen.getByRole("button"));
    expect(screen.getByText(/hello/)).toBeInTheDocument();
  });

  it("reads clean zero exits as Done", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({
              denied: false,
              kill_reason: "clean",
              exitCode: 0,
            }),
            isError: false,
          },
        }}
      />,
    );
    const badge = screen.getByText("Done");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("ok");
  });

  it("keeps a clean envelope with a tool error red instead of Done", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({
              denied: false,
              kill_reason: "clean",
              exitCode: 0,
            }),
            isError: true,
          },
        }}
      />,
    );
    const badge = screen.getByText("Error");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("error");
    expect(screen.queryByText("Done")).not.toBeInTheDocument();
  });

  it("falls back to Error for unparseable bash content", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: "boom",
            isError: true,
          },
        }}
      />,
    );
    const badge = screen.getByText("Error");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveClass("error");
  });

  it("never enters the envelope branch for non-bash tools", () => {
    render(
      <ToolActionRow
        action={{
          ...baseAction,
          result: {
            toolCallID: "call-debug-123",
            content: JSON.stringify({
              denied: true,
              kill_reason: "denied",
              exitCode: 3,
            }),
            isError: true,
          },
        }}
      />,
    );
    expect(screen.getByText("Error")).toBeInTheDocument();
    expect(screen.queryByText("Denied")).not.toBeInTheDocument();
    expect(screen.queryByText(/Exited/)).not.toBeInTheDocument();
  });

  it("ignores bare command/stdout JSON without envelope keys", () => {
    render(
      <ToolActionRow
        action={{
          ...bashAction,
          result: {
            toolCallID: "call-bash-1",
            content: JSON.stringify({ command: "ls", stdout: "hi" }),
            isError: true,
          },
        }}
      />,
    );
    expect(screen.getByText("Error")).toBeInTheDocument();
    expect(screen.queryByText("Done")).not.toBeInTheDocument();
  });
});
