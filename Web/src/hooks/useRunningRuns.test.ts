// Rune Weaver Dashboard — Stillness tests for the shared run-log poller.

import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { listRuns, type RunLogEntry } from "../api";
import {
  resetSharedRunsForTesting,
  runsFingerprint,
  useRunningRuns,
  type FrozenRunLogEntry,
} from "./useRunningRuns";

// Single-flight mock for the run log so each poll tick resolves to the
// payload the test installs; every other helper stays real so timestamps
// and badge derivation exercise the production path.
vi.mock("../api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api")>();
  return {
    ...actual,
    listRuns: vi.fn(),
  };
});

function baseAction(overrides: Record<string, unknown> = {}) {
  return {
    toolName: "email.search",
    callID: "call-1",
    argumentsJSON: '{"limit":1}',
    roundIndex: 0,
    result: {
      toolCallID: "call-1",
      content: "1 found",
      isError: false,
    },
    ...overrides,
  };
}

function baseRun(overrides: Record<string, unknown> = {}): RunLogEntry {
  return {
    id: "run-1",
    jobID: "job-1",
    sessionID: "session-1",
    kind: "chat",
    status: "running",
    message: "hello",
    timestamp: "2024-05-01T12:00:00.000Z",
    response: "reply",
    totalTokens: 10,
    durationMs: 100,
    toolActions: [baseAction()],
    ...overrides,
  } as RunLogEntry;
}

function frozenCopy(run: RunLogEntry): FrozenRunLogEntry {
  return JSON.parse(JSON.stringify(run)) as FrozenRunLogEntry;
}

// Mounts the shared hook while counting renders so stillness reads as zero
// extra renders after the settled tick; refresh drives the next poll tick.
async function mountSettled(runs: RunLogEntry[]) {
  vi.mocked(listRuns).mockResolvedValue({ runs, count: runs.length });
  let renders = 0;
  const hook = renderHook(() => {
    renders += 1;
    return useRunningRuns();
  });
  await waitFor(() => {
    expect(hook.result.current.runs).toHaveLength(runs.length);
  });
  const snapshot = hook.result.current.runs;
  const settledRenders = renders;
  return {
    ...hook,
    snapshot,
    getRenders: () => renders,
    settledRenders,
  };
}

