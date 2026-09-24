// Rune Weaver Dashboard — Component tests for the IndexingPanel status
// dashboard (layout, charts, no-refresh updates, destructive modals) and the
// IndexPolicyPanel form.

import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import IndexingPanel, {
  INDEX_EFFORT_OPTIONS,
  INDEX_LAST_ERRORS_COLLAPSED_COUNT,
  INDEX_LAST_ERROR_PREVIEW_CHARS,
  IndexPolicyPanel,
  dedupeIndexErrors,
  describeAutoStartNotice,
  describeEffortReality,
  describeIndexScope,
  formatIndexAge,
  formatIndexAsOf,
  formatIndexBytes,
  formatIndexLiveHeader,
  formatIndexRate,
  formatIndexReclaimResult,
  formatIndexScopeRoots,
  indexDonutArcs,
  indexSourceBarPercent,
  indexSourceBarWidth,
  isIndexProgressFrame,
  isLongIndexError,
  normalizeIndexEffortPreset,
  resolveAlwaysSkipped,
  resolveDisplayIndexErrors,
  resolveEffortWorkers,
  resolveIndexLastRunText,
  resolveIndexLiveStageTitle,
  resolveIndexLiveTitle,
  resolveIndexOnDiskBytes,
  resolveIndexSourceContent,
  resolveIndexStorageBreakdown,
  resolveIndexVectorCapValue,
  resolveIndexWorkersValue,
  resolveStatusEffort,
  truncateIndexError,
} from "./IndexingPanel";
import {
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_EXCLUDE_PATTERNS,
  DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
  DEFAULT_INDEX_WORKERS,
  describeIndexRun,
  indexRunLabelForRun,
  indexRunTriggerLabel,
  parseIndexRunTrigger,
  resolveIndexRetiredCount,
} from "../api";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";
import sharedStyles from "../styles.css?raw";

// Plain stylesheet imports resolve to empty under the test transform, so the
// raw text import keeps the regression pinned to the single stylesheet owner
// while staying inside the bundler module graph with no runtime file access.

// Complete [index] section as the engine returns it under GET /settings.
const indexConfig = {
  enabled: false,
  files: true,
  mail: false,
  messages: false,
  roots: ["~"],
  exclude: [".git", "node_modules"],
  max_file_mb: 20,
  mail_vector_window: "2y",
  icloud_evicted: "skip",
  describe_images_with_llm: false,
  nightly_budget: 0,
  db_path: "~/.runeweaver/index.db",
};

const statusPayload = {
  enabled: false,
  running: false,
  documents: 42,
  chunks: 100,
  vectorChunks: 80,
  keywordChunks: 20,
  bytes: 2048,
  indexAsOf: null,
  sources: [
    { kind: "files", enabled: false },
    { kind: "mail", enabled: false },
    { kind: "messages", enabled: false },
  ],
  lastErrors: [],
  bySource: [
    { kind: "files", documents: 30, chunks: 70, bytes: 1500 },
    { kind: "mail", documents: 12, chunks: 30, bytes: 548 },
  ],
  byExtractStatus: [
    { status: "extracted", documents: 30 },
    { status: "partial", documents: 12 },
  ],
  lastRun: {
    status: "ok",
    indexed: 3,
    scanned: 5,
    errors: 0,
    finishedAt: 1,
  },
};

// Structural order check: true when b renders after a in document order, so
// the dashboard's run-cards-charts stacking stays pinned by the tests.
function appearsBefore(a: Element, b: Element): boolean {
  return (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
}

function stubFetch(
  overrides: {
    status?: unknown;
    settings?: unknown;
    reclaim?: unknown;
    capture?: (url: string) => Response | null;
  } = {},
) {
  const calls: Array<{ url: string; method: string; body: unknown }> = [];
  const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    let body: unknown = undefined;
    if (typeof init?.body === "string") {
      try {
        body = JSON.parse(init.body) as unknown;
      } catch {
        body = init.body;
      }
    }
    calls.push({ url, method, body });

    if (overrides.capture) {
      const response = overrides.capture(url);
      if (response) return response;
    }
    if (url === "/index/status") {
      return jsonResponse(overrides.status ?? statusPayload);
    }
    if (url === "/index/run") {
      return jsonResponse({
        sessionID: "s1",
        trigger: "onDemand",
        status: "ok",
        documentsIndexed: 3,
        vectorChunks: 2,
        keywordChunks: 1,
        scanned: 5,
        skipped: 0,
        errors: 0,
        warnings: [],
        startedAt: 0,
        finishedAt: 1,
        indexAsOf: 1,
        skippedReason: null,
      });
    }
    if (url === "/index/cancel") {
      return jsonResponse({ cancelled: true });
    }
    if (url === "/index/prune") {
      return jsonResponse({ removed: 7, before: 1 });
    }
    if (url === "/index/reset") {
      return jsonResponse({ reset: true });
    }
    if (url === "/index/reclaim") {
      return jsonResponse(
        overrides.reclaim ?? { beforeBytes: 2048, afterBytes: 1024, reclaimedBytes: 1024 },
      );
    }
    // GET /settings and PUT /settings share the full settings shape.
    return jsonResponse({
      engineName: "Test Engine",
      index: overrides.settings ?? indexConfig,
    });
  });
  return { fetchMock, calls };
}

