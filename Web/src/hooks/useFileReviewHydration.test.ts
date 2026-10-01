// Rune Weaver Dashboard — useFileReviewHydration hook tests.
// Pins the surface-batch contract for write-review hydration: rendered write
// cards dedupe their paths into one review-status request per batch, an
// oversized card set splits at the engine route's path bound, a failed batch
// stays unresolved, and a card set that changes (or flips back) reads pending
// until its own batch settles instead of inheriting stale states.

import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  MAX_REVIEW_STATUS_PATHS,
  useFileReviewHydration,
  writeReviewHydrationKey,
  type WriteReviewHydrationTarget,
} from "./useFileReviewHydration";
import { jsonResponse } from "../test-utils/http";

function stagedTarget(
  path: string,
  cardKey: string,
): WriteReviewHydrationTarget {
  return { kind: "staged", path, cardKey };
}

function reviewResponse(
  stagedStates: Record<string, string>,
  liveStates: Record<string, string> = {},
): Response {
  return jsonResponse({ stagedStates, liveStates });
}

// Minimal externally-settled promise so a test can hold one batch open while
// asserting the state served before it resolves.
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

beforeEach(() => {
  vi.unstubAllGlobals();
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("useFileReviewHydration batching", () => {
  it("dedupes one card set into a single request", async () => {
    // Explicit input/init params keep mock.calls typed as a 2-tuple so the
    // request-body assertions typecheck; a zero-arg impl would trip TS2493.
    const fetchMock = vi.fn(
      async (_input?: unknown, _init?: RequestInit) =>
        reviewResponse({ "/tmp/a.txt": "accepted" }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const { result } = renderHook(() =>
      useFileReviewHydration([
        stagedTarget("/tmp/a.txt", "call-1"),
        stagedTarget("/tmp/a.txt", "call-2"),
      ]),
    );

    await waitFor(() => {
      expect(result.current?.stagedStates["/tmp/a.txt"]).toBe("accepted");
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0];
    expect(JSON.parse(String(init?.body))).toEqual({ paths: ["/tmp/a.txt"] });
  });

  it("splits an oversized card set at the engine path bound", async () => {
    const fetchMock = vi.fn(
      async (_input?: unknown, _init?: RequestInit) => reviewResponse({}),
    );
    vi.stubGlobal("fetch", fetchMock);
    const paths = Array.from(
      { length: MAX_REVIEW_STATUS_PATHS + 1 },
      (_, index) => `/tmp/overflow-${index}.txt`,
    );

    const { result } = renderHook(() =>
      useFileReviewHydration(
        paths.map((path, index) => stagedTarget(path, `call-${index}`)),
      ),
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledTimes(2);
    });
    // The batch reports only after every chunk has settled.
    await waitFor(() => {
      expect(result.current).not.toBeNull();
    });
    const sizes = fetchMock.mock.calls
      .map(
        ([, init]) =>
          JSON.parse(String(init?.body)) as { paths: string[] },
      )
      .map((body) => body.paths.length)
      .sort((a, b) => b - a);
    expect(sizes).toEqual([MAX_REVIEW_STATUS_PATHS, 1]);
  });

  it("leaves a failed batch unresolved instead of serving empty maps", async () => {
    const fetchMock = vi.fn(
      async (_input?: unknown, _init?: RequestInit) =>
        jsonResponse({ reason: "ledger offline" }, 500),
    );
    vi.stubGlobal("fetch", fetchMock);

    const { result } = renderHook(() =>
      useFileReviewHydration([stagedTarget("/tmp/a.txt", "call-1")]),
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledTimes(1);
    });
    expect(result.current).toBeNull();
  });
});

describe("useFileReviewHydration card-set changes", () => {
  it("drops a returning card set's old states until its own batch settles", async () => {
    const first = deferred<Response>();
    const second = deferred<Response>();
    const third = deferred<Response>();
    const pending = [first.promise, second.promise, third.promise];
    let call = 0;
    const fetchMock = vi.fn(
      (_input?: unknown, _init?: RequestInit) => pending[call++],
    );
    vi.stubGlobal("fetch", fetchMock);

    const { result, rerender } = renderHook(
      ({ targets }: { targets: WriteReviewHydrationTarget[] }) =>
        useFileReviewHydration(targets),
      { initialProps: { targets: [stagedTarget("/tmp/a.txt", "call-1")] } },
    );

    await act(async () => {
      first.resolve(reviewResponse({ "/tmp/a.txt": "accepted" }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(result.current?.stagedStates["/tmp/a.txt"]).toBe("accepted");

    // The rendered set changes; its previous states drop before children see
    // them, so the swapped-in card reads pending rather than a foreign state.
    rerender({ targets: [stagedTarget("/tmp/b.txt", "call-2")] });
    expect(result.current).toBeNull();
    await act(async () => {
      second.resolve(reviewResponse({ "/tmp/b.txt": "pending" }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(result.current?.stagedStates["/tmp/b.txt"]).toBe("pending");

    // Returning to the original card set must not resurrect the first batch's
    // states: the fresh read owns the result even when the key matches.
    rerender({ targets: [stagedTarget("/tmp/a.txt", "call-1")] });
    expect(result.current).toBeNull();
    await act(async () => {
      third.resolve(reviewResponse({ "/tmp/a.txt": "superseded" }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(result.current?.stagedStates["/tmp/a.txt"]).toBe("superseded");
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("never requests when no reviewable cards are rendered", () => {
    const fetchMock = vi.fn(
      async (_input?: unknown, _init?: RequestInit) => reviewResponse({}),
    );
    vi.stubGlobal("fetch", fetchMock);

    const { result } = renderHook(() => useFileReviewHydration([]));
    expect(result.current).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("writeReviewHydrationKey", () => {
  it("is order-independent and distinguishes card identities", () => {
    const first = stagedTarget("/tmp/a.txt", "call-1");
    const second = stagedTarget("/tmp/a.txt", "call-2");
    expect(writeReviewHydrationKey([first, second])).toBe(
      writeReviewHydrationKey([second, first]),
    );
    expect(writeReviewHydrationKey([first])).not.toBe(
      writeReviewHydrationKey([second]),
    );
  });
});
