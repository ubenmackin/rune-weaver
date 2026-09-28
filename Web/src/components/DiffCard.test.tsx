// Rune Weaver Dashboard — DiffCard timeout plus retry component tests.
// Pins the inline review contract: HTTP 200 flips the badge immediately, a
// hung engine walk surfaces a 10s retryable timeout instead of an infinite
// loading state, and server failures show the reason with a manual Retry.

import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import DiffCard from "./DiffCard";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
} from "../test-utils/mockWebSocket";

const STAGED_PATH = "/tmp/diff-card-timeout.txt";

function stagedResult() {
  return {
    toolCallID: "call-diff-timeout-1",
    content: JSON.stringify({
      status: "staged",
      path: STAGED_PATH,
      diff: "@@ -1 +1 @@\n-old\n+new\n",
      additions: 1,
      deletions: 1,
      message: "staged",
    }),
    isError: false,
  };
}

function stubSharedSocket() {
  const capture = createMockWebSocketCapture();
  vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  return capture;
}

beforeEach(() => {
  vi.unstubAllGlobals();
  resetSharedSocket();
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  resetSharedSocket();
});

describe("DiffCard accept timeout plus retry", () => {
  it("surfaces a retryable timeout banner when accept hangs", async () => {
    vi.useFakeTimers();
    // Hung engine walk: never settles on its own so the card-side 10s race
    // must supply the timeout without relying on the fetch abort alone.
    // Explicit input/init params keep mock.calls typed as a 2-tuple so the
    // abort-signal assertion below typechecks (a zero-arg impl would infer
    // calls as [] and trip TS2493 on index 1).
    const fetchMock = vi.fn(
      (_input: unknown, _init?: unknown) =>
        new Promise<Response>(() => undefined),
    );
    vi.stubGlobal("fetch", fetchMock);
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    // Loading state is visible while the request is in flight.
    expect(screen.getByText("Accepting…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accepting…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Discard" })).toBeDisabled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });

    // Timeout copy is exact and carries a manual Retry affordance.
    expect(
      screen.getByText("Accept timed out after 10s. The file was not changed. Retry."),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    // No infinite loading state survives the timeout on any path.
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    // No auto-retry: one hung attempt yields exactly one request.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    // The request carries an abort signal so the engine walk can be cancelled.
    const [, init] = fetchMock.mock.calls[0] as unknown as [
      unknown,
      { signal?: unknown },
    ];
    expect(init?.signal).toBeInstanceOf(AbortSignal);
  });

  it("flips to Accepted immediately on HTTP 200", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: "ok", count: 1 })),
    );
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Retry" })).not.toBeInTheDocument();
  });

  it("shows the server reason with Retry and retries to Accepted", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ reason: "disk full" }, 500))
      .mockResolvedValueOnce(jsonResponse({ status: "ok", count: 1 }));
    vi.stubGlobal("fetch", fetchMock);
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    await waitFor(() => {
      expect(screen.getByText("disk full")).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.queryByText("Accepted")).not.toBeInTheDocument();

    // Manual Retry re-invokes the same accept handler and flips the badge.
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("DiffCard discard timeout plus retry", () => {
  it("surfaces a retryable timeout banner when discard hangs", async () => {
    vi.useFakeTimers();
    // Hung discard mirrors the accept hang above: explicit params keep the
    // mock calls tuple typed for future signal assertions.
    const fetchMock = vi.fn(
      (_input: unknown, _init?: unknown) =>
        new Promise<Response>(() => undefined),
    );
    vi.stubGlobal("fetch", fetchMock);
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));

    expect(screen.getByText("Discarding…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discarding…" })).toBeDisabled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });

    expect(
      screen.getByText("Discard timed out after 10s. The file was not changed. Retry."),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("flips to Discarded immediately on HTTP 200", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: "ok", count: 1 })),
    );
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));

    await waitFor(() => {
      expect(screen.getByText("Discarded")).toBeInTheDocument();
    });
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
  });

  it("shows the server reason with Retry on discard failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reason: "locked by greeter" }, 500)),
    );
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));

    await waitFor(() => {
      expect(screen.getByText("locked by greeter")).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
    expect(screen.queryByText("Discarded")).not.toBeInTheDocument();
  });
});