describe("IndexingPanel helpers", () => {
  it("formats byte sizes with bounded precision", () => {
    expect(formatIndexBytes(0)).toBe("0 B");
    expect(formatIndexBytes(512)).toBe("512 B");
    expect(formatIndexBytes(2048)).toBe("2 KB");
    expect(formatIndexBytes(1536 * 1024)).toBe("1.5 MB");
  });

  it("normalizes the last watermark and never renders an epoch for null", () => {
    expect(formatIndexAsOf(null)).toBe("Never indexed");
    expect(formatIndexAsOf(0)).toBe("Never indexed");
    expect(formatIndexAsOf(new Date(0).toISOString())).toBe("Never indexed");
  });

  it("describes the watermark age honestly for a fresh or just-built store", () => {
    expect(formatIndexAge(null)).toBe("Never indexed");
    expect(formatIndexAge(0)).toBe("Never indexed");
    // Seconds-since-epoch now is always sub-second old, so the relative ladder
    // collapses to "just now" instead of a misleading "0s ago".
    expect(formatIndexAge(Math.floor(Date.now() / 1000))).toBe("just now");
  });

  it("maps the vector/keyword split onto donut arc lengths", () => {
    const arcs = indexDonutArcs(80, 20, 40);
    expect(arcs.vectorDash).toBeCloseTo(0.8 * arcs.circumference, 5);
    expect(arcs.keywordDash).toBeCloseTo(0.2 * arcs.circumference, 5);
    // An empty store collapses both arcs so the neutral track renders.
    const empty = indexDonutArcs(0, 0, 40);
    expect(empty.vectorDash).toBe(0);
    expect(empty.keywordDash).toBe(0);
  });

  it("maps phase and stage to stage-aware header copy", () => {
    expect(resolveIndexLiveTitle("extracting", "files")).toBe("Reading files…");
    expect(resolveIndexLiveTitle("embedding", null)).toBe("Vectorizing…");
    expect(resolveIndexLiveTitle("embedding", "vision")).toBe("Describing images…");
    expect(resolveIndexLiveTitle("extracting", "vision")).toBe("Describing images…");
    expect(resolveIndexLiveTitle("discovering", null)).toBe("Discovering…");
    expect(resolveIndexLiveTitle("committing", null)).toBe("Committing…");
    expect(resolveIndexLiveTitle(null, null)).toBe("Running…");
  });

  it("adopts index frames by tool name only", () => {
    expect(isIndexProgressFrame({ toolName: "index" }, false)).toBe(false);
    expect(isIndexProgressFrame({ toolName: "index" }, true)).toBe(true);
    expect(isIndexProgressFrame({ toolName: "email.search" }, true)).toBe(false);
    expect(isIndexProgressFrame({ toolName: "" }, true)).toBe(false);
    expect(isIndexProgressFrame({ toolName: "" }, false)).toBe(false);
  });

  it("scales source bars by document share instead of binary on/off", () => {
    expect(indexSourceBarWidth(30, 30)).toBe("100%");
    expect(indexSourceBarWidth(15, 30)).toBe("50%");
    expect(indexSourceBarWidth(0, 30)).toBe("0%");
    expect(indexSourceBarWidth(5, 0)).toBe("0%");
    // Tiny buckets stay visible on the track but label honestly: a 1/100
    // share paints at the 4% floor while the label reads the true 1%.
    expect(indexSourceBarWidth(1, 100)).toBe("4%");
    expect(indexSourceBarPercent(1, 100)).toBe("1%");
    expect(indexSourceBarPercent(30, 30)).toBe("100%");
    expect(indexSourceBarPercent(15, 30)).toBe("50%");
  });

  it("resolves canonical source rows with real totals", () => {
    const rows = resolveIndexSourceContent({
      sources: [
        { kind: "files", enabled: true },
        { kind: "mail", enabled: false },
        { kind: "messages", enabled: false },
      ],
      bySource: [{ kind: "files", documents: 30, chunks: 70, bytes: 1500 }],
    });
    expect(rows.map((row) => row.kind)).toEqual(["files", "mail", "messages"]);
    expect(rows[0]).toMatchObject({ documents: 30, chunks: 70, bytes: 1500 });
    // A source missing from the aggregates degrades to zero instead of
    // disappearing, so older engines still render all three rows.
    expect(rows[1]).toMatchObject({ documents: 0, chunks: 0, bytes: 0 });
  });

  it("summarizes the last run strip with counts and finish time", () => {
    expect(describeIndexRun(null)).toBe("No runs yet");
    expect(describeIndexRun(null)).toBe("No runs yet");
    expect(
      describeIndexRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1 }),
    ).toContain("Last run ok");
    expect(
      describeIndexRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1 }),
    ).toContain("3 indexed");
  });

  it("shares one run formatter across the notice and the strip", () => {
    // The top notice and the last-run strip render one identical line per
    // status, so a completed run can never read differently in the two places.
    const finishedAt = Math.floor(Date.now() / 1000);
    for (const status of ["ok", "cancelled", "skipped", "error"]) {
      const summary = {
        sessionID: "s1",
        trigger: "onDemand",
        status,
        documentsIndexed: 675,
        vectorChunks: 600,
        keywordChunks: 75,
        scanned: 7028,
        skipped: 0,
        errors: status === "error" ? 2 : 0,
        warnings: [],
        startedAt: 0,
        finishedAt,
        indexAsOf: finishedAt,
        skippedReason: null,
      };
      const lastRun = {
        status,
        indexed: 675,
        scanned: 7028,
        errors: status === "error" ? 2 : 0,
        finishedAt,
        trigger: "onDemand",
      };
      const notice = describeIndexRun(summary);
      const strip = describeIndexRun(lastRun);
      // Identical wording: same status prefix, trigger label, and counts.
      expect(notice).toBe(strip);
      expect(notice).toContain(`Last run ${status}`);
      expect(notice).toContain("Manual Run");
      expect(notice).toContain("675 indexed");
      expect(notice).toContain("7028 scanned");
      if (status === "cancelled") {
        expect(notice).toMatch(/committed work is kept/i);
      } else {
        expect(notice).not.toMatch(/committed work is kept/i);
      }
    }
  });

  it("keeps the kept-work copy on cancelled runs only", () => {
    const finishedAt = Math.floor(Date.now() / 1000);
    expect(
      describeIndexRun({ status: "cancelled", indexed: 1, scanned: 2, errors: 0, finishedAt, trigger: "onDemand" }),
    ).toMatch(/committed work is kept/i);
    expect(
      describeIndexRun({ status: "ok", indexed: 1, scanned: 2, errors: 0, finishedAt, trigger: "onDemand" }),
    ).not.toMatch(/committed work is kept/i);
    expect(
      describeIndexRun({ status: "skipped", indexed: 0, scanned: 2, errors: 0, finishedAt, trigger: "onDemand" }),
    ).not.toMatch(/committed work is kept/i);
    expect(
      describeIndexRun({ status: "error", indexed: 1, scanned: 2, errors: 1, finishedAt, trigger: "onDemand" }),
    ).not.toMatch(/committed work is kept/i);
  });

  it("resolves the strip copy without contradiction", () => {
    // No run ever recorded and idle reads as an honest empty state.
    expect(resolveIndexLastRunText(null, false)).toBe("No runs yet");
    // No run recorded but a first pass in flight names itself.
    expect(resolveIndexLastRunText(null, true)).toBe("First run in progress…");
    // Any recorded run always renders its entry, whether idle or active, so
    // a completed or cancelled run can never vanish behind an empty copy.
    const finishedAt = Math.floor(Date.now() / 1000);
    for (const status of ["ok", "cancelled", "skipped", "error"]) {
      const entry = { status, indexed: 1, scanned: 2, errors: 0, finishedAt, trigger: "onDemand" };
      expect(resolveIndexLastRunText(entry, false)).toContain(`Last run ${status}`);
      expect(resolveIndexLastRunText(entry, true)).toContain(`Last run ${status}`);
      expect(resolveIndexLastRunText(entry, false)).not.toBe("No runs yet");
      expect(resolveIndexLastRunText(entry, true)).not.toBe("No runs yet");
      expect(resolveIndexLastRunText(entry, false)).not.toBe("First run in progress…");
    }
  });

  it("formats the engine rate honestly, omitting it without work", () => {
    expect(formatIndexRate(5)).toBe("5 docs/s");
    expect(formatIndexRate(3.3)).toBe("3.3 docs/s");
    expect(formatIndexRate(41)).toBe("41 docs/s");
    expect(formatIndexRate(0)).toBeNull();
    expect(formatIndexRate(null)).toBeNull();
    expect(formatIndexRate(undefined)).toBeNull();
    // Non-finite and absurd wire values degrade to absent instead of
    // rendering a jittering or impossible figure.
    expect(formatIndexRate(Number.POSITIVE_INFINITY)).toBeNull();
    expect(formatIndexRate(Number.NaN)).toBeNull();
    expect(formatIndexRate(2000000)).toBeNull();
    // Early-run spikes read as absent until the honest elapsed floor, while a
    // settled window keeps the same rate.
    expect(formatIndexRate(100, 10)).toBeNull();
    expect(formatIndexRate(100, 499)).toBeNull();
    expect(formatIndexRate(41, 1500)).toBe("41 docs/s");
  });

  it("maps run triggers to display labels across notices, strip, and history rows", () => {
    // Display-label map stays pinned so run notices, the last-run strip,
    // and run-history rows agree on one copy.
    expect(indexRunTriggerLabel("nightly")).toBe("Nightly Run");
    expect(indexRunTriggerLabel("onDemand")).toBe("Manual Run");
    expect(indexRunTriggerLabel("catchUp")).toBe("Catch-Up Run");
    // Run notices name the trigger explicitly while keeping the
    // machine-readable summary wording verbatim.
    const baseSummary = {
      sessionID: "s1",
      status: "ok",
      documentsIndexed: 3,
      vectorChunks: 2,
      keywordChunks: 1,
      scanned: 5,
      skipped: 0,
      errors: 0,
      warnings: [],
      startedAt: 0,
      finishedAt: 1,
      indexAsOf: 1,
      skippedReason: null,
    };
    expect(describeIndexRun({ ...baseSummary, trigger: "nightly" })).toContain("Nightly Run");
    expect(describeIndexRun({ ...baseSummary, trigger: "nightly" })).toContain("Last run ok");
    expect(describeIndexRun({ ...baseSummary, trigger: "onDemand" })).toContain("Manual Run");
    expect(describeIndexRun({ ...baseSummary, trigger: "catchUp" })).toContain("Catch-Up Run");
    // Last-run strip carries the trigger label without dropping the status prefix.
    expect(
      describeIndexRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1, trigger: "catchUp" }),
    ).toContain("Catch-Up Run");
    expect(
      describeIndexRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1, trigger: "catchUp" }),
    ).toContain("Last run ok");
    // Run-history rows parse the durable trigger token from either the
    // start message or the completion detail line.
    expect(parseIndexRunTrigger({ message: "Index run started (catchUp)", response: null })).toBe("catchUp");
    expect(
      parseIndexRunTrigger({ message: "Index run ok: 3 indexed", response: "Index run ok: 3 indexed\nTrigger: catchUp" }),
    ).toBe("catchUp");
    expect(
      indexRunLabelForRun({ message: "Index run started (nightly)", response: null }),
    ).toBe("Nightly Run");
    // Auto-start notice on launch-triggered runs names the catch-up explicitly.
    expect(describeAutoStartNotice({ message: "Index run started (catchUp)" })).toContain("Catch-Up Run");
  });
});

