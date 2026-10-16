// Rune Weaver Dashboard — DiffCard component tests.

import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import DiffCard, {
  DIFF_CARD_ACCEPT_TIMEOUT_MESSAGE,
  DIFF_CARD_DISCARD_TIMEOUT_MESSAGE,
  DIFF_CARD_LIVE_ACCEPT_TIMEOUT_MESSAGE,
  DIFF_CARD_LIVE_DECLINE_TIMEOUT_MESSAGE,
  DIFF_CARD_OWNED_BY_NEWER_NOTE,
  writeReviewKey,
  writeReviewTarget,
} from "./DiffCard";
import { collectWriteReviewOwners } from "./writeReviewOwnership";
import type { ToolAction, ToolResult } from "../api";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";

const STAGED_PATH = "/tmp/diff-card-timeout.txt";
const LIVE_PATH = "/tmp/diff-card-live.txt";
// Derived rollback sibling the engine names for an existing-file live review.
const LIVE_BACKUP_PATH = "/tmp/.rune_backup_diff-card-live.txt";
const REVIEW_STATUS_URL = "/files/review-status";
const ACCEPT_URL = "/files/accept";
const DISCARD_URL = "/files/discard";
const LIVE_ACCEPT_URL = "/files/live-accept";
const LIVE_DECLINE_URL = "/files/live-decline";

// Live envelopes mirror the engine wire shape: `backupPath` names the rollback
// copy for an existing-file review and is null for a newly created file, so a
// card's decline posture (Revert versus Discard) comes from the envelope.
function writeEnvelope(
  status: "staged" | "live",
  path: string,
  backupPath: string | null = null,
): string {
  return JSON.stringify({
    status,
    path,
    backupPath,
    diff: "@@ -1 +1 @@\n-old\n+new\n",
    additions: 1,
    deletions: 1,
    message: status,
  });
}

function stagedResult(path = STAGED_PATH): ToolResult {
  return {
    toolCallID: "call-diff-staged-1",
    content: writeEnvelope("staged", path),
    isError: false,
  };
}

// Defaults to a new-file review (no rollback copy); pass the derived backup
// sibling to model an existing-file review whose decline restores the file.
function liveResult(
  path = LIVE_PATH,
  backupPath: string | null = null,
): ToolResult {
  return {
    toolCallID: "call-diff-live-1",
    content: writeEnvelope("live", path, backupPath),
    isError: false,
  };
}

function reviewResponse(
  stagedStates: Record<string, string>,
  liveStates: Record<string, string> = {},
): Response {
  return jsonResponse({ stagedStates, liveStates });
}

type FetchHandler = () => Promise<Response> | Response;

interface FetchMockLike {
  mock: { calls: unknown[][] };
}

