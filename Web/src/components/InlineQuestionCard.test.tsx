// Rune Weaver Dashboard — Unit tests for InlineQuestionCard.

import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import InlineQuestionCard, { parseQuestionArgs } from "./InlineQuestionCard";
import type { PermissionRequest } from "../api";

afterEach(() => {
  cleanup();
});

const mockRequest: PermissionRequest = {
  id: "req-q-1",
  toolName: "question.ask",
  description: "Question for operator",
  input: {
    callID: "call-1",
    toolName: "question.ask",
    argumentsJSON: JSON.stringify({
      question: "Which movie version do you want?",
      options: ["The Matrix (1999) - 4K", "The Matrix Reloaded (2003) - 1080p"],
    }),
  },
  suggestedDurations: ["thisTime"],
  sessionID: "session-1",
};

describe("InlineQuestionCard", () => {
  it("parses question and options correctly from argumentsJSON", () => {
    const parsed = parseQuestionArgs(mockRequest.input?.argumentsJSON);
    expect(parsed.question).toBe("Which movie version do you want?");
    expect(parsed.options).toEqual([
      "The Matrix (1999) - 4K",
      "The Matrix Reloaded (2003) - 1080p",
    ]);
  });

  it("renders question text and candidate options", () => {
    const onRespond = vi.fn();
    render(<InlineQuestionCard request={mockRequest} deciding={false} onRespond={onRespond} />);

    expect(screen.getByText("Which movie version do you want?")).toBeInTheDocument();
    expect(screen.getByText("The Matrix (1999) - 4K")).toBeInTheDocument();
    expect(screen.getByText("The Matrix Reloaded (2003) - 1080p")).toBeInTheDocument();
    expect(screen.getByText("Other:")).toBeInTheDocument();
  });

  it("disables Submit Choice initially until an option is picked", () => {
    const onRespond = vi.fn();
    render(<InlineQuestionCard request={mockRequest} deciding={false} onRespond={onRespond} />);

    const submitBtn = screen.getByRole("button", { name: /submit choice/i });
    expect(submitBtn).toBeDisabled();
  });

  it("enables Submit Choice and submits selected candidate option", async () => {
    const user = userEvent.setup();
    const onRespond = vi.fn();
    render(<InlineQuestionCard request={mockRequest} deciding={false} onRespond={onRespond} />);

    const option1 = screen.getByLabelText("The Matrix (1999) - 4K");
    await user.click(option1);

    const submitBtn = screen.getByRole("button", { name: /submit choice/i });
    expect(submitBtn).toBeEnabled();

    await user.click(submitBtn);
    expect(onRespond).toHaveBeenCalledWith("req-q-1", "The Matrix (1999) - 4K", false);
  });

  it("submits custom write-in text when Other is selected", async () => {
    const user = userEvent.setup();
    const onRespond = vi.fn();
    render(<InlineQuestionCard request={mockRequest} deciding={false} onRespond={onRespond} />);

    const input = screen.getByPlaceholderText(/type your own answer/i);
    await user.type(input, "The Matrix Resurrections");

    const submitBtn = screen.getByRole("button", { name: /submit choice/i });
    expect(submitBtn).toBeEnabled();

    await user.click(submitBtn);
    expect(onRespond).toHaveBeenCalledWith("req-q-1", "The Matrix Resurrections", false);
  });

  it("fires cancellation when Cancel button is clicked", async () => {
    const user = userEvent.setup();
    const onRespond = vi.fn();
    render(<InlineQuestionCard request={mockRequest} deciding={false} onRespond={onRespond} />);

    const cancelBtn = screen.getByRole("button", { name: /cancel question/i });
    await user.click(cancelBtn);

    expect(onRespond).toHaveBeenCalledWith("req-q-1", undefined, true);
  });
});