describe("IndexingPanel", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("renders stat cards with counts, size, watermark age, and state", async () => {
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("42")).toBeInTheDocument();
    });
    expect(screen.getByText("100")).toBeInTheDocument();
    expect(screen.getByText("2 KB")).toBeInTheDocument();
    expect(screen.getByText("80 vector · 20 keyword")).toBeInTheDocument();
    // The watermark card carries the relative age prominently plus the
    // absolute date below, so the honest never-indexed label appears twice.
    expect(screen.getAllByText("Never indexed").length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText("Disabled")).toBeInTheDocument();
    // The last-run strip distills the newest run log row above the cards.
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("Last run ok");
  });

  it("keeps run controls above the stat cards and the charts", async () => {
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("42")).toBeInTheDocument();
    });
    // Layout order: Run controls top, stat cards middle, charts bottom.
    expect(
      appearsBefore(
        screen.getByRole("heading", { name: "Run" }),
        screen.getByRole("heading", { name: "Status" }),
      ),
    ).toBe(true);
    expect(
      appearsBefore(
        screen.getByRole("button", { name: "Rebuild / Run Now" }),
        screen.getByText("Documents"),
      ),
    ).toBe(true);
    expect(
      appearsBefore(
        screen.getByText("Documents"),
        screen.getByRole("heading", { name: "Charts" }),
      ),
    ).toBe(true);
  });

  it("exposes only the status surface — no policy fields or Save button", async () => {
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("42")).toBeInTheDocument();
    });
    expect(screen.queryByLabelText("Enable background indexing")).toBeNull();
    expect(screen.queryByLabelText(/Exclude patterns/)).toBeNull();
    expect(
      screen.queryByRole("button", { name: "Save Index Settings" }),
    ).toBeNull();
  });

  it("updates status automatically with no manual Refresh button", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("42")).toBeInTheDocument();
    });
    expect(
      screen.queryByRole("button", { name: /refresh/i }),
    ).toBeNull();

    // Freshness comes from the socket: a terminal run broadcast re-reads the
    // status route without any user control.
    const statusCallsBefore = fetchMock.mock.calls.filter(
      ([url]) => String(url) === "/index/status",
    ).length;
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: { kind: "index", status: "ok" },
    });
    await waitFor(() => {
      const statusCalls = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/index/status",
      ).length;
      expect(statusCalls).toBeGreaterThan(statusCallsBefore);
    });
  });

  it("shows the last index errors when the engine reports failures", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, lastErrors: ["mail: IMAP unreachable"] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText(/Last errors/)).toBeInTheDocument();
    });
    expect(screen.getByText("mail: IMAP unreachable")).toBeInTheDocument();
  });

  it("renders real-count source bars, the extract breakdown, and the last-run strip", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        sources: [
          { kind: "files", enabled: true },
          { kind: "mail", enabled: false },
          { kind: "messages", enabled: false },
        ],
        bySource: [
          { kind: "files", documents: 30, chunks: 70, bytes: 1500 },
          { kind: "mail", documents: 15, chunks: 30, bytes: 548 },
        ],
        byExtractStatus: [
          { status: "extracted", documents: 30 },
          { status: "partial", documents: 15 },
        ],
        lastRun: { status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1 },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-donut-chart")).toBeInTheDocument();
    });
    // The donut aria-label carries the vector/keyword split from status.
    expect(screen.getByTestId("index-donut-chart")).toHaveAttribute(
      "aria-label",
      "80 vector chunks, 20 keyword chunks",
    );
    // Bars scale by real document share: the largest source fills the track
    // while the half-size source renders at half width — never binary on/off.
    expect(screen.getByTestId("index-bar-files")).toHaveStyle({ width: "100%" });
    expect(screen.getByTestId("index-bar-mail")).toHaveStyle({ width: "50%" });
    expect(screen.getByTestId("index-bar-mail")).not.toHaveStyle({ width: "0%" });
    // Each row names its real totals instead of an On/Off token.
    expect(screen.getByText("30 docs · 70 chunks · 1.5 KB")).toBeInTheDocument();
    // Pills mirror the same enablement state the bars no longer encode.
    expect(screen.getByText("Files · On")).toBeInTheDocument();
    expect(screen.getByText("Mail · Off")).toBeInTheDocument();
    // The extraction-outcome breakdown renders one scaled bar per status.
    expect(screen.getByTestId("index-extract-bar-extracted")).toHaveStyle({
      width: "100%",
    });
    expect(screen.getByTestId("index-extract-bar-partial")).toHaveStyle({
      width: "50%",
    });
    // The last-run strip distills status, counts, and finish time.
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("Last run ok");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("3 indexed");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("5 scanned");
    // The watermark card keeps the absolute date alongside the prominent age.
    expect(screen.getByTestId("index-watermark-card")).toBeInTheDocument();
  });

  it("titles both bar groups with their share-of-largest contract", async () => {
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-donut-chart")).toBeInTheDocument();
    });
    // Headings name the scaling so a half-width bar reads as half of the
    // largest bucket rather than half of the total.
    expect(
      screen.getByText("Documents by source — share of largest"),
    ).toBeInTheDocument();
    expect(
      screen.getByText("Extraction outcomes — share of largest"),
    ).toBeInTheDocument();
  });

  it("labels every bar with its share-of-largest percent", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        bySource: [
          { kind: "files", documents: 30, chunks: 70, bytes: 1500 },
          { kind: "mail", documents: 15, chunks: 30, bytes: 548 },
        ],
        byExtractStatus: [
          { status: "extracted", documents: 30 },
          { status: "partial", documents: 15 },
        ],
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-bar-files")).toBeInTheDocument();
    });
    // Percent labels reuse the track scale so the copy and the paint agree.
    expect(screen.getByTestId("index-bar-pct-files")).toHaveTextContent("100%");
    expect(screen.getByTestId("index-bar-pct-mail")).toHaveTextContent("50%");
    expect(screen.getByTestId("index-extract-pct-extracted")).toHaveTextContent(
      "100%",
    );
    expect(screen.getByTestId("index-extract-pct-partial")).toHaveTextContent(
      "50%",
    );
  });

  it("renders No data yet instead of an empty track for zero-document rows", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        bySource: [
          { kind: "files", documents: 20, chunks: 40, bytes: 1000 },
          { kind: "mail", documents: 0, chunks: 0, bytes: 0 },
        ],
        byExtractStatus: [
          { status: "extracted", documents: 10 },
          { status: "failed", documents: 0 },
        ],
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-source-bars")).toBeInTheDocument();
    });
    // A zero-document source skips its track so the row never renders as a
    // hairline bar, while the populated source keeps its bar and percent.
    expect(screen.getByTestId("index-bar-empty-mail")).toHaveTextContent(
      "No data yet",
    );
    expect(screen.queryByTestId("index-bar-mail")).toBeNull();
    expect(screen.queryByTestId("index-bar-pct-mail")).toBeNull();
    expect(screen.getByTestId("index-bar-files")).toBeInTheDocument();
    expect(screen.getByTestId("index-bar-pct-files")).toHaveTextContent("100%");
    // The same contract holds for extraction outcomes: the zero bucket names
    // its gap while the largest bucket keeps its bar and percent.
    expect(screen.getByTestId("index-extract-empty-failed")).toHaveTextContent(
      "No data yet",
    );
    expect(screen.queryByTestId("index-extract-bar-failed")).toBeNull();
    expect(screen.queryByTestId("index-extract-pct-failed")).toBeNull();
    expect(screen.getByTestId("index-extract-bar-extracted")).toBeInTheDocument();
    expect(screen.getByTestId("index-extract-pct-extracted")).toHaveTextContent(
      "100%",
    );
    // Enablement pills stay as the on/off signal while bars carry content.
    expect(screen.getByText("Files · Off")).toBeInTheDocument();
  });

  it("renders No data yet for an empty extraction breakdown", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, byExtractStatus: [] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-extract-bars")).toBeInTheDocument();
    });
    // With no outcome rows the group names the gap instead of an empty card.
    expect(screen.getByTestId("index-extract-empty")).toHaveTextContent(
      "No data yet",
    );
  });

  it("saves the index policy through a PUT /settings index patch", async () => {
    const user = userEvent.setup();
    const { fetchMock, calls } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Exclude patterns/)).toBeInTheDocument();
    });

    // The policy form owns no status surface: run controls live on the Memory
    // tab instead of being duplicated here.
    expect(
      screen.queryByRole("button", { name: "Rebuild / Run Now" }),
    ).toBeNull();

    // Master enable unlocks the source toggles; enabling Mail then saving must
    // persist a partial [index] patch carrying the toggle.
    // The save control matches every other Settings tab: a shared
    // settings-footer wrapping a primary-button save-button.
    const saveButton = screen.getByRole("button", {
      name: "Save Index Settings",
    });
    expect(saveButton).toHaveClass("primary-button");
    expect(saveButton).toHaveClass("save-button");
    expect(saveButton.closest(".settings-footer")).not.toBeNull();
    await user.click(screen.getByLabelText("Enable background indexing"));
    await user.click(screen.getByLabelText("Index Mail"));
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Index settings saved.")).toBeInTheDocument();
    });

    const put = calls.find((call) => call.url === "/settings" && call.method === "PUT");
    expect(put).toBeDefined();
    expect(Object.keys((put?.body as Record<string, unknown>) ?? {})).toEqual([
      "index",
    ]);
    const patch = (put?.body as { index?: Record<string, unknown> })?.index;
    expect(patch?.enabled).toBe(true);
    expect(patch?.mail).toBe(true);
    expect(patch?.exclude).toEqual([".git", "node_modules"]);
    expect(patch?.mail_vector_window).toBe("2y");
    // Presets derive workers on the engine so they must save 0; only custom
    // carries an explicit count, otherwise the engine rejects with 400.
    expect(patch?.effort).toBe("balanced");
    expect(patch?.workers).toBe(0);
    // The capped vector path stays configurable: the save carries the
    // per-document cap (fixture omits it so it degrades to the engine
    // default) alongside the [index]-only patch.
    expect(patch?.max_vector_chunks_per_document).toBe(
      DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
    );
  });

  it("restarts the running scan on policy save", async () => {
    // A policy saved mid-scan stops the old generation and starts a fresh run
    // so the new roots/excludes/caps apply without waiting for the next
    // nightly pass.
    const user = userEvent.setup();
    let running = true;
    const calls: Array<{ url: string; method: string; body: unknown }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      let body: unknown = undefined;
      if (typeof init?.body === "string") {
        try {
          body = JSON.parse(init.body) as unknown;
        } catch {
          body = init.body;
        }
      }
      calls.push({ url, method, body });
      if (url === "/index/status") {
        return jsonResponse({ ...statusPayload, enabled: true, running, live: null });
      }
      if (url === "/index/cancel") {
        running = false;
        return jsonResponse({ cancelled: true });
      }
      if (url === "/index/run") {
        return jsonResponse({
          sessionID: "s1",
          trigger: "onDemand",
          status: "ok",
          documentsIndexed: 3,
          vectorChunks: 2,
          keywordChunks: 1,
          scanned: 5,
          skipped: 0,
          errors: 0,
          warnings: [],
          startedAt: 0,
          finishedAt: 1,
          indexAsOf: 1,
          skippedReason: null,
        });
      }
      return jsonResponse({
        engineName: "Test Engine",
        index: { ...indexConfig, enabled: true },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Exclude patterns/)).toBeInTheDocument();
    });
    // The boot status read settles the in-flight flag before Save, so the
    // restart decision observes the running scan instead of the initial null.
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) => String(url) === "/index/status").length,
      ).toBeGreaterThanOrEqual(1);
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });

    await user.click(screen.getByRole("button", { name: "Save Index Settings" }));

    await waitFor(() => {
      expect(
        screen.getByText(
          "Index settings saved. Restarted the running scan so new settings apply.",
        ),
      ).toBeInTheDocument();
    });
    // The fresh run outcome shares the strip formatter.
    expect(screen.getByText(/Last run ok/)).toBeInTheDocument();
    const cancelAt = calls.findIndex((call) => call.url === "/index/cancel");
    const runAt = calls.findIndex((call) => call.url === "/index/run");
    expect(cancelAt).toBeGreaterThan(-1);
    expect(runAt).toBeGreaterThan(cancelAt);
    // The policy persists before any restart step.
    const putAt = calls.findIndex(
      (call) => call.url === "/settings" && call.method === "PUT",
    );
    expect(putAt).toBeGreaterThan(-1);
    expect(putAt).toBeLessThan(cancelAt);
  });

  it("saves without restarting when idle", async () => {
    // An idle save keeps the save-only path: no stop, no fresh run, just the
    // plain confirmation.
    const user = userEvent.setup();
    const { fetchMock, calls } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: false },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Exclude patterns/)).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) => String(url) === "/index/status").length,
      ).toBeGreaterThanOrEqual(1);
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });

    await user.click(screen.getByRole("button", { name: "Save Index Settings" }));

    await waitFor(() => {
      expect(screen.getByText("Index settings saved.")).toBeInTheDocument();
    });
    expect(
      screen.queryByText(
        "Index settings saved. Restarted the running scan so new settings apply.",
      ),
    ).toBeNull();
    expect(calls.some((call) => call.url === "/index/cancel")).toBe(false);
    expect(calls.some((call) => call.url === "/index/run")).toBe(false);
  });

  it("keeps the shared Save fill in the stylesheet", () => {
    // The Save control owns no local color: both Settings footers share one
    // stylesheet fill so an enabled Save stays solid theme blue even as forms
    // evolve, with hover brightening and disabled dimming pinned alongside.
    expect(sharedStyles).toMatch(
      /\.primary-button\s*\{[^}]*background:\s*var\(--accent-blue\)/,
    );
    expect(sharedStyles).toMatch(/\.primary-button\s*\{[^}]*color:\s*white/);
    expect(sharedStyles).toMatch(
      /\.primary-button:hover:not\(:disabled\)[^{]*\{[^}]*brightness/,
    );
    expect(sharedStyles).toMatch(
      /\.primary-button:disabled[^{]*\{[^}]*opacity/,
    );
  });

  it("sends the custom worker count only for the custom preset", async () => {
    const user = userEvent.setup();
    const { fetchMock, calls } = stubFetch({
      settings: { ...indexConfig, effort: "custom", workers: 6 },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText("Custom workers")).toBeInTheDocument();
    });
    expect(screen.getByLabelText("Custom workers")).toHaveValue(6);

    await user.click(
      screen.getByRole("button", { name: "Save Index Settings" }),
    );

    await waitFor(() => {
      expect(screen.getByText("Index settings saved.")).toBeInTheDocument();
    });

    const put = calls.find((call) => call.url === "/settings" && call.method === "PUT");
    expect(put).toBeDefined();
    const patch = (put?.body as { index?: Record<string, unknown> })?.index;
    expect(patch?.effort).toBe("custom");
    expect(patch?.workers).toBe(6);
  });

  it("mirrors the engine index defaults for a fresh form", () => {
    // The wire default derives workers from the preset (0), while the
    // stepper fallback for a custom preset with no stored value stays
    // DEFAULT_INDEX_WORKERS so it still opens on a valid count.
    expect(DEFAULT_INDEX_CONFIG.workers).toBe(0);
    expect(DEFAULT_INDEX_CONFIG.effort).toBe("balanced");
    expect(DEFAULT_INDEX_WORKERS).toBe(4);
    // The exclude list is single-sourced from the engine
    // IndexConfig.defaultExcludePatterns so the fresh form cannot drift.
    expect(DEFAULT_INDEX_CONFIG.exclude).toEqual(DEFAULT_INDEX_EXCLUDE_PATTERNS);
    for (const pattern of [
      ".build",
      "*.app",
      "*.log",
      "*.tmp",
      ".DS_Store",
      "gopath",
      "nltk_data",
    ]) {
      expect(DEFAULT_INDEX_CONFIG.exclude).toContain(pattern);
    }
  });

  it("prefers the engine core count for the policy reality line", async () => {
    // A remote dashboard (phone browser vs Mac engine) must resolve the
    // preset against the engine activeProcessors, not the browser
    // hardwareConcurrency.
    const hardwareConcurrency = Object.getOwnPropertyDescriptor(
      window.navigator,
      "hardwareConcurrency",
    );
    Object.defineProperty(window.navigator, "hardwareConcurrency", {
      value: 2,
      configurable: true,
    });
    try {
      const { fetchMock } = stubFetch({
        settings: { ...indexConfig, effort: "balanced" },
        status: {
          ...statusPayload,
          effort: {
            preset: "balanced",
            resolvedWorkers: 4,
            activeProcessors: 10,
          },
        },
      });
      vi.stubGlobal("fetch", fetchMock);

      render(<IndexPolicyPanel />);

      await waitFor(() => {
        expect(screen.getByTestId("index-effort-reality")).toBeInTheDocument();
      });
      expect(screen.getByTestId("index-effort-reality")).toHaveTextContent(
        "Balanced - using 4 of 10 cores",
      );
    } finally {
      if (hardwareConcurrency) {
        Object.defineProperty(
          window.navigator,
          "hardwareConcurrency",
          hardwareConcurrency,
        );
      }
    }
  });

  it("runs an on-demand pass and reports the terminal summary", async () => {
    const user = userEvent.setup();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("Enabled")).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Rebuild / Run Now" }));

    // The top notice shares the strip formatter, so it reads as the same
    // one-line outcome the strip renders. Both surfaces carry the status, so
    // the assertions scope to all matches instead of a single element.
    await waitFor(() => {
      expect(screen.getAllByText(/Last run ok/).length).toBeGreaterThanOrEqual(1);
    });
    expect(screen.getAllByText(/3 indexed/).length).toBeGreaterThanOrEqual(1);
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("Last run ok");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("3 indexed");
  });

  it("shows a muted hint under Run when indexing is disabled", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, enabled: false },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("Disabled")).toBeInTheDocument();
    });
    // Run stays disabled while prune/reset stay independent of the flag.
    expect(screen.getByRole("button", { name: "Rebuild / Run Now" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Prune" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Reset Index" })).toBeEnabled();
    expect(
      screen.getByText(
        "Indexing is off — turn it on in Settings → Indexing to run a pass.",
      ),
    ).toBeInTheDocument();
  });

  it("hides the disabled hint when indexing is enabled", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, enabled: true },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("Enabled")).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: "Rebuild / Run Now" })).toBeEnabled();
    expect(
      screen.queryByText(
        "Indexing is off — turn it on in Settings → Indexing to run a pass.",
      ),
    ).toBeNull();
  });

  it("requires an explicit cutoff date before calling the prune route", async () => {
    const user = userEvent.setup();
    const { fetchMock, calls } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Prune" })).toBeInTheDocument();
    });

    // The button row stays label-only: the cutoff description lives in the
    // modal, not repeated under the controls.
    expect(
      screen.queryByText(/Prune removes documents older/),
    ).toBeNull();

    await user.click(screen.getByRole("button", { name: "Prune" }));
    const pruneDialog = screen.getByRole("dialog", { name: "Confirm prune index" });
    expect(pruneDialog).toBeInTheDocument();
    // The prune modal's dismiss action reads Cancel, matching the reset modal.
    expect(
      within(pruneDialog).getByRole("button", { name: "Cancel" }),
    ).toBeInTheDocument();
    expect(
      within(pruneDialog).queryByRole("button", { name: "Keep" }),
    ).toBeNull();
    expect(calls.some((call) => call.url === "/index/prune")).toBe(false);

    // Confirming without a cutoff blocks and never calls the route, so an
    // empty choice cannot silently clear the store via a default-to-now.
    await user.click(screen.getByRole("button", { name: "Confirm prune index" }));
    await waitFor(() => {
      expect(screen.getByText(/Choose a cutoff date/)).toBeInTheDocument();
    });
    expect(calls.some((call) => call.url === "/index/prune")).toBe(false);

    // An explicit cutoff sends `before` instead of an empty body.
    fireEvent.change(screen.getByLabelText(/Cutoff date/), {
      target: { value: "2024-01-01" },
    });
    await user.click(screen.getByRole("button", { name: "Confirm prune index" }));
    await waitFor(() => {
      expect(calls.some((call) => call.url === "/index/prune")).toBe(true);
    });
    const prune = calls.find((call) => call.url === "/index/prune");
    expect((prune?.body as { before?: unknown })?.before).toBeDefined();
  });

  it("keeps the reset modal's dismiss action labeled Cancel", async () => {
    const user = userEvent.setup();
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Reset Index" })).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Reset Index" }));
    const resetDialog = screen.getByRole("dialog", { name: "Confirm reset index" });
    expect(
      within(resetDialog).getByRole("button", { name: "Cancel" }),
    ).toBeInTheDocument();
    expect(
      within(resetDialog).queryByRole("button", { name: "Keep" }),
    ).toBeNull();
    // The confirm button's aria-label matches the dialog label, so the
    // accessible-name query uses it instead of the visible "Reset" text.
    expect(
      within(resetDialog).getByRole("button", { name: "Confirm reset index" }),
    ).toBeInTheDocument();

    await user.click(within(resetDialog).getByRole("button", { name: "Cancel" }));
    expect(
      screen.queryByRole("dialog", { name: "Confirm reset index" }),
    ).toBeNull();
  });

  it("mounts the grep-style live block only with live", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: {
        ...statusPayload,
        enabled: true,
        running: true,
        live: {
          trigger: "onDemand",
          phase: "extracting",
          stage: "files",
          scanned: 5,
          indexed: 3,
          elapsedMs: 1500,
          current: "notes/ideas.md",
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    // The single live block mounts from the polled snapshot with its header,
    // one file line, and the activity bar — never the old cards or strip.
    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Manual Run");
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Reading files…");
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("5 scanned");
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("3 indexed");
    expect(screen.getByTestId("index-live-current")).toHaveTextContent("notes/ideas.md");
    expect(screen.getByTestId("index-live-activity")).toBeInTheDocument();
    expect(screen.queryByTestId("index-live-strip")).toBeNull();
    expect(screen.queryByTestId("index-progress-shimmer")).toBeNull();
    expect(screen.queryByTestId("index-mini-card-extracting")).toBeNull();
  });

  it("renders nothing without live even while running", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true, live: null },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("Running")).toBeInTheDocument();
    });
    // No live data renders nothing; the Status pill owns Running.
    expect(screen.queryByTestId("index-live-progress")).toBeNull();
    expect(screen.queryByTestId("index-live-header")).toBeNull();
    expect(screen.queryByTestId("index-live-current")).toBeNull();
    expect(screen.queryByTestId("index-live-activity")).toBeNull();
  });

  it("renders a single file line with full-path title and activity semantics", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: {
        ...statusPayload,
        enabled: true,
        running: true,
        live: {
          trigger: "nightly",
          phase: "extracting",
          stage: "mail",
          scanned: 7,
          indexed: 4,
          elapsedMs: 2500,
          current: "notes/ideas.md",
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-current")).toBeInTheDocument();
    });
    // Exactly one file line, truncated via CSS with the full path on title.
    expect(screen.getAllByTestId("index-live-current").length).toBe(1);
    expect(screen.getByTestId("index-live-current")).toHaveTextContent("notes/ideas.md");
    expect(screen.getByTestId("index-live-current")).toHaveAttribute("title", "notes/ideas.md");
    // Header names the trigger label explicitly.
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Nightly Run");
    // Activity bar reuses the ToolProgress shimmer style for activity only.
    const activity = screen.getByTestId("index-live-activity");
    expect(activity).toHaveClass("tool-progress-shimmer");
    expect(activity).toHaveAttribute("role", "progressbar");
    expect(activity).toHaveAttribute("aria-label", "Index run in progress");
    expect(activity.textContent ?? "").not.toMatch(/%/);
    // No duplicate Running text inside the live block.
    expect(within(screen.getByTestId("index-live-progress")).queryByText(/Running/)).toBeNull();
    const runningPills = document.querySelectorAll(".status-pill.running");
    expect(runningPills.length).toBe(1);
  });

  it("ignores progress frames from other tools", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "email.search",
      message: "Searching mail",
      scanned: 1,
      matched: 0,
      elapsedMs: 10,
    });

    expect(screen.queryByTestId("index-live-progress")).not.toBeInTheDocument();
    expect(screen.queryByTestId("index-live-activity")).not.toBeInTheDocument();
    expect(screen.queryByTestId("index-live-current")).not.toBeInTheDocument();
  });

  it("holds a cancelling state until the run settles, then re-enables Run", async () => {
    const user = userEvent.setup();
    // Remote run in flight: the panel did not start it, so Cancel stays
    // enabled until it is clicked and the cancelling window opens.
    let running = true;
    let lastRun: Record<string, unknown> = {
      status: "ok",
      indexed: 3,
      scanned: 5,
      errors: 0,
      finishedAt: 1,
      trigger: "onDemand",
    };
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({ ...statusPayload, enabled: true, running, lastRun, live: null });
      }
      if (url === "/index/cancel") {
        return jsonResponse({ cancelled: true });
      }
      return jsonResponse({
        engineName: "Test Engine",
        index: indexConfig,
      });
    });
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("Running")).toBeInTheDocument();
    });
    // Run stays disabled while a run is active and only re-enables once the
    // run fully stops; Cancel stays enabled until it is clicked.
    expect(
      screen.getByRole("button", { name: "Rebuild / Run Now" }),
    ).toBeDisabled();
    expect(screen.getByRole("button", { name: "Cancel" })).toBeEnabled();

    await user.click(screen.getByRole("button", { name: "Cancel" }));

    // Cancelling window: every Running indicator flips to Cancelling, the
    // header reads Cancelling…, and both Run and Cancel stay disabled.
    await waitFor(() => {
      expect(screen.getAllByText("Cancelling").length).toBeGreaterThanOrEqual(
        1,
      );
    });
    expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
      "Cancelling…",
    );
    expect(
      screen.getByRole("button", { name: "Rebuild / Run Now" }),
    ).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Cancelling…" }),
    ).toBeDisabled();

    // Settle the run: the terminal broadcast plus a stopped status probe ends
    // the window with the shared kept-work notice and no separate Stopped
    // variant. The fresh strip entry carries the cancelled outcome counts.
    running = false;
    lastRun = {
      status: "cancelled",
      indexed: 1,
      scanned: 2,
      errors: 0,
      finishedAt: Math.floor(Date.now() / 1000),
      trigger: "onDemand",
    };
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: {
        kind: "index",
        status: "cancelled",
        message: "Index run cancelled: 1 indexed, 2 scanned",
        response: "Index run cancelled: 1 indexed, 2 scanned",
      },
    });

    // The shared notice shows the cancelled outcome with its kept-work copy.
    // Both the notice and the strip carry the shared line, so the assertions
    // scope to all matches instead of a single element.
    await waitFor(() => {
      expect(screen.getAllByText(/Last run cancelled/).length).toBeGreaterThanOrEqual(1);
    });
    expect(screen.getAllByText(/committed work is kept/i).length).toBeGreaterThanOrEqual(1);
    // The live block unmounts on settle with no persistence.
    await waitFor(() => {
      expect(screen.queryByTestId("index-live-progress")).toBeNull();
    });
    // The strip shows the same cancelled entry instead of an empty history.
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("Last run cancelled");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("1 indexed");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("2 scanned");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent(/committed work is kept/i);
    expect(screen.getByTestId("index-last-run")).not.toHaveTextContent("No runs yet");
    // No additional elements: no separate Stopped variant survives settle.
    expect(screen.queryByText("Stopped")).toBeNull();
    await waitFor(() => {
      expect(screen.getByText("Enabled")).toBeInTheDocument();
    });
    expect(screen.queryByText("Cancelling")).toBeNull();
    expect(
      screen.getByRole("button", { name: "Rebuild / Run Now" }),
    ).toBeEnabled();
  });

  it("populates the strip from a cancelled run with kept work", async () => {
    // Regression read: a cancelled pass keeps its committed batches, so the
    // strip renders the partial counts instead of an empty history.
    const finishedAt = Math.floor(Date.now() / 1000);
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        enabled: true,
        running: false,
        live: null,
        lastRun: {
          status: "cancelled",
          indexed: 675,
          scanned: 7028,
          errors: 0,
          finishedAt,
          trigger: "onDemand",
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-run")).toHaveTextContent("Last run cancelled");
    });
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("675 indexed");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("7028 scanned");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("Manual Run");
    expect(screen.getByTestId("index-last-run")).toHaveTextContent(/committed work is kept/i);
    expect(screen.getByTestId("index-last-run")).not.toHaveTextContent("No runs yet");
    expect(screen.getByTestId("index-last-run")).not.toHaveTextContent("First run in progress");
    // The live block stays unmounted for a settled cancelled run.
    expect(screen.queryByTestId("index-live-progress")).toBeNull();
  });

  it("renders stage-aware copy from the polled live snapshot", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: {
        ...statusPayload,
        enabled: true,
        running: true,
        live: {
          trigger: "onDemand",
          phase: "extracting",
          stage: "files",
          scanned: 5,
          indexed: 3,
          elapsedMs: 1500,
          current: "notes/ideas.md",
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent("Reading files…");
    });
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Manual Run");
  });

  it("takes numbers from the poll, not the frame", async () => {
    let live = {
      trigger: "onDemand",
      phase: "extracting",
      stage: "files",
      scanned: 5,
      indexed: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    };
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({ ...statusPayload, enabled: true, running: true, live });
      }
      return jsonResponse({ engineName: "Test Engine", index: indexConfig });
    });
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-header")).toHaveTextContent("5 scanned");
    });
    const callsBefore = fetchMock.mock.calls.filter(([url]) => String(url) === "/index/status").length;
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    // A frame with different numbers only triggers a poll; the header keeps
    // the polled snapshot instead of adopting the frame counters.
    live = { ...live, scanned: 9, indexed: 7, elapsedMs: 2500 };
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting files: 99 indexed, 99 scanned",
      scanned: 99,
      matched: 99,
      elapsedMs: 99000,
      current: "other/file.md",
    });
    await waitFor(() => {
      const calls = fetchMock.mock.calls.filter(([url]) => String(url) === "/index/status").length;
      expect(calls).toBeGreaterThan(callsBefore);
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-live-header")).toHaveTextContent("9 scanned");
    });
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("7 indexed");
    expect(screen.getByTestId("index-live-header")).not.toHaveTextContent("99 scanned");
  });

  it("maps the live stage title without duplicating Running", () => {
    expect(resolveIndexLiveStageTitle("extracting", "files")).toBe("Reading files…");
    expect(resolveIndexLiveStageTitle("embedding", null)).toBe("Vectorizing…");
    expect(resolveIndexLiveStageTitle("embedding", "vision")).toBe("Describing images…");
    expect(resolveIndexLiveStageTitle(null, null)).toBe("Indexing…");
  });

  it("formats the grep-style live header from the polled snapshot", () => {
    const header = formatIndexLiveHeader({
      trigger: "onDemand",
      phase: "extracting",
      stage: "files",
      scanned: 5,
      indexed: 3,
      skipped: 0,
      errors: 0,
      rate: 41,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });
    expect(header).toContain("Manual Run");
    expect(header).toContain("Reading files…");
    expect(header).toContain("5 scanned");
    expect(header).toContain("3 indexed");
    expect(header).toContain("41 docs/s");
    expect(header).toContain("1.5s");
    expect(header).not.toMatch(/Running/);
    expect(formatIndexLiveHeader(null)).toBeNull();
    // Non-zero skipped/errors mid-run render inline; zero values stay omitted.
    const withSkips = formatIndexLiveHeader({
      trigger: "onDemand",
      phase: "extracting",
      stage: "files",
      scanned: 5,
      indexed: 3,
      skipped: 2,
      errors: 1,
      rate: 41,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });
    expect(withSkips).toContain("2 skipped");
    expect(withSkips).toContain("1 errors");
    expect(header).not.toContain("skipped");
    // An early-run spike omits the rate until the honest elapsed floor.
    const early = formatIndexLiveHeader({
      trigger: "onDemand",
      phase: "extracting",
      stage: "files",
      scanned: 5,
      indexed: 1,
      skipped: 0,
      errors: 0,
      rate: 100,
      elapsedMs: 10,
      current: "notes/ideas.md",
    });
    expect(early).not.toContain("docs/s");
  });

  it("renders vision stage copy from the polled live snapshot", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: {
        ...statusPayload,
        enabled: true,
        running: true,
        live: {
          trigger: "onDemand",
          phase: "embedding",
          stage: "vision",
          scanned: 2,
          indexed: 1,
          elapsedMs: 3500,
          current: null,
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent("Describing images…");
    });
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Manual Run");
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("2 scanned");
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("1 indexed");
  });

  // Mini-card step tests left with the deleted cards; the grep-style block
  // covers vision and counts through the polled snapshot above.

  it("unmounts the live block on settle with no persistence", async () => {
    let live: Record<string, unknown> | null = {
      trigger: "onDemand",
      phase: "committing",
      stage: null,
      scanned: 5,
      indexed: 3,
      elapsedMs: 5000,
      current: "notes/ideas.md",
    };
    let running = true;
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({ ...statusPayload, enabled: true, running, live });
      }
      return jsonResponse({
        engineName: "Test Engine",
        index: indexConfig,
      });
    });
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent("Committing…");
    });
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Manual Run");
    expect(screen.getByTestId("index-live-current")).toHaveTextContent("notes/ideas.md");

    // Settle the run: the cleared snapshot plus the terminal broadcast
    // unmounts the block instead of leaving a completed summary behind.
    live = null;
    running = false;
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: {
        kind: "index",
        status: "ok",
        message: "Index run ok: 3 indexed, 5 scanned",
        response: "Index run ok: 3 indexed, 5 scanned",
      },
    });

    await waitFor(() => {
      expect(screen.queryByTestId("index-live-progress")).toBeNull();
    });
    expect(screen.queryByTestId("index-live-header")).toBeNull();
    expect(screen.queryByTestId("index-live-current")).toBeNull();
    expect(screen.queryByTestId("index-live-activity")).toBeNull();
    expect(screen.queryByText("Completed")).toBeNull();
  });

  it("mounts a fresh live block when the next run starts", async () => {
    let live: Record<string, unknown> | null = null;
    let running = false;
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({ ...statusPayload, enabled: true, running, live });
      }
      return jsonResponse({
        engineName: "Test Engine",
        index: indexConfig,
      });
    });
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.queryByTestId("index-live-progress")).toBeNull();
    });

    // The next run begins: the polled snapshot mounts one fresh block with a
    // single file line and no stale cards.
    live = {
      trigger: "catchUp",
      phase: "extracting",
      stage: "files",
      scanned: 2,
      indexed: 1,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    };
    running = true;
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_started",
      run: {
        kind: "index",
        message: "Index run started (catchUp)",
        response: null,
      },
    });

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent("Catch-Up Run");
    });
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Reading files…");
    expect(screen.getAllByTestId("index-live-current").length).toBe(1);
    expect(screen.queryByTestId("index-live-strip")).toBeNull();
    expect(screen.queryByTestId("index-progress-shimmer")).toBeNull();
  });

  it("names the first run in progress instead of an empty history", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, enabled: true, running: true, lastRun: null },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-run")).toHaveTextContent(
        "First run in progress…",
      );
    });
    expect(screen.getByTestId("index-last-run")).not.toHaveTextContent(
      "No runs yet",
    );
  });

  it("keeps No runs yet for a fresh idle store", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, enabled: true, running: false, lastRun: null },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-run")).toHaveTextContent("No runs yet");
    });
    expect(screen.queryByTestId("index-live-progress")).toBeNull();
  });

  it("renders no mini-cards for the grep-style block", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: {
        ...statusPayload,
        enabled: true,
        running: true,
        live: {
          trigger: "onDemand",
          phase: "extracting",
          stage: "files",
          scanned: 5,
          indexed: 3,
          elapsedMs: 1500,
          current: "notes/ideas.md",
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
    });

    // The five mini-cards and the strip are gone; one file line remains.
    expect(screen.queryByTestId("index-live-strip")).toBeNull();
    expect(screen.queryByTestId("index-mini-card-extracting")).toBeNull();
    expect(screen.queryByTestId("index-progress-shimmer")).toBeNull();
    expect(screen.getAllByTestId("index-live-current").length).toBe(1);
  });

  it(
    "polls committed status while a run is in flight and stops on settle",
    async () => {
      let running = true;
      const fetchMock = vi.fn(async (input: string) => {
        const url = String(input);
        if (url === "/index/status") {
          return jsonResponse({ ...statusPayload, enabled: true, running });
        }
        return jsonResponse({
          engineName: "Test Engine",
          index: indexConfig,
        });
      });
      const capture = createMockWebSocketCapture();
      vi.stubGlobal("WebSocket", createMockWebSocket(capture));
      vi.stubGlobal("fetch", fetchMock);

      render(<IndexingPanel />);

      await waitFor(() => {
        expect(screen.getByText("Running")).toBeInTheDocument();
      });
      const callsAfterMount = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/index/status",
      ).length;
      // One poll tick (~2s) while the run window stays open re-reads status.
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 2300));
      });
      const callsDuringRun = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/index/status",
      ).length;
      expect(callsDuringRun).toBeGreaterThan(callsAfterMount);

      // Settle the run: the terminal broadcast plus a stopped probe ends the
      // window, and the pill falls back to Enabled.
      running = false;
      await waitFor(() => {
        expect(capture.onMessage).not.toBeNull();
      });
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "run_completed",
        run: {
          kind: "index",
          status: "ok",
          message: "Index run ok: 3 indexed, 5 scanned",
          response: "Index run ok: 3 indexed, 5 scanned",
        },
      });
      await waitFor(() => {
        expect(screen.getByText("Enabled")).toBeInTheDocument();
      });
      const callsAfterSettle = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/index/status",
      ).length;
      // Idle never polls: a full tick past settle adds no further reads.
      await new Promise((resolve) => setTimeout(resolve, 2300));
      const callsWhenIdle = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/index/status",
      ).length;
      expect(callsWhenIdle).toBe(callsAfterSettle);
    },
    15000,
  );

  it("updates cards mid-run from the polled live snapshot", async () => {
    let documents = 42;
    let live: Record<string, unknown> | null = {
      trigger: "onDemand",
      phase: "extracting",
      stage: "files",
      scanned: 5,
      indexed: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    };
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({
          ...statusPayload,
          enabled: true,
          running: true,
          documents,
          live,
        });
      }
      return jsonResponse({
        engineName: "Test Engine",
        index: indexConfig,
      });
    });
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-stat-documents-value")).toHaveTextContent("42");
    });
    // Committed growth arrives through the status reload while the run stays
    // in flight, so the card tracks the new total without settling.
    documents = 87;
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_started",
      run: {
        kind: "index",
        message: "Index run started (onDemand)",
        response: null,
      },
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-stat-documents-value")).toHaveTextContent("87");
    });
    // The live block stays mounted through the committed update with its
    // polled header.
    expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Reading files…");
  });

  it("flashes changed Size/Documents/Chunks values on update only", async () => {
    let payload = {
      ...statusPayload,
      enabled: true,
      running: true,
      documents: 42,
      chunks: 100,
      bytes: 2048,
    };
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse(payload);
      }
      return jsonResponse({
        engineName: "Test Engine",
        index: indexConfig,
      });
    });
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-stat-documents-value")).toBeInTheDocument();
    });
    // The first snapshot seeds the baseline and never flashes.
    expect(screen.getByTestId("index-stat-size-value")).not.toHaveClass(
      "index-stat-value-flash",
    );
    expect(screen.getByTestId("index-stat-documents-value")).not.toHaveClass(
      "index-stat-value-flash",
    );
    expect(screen.getByTestId("index-stat-chunks-value")).not.toHaveClass(
      "index-stat-value-flash",
    );

    // Change only Documents: that value flashes while Size and Chunks stay
    // plain, and the watermark, pills, and last-run strip never carry it.
    payload = { ...payload, documents: 60 };
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_started",
      run: {
        kind: "index",
        message: "Index run started (onDemand)",
        response: null,
      },
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-stat-documents-value")).toHaveTextContent("60");
    });
    expect(screen.getByTestId("index-stat-documents-value")).toHaveClass(
      "index-stat-value-flash",
    );
    expect(screen.getByTestId("index-stat-size-value")).not.toHaveClass(
      "index-stat-value-flash",
    );
    expect(screen.getByTestId("index-stat-chunks-value")).not.toHaveClass(
      "index-stat-value-flash",
    );
    expect(screen.getByTestId("index-last-run")).not.toHaveClass(
      "index-stat-value-flash",
    );
    expect(screen.getByTestId("index-watermark-card")).not.toHaveClass(
      "index-stat-value-flash",
    );
    for (const pill of document.querySelectorAll(".index-source-pills .status-pill")) {
      expect(pill).not.toHaveClass("index-stat-value-flash");
    }
  });
});