// Routes each request by URL: the mount hydration call coexists with accept/discard/live calls, so
// tests count calls per route instead of assuming a call order.
function stubRoutedFetch(
  handlers: {
    review?: FetchHandler;
    accept?: FetchHandler;
    discard?: FetchHandler;
    liveAccept?: FetchHandler;
    liveDecline?: FetchHandler;
  } = {},
) {
  const fetchMock = vi.fn(async (input: unknown) => {
    const url = String(input);
    if (url.includes(REVIEW_STATUS_URL)) {
      return handlers.review
        ? handlers.review()
        : jsonResponse({ stagedStates: {}, liveStates: {} });
    }
    // Live routes are matched first so the routing never depends on the staged
    // and live spellings staying disjoint substrings of each other.
    if (url.includes(LIVE_ACCEPT_URL)) {
      return handlers.liveAccept
        ? handlers.liveAccept()
        : jsonResponse({ status: "accepted", count: 1 });
    }
    if (url.includes(LIVE_DECLINE_URL)) {
      return handlers.liveDecline
        ? handlers.liveDecline()
        : jsonResponse({ status: "reverted", count: 1 });
    }
    if (url.includes(ACCEPT_URL)) {
      return handlers.accept
        ? handlers.accept()
        : jsonResponse({ status: "ok", count: 1 });
    }
    if (url.includes(DISCARD_URL)) {
      return handlers.discard
        ? handlers.discard()
        : jsonResponse({ status: "ok", count: 1 });
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function callsTo(fetchMock: FetchMockLike, route: string): unknown[][] {
  return fetchMock.mock.calls.filter((call) => String(call[0]).includes(route));
}

function stubSharedSocket() {
  const capture = createMockWebSocketCapture();
  vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  return capture;
}

// Minimal externally-settled promise so a test can hold one response back
// until after another action has settled, which pins the hydration race.
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

// Drains the mocked hydration round trip (fetch -> JSON -> setState) inside
// act so a test asserts the settled card instead of one mid-flight.
async function flushHydration() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
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
    // Hung engine walk: never settles on its own so the card-side 10s race must supply the timeout
    // without relying on the fetch abort alone. The mount hydration request hangs the same way.
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
    expect(screen.getByText(DIFF_CARD_ACCEPT_TIMEOUT_MESSAGE)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    // No infinite loading state survives the timeout on any path.
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    // No auto-retry: one hung attempt yields exactly one accept request,
    // counted by route so the mount hydration call is never misread as one.
    const acceptCalls = callsTo(fetchMock, ACCEPT_URL);
    expect(acceptCalls).toHaveLength(1);
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);
    // The request carries an abort signal so the engine walk can be cancelled.
    const [, init] = acceptCalls[0] as unknown as [
      unknown,
      { signal?: unknown },
    ];
    expect(init?.signal).toBeInstanceOf(AbortSignal);
  });

  it("flips to Accepted immediately on HTTP 200", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Retry" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    // Drain the still-open hydration request before test teardown.
    await flushHydration();
  });

  it("never lets late hydration downgrade a settled accept", async () => {
    const reviewGate = deferred<Response>();
    const fetchMock = stubRoutedFetch({ review: () => reviewGate.promise });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));
    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);

    // The hydration response lands after the accept won the race and resolves to a different state;
    // first write wins, so the pill must stay Accepted.
    await act(async () => {
      reviewGate.resolve(reviewResponse({ [STAGED_PATH]: "unknown" }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(screen.getByText("Accepted")).toBeInTheDocument();
    expect(screen.queryByText("No longer staged")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByText("Staged (Review Required)")).not.toBeInTheDocument();
  });

  it("shows the server reason with Retry and retries to Accepted", async () => {
    let acceptAttempts = 0;
    const fetchMock = stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
      accept: () => {
        acceptAttempts += 1;
        return acceptAttempts === 1
          ? jsonResponse({ reason: "disk full" }, 500)
          : jsonResponse({ status: "ok", count: 1 });
      },
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    await waitFor(() => {
      expect(screen.getByText("disk full")).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.queryByText("Accepted")).not.toBeInTheDocument();

    // Manual Retry re-invokes the same accept handler and flips the pill.
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(callsTo(fetchMock, ACCEPT_URL)).toHaveLength(2);
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);
    // Drain the still-open hydration request before test teardown.
    await flushHydration();
  });
});

describe("DiffCard discard timeout plus retry", () => {
  it("surfaces a retryable timeout banner when discard hangs", async () => {
    vi.useFakeTimers();
    // Hung discard mirrors the accept hang above: explicit params keep the
    // mock calls tuple typed for future signal assertions, and the hydration
    // request stays pending for the same reason.
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

    expect(screen.getByText(DIFF_CARD_DISCARD_TIMEOUT_MESSAGE)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
    expect(callsTo(fetchMock, DISCARD_URL)).toHaveLength(1);
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);
  });

  it("flips to Discarded immediately on HTTP 200", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));

    await waitFor(() => {
      expect(screen.getByText("Discarded")).toBeInTheDocument();
    });
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
    // Drain the still-open hydration request before test teardown.
    await flushHydration();
  });

  it("shows the server reason with Retry on discard failure", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
      discard: () => jsonResponse({ reason: "locked by greeter" }, 500),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));

    await waitFor(() => {
      expect(screen.getByText("locked by greeter")).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
    expect(screen.queryByText("Discarded")).not.toBeInTheDocument();
    // Drain the still-open hydration request before test teardown.
    await flushHydration();
  });
});