async function tickRefresh(refresh: () => void) {
  await act(async () => {
    refresh();
    await Promise.resolve();
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

describe("runsFingerprint", () => {
  it("matches identical payloads with fresh object identities", () => {
    const left = [frozenCopy(baseRun())];
    const right = [frozenCopy(baseRun())];
    expect(left[0]).not.toBe(right[0]);
    expect(runsFingerprint(left)).toBe(runsFingerprint(right));
  });

  it("differs on changed status", () => {
    const left = [frozenCopy(baseRun({ status: "running" }))];
    const right = [frozenCopy(baseRun({ status: "ok" }))];
    expect(runsFingerprint(left)).not.toBe(runsFingerprint(right));
  });

  it("differs on changed response", () => {
    const left = [frozenCopy(baseRun({ response: "one" }))];
    const right = [frozenCopy(baseRun({ response: "two" }))];
    expect(runsFingerprint(left)).not.toBe(runsFingerprint(right));
  });

  it("differs on changed tool result content", () => {
    const left = [
      frozenCopy(baseRun({ toolActions: [baseAction()] })),
    ];
    const right = [
      frozenCopy(
        baseRun({
          toolActions: [
            baseAction({
              result: {
                toolCallID: "call-1",
                content: "changed",
                isError: false,
              },
            }),
          ],
        }),
      ),
    ];
    expect(runsFingerprint(left)).not.toBe(runsFingerprint(right));
  });

  it("differs on reordered rows with no sorting", () => {
    const first = frozenCopy(baseRun({ id: "run-a" }));
    const second = frozenCopy(baseRun({ id: "run-b" }));
    expect(runsFingerprint([first, second])).not.toBe(
      runsFingerprint([second, first]),
    );
  });

  it("treats null and undefined field shapes as stable", () => {
    const left = [
      frozenCopy(
        baseRun({
          jobID: null,
          sessionID: null,
          response: null,
          totalTokens: null,
          durationMs: null,
        }),
      ),
    ];
    const right = [
      frozenCopy(
        baseRun({
          jobID: undefined,
          sessionID: undefined,
          response: undefined,
          totalTokens: undefined,
          durationMs: undefined,
        }),
      ),
    ];
    expect(runsFingerprint(left)).toBe(runsFingerprint(right));
  });

  it("normalizes dual timestamp shapes to one epoch value", () => {
    const iso = frozenCopy(baseRun({ timestamp: "2024-05-01T12:00:00.000Z" }));
    const seconds = frozenCopy(baseRun({ timestamp: 1714564800 }));
    expect(runsFingerprint([iso])).toBe(runsFingerprint([seconds]));
  });
});

describe("shared runs stillness", () => {
  beforeEach(() => {
    resetSharedRunsForTesting();
    vi.clearAllMocks();
  });

  it("keeps the snapshot reference with zero notify on an identical second tick", async () => {
    const mounted = await mountSettled([baseRun()]);
    const first = mounted.snapshot;
    const callsBefore = vi.mocked(listRuns).mock.calls.length;
    vi.mocked(listRuns).mockResolvedValue({
      runs: [baseRun()],
      count: 1,
    });
    await tickRefresh(mounted.result.current.refresh);
    await waitFor(() => {
      expect(vi.mocked(listRuns).mock.calls.length).toBeGreaterThan(
        callsBefore,
      );
    });
    expect(mounted.result.current.runs).toBe(first);
    expect(mounted.getRenders()).toBe(mounted.settledRenders);
    mounted.unmount();
  });

  it("notifies on changed status", async () => {
    const mounted = await mountSettled([baseRun({ status: "running" })]);
    const first = mounted.snapshot;
    vi.mocked(listRuns).mockResolvedValue({
      runs: [baseRun({ status: "ok" })],
      count: 1,
    });
    await tickRefresh(mounted.result.current.refresh);
    await waitFor(() => {
      expect(mounted.result.current.runs).not.toBe(first);
    });
    expect(mounted.result.current.runs[0].status).toBe("ok");
    mounted.unmount();
  });

  it("notifies on changed response", async () => {
    const mounted = await mountSettled([baseRun({ response: "one" })]);
    const first = mounted.snapshot;
    vi.mocked(listRuns).mockResolvedValue({
      runs: [baseRun({ response: "two" })],
      count: 1,
    });
    await tickRefresh(mounted.result.current.refresh);
    await waitFor(() => {
      expect(mounted.result.current.runs).not.toBe(first);
    });
    expect(mounted.result.current.runs[0].response).toBe("two");
    mounted.unmount();
  });

  it("notifies on changed tool result", async () => {
    const mounted = await mountSettled([baseRun()]);
    const first = mounted.snapshot;
    vi.mocked(listRuns).mockResolvedValue({
      runs: [
        baseRun({
          toolActions: [
            baseAction({
              result: {
                toolCallID: "call-1",
                content: "changed result",
                isError: false,
              },
            }),
          ],
        }),
      ],
      count: 1,
    });
    await tickRefresh(mounted.result.current.refresh);
    await waitFor(() => {
      expect(mounted.result.current.runs).not.toBe(first);
    });
    mounted.unmount();
  });

  it("notifies on reordered rows", async () => {
    const rowA = baseRun({ id: "run-a", message: "a" });
    const rowB = baseRun({ id: "run-b", message: "b" });
    const mounted = await mountSettled([rowA, rowB]);
    const first = mounted.snapshot;
    expect(first[0].id).toBe("run-a");
    vi.mocked(listRuns).mockResolvedValue({
      runs: [baseRun({ id: "run-b", message: "b" }), baseRun({ id: "run-a", message: "a" })],
      count: 2,
    });
    await tickRefresh(mounted.result.current.refresh);
    await waitFor(() => {
      expect(mounted.result.current.runs).not.toBe(first);
    });
    expect(mounted.result.current.runs[0].id).toBe("run-b");
    mounted.unmount();
  });

  it("keeps the snapshot on null versus undefined field shapes", async () => {
    const nullShape = baseRun({
      jobID: null,
      sessionID: null,
      response: null,
      totalTokens: null,
      durationMs: null,
    });
    const mounted = await mountSettled([nullShape]);
    const first = mounted.snapshot;
    const undefinedShape = baseRun({
      jobID: undefined,
      sessionID: undefined,
      response: undefined,
      totalTokens: undefined,
      durationMs: undefined,
    });
    // Absent keys read the same as explicit nulls in the key.
    delete (undefinedShape as unknown as Record<string, unknown>).jobID;
    delete (undefinedShape as unknown as Record<string, unknown>).sessionID;
    delete (undefinedShape as unknown as Record<string, unknown>).response;
    delete (undefinedShape as unknown as Record<string, unknown>).totalTokens;
    delete (undefinedShape as unknown as Record<string, unknown>).durationMs;
    vi.mocked(listRuns).mockResolvedValue({
      runs: [undefinedShape],
      count: 1,
    });
    await tickRefresh(mounted.result.current.refresh);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(mounted.result.current.runs).toBe(first);
    mounted.unmount();
  });

  it("keeps the prior snapshot on a malformed payload", async () => {
    const mounted = await mountSettled([baseRun()]);
    const first = mounted.snapshot;
    vi.mocked(listRuns).mockResolvedValue({
      runs: null,
      count: 0,
    } as unknown as { runs: RunLogEntry[]; count: number });
    await tickRefresh(mounted.result.current.refresh);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(mounted.result.current.runs).toBe(first);
    mounted.unmount();
  });

  it("keeps the prior snapshot on poll rejection", async () => {
    const mounted = await mountSettled([baseRun()]);
    const first = mounted.snapshot;
    vi.mocked(listRuns).mockRejectedValue(new Error("network down"));
    await tickRefresh(mounted.result.current.refresh);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(mounted.result.current.runs).toBe(first);
    mounted.unmount();
  });
});