describe("IndexingPanel last errors helpers", () => {
  it("dedupes identical error strings in first-seen order", () => {
    expect(
      dedupeIndexErrors(["b failed", "a failed", "b failed", "a failed", "c failed"]),
    ).toEqual(["b failed", "a failed", "c failed"]);
    // Malformed entries degrade to skipped instead of blank rows.
    expect(dedupeIndexErrors(["a failed", 42, null, "a failed"])).toEqual([
      "a failed",
    ]);
    expect(dedupeIndexErrors(null)).toEqual([]);
    expect(dedupeIndexErrors("not-an-array")).toEqual([]);
  });

  it("pins the collapsed budget and preview budget", () => {
    expect(INDEX_LAST_ERRORS_COLLAPSED_COUNT).toBe(3);
    expect(INDEX_LAST_ERROR_PREVIEW_CHARS).toBeGreaterThan(0);
  });

  it("truncates long lines with an expand control rule", () => {
    const short = "mail: IMAP unreachable";
    expect(isLongIndexError(short)).toBe(false);
    expect(truncateIndexError(short)).toBe(short);
    const long = `files: scan failed: ${"x".repeat(INDEX_LAST_ERROR_PREVIEW_CHARS + 50)}`;
    expect(isLongIndexError(long)).toBe(true);
    const preview = truncateIndexError(long);
    expect(preview.length).toBeLessThan(long.length);
    expect(preview).toMatch(/…$/);
    expect(long.startsWith(preview.slice(0, -1))).toBe(true);
  });

  it("suppresses the raw denial bullet when guidance renders", () => {
    const denial = "messages: Full Disk Access required to read chat.db";
    // Guidance is the formatted form, so the raw bullet drops out.
    expect(resolveDisplayIndexErrors([denial, "mail: IMAP unreachable"])).toEqual([
      "mail: IMAP unreachable",
    ]);
    // Dedupe applies before suppression so a repeated denial still vanishes once.
    expect(resolveDisplayIndexErrors([denial, denial])).toEqual([]);
    // Without a denial every deduped line stays visible.
    expect(
      resolveDisplayIndexErrors(["mail: IMAP unreachable", "mail: IMAP unreachable"]),
    ).toEqual(["mail: IMAP unreachable"]);
  });
});