describe("DiffCard live review actions", () => {
  it("shows Accept and Revert for a pending existing-file live card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    await flushHydration();

    expect(screen.getByText("Live Edit")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revert" })).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Discard" }),
    ).not.toBeInTheDocument();
  });

  it("shows Accept and Discard for a pending new-file live card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult()} />);
    await flushHydration();

    expect(screen.getByText("Live Edit")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discard" })).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Revert" }),
    ).not.toBeInTheDocument();
  });

  it("flips an existing-file live card to Accepted on HTTP 200", async () => {
    const fetchMock = stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(screen.getByText("Accepted")).toHaveClass(
      "diff-status-pill",
      "accepted",
    );
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Accept" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Revert" }),
    ).not.toBeInTheDocument();
    expect(callsTo(fetchMock, LIVE_ACCEPT_URL)).toHaveLength(1);
    expect(callsTo(fetchMock, LIVE_DECLINE_URL)).toHaveLength(0);
    // Drain the still-open hydration request before test teardown.
    await flushHydration();
  });

  it("flips an existing-file live card to Reverted on a 200 decline", async () => {
    const fetchMock = stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    fireEvent.click(screen.getByRole("button", { name: "Revert" }));

    await waitFor(() => {
      expect(screen.getByText("Reverted")).toBeInTheDocument();
    });
    expect(screen.getByText("Reverted")).toHaveClass(
      "diff-status-pill",
      "reverted",
    );
    expect(screen.queryByText("Reverting…")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Revert" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Accept" }),
    ).not.toBeInTheDocument();
    expect(callsTo(fetchMock, LIVE_DECLINE_URL)).toHaveLength(1);
    expect(callsTo(fetchMock, LIVE_ACCEPT_URL)).toHaveLength(0);
    await flushHydration();
  });

  it("flips a new-file live card to Discarded on a 200 decline", async () => {
    const fetchMock = stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
      liveDecline: () => jsonResponse({ status: "discarded", count: 1 }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult()} />);
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));

    await waitFor(() => {
      expect(screen.getByText("Discarded")).toBeInTheDocument();
    });
    expect(screen.getByText("Discarded")).toHaveClass(
      "diff-status-pill",
      "discarded",
    );
    expect(screen.queryByText("Discarding…")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Discard" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Revert" }),
    ).not.toBeInTheDocument();
    expect(callsTo(fetchMock, LIVE_DECLINE_URL)).toHaveLength(1);
    await flushHydration();
  });

  it("surfaces a retryable timeout banner when a live accept hangs", async () => {
    vi.useFakeTimers();
    // Hung engine walk: the fetch never settles on its own, so the 10s race
    // must supply the timeout. The mount hydration request hangs the same way.
    const fetchMock = vi.fn(
      (_input: unknown, _init?: unknown) =>
        new Promise<Response>(() => undefined),
    );
    vi.stubGlobal("fetch", fetchMock);
    stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    expect(screen.getByText("Accepting…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accepting…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Revert" })).toBeDisabled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });

    expect(
      screen.getByText(DIFF_CARD_LIVE_ACCEPT_TIMEOUT_MESSAGE),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    // No infinite loading state survives the timeout.
    expect(screen.queryByText("Accepting…")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(callsTo(fetchMock, LIVE_ACCEPT_URL)).toHaveLength(1);
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);
  });

  it("surfaces a retryable timeout banner when a live decline hangs", async () => {
    vi.useFakeTimers();
    // Hung engine walk mirrors the staged hangs above: the fetch never settles
    // on its own, so the 10s race must supply the timeout. The mount hydration
    // request hangs the same way.
    const fetchMock = vi.fn(
      (_input: unknown, _init?: unknown) =>
        new Promise<Response>(() => undefined),
    );
    vi.stubGlobal("fetch", fetchMock);
    stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    fireEvent.click(screen.getByRole("button", { name: "Revert" }));

    expect(screen.getByText("Reverting…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reverting…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Accept" })).toBeDisabled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });

    expect(
      screen.getByText(DIFF_CARD_LIVE_DECLINE_TIMEOUT_MESSAGE),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
    // No infinite loading state survives the timeout.
    expect(screen.queryByText("Reverting…")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revert" })).toBeInTheDocument();
    expect(callsTo(fetchMock, LIVE_DECLINE_URL)).toHaveLength(1);
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);
  });

  it("flips the pill when a matching live_resolved frame arrives", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    const capture = stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "live_resolved",
      path: LIVE_PATH,
      state: "reverted",
    });

    expect(screen.getByText("Reverted")).toBeInTheDocument();
    expect(screen.getByText("Reverted")).toHaveClass(
      "diff-status-pill",
      "reverted",
    );
    expect(
      screen.queryByRole("button", { name: "Revert" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Accept" }),
    ).not.toBeInTheDocument();
    await flushHydration();
  });

  it("keeps the note and hides live buttons on a shadowed card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(
      <DiffCard
        result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)}
        ownsFileReview={false}
      />,
    );
    await flushHydration();

    expect(screen.getByText(DIFF_CARD_OWNED_BY_NEWER_NOTE)).toBeInTheDocument();
    expect(screen.getByText("Live Edit")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Accept" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Revert" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Discard" }),
    ).not.toBeInTheDocument();
  });
});

