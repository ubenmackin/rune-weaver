// Rune Weaver Dashboard — Shared Recent Runs Fetcher Tests.
//
// Purpose: guard the single-flight cache that lets the Working Right Now stream
// and the Recent Reports cards share one `GET /runs` instead of polling twice.
//
// Scope: unit coverage for request collapsing, TTL expiry, failure handling,
// and per-caller slicing, plus widget-level checks that both cards render a
// loading skeleton first and only show their empty copy after the fetch
// settles.
//
// Architectural role: regression net for the dashboard's run-log read path —
// the shared fetcher owns timing while each widget owns filtering, so these
// tests pin the timing contract without duplicating filter logic.

import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { listRuns, type RunLogEntry } from "../../api";
import {
  clearSharedRecentRunsForTesting,
  getSharedRecentRuns,
} from "./sharedRuns";
import RecentReports from "./RecentReports";
import WorkingNowStream from "./WorkingNowStream";

// Single-flight mock for the run log so the shared fetcher exercises the real
// coalescing logic while every other API helper stays untouched.
vi.mock("../../api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api")>();
  return {
    ...actual,
    listRuns: vi.fn(),
  };
});

function makeRun(id: string, status = "ok", kind = "chat"): RunLogEntry {
  return {
    id,
    kind,
    status,
    message: `message ${id}`,
    timestamp: Date.now(),
  };
}

function makeRuns(count: number, prefix = "run"): RunLogEntry[] {
  return Array.from({ length: count }, (_, i) => makeRun(`${prefix}-${i}`));
}

beforeEach(() => {
  clearSharedRecentRunsForTesting();
  vi.clearAllMocks();
  vi.restoreAllMocks();
});

