import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import ThoughtContainer from "./ThoughtContainer";

describe("ThoughtContainer", () => {
  it("renders null when text is empty or whitespace", () => {
    const { container } = render(
      <ThoughtContainer text="   " defaultExpanded={false} />
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders collapsed by default when defaultExpanded is false", () => {
    const { container } = render(
      <ThoughtContainer
        text="Analyzing codebase structure..."
        defaultExpanded={false}
      />
    );

    const details = container.querySelector("details.chat-thought-container");
    expect(details).toBeInTheDocument();
    expect(details).not.toHaveAttribute("open");
    expect(screen.getByText("Thinking Process")).toBeInTheDocument();
    expect(screen.getByText("Analyzing codebase structure...")).toBeInTheDocument();
  });

  it("renders expanded by default when defaultExpanded is true", () => {
    const { container } = render(
      <ThoughtContainer
        text="Evaluating algorithm tradeoffs..."
        defaultExpanded={true}
      />
    );

    const details = container.querySelector("details.chat-thought-container");
    expect(details).toBeInTheDocument();
    expect(details).toHaveAttribute("open");
    expect(screen.getByText("Evaluating algorithm tradeoffs...")).toBeInTheDocument();
  });

  it("updates open state when defaultExpanded prop updates", () => {
    const { container, rerender } = render(
      <ThoughtContainer text="Initial reasoning" defaultExpanded={false} />
    );

    const details = container.querySelector("details.chat-thought-container");
    expect(details).not.toHaveAttribute("open");

    rerender(
      <ThoughtContainer text="Initial reasoning" defaultExpanded={true} />
    );
    expect(details).toHaveAttribute("open");
  });

  it("allows user to manually toggle expansion", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <ThoughtContainer text="Deep reasoning steps" defaultExpanded={false} />
    );

    const details = container.querySelector("details.chat-thought-container");
    expect(details).not.toHaveAttribute("open");

    const summary = screen.getByText("Thinking Process");
    await user.click(summary);

    expect(details).toHaveAttribute("open");
  });
});