describe("DiffCard review ledger hydration", () => {
  it("hydrates an accepted staged review into the pill with no controls", async () => {
    stubRoutedFetch({
      // The live map carries a different value so a wrong map selection fails.
      review: () =>
        reviewResponse(
          { [STAGED_PATH]: "accepted" },
          { [STAGED_PATH]: "reverted" },
        ),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    expect(screen.getByText("Accepted")).toHaveClass(
      "diff-status-pill",
      "accepted",
    );
    expect(screen.queryByText("Reverted")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
    expect(
      screen.queryByText(DIFF_CARD_OWNED_BY_NEWER_NOTE),
    ).not.toBeInTheDocument();
  });

  it("reads a missing staged row as no longer staged", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "unknown" }),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    await waitFor(() => {
      expect(screen.getByText("No longer staged")).toBeInTheDocument();
    });
    expect(screen.getByText("No longer staged")).toHaveClass(
      "diff-status-pill",
      "neutral",
    );
    expect(screen.queryByText("Staged (Review Required)")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });

  it("hydrates a reverted live review from the live map only", async () => {
    stubRoutedFetch({
      review: () =>
        reviewResponse(
          { [LIVE_PATH]: "accepted" },
          { [LIVE_PATH]: "reverted" },
        ),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult()} />);
    await waitFor(() => {
      expect(screen.getByText("Reverted")).toBeInTheDocument();
    });
    expect(screen.getByText("Reverted")).toHaveClass(
      "diff-status-pill",
      "reverted",
    );
    expect(screen.queryByText("Live Edit")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });

  it("hydrates a discarded live review into the pill", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "discarded" }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult()} />);
    await waitFor(() => {
      expect(screen.getByText("Discarded")).toBeInTheDocument();
    });
    expect(screen.getByText("Discarded")).toHaveClass(
      "diff-status-pill",
      "discarded",
    );
    expect(screen.queryByText("Live Edit")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
  });

  it("reads a missing live row as no longer pending", async () => {
    stubRoutedFetch({
      review: () =>
        reviewResponse({ [LIVE_PATH]: "reverted" }, { [LIVE_PATH]: "unknown" }),
    });
    stubSharedSocket();

    render(<DiffCard result={liveResult()} />);
    await waitFor(() => {
      expect(screen.getByText("No longer pending")).toBeInTheDocument();
    });
    expect(screen.getByText("No longer pending")).toHaveClass(
      "diff-status-pill",
      "neutral",
    );
    expect(screen.queryByText("No longer staged")).not.toBeInTheDocument();
    expect(screen.queryByText("Live Edit")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
  });

  it("leaves the actionable card intact when hydration fails", async () => {
    const fetchMock = stubRoutedFetch({
      review: () => Promise.reject(new Error("ledger offline")),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    // Drains the rejected hydration round trip so the settled card is asserted.
    await flushHydration();
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);

    // No banner, no state change: the transient status error must not block
    // Accept/Discard or surface an error the owner cannot act on.
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discard" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Retry" })).not.toBeInTheDocument();
    expect(screen.queryByText("ledger offline")).not.toBeInTheDocument();
  });
});