describe("getSharedRecentRuns single-flight", () => {
  it("collapses concurrent callers into one request sized with the larger limit", async () => {
    const all = makeRuns(30, "shared");
    vi.mocked(listRuns).mockResolvedValue({ runs: all, count: all.length });

    // Fired synchronously in the same tick, mirroring two widgets mounting in
    // one Dashboard commit before the network starts.
    const [small, large] = await Promise.all([
      getSharedRecentRuns(25),
      getSharedRecentRuns(30),
    ]);

    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(listRuns)).toHaveBeenCalledWith(30);
    expect(small).toHaveLength(25);
    expect(small).toEqual(all.slice(0, 25));
    expect(large).toHaveLength(30);
    expect(large).toEqual(all.slice(0, 30));
  });

  it("collapses when the smaller limit arrives first", async () => {
    const all = makeRuns(30, "small-first");
    vi.mocked(listRuns).mockResolvedValue({ runs: all, count: all.length });

    const firstCall = getSharedRecentRuns(25);
    const secondCall = getSharedRecentRuns(30);
    const [small, large] = await Promise.all([firstCall, secondCall]);

    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(listRuns)).toHaveBeenCalledWith(30);
    expect(small).toHaveLength(25);
    expect(large).toHaveLength(30);
  });

  it("serves a fresh cache with zero network and slices per caller", async () => {
    const all = makeRuns(30, "cached");
    vi.mocked(listRuns).mockResolvedValue({ runs: all, count: all.length });

    const full = await getSharedRecentRuns(30);
    expect(full).toHaveLength(30);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);

    // Within the freshness window the second caller slices the cached payload
    // without touching the network.
    const small = await getSharedRecentRuns(10);
    expect(small).toHaveLength(10);
    expect(small).toEqual(all.slice(0, 10));
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);

    const medium = await getSharedRecentRuns(25);
    expect(medium).toHaveLength(25);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
  });

  it("refetches once the cached payload expires", async () => {
    const first = makeRuns(30, "first");
    const second = makeRuns(30, "second");
    vi.mocked(listRuns).mockResolvedValueOnce({ runs: first, count: first.length });

    const initial = await getSharedRecentRuns(30);
    expect(initial).toEqual(first);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);

    // A call inside the window stays cached.
    const cached = await getSharedRecentRuns(30);
    expect(cached).toEqual(first);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);

    // Moving the clock past the freshness window forces exactly one refetch.
    const settledAt = Date.now();
    const clock = vi.spyOn(Date, "now").mockReturnValue(settledAt + 6000);
    try {
      vi.mocked(listRuns).mockResolvedValueOnce({ runs: second, count: second.length });
      const refetched = await getSharedRecentRuns(30);
      expect(refetched).toEqual(second);
      expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(2);
    } finally {
      clock.mockRestore();
    }
  });

  it("refetches when the cached limit cannot satisfy a larger caller", async () => {
    const smallPayload = makeRuns(25, "small-payload");
    vi.mocked(listRuns).mockResolvedValueOnce({
      runs: smallPayload,
      count: smallPayload.length,
    });
    await getSharedRecentRuns(25);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(listRuns)).toHaveBeenCalledWith(25);

    // Fresh but insufficient: slicing the smaller payload would silently short
    // the hungrier caller, so the module fetches with the larger limit.
    const largePayload = makeRuns(30, "large-payload");
    vi.mocked(listRuns).mockResolvedValueOnce({
      runs: largePayload,
      count: largePayload.length,
    });
    const large = await getSharedRecentRuns(30);
    expect(large).toHaveLength(30);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(2);
    expect(vi.mocked(listRuns)).toHaveBeenLastCalledWith(30);
  });

  it("refetches once when a hungrier caller arrives after the flight dispatched", async () => {
    const dispatched = makeRuns(10, "dispatched");
    let releaseFirst!: (value: { runs: RunLogEntry[]; count: number }) => void;
    vi.mocked(listRuns).mockImplementationOnce(
      () =>
        new Promise<{ runs: RunLogEntry[]; count: number }>((resolve) => {
          releaseFirst = resolve;
        }),
    );
    const first = getSharedRecentRuns(10);
    // Flush the flight's deferred start so the hungrier caller below arrives
    // after dispatch and can no longer widen the shared request.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(listRuns)).toHaveBeenCalledWith(10);

    // The late caller wants more rows than the dispatched limit holds: it must
    // await the flight and refetch once rather than slicing short with no error.
    const large = makeRuns(30, "large-late");
    vi.mocked(listRuns).mockImplementationOnce(async () => ({ runs: large, count: large.length }));
    const second = getSharedRecentRuns(30);
    releaseFirst({ runs: dispatched, count: dispatched.length });
    const [firstRuns, secondRuns] = await Promise.all([first, second]);
    expect(firstRuns).toEqual(dispatched.slice(0, 10));
    expect(secondRuns).toHaveLength(30);
    expect(secondRuns).toEqual(large.slice(0, 30));
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(2);
    expect(vi.mocked(listRuns)).toHaveBeenLastCalledWith(30);
  });

  it("forceRefresh bypasses a fresh cache for lifecycle-driven refetches", async () => {
    const first = makeRuns(5, "first");
    vi.mocked(listRuns).mockResolvedValueOnce({ runs: first, count: first.length });
    await getSharedRecentRuns(5);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);

    // A `run_completed` frame must observe the newly settled run now, not when
    // the freshness window lapses.
    const second = makeRuns(5, "second");
    vi.mocked(listRuns).mockResolvedValueOnce({ runs: second, count: second.length });
    const refetched = await getSharedRecentRuns(5, { forceRefresh: true });
    expect(refetched).toEqual(second);
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(2);
  });

  it("never caches failures and lets the next call retry", async () => {
    vi.mocked(listRuns).mockRejectedValueOnce(new Error("network down"));
    await expect(getSharedRecentRuns(25)).rejects.toThrow("network down");
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);

    const recovered = makeRuns(5, "recovered");
    vi.mocked(listRuns).mockResolvedValueOnce({ runs: recovered, count: recovered.length });
    const ok = await getSharedRecentRuns(25);
    expect(ok).toEqual(recovered.slice(0, 25));
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(2);
  });

  it("propagates one failure to concurrent callers with a single request", async () => {
    vi.mocked(listRuns).mockRejectedValueOnce(new Error("engine offline"));
    const first = getSharedRecentRuns(25);
    const second = getSharedRecentRuns(30);
    await expect(first).rejects.toThrow("engine offline");
    await expect(second).rejects.toThrow("engine offline");
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(listRuns)).toHaveBeenCalledWith(30);
  });
});

