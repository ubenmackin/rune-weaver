// Rune Weaver Dashboard — Tests for the verbatim bash sandbox tier line.

import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import BashTierLine from "./BashTierLine";

afterEach(() => {
  cleanup();
});

describe("BashTierLine", () => {
  it("renders the stamped summary verbatim", () => {
    const summary =
      "Runs in a temporary container with no internet access. Nothing is kept after the run.";
    render(<BashTierLine summary={summary} />);

    const line = screen.getByTestId("bash-tier-line");
    expect(line).toBeInTheDocument();
    expect(line).toHaveClass("approval-narrative");
    expect(line).toHaveClass("approval-tier");
    expect(line).toHaveTextContent(summary);
  });

  it("renders nothing when the summary is null", () => {
    const { container } = render(<BashTierLine summary={null} />);

    expect(screen.queryByTestId("bash-tier-line")).not.toBeInTheDocument();
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing when the summary is undefined", () => {
    const { container } = render(<BashTierLine summary={undefined} />);

    expect(screen.queryByTestId("bash-tier-line")).not.toBeInTheDocument();
    expect(container).toBeEmptyDOMElement();
  });
});