describe("DiffCard newest-write ownership", () => {
  it("shows the newer-write note instead of controls for a shadowed card", async () => {
    const fetchMock = stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} ownsFileReview={false} />);
    await flushHydration();
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(1);

    expect(screen.getByText(DIFF_CARD_OWNED_BY_NEWER_NOTE)).toBeInTheDocument();
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });

  it("keeps controls on the owning staged card and notes the shadowed sibling", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(
      <>
        <div data-testid="older-card">
          <DiffCard result={stagedResult()} ownsFileReview={false} />
        </div>
        <div data-testid="newer-card">
          <DiffCard result={stagedResult()} />
        </div>
      </>,
    );

    const older = screen.getByTestId("older-card");
    const newer = screen.getByTestId("newer-card");
    await flushHydration();
    // Only the newest card keeps the review controls; the shadowed card
    // explains its missing controls instead of racing the newer write's row.
    expect(within(older).getByText(DIFF_CARD_OWNED_BY_NEWER_NOTE)).toBeInTheDocument();
    expect(within(newer).getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(within(newer).getByRole("button", { name: "Discard" })).toBeInTheDocument();
    expect(within(newer).queryByText(DIFF_CARD_OWNED_BY_NEWER_NOTE)).not.toBeInTheDocument();
    expect(within(older).queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(within(older).queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });

  it("shows two live cards for one path with review controls only on the newer one", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    stubSharedSocket();

    // Both cards track the same pending live row: the newer card owns the
    // review and renders its controls, while the shadowed card keeps the note.
    render(
      <>
        <div data-testid="older-card">
          <DiffCard result={liveResult()} ownsFileReview={false} />
        </div>
        <div data-testid="newer-card">
          <DiffCard result={liveResult()} />
        </div>
      </>,
    );

    const older = screen.getByTestId("older-card");
    const newer = screen.getByTestId("newer-card");
    await flushHydration();
    // The newer card owns the row and stays note-free; the older card shows
    // why it has no controls.
    expect(within(older).getByText(DIFF_CARD_OWNED_BY_NEWER_NOTE)).toBeInTheDocument();
    expect(within(newer).queryByText(DIFF_CARD_OWNED_BY_NEWER_NOTE)).not.toBeInTheDocument();
    expect(within(newer).getByText("Live Edit")).toBeInTheDocument();
    expect(within(newer).getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(within(newer).getByRole("button", { name: "Discard" })).toBeInTheDocument();
    expect(within(older).queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(within(older).queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });
});

describe("DiffCard collapse default", () => {
  it("starts collapsed when defaultExpanded is false and toggles the diff body", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} defaultExpanded={false} />);

    // The header keeps name, pill, and review controls; only the diff hides.
    expect(screen.getByText("diff-card-timeout.txt")).toBeInTheDocument();
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discard" })).toBeInTheDocument();
    expect(screen.queryByText(/Unified Diff/)).not.toBeInTheDocument();

    const expandToggle = screen.getByRole("button", {
      name: "Expand file diff",
    });
    expect(expandToggle).toHaveAttribute("aria-expanded", "false");

    fireEvent.click(expandToggle);
    expect(screen.getByText(/Unified Diff/)).toBeInTheDocument();

    fireEvent.click(
      screen.getByRole("button", { name: "Collapse file diff" }),
    );
    expect(screen.queryByText(/Unified Diff/)).not.toBeInTheDocument();
    await flushHydration();
  });

  it("shows the diff immediately when defaultExpanded is true", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} defaultExpanded={true} />);

    expect(screen.getByText(/Unified Diff/)).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Collapse file diff" }),
    ).toHaveAttribute("aria-expanded", "true");
    await flushHydration();
  });

  it("defaults to expanded when the prop is omitted", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    // Run-detail surfaces render without the prop and must stay fully expanded.
    render(<DiffCard result={stagedResult()} />);
    expect(screen.getByText(/Unified Diff/)).toBeInTheDocument();
    await flushHydration();
  });

  it("applies a defaultExpanded change to an already-mounted card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    stubSharedSocket();

    const { rerender } = render(
      <DiffCard result={stagedResult()} defaultExpanded={false} />,
    );
    expect(screen.queryByText(/Unified Diff/)).not.toBeInTheDocument();

    // A chat-settings flip must reach mounted cards, not just new mounts.
    rerender(<DiffCard result={stagedResult()} defaultExpanded={true} />);
    expect(screen.getByText(/Unified Diff/)).toBeInTheDocument();

    rerender(<DiffCard result={stagedResult()} defaultExpanded={false} />);
    expect(screen.queryByText(/Unified Diff/)).not.toBeInTheDocument();
    await flushHydration();
  });
});