describe("IndexingPanel last errors card", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("dedupes identical error strings in the card", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        lastErrors: ["mail: IMAP unreachable", "mail: IMAP unreachable", "files: denied"],
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-errors")).toBeInTheDocument();
    });
    // One repeated line reads once.
    expect(screen.getAllByText("mail: IMAP unreachable").length).toBe(1);
    expect(screen.getByText("files: denied")).toBeInTheDocument();
    const items = within(screen.getByTestId("index-last-errors")).getAllByRole("listitem");
    expect(items.length).toBe(2);
    // Every row carries a warning icon.
    for (const item of items) {
      expect(item.querySelector("svg")).not.toBeNull();
    }
  });

  it("suppresses the raw denial bullet when guidance renders", async () => {
    const denial = "messages: Full Disk Access required to read chat.db";
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, lastErrors: [denial, "mail: IMAP unreachable"] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-fda-guidance")).toBeInTheDocument();
    });
    // Guidance is the formatted error, so the raw bullet stays hidden.
    expect(screen.queryByText(denial)).toBeNull();
    expect(screen.getByText("mail: IMAP unreachable")).toBeInTheDocument();
  });

  it("renders guidance-only with no raw rows when every error is a denial", async () => {
    const denial = "messages: Full Disk Access required to read chat.db";
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, lastErrors: [denial, denial] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-fda-guidance")).toBeInTheDocument();
    });
    expect(screen.queryByText(denial)).toBeNull();
    // Guidance steps render their own list items, so scope the raw-row check
    // to error rows: guidance-only means no indexed error row exists.
    expect(screen.queryByTestId("index-error-list")).toBeNull();
    expect(screen.queryAllByTestId(/^index-last-error-\d+$/).length).toBe(0);
  });

  it("caps rows with a show-all toggle", async () => {
    const user = userEvent.setup();
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        lastErrors: ["error one", "error two", "error three", "error four", "error five"],
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-errors")).toBeInTheDocument();
    });
    // Collapsed to the budget with the remainder behind the toggle.
    expect(
      within(screen.getByTestId("index-last-errors")).getAllByRole("listitem").length,
    ).toBe(INDEX_LAST_ERRORS_COLLAPSED_COUNT);
    expect(screen.getByText("error one")).toBeInTheDocument();
    expect(screen.queryByText("error five")).toBeNull();
    const toggle = screen.getByTestId("index-errors-toggle");
    expect(toggle).toHaveTextContent("Show all 5 errors");

    await user.click(toggle);
    await waitFor(() => {
      expect(screen.getByText("error five")).toBeInTheDocument();
    });
    expect(
      within(screen.getByTestId("index-last-errors")).getAllByRole("listitem").length,
    ).toBe(5);
    expect(screen.getByTestId("index-errors-toggle")).toHaveTextContent("Show fewer");

    await user.click(screen.getByTestId("index-errors-toggle"));
    await waitFor(() => {
      expect(screen.queryByText("error five")).toBeNull();
    });
    expect(
      within(screen.getByTestId("index-last-errors")).getAllByRole("listitem").length,
    ).toBe(INDEX_LAST_ERRORS_COLLAPSED_COUNT);
  });

  it("truncates long lines with an expand control", async () => {
    const user = userEvent.setup();
    // Unique tail marker so the hidden-suffix check reads the truncated suffix
    // rather than a repeated-character slice present in both states.
    const longError = `files: scan failed on a very long path: ${"x".repeat(INDEX_LAST_ERROR_PREVIEW_CHARS + 40)}TAILEND98765`;
    const tail = "TAILEND98765";
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, lastErrors: [longError] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-error-0")).toBeInTheDocument();
    });
    // Preview hides the tail behind the expand control.
    expect(screen.getByTestId("index-last-error-0")).not.toHaveTextContent(tail);
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument();
    // Warning icon stays on the truncated row.
    expect(
      screen.getByTestId("index-last-error-0").querySelector("svg"),
    ).not.toBeNull();

    await user.click(screen.getByRole("button", { name: "Show more" }));
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Show less" })).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-last-error-0")).toHaveTextContent(tail);

    await user.click(screen.getByRole("button", { name: "Show less" }));
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-last-error-0")).not.toHaveTextContent(tail);
  });

  it("omits the expand control and toggle for short lists", async () => {
    const { fetchMock } = stubFetch({
      status: { ...statusPayload, lastErrors: ["mail: IMAP unreachable"] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText("mail: IMAP unreachable")).toBeInTheDocument();
    });
    expect(screen.queryByRole("button", { name: "Show more" })).toBeNull();
    expect(screen.queryByTestId("index-errors-toggle")).toBeNull();
  });
});

