// Rune Weaver Dashboard — Component tests for RunLogViewer listing and details view.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import RunLogViewer from "./RunLogViewer";

const runsPayload = {
  runs: [
    {
      id: "22222222-2222-2222-2222-222222222222",
      jobID: null,
      kind: "chat",
      status: "ok",
      message: "hello",
      timestamp: new Date(0).toISOString(),
    },
  ],
  count: 1,
};

describe("RunLogViewer", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("lists runs and opens details", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify(runsPayload), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("hello")).toBeInTheDocument();
    });
    expect(screen.getByText("1 entries")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Details" }));
    expect(screen.getByLabelText("Run details")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.queryByLabelText("Run details")).not.toBeInTheDocument();
  });

  it("shows an empty state when no runs exist", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ runs: [], count: 0 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText(/No runs yet/)).toBeInTheDocument();
    });
  });
});