describe("write envelope helpers", () => {
  it("classifies reviewable envelopes and keys staged versus live apart", () => {
    const staged = stagedResult();
    const live = liveResult();
    // The canonical parse returns the ledger kind plus the live path together,
    // so kind classification is pinned through the same helper the batched
    // hydration scan consumes.
    expect(writeReviewTarget(staged)).toEqual({ kind: "staged", path: STAGED_PATH });
    expect(writeReviewTarget(live)).toEqual({ kind: "live", path: LIVE_PATH });
    // Dry runs, malformed output, and errors have no ledger row.
    expect(
      writeReviewTarget({
        ...staged,
        content: '{"status":"preview","path":"/tmp/a","diff":""}',
      }),
    ).toBeNull();
    expect(writeReviewTarget({ ...staged, content: "not json" })).toBeNull();
    expect(writeReviewTarget({ ...staged, isError: true })).toBeNull();
    expect(writeReviewTarget(null)).toBeNull();
    // Same path and kind share one key; a live envelope never collides with
    // the staged envelope for the same path.
    expect(writeReviewKey(staged)).toBe(writeReviewKey(stagedResult()));
    expect(writeReviewKey(staged)).not.toBe(writeReviewKey(live));
    expect(writeReviewKey({ ...staged, isError: true })).toBeNull();
  });
});