describe("IndexingPanel honest size", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("sums the database file and WAL for the on-disk total", () => {
    expect(resolveIndexOnDiskBytes({ bytes: 2048, dbFileBytes: 2048, walBytes: 1024 })).toBe(3072);
    expect(resolveIndexOnDiskBytes({ bytes: 2048, dbFileBytes: 2048, walBytes: null })).toBe(2048);
    // Older engines without the file sizes fall back to the content total.
    expect(resolveIndexOnDiskBytes({ bytes: 2048 })).toBe(2048);
    expect(resolveIndexOnDiskBytes(null)).toBe(0);
    expect(
      resolveIndexOnDiskBytes({
        bytes: Number.NaN,
        dbFileBytes: -5,
        walBytes: "x",
      } as unknown as Parameters<typeof resolveIndexOnDiskBytes>[0]),
    ).toBe(0);
  });

  it("resolves the storage breakdown with presence flags", () => {
    const full = resolveIndexStorageBreakdown({
      bytes: 2048,
      dbFileBytes: 2048,
      walBytes: 1024,
      textBytes: 1024,
      vectorBytes: 1024,
      ftsBytes: 512,
      freeBytes: 512,
    });
    expect(full.onDisk).toBe(3072);
    expect(full.content).toBe(2048);
    expect(full.hasOnDisk).toBe(true);
    expect(full.hasBreakdown).toBe(true);
    // Older engines degrade to content-only with no breakdown row.
    const legacy = resolveIndexStorageBreakdown({ bytes: 2048 });
    expect(legacy.onDisk).toBe(2048);
    expect(legacy.hasOnDisk).toBe(false);
    expect(legacy.hasBreakdown).toBe(false);
  });

  it("renders the on-disk primary with the breakdown and content secondary", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        bytes: 2048,
        dbFileBytes: 2048,
        walBytes: 1024,
        textBytes: 1024,
        vectorBytes: 1024,
        ftsBytes: 512,
        freeBytes: 512,
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-stat-size-value")).toBeInTheDocument();
    });
    // Primary is the honest on-disk sum (2048 + 1024 = 3072 → 3 KB).
    expect(screen.getByTestId("index-stat-size-value")).toHaveTextContent("3 KB");
    // Breakdown row names each storage kind with its formatted bytes.
    expect(screen.getByTestId("index-size-breakdown")).toBeInTheDocument();
    expect(screen.getByTestId("index-size-text")).toHaveTextContent("1 KB");
    expect(screen.getByTestId("index-size-vectors")).toHaveTextContent("1 KB");
    expect(screen.getByTestId("index-size-fts")).toHaveTextContent("512 B");
    expect(screen.getByTestId("index-size-free")).toHaveTextContent("512 B");
    // File detail shows the two addends behind the primary.
    expect(screen.getByTestId("index-size-files")).toHaveTextContent("DB");
    expect(screen.getByTestId("index-size-files")).toHaveTextContent("WAL");
    // Content bytes stay as the secondary detail.
    expect(screen.getByTestId("index-size-content")).toHaveTextContent("2 KB");
  });

  it("omits the breakdown row for older engines without storage rows", async () => {
    const { fetchMock } = stubFetch({ status: { ...statusPayload, bytes: 2048 } });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-stat-size-value")).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-stat-size-value")).toHaveTextContent("2 KB");
    expect(screen.queryByTestId("index-size-breakdown")).toBeNull();
    expect(screen.getByTestId("index-size-content")).toHaveTextContent("2 KB");
  });
});

