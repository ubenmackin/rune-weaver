// Rune Weaver Dashboard — Component tests for ChatView sending turns and token display.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ChatView from "./ChatView";

describe("ChatView", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends a message and renders the assistant reply", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({ text: "hello back", sessionID: "s1", toolActions: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );
    render(<ChatView />);
    await user.type(screen.getByLabelText("Chat input"), "hello");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("hello back")).toBeInTheDocument();
    });
    expect(screen.getByText("hello")).toBeInTheDocument();
  });

  it("starts a new session clearing messages", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({ text: "reply", sessionID: "s1", toolActions: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );
    render(<ChatView />);
    await user.type(screen.getByLabelText("Chat input"), "hi");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => {
      expect(screen.getByText("reply")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "New session" }));
    expect(screen.queryByText("reply")).not.toBeInTheDocument();
  });
});