describe("DiffCard frame-kind gating", () => {
  it("settles a matching staged card on a file_accepted frame", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    const capture = stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await flushHydration();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "file_accepted",
      path: STAGED_PATH,
    });

    expect(screen.getByText("Accepted")).toBeInTheDocument();
    expect(screen.getByText("Accepted")).toHaveClass(
      "diff-status-pill",
      "accepted",
    );
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });

  it("ignores a staged file_accepted frame on a live card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    const capture = stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await flushHydration();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "file_accepted",
      path: LIVE_PATH,
    });

    // The live ledger row is still pending, so the staged broadcast must not
    // flip the pill or hide the still-actionable controls.
    expect(screen.getByText("Live Edit")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revert" })).toBeInTheDocument();
    expect(screen.queryByText("Accepted")).not.toBeInTheDocument();
  });

  it("ignores a staged file_discarded frame on a live card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    const capture = stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await flushHydration();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "file_discarded",
      path: LIVE_PATH,
    });

    expect(screen.getByText("Live Edit")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revert" })).toBeInTheDocument();
    expect(screen.queryByText("Discarded")).not.toBeInTheDocument();
  });

  it("settles a staged card on a matching file_superseded frame", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({ [STAGED_PATH]: "pending" }),
    });
    const capture = stubSharedSocket();

    render(<DiffCard result={stagedResult()} />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await flushHydration();

    // A drifted state can never pin a resolution the pill cannot render.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "file_superseded",
      path: STAGED_PATH,
      state: "pending",
    });
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "file_superseded",
      path: STAGED_PATH,
      state: "superseded",
    });

    // The staged row is terminal server-side, so the mounted card settles
    // immediately with no review actions and no reload.
    expect(screen.getByText("Superseded")).toBeInTheDocument();
    expect(screen.getByText("Superseded")).toHaveClass(
      "diff-status-pill",
      "superseded",
    );
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard" })).not.toBeInTheDocument();
  });

  it("ignores a file_superseded frame on a live card", async () => {
    stubRoutedFetch({
      review: () => reviewResponse({}, { [LIVE_PATH]: "pending" }),
    });
    const capture = stubSharedSocket();

    render(<DiffCard result={liveResult(LIVE_PATH, LIVE_BACKUP_PATH)} />);
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await flushHydration();

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "file_superseded",
      path: LIVE_PATH,
      state: "superseded",
    });

    // The frame concerns the staged review, so the live card keeps its own
    // pending posture and controls.
    expect(screen.getByText("Live Edit")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revert" })).toBeInTheDocument();
    expect(screen.queryByText("Superseded")).not.toBeInTheDocument();
  });
});

describe("DiffCard surface-batched hydration", () => {
  it("adopts a provided batch state without issuing its own request", async () => {
    const fetchMock = stubRoutedFetch();
    stubSharedSocket();

    render(
      <DiffCard
        result={stagedResult()}
        fileReviewStates={{
          stagedStates: { [STAGED_PATH]: "accepted" },
          liveStates: {},
        }}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });
    // The surface's batch owns the read: the card must not add a request.
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(0);
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
  });

  it("keeps the pending UI on a null batch without falling back", async () => {
    const fetchMock = stubRoutedFetch();
    stubSharedSocket();

    render(<DiffCard result={stagedResult()} fileReviewStates={null} />);
    await flushHydration();

    // A null batch means in flight or failed; either way the actionable card
    // survives and no per-card fallback request races the surface's batch.
    expect(screen.getByText("Staged (Review Required)")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Accept" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discard" })).toBeInTheDocument();
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(0);
  });

  it("never lets a late batch downgrade a settled action", async () => {
    const fetchMock = stubRoutedFetch();
    stubSharedSocket();

    const { rerender } = render(
      <DiffCard result={stagedResult()} fileReviewStates={null} />,
    );
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));
    await waitFor(() => {
      expect(screen.getByText("Accepted")).toBeInTheDocument();
    });

    // The batch settles after the click with a different stored state; the
    // action's resolution wins and the pill must not flip back.
    rerender(
      <DiffCard
        result={stagedResult()}
        fileReviewStates={{
          stagedStates: { [STAGED_PATH]: "discarded" },
          liveStates: {},
        }}
      />,
    );
    expect(screen.getByText("Accepted")).toBeInTheDocument();
    expect(screen.queryByText("Discarded")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();
    expect(callsTo(fetchMock, REVIEW_STATUS_URL)).toHaveLength(0);
    expect(callsTo(fetchMock, ACCEPT_URL)).toHaveLength(1);
  });
});

// The shadowed-card flag is computed by list owners (chat transcript and run detail) from render
// order.
describe("newest-write ownership keys", () => {
  it("resolves one owner per path and envelope kind", () => {
    const actions: ToolAction[] = [
      {
        toolName: "files.write",
        callID: "older",
        argumentsJSON: "{}",
        result: liveResult(),
      },
      {
        toolName: "files.write",
        callID: "newer",
        argumentsJSON: "{}",
        result: liveResult(),
      },
    ];
    const owners = collectWriteReviewOwners(actions);
    expect(owners.size).toBe(1);
    expect(owners.get(writeReviewKey(liveResult()) ?? "")?.callID).toBe("newer");
  });
});