describe("IndexingPanel effort control", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("maps presets onto worker counts against the core count", () => {
    // Balanced on 10 cores resolves to half the cores up to four; light pins
    // one worker and performance takes all but one, mirroring the engine.
    expect(resolveEffortWorkers("balanced", 10)).toBe(4);
    expect(resolveEffortWorkers("light", 10)).toBe(1);
    expect(resolveEffortWorkers("performance", 10)).toBe(9);
    expect(resolveEffortWorkers("custom", 10, 6)).toBe(6);
    // Custom clamps into the static ceiling and the machine so a stale large
    // value never overshoots.
    expect(resolveEffortWorkers("custom", 10, 99)).toBe(10);
    expect(resolveEffortWorkers("custom", 128, 99)).toBe(64);
    expect(resolveEffortWorkers("custom", null, 99)).toBe(64);
    expect(resolveEffortWorkers("custom", 10, 0)).toBe(4);
    // Unknown core counts mirror safeCores=max(1,cores): every preset
    // resolves to 1 like the engine instead of guessing 2/4.
    expect(resolveEffortWorkers("light", null)).toBe(1);
    expect(resolveEffortWorkers("balanced", null)).toBe(1);
    expect(resolveEffortWorkers("performance", null)).toBe(1);
    expect(resolveEffortWorkers("balanced", 0)).toBe(1);
    expect(resolveEffortWorkers("performance", 0)).toBe(1);
    // Unknown presets degrade to the balanced mapping.
    expect(resolveEffortWorkers("unknown", 10)).toBe(4);
    expect(resolveEffortWorkers("unknown", null)).toBe(1);
    // Legacy tokens map onto their canonical successor instead of falling back.
    expect(normalizeIndexEffortPreset("eco")).toBe("light");
    expect(normalizeIndexEffortPreset("fast")).toBe("performance");
    expect(normalizeIndexEffortPreset("max")).toBe("performance");
    expect(normalizeIndexEffortPreset("standard")).toBe("balanced");
    expect(normalizeIndexEffortPreset("BALANCED")).toBe("balanced");
    expect(normalizeIndexEffortPreset("unknown")).toBe("balanced");
    expect(normalizeIndexEffortPreset(null)).toBe("balanced");
  });

  it("describes the resolved reality with the machine core count", () => {
    expect(describeEffortReality("balanced", 4, 10)).toBe(
      "Balanced - using 4 of 10 cores",
    );
    expect(describeEffortReality("light", 1, 10)).toContain("Light");
    expect(describeEffortReality("light", 1, 10)).toContain("1 of 10 cores");
    expect(describeEffortReality("performance", 9, 10)).toContain("Performance");
    // Without a core count the line names workers alone instead of guessing.
    expect(describeEffortReality("balanced", 4, null)).toBe(
      "Balanced - using 4 workers",
    );
  });

  it("reflects the machine core count in the status pane", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        effort: {
          preset: "balanced",
          resolvedWorkers: 4,
          activeProcessors: 10,
        },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-effort-status")).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-effort-status")).toHaveTextContent(
      "Balanced - using 4 of 10 cores",
    );
  });

  it("exposes three presets plus custom with a worker stepper and toggles", async () => {
    const user = userEvent.setup();
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-effort-reality")).toBeInTheDocument();
    });
    // Three scaling presets plus the custom mode share one radio group.
    expect(INDEX_EFFORT_OPTIONS.map((option) => option.id)).toEqual([
      "light",
      "balanced",
      "performance",
      "custom",
    ]);
    for (const label of ["Light", "Balanced", "Performance", "Custom"]) {
      expect(screen.getByRole("radio", { name: label })).toBeInTheDocument();
    }
    // Toggles for thermal backoff and pause on battery persist on Save.
    expect(screen.getByRole("checkbox", { name: "Thermal backoff" })).toBeInTheDocument();
    expect(screen.getByRole("checkbox", { name: "Pause on battery" })).toBeInTheDocument();
    // Custom reveals the stepper with bounded increment and decrement.
    await user.click(screen.getByRole("radio", { name: "Custom" }));
    expect(screen.getByLabelText("Custom workers")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Decrease workers" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Increase workers" })).toBeInTheDocument();
    // Reality names the newly selected preset.
    expect(screen.getByTestId("index-effort-reality")).toHaveTextContent("Custom");
    // Per-document vector cap is configurable from the same form, bounded to
    // the engine 1..4096 range with the 128 default.
    const capInput = screen.getByLabelText("Max vector chunks per document");
    expect(capInput).toBeInTheDocument();
    expect(capInput).toHaveAttribute("min", "1");
    expect(capInput).toHaveAttribute("max", "4096");
    // The fixture omits the cap so the form degrades to the engine default
    // instead of rendering blank.
    expect(capInput).toHaveValue(DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT);
    expect(screen.getByRole("button", { name: "Decrease vector cap" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Increase vector cap" })).toBeInTheDocument();
  });

  it("renders the Custom workers compact stepper with bounded states", async () => {
    // Engine reports four cores so the stepper ceiling stays deterministic
    // regardless of the browser running the test; the stored count opens at
    // the floor so both disabled edges are reachable in one render.
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, effort: "custom", workers: 1 },
      status: {
        ...statusPayload,
        effort: { preset: "custom", resolvedWorkers: 1, activeProcessors: 4 },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText("Custom workers")).toBeInTheDocument();
    });
    const input = screen.getByLabelText("Custom workers");
    // Compact presentation owns the single flex row: the numeric field keeps
    // its label association while the row carries the stepper scope.
    expect(input).toHaveClass("input-field");
    expect(input).toHaveClass("index-stepper-input");
    const row = input.closest(".index-stepper");
    expect(row).not.toBeNull();
    expect(row).toHaveClass("row");
    expect(row).toHaveClass("index-stepper");
    // Floor state keeps the stored count valid: Decrease has nothing to step
    // to while Increase stays available.
    expect(screen.getByRole("button", { name: "Decrease workers" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Increase workers" })).toBeEnabled();
    // Typed entry still flows through the existing clamped handler, so a
    // valid count updates the stored workers without touching Save.
    fireEvent.change(input, { target: { value: "3" } });
    expect(input).toHaveValue(3);
    expect(screen.getByRole("button", { name: "Decrease workers" })).toBeEnabled();
    // Ceiling state mirrors the floor: at the machine-clamped max the stored
    // count cannot step higher while Decrease stays available.
    fireEvent.change(input, { target: { value: "4" } });
    expect(input).toHaveValue(4);
    expect(screen.getByRole("button", { name: "Increase workers" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Decrease workers" })).toBeEnabled();
  });

  it("disables Increase workers when the stored count opens at the ceiling", async () => {
    // Opening directly at the clamped ceiling covers the persisted-at-max
    // case without driving the stepper there first.
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, effort: "custom", workers: 4 },
      status: {
        ...statusPayload,
        effort: { preset: "custom", resolvedWorkers: 4, activeProcessors: 4 },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText("Custom workers")).toBeInTheDocument();
    });
    expect(screen.getByLabelText("Custom workers")).toHaveValue(4);
    expect(screen.getByRole("button", { name: "Increase workers" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Decrease workers" })).toBeEnabled();
  });

  it("reads canonical workers", () => {
    expect(resolveIndexWorkersValue({ workers: 6 })).toBe(6);
    expect(resolveIndexWorkersValue({})).toBeNull();
    expect(resolveIndexWorkersValue(null)).toBeNull();
    expect(resolveIndexVectorCapValue({ max_vector_chunks_per_document: 64 })).toBe(64);
    expect(resolveIndexVectorCapValue({})).toBeNull();
  });

  it("resolves status effort from the nested effort block", () => {
    expect(
      resolveStatusEffort({
        effort: { preset: "performance", resolvedWorkers: 9, activeProcessors: 10 },
      }),
    ).toEqual({ preset: "performance", resolvedWorkers: 9, coreCount: 10 });
    expect(resolveStatusEffort(null)).toEqual({
      preset: null,
      resolvedWorkers: null,
      coreCount: null,
    });
  });
});

describe("IndexingPanel reclaim action", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("formats the reclaim result with before and after figures", () => {
    expect(
      formatIndexReclaimResult({ beforeBytes: 2048, afterBytes: 1024, reclaimedBytes: 1024 }),
    ).toBe("Reclaimed 1 KB (before 2 KB → after 1 KB)");
    expect(formatIndexReclaimResult(null)).toBeNull();
  });

  it("calls POST /index/reclaim and shows the before/after display", async () => {
    const user = userEvent.setup();
    const { fetchMock, calls } = stubFetch({
      status: { ...statusPayload, enabled: true },
      settings: { ...indexConfig, enabled: true },
      reclaim: { beforeBytes: 3072, afterBytes: 2048, reclaimedBytes: 1024 },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Reclaim space" })).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Reclaim space" }));

    await waitFor(() => {
      expect(screen.getByTestId("index-reclaim-result")).toBeInTheDocument();
    });
    expect(calls.some((call) => call.url === "/index/reclaim")).toBe(true);
    // Both on-disk figures read in the result block.
    expect(screen.getByTestId("index-reclaim-result")).toHaveTextContent("3 KB");
    expect(screen.getByTestId("index-reclaim-result")).toHaveTextContent("2 KB");
    expect(screen.getByTestId("index-reclaim-result")).toHaveTextContent("1 KB");
  });

  it("surfaces the retired count from the last run", async () => {
    expect(resolveIndexRetiredCount({ retiredCount: 7 })).toBe(7);
    expect(resolveIndexRetiredCount({ retired: 5 })).toBe(5);
    expect(resolveIndexRetiredCount({})).toBeNull();
    expect(resolveIndexRetiredCount(null)).toBeNull();
    expect(
      describeIndexRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1, retiredCount: 7 }),
    ).toContain("7 retired");

    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        lastRun: { status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1, retiredCount: 7 },
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-last-run")).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-last-run")).toHaveTextContent("7 retired");
    expect(screen.getByTestId("index-last-run-retired")).toHaveTextContent("7 retired");
  });
});

