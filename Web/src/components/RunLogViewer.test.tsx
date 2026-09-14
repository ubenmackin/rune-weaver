// Rune Weaver Dashboard — Component tests for RunLogViewer listing and details view.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import RunLogViewer from "./RunLogViewer";
import { jsonResponse } from "../test-utils/http";

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
    localStorage.clear();
  });

  it("lists runs and opens details", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(runsPayload)));
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

  it("filters runs by time range and persists filter choices to localStorage", async () => {
    const user = userEvent.setup();
    const now = Date.now();
    const recentTime = new Date(now - 1000 * 60 * 60).toISOString(); // 1 hour ago (within 24h)
    const oldTime = new Date(now - 1000 * 60 * 60 * 24 * 10).toISOString(); // 10 days ago (older than 7d, within 30d)

    const multiRunsPayload = {
      runs: [
        {
          id: "run-recent",
          kind: "chat",
          status: "ok",
          message: "Recent chat",
          timestamp: recentTime,
        },
        {
          id: "run-old",
          kind: "scheduler",
          status: "ok",
          message: "Older job",
          timestamp: oldTime,
        },
      ],
      count: 2,
    };

    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(multiRunsPayload)));

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Recent chat")).toBeInTheDocument();
      expect(screen.getByText("Older job")).toBeInTheDocument();
    });

    // Filter by "Last Day": only "Recent chat" should remain
    await user.click(screen.getByRole("button", { name: "Last Day" }));
    expect(screen.getByText("Recent chat")).toBeInTheDocument();
    expect(screen.queryByText("Older job")).not.toBeInTheDocument();
    expect(localStorage.getItem("rw_runs_filter_time")).toBe("24h");

    // Filter by "Scheduled Jobs" while still in Last Day: none match
    await user.click(screen.getByRole("button", { name: /Scheduled Jobs/ }));
    expect(screen.queryByText("Recent chat")).not.toBeInTheDocument();
    expect(screen.queryByText("Older job")).not.toBeInTheDocument();
    expect(localStorage.getItem("rw_runs_filter_kind")).toBe("scheduler");

    // Switch to "Last Month": Older job matches
    await user.click(screen.getByRole("button", { name: "Last Month" }));
    expect(screen.getByText("Older job")).toBeInTheDocument();
  });

  it("opens clear logs confirmation modal and clears all runs", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      return jsonResponse(runsPayload);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("hello")).toBeInTheDocument();
    });

    // Click "Clear Logs"
    await user.click(screen.getByRole("button", { name: "Clean up run history" }));

    // Modal dialog should appear
    const dialog = screen.getByRole("dialog", { name: "Clean up run history" });
    expect(dialog).toBeInTheDocument();

    // Confirm Clear All
    await user.click(screen.getByRole("button", { name: "Confirm clear all runs" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/runs", expect.objectContaining({ method: "DELETE" }));
    });
    expect(screen.queryByText("hello")).not.toBeInTheDocument();
    expect(screen.getByText(/No runs yet/)).toBeInTheDocument();
  });

  it("deletes an individual run entry", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      return jsonResponse(runsPayload);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("hello")).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Delete run" }));
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/runs/${encodeURIComponent("22222222-2222-2222-2222-222222222222")}`,
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    expect(screen.queryByText("hello")).not.toBeInTheDocument();
  });

  it("shows an empty state when no runs exist", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({ runs: [], count: 0 })));
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText(/No runs yet/)).toBeInTheDocument();
    });
  });
});