describe("dashboard widgets shared loading", () => {
  it("paints both widgets from a single request on a cold mount", async () => {
    const runs: RunLogEntry[] = [
      { ...makeRun("run-active-1", "running", "goal"), message: "Executing migration step 2", sessionID: "sess-1" },
      { ...makeRun("run-done-1", "ok", "scheduler"), message: "Morning Inbox Triage", response: "Processed 12 emails." },
    ];
    vi.mocked(listRuns).mockResolvedValue({ runs, count: runs.length });

    render(
      <>
        <WorkingNowStream />
        <RecentReports />
      </>,
    );

    await waitFor(() => {
      expect(screen.getByText("Executing migration step 2")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText("Morning Inbox Triage")).toBeInTheDocument();
    });
    expect(vi.mocked(listRuns)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(listRuns)).toHaveBeenCalledWith(30);
  });

  it("RecentReports shows a spinner first, then the report, never a premature empty state", async () => {
    let resolveFetch!: (value: { runs: RunLogEntry[]; count: number }) => void;
    vi.mocked(listRuns).mockImplementation(
      () =>
        new Promise<{ runs: RunLogEntry[]; count: number }>((resolve) => {
          resolveFetch = resolve;
        }),
    );

    render(<RecentReports />);

    // Loading skeleton appears on the first render while the shared fetch is
    // still pending; the empty copy stays hidden until the fetch settles.
    expect(screen.getByText(/Loading recent reports/i)).toBeInTheDocument();
    expect(screen.queryByText(/No completed runs recorded yet/i)).not.toBeInTheDocument();

    await waitFor(() => expect(vi.mocked(listRuns)).toHaveBeenCalled());
    resolveFetch({
      runs: [{ ...makeRun("run-done-9", "ok", "scheduler"), message: "Morning Inbox Triage" }],
      count: 1,
    });

    await waitFor(() => {
      expect(screen.getByText("Morning Inbox Triage")).toBeInTheDocument();
    });
    expect(screen.queryByText(/Loading recent reports/i)).not.toBeInTheDocument();
  });

  it("RecentReports shows its empty copy only after the load settles with zero rows", async () => {
    vi.mocked(listRuns).mockResolvedValue({ runs: [], count: 0 });

    render(<RecentReports />);

    expect(screen.getByText(/Loading recent reports/i)).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.getByText(/No completed runs recorded yet/i)).toBeInTheDocument();
    });
    expect(screen.queryByText(/Loading recent reports/i)).not.toBeInTheDocument();
  });

  it("WorkingNowStream shows a spinner first, then live work, never a premature idle state", async () => {
    let resolveFetch!: (value: { runs: RunLogEntry[]; count: number }) => void;
    vi.mocked(listRuns).mockImplementation(
      () =>
        new Promise<{ runs: RunLogEntry[]; count: number }>((resolve) => {
          resolveFetch = resolve;
        }),
    );

    render(<WorkingNowStream />);

    expect(screen.getByText(/Loading live tasks/i)).toBeInTheDocument();
    expect(screen.queryByText("All Systems Idle")).not.toBeInTheDocument();

    await waitFor(() => expect(vi.mocked(listRuns)).toHaveBeenCalled());
    resolveFetch({
      runs: [{ ...makeRun("run-active-9", "running", "goal"), message: "Executing migration step 2" }],
      count: 1,
    });

    await waitFor(() => {
      expect(screen.getByText("Executing migration step 2")).toBeInTheDocument();
    });
    expect(screen.queryByText(/Loading live tasks/i)).not.toBeInTheDocument();
  });

  it("WorkingNowStream shows its idle copy only after the load settles with zero rows", async () => {
    vi.mocked(listRuns).mockResolvedValue({ runs: [], count: 0 });

    render(<WorkingNowStream />);

    expect(screen.getByText(/Loading live tasks/i)).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.getByText("All Systems Idle")).toBeInTheDocument();
    });
    expect(screen.queryByText(/Loading live tasks/i)).not.toBeInTheDocument();
  });
});