describe("IndexPolicyPanel index scope", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("formats the root-scoped coverage subtitle from the configured roots", () => {
    // Default home root gains its parenthetical so a stock install reads as
    // the home directory instead of a bare sigil.
    expect(describeIndexScope(["~"])).toBe(
      "Builds a local search index of ~ (your home directory). Nothing outside the configured roots is ever scanned.",
    );
    expect(formatIndexScopeRoots(["~"])).toBe("~ (your home directory)");
    // Custom roots join verbatim so the subtitle names exactly what the walker
    // covers, and non-array payloads degrade honestly instead of blanking.
    expect(describeIndexScope(["~/Documents", "~/Code"])).toContain("~/Documents");
    expect(describeIndexScope(["~/Documents", "~/Code"])).toContain("~/Code");
    expect(describeIndexScope(["~/Documents", "~/Code"])).toContain(
      "Nothing outside the configured roots is ever scanned.",
    );
    expect(formatIndexScopeRoots([])).toBe("no configured roots");
    expect(resolveAlwaysSkipped({ always_skipped: ["Music", ".git"] })).toEqual([
      "Music",
      ".git",
    ]);
    expect(resolveAlwaysSkipped({})).toEqual([]);
    expect(resolveAlwaysSkipped(null)).toEqual([]);
  });

  it("states the root-scoped coverage naming the configured roots", async () => {
    const { fetchMock } = stubFetch({
      settings: {
        ...indexConfig,
        roots: ["~/Documents", "~/Code"],
        always_skipped: ["Music", "Pictures", ".git"],
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-scope-subtitle")).toBeInTheDocument();
    });
    // The subtitle interpolates the configured roots instead of a generic
    // chooser line, and states the walk never leaves them.
    expect(screen.getByTestId("index-scope-subtitle")).toHaveTextContent("~/Documents");
    expect(screen.getByTestId("index-scope-subtitle")).toHaveTextContent("~/Code");
    expect(screen.getByTestId("index-scope-subtitle")).toHaveTextContent(
      "Nothing outside the configured roots is ever scanned.",
    );
  });

  it("names the home directory for the default root", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, roots: ["~"], always_skipped: ["Music", ".git"] },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-scope-subtitle")).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-scope-subtitle")).toHaveTextContent(
      "Builds a local search index of ~ (your home directory).",
    );
  });

  it("renders the always-skipped names from the payload rather than a literal", async () => {
    // Sentinel names prove the list renders from `always_skipped` data, while
    // the outer block carries no hardcoded walker names so the copy cannot
    // drift from FilesIndexer.alwaysSkippedPatterns.
    const { fetchMock } = stubFetch({
      settings: {
        ...indexConfig,
        roots: ["~"],
        always_skipped: ["SentinelSkipAlpha", "SentinelSkipBeta"],
      },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-always-skipped")).toBeInTheDocument();
    });
    expect(screen.getByTestId("index-always-skipped")).toHaveTextContent(
      "SentinelSkipAlpha",
    );
    expect(screen.getByTestId("index-always-skipped")).toHaveTextContent(
      "SentinelSkipBeta",
    );
    // The data-driven element carries only the payload names: a hard-coded
    // literal would still read the walker defaults here instead.
    expect(screen.getByTestId("index-always-skipped")).not.toHaveTextContent("Music");
    // The outer block renders solely from the payload with no hardcoded
    // walker names alongside the dynamic list.
    const skippedBlock = screen.getByTestId("index-always-skipped-block");
    for (const banned of [
      "Music",
      "Pictures",
      "Movies",
      "Library",
      "Trash",
      ".git",
      "node_modules",
      "DerivedData",
    ]) {
      expect(skippedBlock).not.toHaveTextContent(banned);
    }
    // The block keeps the generic credential sentence without listing deny
    // patterns.
    expect(screen.getByTestId("index-always-skipped-block")).toHaveTextContent(
      /Credential and key files blocked by your file access rules are never indexed either/,
    );
  });
});
