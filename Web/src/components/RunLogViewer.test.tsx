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

  it("deletes an individual run entry through the shared modal", async () => {
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

    // Trash stages a confirmation instead of deleting immediately.
    await user.click(screen.getByRole("button", { name: "Delete run" }));
    const dialog = screen.getByRole("dialog", { name: "Confirm delete run" });
    expect(dialog).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining("/runs/"),
      expect.objectContaining({ method: "DELETE" }),
    );

    // Keep dismisses without a request.
    await user.click(screen.getByRole("button", { name: "Keep" }));
    expect(screen.queryByRole("dialog", { name: "Confirm delete run" })).not.toBeInTheDocument();
    expect(screen.getByText("hello")).toBeInTheDocument();

    // Delete confirms the persisted removal and clears the entry.
    await user.click(screen.getByRole("button", { name: "Delete run" }));
    await user.click(screen.getByRole("button", { name: "Confirm delete run" }));
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/runs/${encodeURIComponent("22222222-2222-2222-2222-222222222222")}`,
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    expect(screen.queryByText("hello")).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Confirm delete run" })).not.toBeInTheDocument();
  });

  it("clears the detail selection when its run is deleted", async () => {
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

    await user.click(screen.getByRole("button", { name: "Details" }));
    expect(screen.getByLabelText("Run details")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Delete run" }));
    await user.click(screen.getByRole("button", { name: "Confirm delete run" }));
    await waitFor(() => {
      expect(screen.queryByText("hello")).not.toBeInTheDocument();
    });
    // The open detail view unmounts with its deleted run.
    expect(screen.queryByLabelText("Run details")).not.toBeInTheDocument();
  });

  it("shows an empty state when no runs exist", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({ runs: [], count: 0 })));
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText(/No runs yet/)).toBeInTheDocument();
    });
  });

  it("clears completed runs while preserving in-progress runs", async () => {
    const user = userEvent.setup();
    const runsWithRunning = {
      runs: [
        {
          id: "run-active",
          kind: "chat",
          status: "running",
          message: "active in-progress turn",
          timestamp: new Date().toISOString(),
        },
        {
          id: "run-done",
          kind: "chat",
          status: "ok",
          message: "completed turn",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 2,
    };
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      return jsonResponse(runsWithRunning);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("active in-progress turn")).toBeInTheDocument();
      expect(screen.getByText("completed turn")).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Clean up run history" }));
    await user.click(screen.getByRole("button", { name: "Confirm clear all runs" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/runs", expect.objectContaining({ method: "DELETE" }));
    });
    // In-progress run remains visible; completed run is gone
    expect(screen.getByText("active in-progress turn")).toBeInTheDocument();
    expect(screen.queryByText("completed turn")).not.toBeInTheDocument();
  });

  it("confirms single run deletion when pressing Enter in modal", async () => {
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
    const dialog = screen.getByRole("dialog", { name: "Confirm delete run" });
    expect(dialog).toBeInTheDocument();

    // Press Enter to confirm deletion
    await user.keyboard("{Enter}");

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/runs/${encodeURIComponent("22222222-2222-2222-2222-222222222222")}`,
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    expect(screen.queryByText("hello")).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Confirm delete run" })).not.toBeInTheDocument();
  });

  it("groups fan-out worker rows under their parent swarm and expands them", async () => {
    const user = userEvent.setup();
    // Newest-first order mirrors the audit trail: the worker children appear
    // before their parent, so the grouping helper must reproduce the swarm
    // shape (children in run order under the parent).
    const fanOutPayload = {
      runs: [
        {
          id: "worker-2",
          kind: "fanout_worker",
          status: "ok",
          message: "Research B",
          timestamp: new Date().toISOString(),
          durationMs: 1200,
        },
        {
          id: "worker-1",
          kind: "fanout_worker",
          status: "failed",
          message: "Research A",
          timestamp: new Date().toISOString(),
          durationMs: 800,
        },
        {
          id: "parent-1",
          kind: "fanout",
          status: "ok",
          message: "Research A; Research B",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 3,
    };
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(fanOutPayload)));

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Research A; Research B")).toBeInTheDocument();
    });

    // Children stay collapsed until the parent expands.
    expect(screen.queryByText("Research B")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /Expand worker turns/ }));

    // Children render status plus duration each with the same pill colors as
    // run statuses.
    expect(screen.getByText("Research A")).toBeInTheDocument();
    expect(screen.getByText("Research B")).toBeInTheDocument();
    // Duration renders as a bullet plus value across split text nodes inside
    // one span (textContent "• 800ms"), so match on the joined textContent
    // instead of an exact single-node string.
    expect(screen.getByText((_, element) => element?.textContent === "• 800ms")).toBeInTheDocument();
    expect(screen.getByText((_, element) => element?.textContent === "• 1.2s")).toBeInTheDocument();
    expect(screen.getByText("FAILED")).toBeInTheDocument();

    // Collapse hides the children again.
    await user.click(screen.getByRole("button", { name: /Collapse worker turns/ }));
    expect(screen.queryByText("Research B")).not.toBeInTheDocument();
  });

  it("renders the merged fan-out summary through the sanitized markdown renderer", async () => {
    const user = userEvent.setup();
    const mergedPayload = {
      runs: [
        {
          id: "parent-1",
          kind: "fanout",
          status: "ok",
          message: "Research A; Research B",
          response: '<img src=x onerror="alert(1)">Merged findings',
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(mergedPayload)));

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Research A; Research B")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Details" }));
    expect(screen.getByLabelText("Run details")).toBeInTheDocument();

    // A fan-out parent's response is the merged summary, so the section reads
    // Merged Summary and the sanitized renderer strips the injected markup
    // element entirely while the text still renders.
    expect(screen.getByText("Merged Summary")).toBeInTheDocument();
    expect(screen.queryByRole("img")).not.toBeInTheDocument();
    expect(screen.getByText(/Merged findings/)).toBeInTheDocument();
  });

  it("shows cancel actions only on running fan-out rows", async () => {
    const user = userEvent.setup();
    // Newest-first audit order: running worker, settled worker, running parent,
    // settled parent, then a running chat turn that has no swarm cancel route.
    const payload = {
      runs: [
        {
          id: "worker-running",
          kind: "fanout_worker",
          status: "running",
          message: "Research B",
          timestamp: new Date().toISOString(),
        },
        {
          id: "worker-done",
          kind: "fanout_worker",
          status: "ok",
          message: "Research A",
          timestamp: new Date().toISOString(),
        },
        {
          id: "parent-running",
          kind: "fanout",
          status: "running",
          message: "Running swarm",
          timestamp: new Date().toISOString(),
        },
        {
          id: "parent-done",
          kind: "fanout",
          status: "ok",
          message: "Settled swarm",
          timestamp: new Date().toISOString(),
        },
        {
          id: "chat-running",
          kind: "chat",
          status: "running",
          message: "Running chat turn",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 5,
    };
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(payload)));

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Running swarm")).toBeInTheDocument();
    });

    // Only the running fan-out parent offers the whole-swarm action; settled
    // parents and running chat turns never get one.
    expect(screen.getAllByRole("button", { name: "Cancel run" })).toHaveLength(1);
    expect(screen.getByText("Settled swarm")).toBeInTheDocument();
    expect(screen.getByText("Running chat turn")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /Expand worker turns/ }));
    // Of the two worker children only the running one can be stopped.
    expect(screen.getAllByRole("button", { name: "Cancel" })).toHaveLength(1);
  });

  it("confirms the whole-swarm stop, posts the parent id, and refetches", async () => {
    const user = userEvent.setup();
    const runningPayload = {
      runs: [
        {
          id: "parent-1",
          kind: "fanout",
          status: "running",
          message: "Swarm prompt",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };
    const settledPayload = {
      runs: [
        {
          id: "parent-1",
          kind: "fanout",
          status: "cancelled",
          message: "Swarm prompt",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };
    let currentRuns = runningPayload;
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit) => {
        const path = String(url);
        if (init?.method === "POST" && path.endsWith("/cancel")) {
          return jsonResponse({
            id: "parent-1",
            status: "cancelled",
            cancelled: true,
          });
        }
        if (path.startsWith("/runs?")) return jsonResponse(currentRuns);
        return jsonResponse({ approvals: [], count: 0 });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Swarm prompt")).toBeInTheDocument();
    });

    // A parent stop stages confirmation first; the row click fires nothing.
    await user.click(screen.getByRole("button", { name: "Cancel run" }));
    expect(
      screen.getByRole("dialog", { name: "Confirm cancel run" }),
    ).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining("/cancel"),
      expect.objectContaining({ method: "POST" }),
    );

    currentRuns = settledPayload;
    await user.click(screen.getByRole("button", { name: "Confirm cancel run" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/runs/${encodeURIComponent("parent-1")}/cancel`,
        expect.objectContaining({ method: "POST" }),
      );
    });
    // Success copy names the run scope, and the refetched list settles the badge.
    expect(await screen.findByTestId("toast")).toHaveTextContent(/whole swarm/i);
    await waitFor(() => {
      expect(screen.getByText("CANCELLED")).toBeInTheDocument();
    });
    expect(screen.queryByText("IN PROGRESS")).not.toBeInTheDocument();
    const runListCalls = fetchMock.mock.calls.filter(([url]) =>
      String(url).startsWith("/runs?"),
    );
    expect(runListCalls.length).toBeGreaterThanOrEqual(2);
  });

  it("stops one worker directly with the worker row id and worker-scope copy", async () => {
    const user = userEvent.setup();
    const payload = {
      runs: [
        {
          id: "worker-1",
          kind: "fanout_worker",
          status: "running",
          message: "Worker task",
          timestamp: new Date().toISOString(),
        },
        {
          id: "parent-1",
          kind: "fanout",
          status: "running",
          message: "Worker swarm",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 2,
    };
    const postedPaths: string[] = [];
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit) => {
        const path = String(url);
        if (init?.method === "POST" && path.endsWith("/cancel")) {
          postedPaths.push(path);
          return jsonResponse({
            id: "worker-1",
            status: "cancelled",
            cancelled: true,
          });
        }
        if (path.startsWith("/runs?")) return jsonResponse(payload);
        return jsonResponse({ approvals: [], count: 0 });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Worker swarm")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: /Expand worker turns/ }));

    await user.click(screen.getByRole("button", { name: "Cancel" }));

    // A worker stop is narrow enough to fire without a confirmation dialog.
    expect(
      screen.queryByRole("dialog", { name: "Confirm cancel run" }),
    ).not.toBeInTheDocument();
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/runs/${encodeURIComponent("worker-1")}/cancel`,
        expect.objectContaining({ method: "POST" }),
      );
    });
    // Only the worker row was posted; the parent swarm keeps running.
    expect(postedPaths).toEqual([
      `/runs/${encodeURIComponent("worker-1")}/cancel`,
    ]);
    expect(await screen.findByTestId("toast")).toHaveTextContent(
      /rest of the swarm keeps running/i,
    );
  });

  it("surfaces the server's honest 409 reason without an optimistic state change", async () => {
    const user = userEvent.setup();
    const payload = {
      runs: [
        {
          id: "parent-1",
          kind: "fanout",
          status: "running",
          message: "Already settled swarm",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit) => {
        const path = String(url);
        if (init?.method === "POST" && path.endsWith("/cancel")) {
          return jsonResponse({ reason: "Run already finished" }, 409);
        }
        if (path.startsWith("/runs?")) return jsonResponse(payload);
        return jsonResponse({ approvals: [], count: 0 });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Already settled swarm")).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Cancel run" }));
    await user.click(screen.getByRole("button", { name: "Confirm cancel run" }));

    const errorToast = await screen.findByTestId("toast-error");
    expect(errorToast).toHaveTextContent("Run already finished");
    // No optimistic settle: the row still reads running until a refetch says
    // otherwise.
    expect(screen.getByText("IN PROGRESS")).toBeInTheDocument();
    expect(screen.queryByText("CANCELLED")).not.toBeInTheDocument();
    // The confirmation closes so the settled run cannot be re-fired from a
    // hidden dialog.
    expect(
      screen.queryByRole("dialog", { name: "Confirm cancel run" }),
    ).not.toBeInTheDocument();
  });

  it("settles the open detail modal after a cancel refetch", async () => {
    const user = userEvent.setup();
    const runningPayload = {
      runs: [
        {
          id: "parent-1",
          kind: "fanout",
          status: "running",
          message: "Stale swarm",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };
    const settledPayload = {
      runs: [
        {
          id: "parent-1",
          kind: "fanout",
          status: "cancelled",
          message: "Stale swarm",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };
    let currentRuns = runningPayload;
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit) => {
        const path = String(url);
        if (init?.method === "POST" && path.endsWith("/cancel")) {
          return jsonResponse({
            id: "parent-1",
            status: "cancelled",
            cancelled: true,
          });
        }
        if (path.startsWith("/runs?")) return jsonResponse(currentRuns);
        return jsonResponse({ approvals: [], count: 0 });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Stale swarm")).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Details" }));
    expect(screen.getByLabelText("Run details")).toBeInTheDocument();
    // The list row plus the open detail view both read running.
    expect(screen.getAllByText("IN PROGRESS").length).toBeGreaterThanOrEqual(2);

    currentRuns = settledPayload;
    await user.click(screen.getByRole("button", { name: "Cancel run" }));
    await user.click(screen.getByRole("button", { name: "Confirm cancel run" }));

    // The refetched status flows into the open detail view, so its in-progress
    // note is replaced by the honest cancelled copy.
    await waitFor(() => {
      expect(
        screen.getByText(
          "Cancelled before completion: no output was recorded.",
        ),
      ).toBeInTheDocument();
    });

    // Closing the detail view leaves only the settled list badge behind.
    await user.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.queryByLabelText("Run details")).not.toBeInTheDocument();
    expect(screen.getByText("CANCELLED")).toBeInTheDocument();
    expect(screen.queryByText("IN PROGRESS")).not.toBeInTheDocument();
    // Cancel plus refetch plus detail settle runs several round trips; loaded
    // CI bursts past the 5s default, so this test alone carries headroom.
  }, 15000);

  it("renders budget_exceeded status pill and detail modal warning banner", async () => {
    const user = userEvent.setup();
    const budgetPayload = {
      runs: [
        {
          id: "budget-run-123",
          jobID: "daily-digest",
          kind: "scheduler",
          status: "budget_exceeded",
          message: "Daily digest synthesis",
          response: "Partial draft report collected before reaching tool budget limit.",
          timestamp: new Date().toISOString(),
        },
      ],
      count: 1,
    };

    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(budgetPayload)));
    render(<RunLogViewer />);
    await waitFor(() => {
      expect(screen.getByText("Daily digest synthesis")).toBeInTheDocument();
    });
    expect(screen.getByText("BUDGET EXCEEDED")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Details" }));
    expect(screen.getByLabelText("Run details")).toBeInTheDocument();
    expect(screen.getByText("Tool Budget Exceeded:")).toBeInTheDocument();
    expect(screen.getByText(/Partial draft report collected before reaching tool budget limit/)).toBeInTheDocument();
  });
});
