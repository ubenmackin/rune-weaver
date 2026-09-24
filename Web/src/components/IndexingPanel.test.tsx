// Rune Weaver Dashboard — Component tests for the IndexingPanel status
// dashboard (layout, charts, no-refresh updates, destructive modals) and the
// IndexPolicyPanel form.

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import IndexingPanel, {
  INDEX_LAST_ERRORS_COLLAPSED_COUNT,
  INDEX_LAST_ERROR_PREVIEW_CHARS,
  INDEX_STEPS,
  INDEX_STEP_ICONS,
  IndexPolicyPanel,
  dedupeIndexErrors,
  describeAutoStartNotice,
  describeIndexLastRun,
  describeRunSummary,
  formatIndexAge,
  formatIndexAsOf,
  formatIndexBytes,
  formatIndexRate,
  indexDonutArcs,
  indexSourceBarPercent,
  indexSourceBarWidth,
  indexStepsForFrame,
  isIndexProgressFrame,
  isLongIndexError,
  resolveDisplayIndexErrors,
  resolveIndexLiveTitle,
  resolveIndexPhase,
  resolveIndexSourceContent,
  resolveIndexStage,
  resolveIndexStep,
  resolveIndexStepStatus,
  truncateIndexError,
} from "./IndexingPanel";
import {
  indexRunLabelForRun,
  indexRunTriggerLabel,
  parseIndexRunTrigger,
} from "../api";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";

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
  overrides: { status?: unknown; settings?: unknown; capture?: (url: string) => Response | null } = {},
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

  it("extracts a known phase from the frame message", () => {
    expect(resolveIndexPhase("Indexing extracting: 3 indexed")).toBe("extracting");
    expect(resolveIndexPhase("Indexing extracting files: 3 indexed")).toBe("extracting");
    expect(resolveIndexPhase("Indexing unknownphase: 0")).toBeNull();
    expect(resolveIndexPhase(null)).toBeNull();
  });

  it("extracts the active stage from the frame message", () => {
    expect(resolveIndexStage("Indexing extracting files: 3 indexed")).toBe("files");
    expect(resolveIndexStage("Indexing extracting mail: 1 indexed")).toBe("mail");
    expect(resolveIndexStage("Indexing extracting messages: 1 indexed")).toBe("messages");
    expect(resolveIndexStage("Indexing embedding vision: 1 indexed")).toBe("vision");
    // Discovering and committing frames carry no stage.
    expect(resolveIndexStage("Indexing discovering: 0 indexed")).toBeNull();
    expect(resolveIndexStage("Indexing committing: 3 indexed")).toBeNull();
    expect(resolveIndexStage("Indexing extracting: 3 indexed")).toBeNull();
    expect(resolveIndexStage("Indexing unknownstage: 0")).toBeNull();
    expect(resolveIndexStage(null)).toBeNull();
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

  it("adopts index frames by tool name or during an active run", () => {
    expect(isIndexProgressFrame({ toolName: "index" }, false)).toBe(false);
    expect(isIndexProgressFrame({ toolName: "index" }, true)).toBe(true);
    expect(isIndexProgressFrame({ toolName: "email.search" }, true)).toBe(false);
    expect(isIndexProgressFrame({ toolName: "" }, true)).toBe(true);
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
    expect(describeIndexLastRun(null)).toBe("No runs yet");
    expect(
      describeIndexLastRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1 }),
    ).toContain("Last run ok");
    expect(
      describeIndexLastRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1 }),
    ).toContain("3 indexed");
  });

  it("formats the active-card rate honestly, omitting it without work or time", () => {
    expect(formatIndexRate(5, 1000)).toBe("5 scanned/s");
    expect(formatIndexRate(33, 10000)).toBe("3.3 scanned/s");
    expect(formatIndexRate(0, 1000)).toBeNull();
    expect(formatIndexRate(5, 0)).toBeNull();
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
    expect(describeRunSummary({ ...baseSummary, trigger: "nightly" })).toContain("Nightly Run");
    expect(describeRunSummary({ ...baseSummary, trigger: "nightly" })).toContain("Index run ok");
    expect(describeRunSummary({ ...baseSummary, trigger: "onDemand" })).toContain("Manual Run");
    expect(describeRunSummary({ ...baseSummary, trigger: "catchUp" })).toContain("Catch-Up Run");
    // Last-run strip carries the trigger label without dropping the status prefix.
    expect(
      describeIndexLastRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1, trigger: "catchUp" }),
    ).toContain("Catch-Up Run");
    expect(
      describeIndexLastRun({ status: "ok", indexed: 3, scanned: 5, errors: 0, finishedAt: 1, trigger: "catchUp" }),
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
    await user.click(screen.getByLabelText("Enable background indexing"));
    await user.click(screen.getByLabelText("Index Mail"));
    await user.click(screen.getByRole("button", { name: "Save Index Settings" }));

    await waitFor(() => {
      expect(screen.getByText("Index settings saved.")).toBeInTheDocument();
    });

    const put = calls.find((call) => call.url === "/settings" && call.method === "PUT");
    expect(put).toBeDefined();
    const patch = (put?.body as { index?: Record<string, unknown> })?.index;
    expect(patch?.enabled).toBe(true);
    expect(patch?.mail).toBe(true);
    expect(patch?.exclude).toEqual([".git", "node_modules"]);
    expect(patch?.mail_vector_window).toBe("2y");
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

    await waitFor(() => {
      expect(screen.getByText(/Index run ok: 3 indexed/)).toBeInTheDocument();
    });
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

  it("renders live phase steps and the current item from a progress frame", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });

    // The active mini-card carries the truncated current file plus counts.
    await waitFor(() => {
      expect(screen.getByTestId("index-step-current-extracting")).toHaveTextContent(
        "notes/ideas.md",
      );
    });
    // The extracting phase step is highlighted and the shimmer proves liveness.
    // The step renders the plain-language copy ("Reading") for the wire token.
    expect(screen.getByText("Reading")).toBeInTheDocument();
    expect(screen.getByTestId("index-step-counts-extracting")).toHaveTextContent(
      "5 scanned",
    );
    expect(screen.getByTestId("index-step-counts-extracting")).toHaveTextContent(
      "3 indexed",
    );
    expect(screen.getByTestId("index-progress-shimmer")).toBeInTheDocument();
    // The live header is text only with the stage-aware title plus counts.
    expect(screen.getByTestId("index-live-header")).toHaveTextContent("Reading…");
  });

  it("renders a single pill with a wrapping icon strip keeping progressbar semantics", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    // The old Progress card is gone: no heading and no pill inside the live
    // block, while the Status pill below stays the single running indicator.
    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
    });
    expect(
      screen.queryByRole("heading", { name: "Progress" }),
    ).toBeNull();
    expect(
      within(screen.getByTestId("index-live-progress")).queryByText("Indexing"),
    ).toBeNull();
    const runningPills = document.querySelectorAll(".status-pill.running");
    expect(runningPills.length).toBe(1);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });

    await waitFor(() => {
      expect(screen.getByTestId("index-step-current-extracting")).toHaveTextContent(
        "notes/ideas.md",
      );
    });

    // The shimmer keeps progressbar semantics for assistive tech.
    const shimmer = screen.getByTestId("index-progress-shimmer");
    expect(shimmer).toHaveAttribute("role", "progressbar");
    expect(shimmer).toHaveAttribute("aria-label", "Index run in progress");

    // The strip wraps instead of scrolling via the base flex-wrap rule, with
    // no redundant wrap modifier.
    const strip = screen.getByTestId("index-live-strip");
    expect(strip).toHaveClass("index-live-strip");
    expect(strip).not.toHaveClass("index-live-strip--wrap");

    // Each mini-card renders its step icon alongside the label.
    for (const step of INDEX_STEPS) {
      const card = screen.getByTestId(`index-mini-card-${step.id}`);
      expect(card).toBeInTheDocument();
      expect(card.querySelector("svg")).not.toBeNull();
    }

    // Phase steps and live counts stay inside the strip.
    expect(within(strip).getByText("Reading")).toBeInTheDocument();
    expect(screen.getByTestId("index-progress-shimmer")).toBeInTheDocument();
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
    expect(screen.queryByTestId("index-live-strip")).not.toBeInTheDocument();
  });

  it("holds a cancelling state until the run settles, then re-enables Run", async () => {
    const user = userEvent.setup();
    // Remote run in flight: the panel did not start it, so Cancel stays
    // enabled until it is clicked and the cancelling window opens.
    let running = true;
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({ ...statusPayload, enabled: true, running });
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
    // the window with the kept-work notice and no separate Stopped variant.
    running = false;
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

    await waitFor(() => {
      expect(screen.getByText(/Index run cancelled:/)).toBeInTheDocument();
    });
    expect(screen.getByText(/committed work is kept/)).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByText("Enabled")).toBeInTheDocument();
    });
    expect(screen.queryByText("Cancelling")).toBeNull();
    expect(
      screen.getByRole("button", { name: "Rebuild / Run Now" }),
    ).toBeEnabled();
  });

  it("adopts auto-started run frames that omit the tool name", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    // The engine reports a run in flight this panel did not start, so the
    // Status pill is the authoritative Running source with no local flight.
    await waitFor(() => {
      expect(screen.getByText("Running")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    // Older engines omit the tool name; the frame is still adopted because a
    // run is in flight via the status probe.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "",
      message: "Indexing extracting files: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });

    await waitFor(() => {
      expect(screen.getByTestId("index-step-current-extracting")).toHaveTextContent(
        "notes/ideas.md",
      );
    });
    expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
      "Reading files…",
    );
  });

  it("renders stage-aware header copy per stage", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting files: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Reading files…",
      );
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing embedding: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 2500,
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Vectorizing…",
      );
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing embedding vision: 1 indexed, 2 scanned",
      scanned: 2,
      matched: 1,
      elapsedMs: 3500,
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Describing images…",
      );
    });
  });

  it(
    "falls back to Running… when a run stays without frames",
    async () => {
      const { fetchMock } = stubFetch({
        settings: { ...indexConfig, enabled: true },
        status: { ...statusPayload, enabled: true, running: true },
      });
      vi.stubGlobal("fetch", fetchMock);

      render(<IndexingPanel />);

      await waitFor(() => {
        expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
      });
      // Before any frame the header starts on Starting….
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Starting…",
      );
      // Well under two seconds without a frame it falls back to Running…
      // instead of freezing on Starting…, while the Status pill stays
      // authoritative.
      await waitFor(
        () => {
          expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
            "Running…",
          );
        },
        { timeout: 5000 },
      );
      expect(screen.getByText("Running")).toBeInTheDocument();
    },
    10000,
  );

  it("maps phase and stage tokens onto one explained step", () => {
    expect(resolveIndexStep("discovering", null)).toBe("discovering");
    expect(resolveIndexStep("extracting", "files")).toBe("extracting");
    expect(resolveIndexStep("embedding", null)).toBe("embedding");
    expect(resolveIndexStep("committing", null)).toBe("committing");
    // Vision wins over any phase token so image work never reads as another step.
    expect(resolveIndexStep("embedding", "vision")).toBe("vision");
    expect(resolveIndexStep("extracting", "vision")).toBe("vision");
    expect(resolveIndexStep(null, null)).toBeNull();
    expect(resolveIndexStep("unknown", null)).toBeNull();
  });

  it("marks vision frames as both phase and vision visits", () => {
    expect(indexStepsForFrame("discovering", null)).toEqual(["discovering"]);
    expect(indexStepsForFrame("embedding", "vision")).toEqual([
      "embedding",
      "vision",
    ]);
    expect(indexStepsForFrame(null, "vision")).toEqual(["vision"]);
    expect(indexStepsForFrame(null, null)).toEqual([]);
  });

  it("resolves done/active/pending from the active step and visits", () => {
    const visited = new Set(["discovering", "extracting"]);
    expect(resolveIndexStepStatus("extracting", "extracting", visited)).toBe(
      "active",
    );
    // The other visited step reads done while the active step holds the counts.
    expect(resolveIndexStepStatus("discovering", "embedding", visited)).toBe(
      "done",
    );
    expect(resolveIndexStepStatus("embedding", "embedding", visited)).toBe(
      "active",
    );
    expect(resolveIndexStepStatus("committing", "embedding", visited)).toBe(
      "pending",
    );
    // The completed summary has no active step, so every visit reads done.
    expect(resolveIndexStepStatus("discovering", null, visited)).toBe("done");
    expect(resolveIndexStepStatus("committing", null, visited)).toBe("pending");
  });

  it("explains all five steps with tooltips", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
    });

    // All five explained steps render in run order with plain-language labels.
    expect(INDEX_STEPS.map((step) => step.id)).toEqual([
      "discovering",
      "extracting",
      "embedding",
      "vision",
      "committing",
    ]);
    expect(screen.getByText("Discovering")).toBeInTheDocument();
    expect(screen.getByText("Reading")).toBeInTheDocument();
    expect(screen.getByText("Vectorizing")).toBeInTheDocument();
    expect(screen.getByText("Describing images")).toBeInTheDocument();
    expect(screen.getByText("Committing")).toBeInTheDocument();
    // Each step carries an explanatory tooltip rather than a wire token.
    expect(
      screen.getByText("Discovering").closest("li"),
    ).toHaveAttribute("title", expect.stringMatching(/finding candidates/i));
    expect(
      screen.getByText("Reading").closest("li"),
    ).toHaveAttribute("title", expect.stringMatching(/extracting text/i));
    expect(
      screen.getByText("Vectorizing").closest("li"),
    ).toHaveAttribute("title", expect.stringMatching(/building embeddings/i));
    expect(
      screen.getByText("Describing images").closest("li"),
    ).toHaveAttribute(
      "title",
      expect.stringMatching(/describing images with llm/i),
    );
    expect(
      screen.getByText("Committing").closest("li"),
    ).toHaveAttribute("title", expect.stringMatching(/saving to the index/i));
  });

  it("activates the Describing images step on vision-stage frames with live counts", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing embedding vision: 1 indexed, 2 scanned",
      scanned: 2,
      matched: 1,
      elapsedMs: 3500,
    });

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Describing images…",
      );
    });

    // Vision is its own step: active on the stage token with live counts.
    const visionStep = screen.getByText("Describing images").closest("li");
    expect(visionStep).not.toBeNull();
    expect(visionStep).toHaveClass("active");
    expect(visionStep).toHaveAttribute(
      "title",
      expect.stringMatching(/describing images with llm/i),
    );
    expect(visionStep).toHaveTextContent("2 scanned");
    expect(visionStep).toHaveTextContent("1 indexed");
    // Its phase companion already reads done while describing stays active.
    const vectorStep = screen.getByText("Vectorizing").closest("li");
    expect(vectorStep).toHaveClass("done");
    expect(vectorStep).toHaveAttribute(
      "title",
      expect.stringMatching(/building embeddings/i),
    );
  });

  it("carries live counts on the active step", async () => {
    const capture = createMockWebSocketCapture();
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting files: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 1500,
      current: "notes/ideas.md",
    });

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Reading files…",
      );
    });
    const readingStep = screen.getByText("Reading").closest("li");
    expect(readingStep).toHaveClass("active");
    expect(readingStep).toHaveTextContent("5 scanned");
    expect(readingStep).toHaveTextContent("3 indexed");
    // The active card also carries elapsed, rate, and the truncated file.
    expect(readingStep).toHaveTextContent("1.5s");
    expect(readingStep).toHaveTextContent("3.3 scanned/s");
    expect(
      within(readingStep as HTMLElement).getByTestId("index-step-current-extracting"),
    ).toHaveTextContent("notes/ideas.md");
  });

  it("unmounts the strip on settle with no persistence", async () => {
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
      expect(capture.onMessage).not.toBeNull();
    });

    const frames = [
      "Indexing discovering: 0 indexed, 1 scanned",
      "Indexing extracting files: 1 indexed, 2 scanned",
      "Indexing embedding: 2 indexed, 3 scanned",
      "Indexing embedding vision: 2 indexed, 4 scanned",
      "Indexing committing: 3 indexed, 5 scanned",
    ];
    for (const [index, message] of frames.entries()) {
      await dispatchFrameOrThrow(capture.onMessage, {
        type: "tool_progress",
        callID: "c1",
        toolName: "index",
        message,
        scanned: index + 1,
        matched: index,
        elapsedMs: 1000 * (index + 1),
      });
    }

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Committing…",
      );
    });
    // The committing step is live with its counts before the run settles.
    expect(screen.getByText("Committing").closest("li")).toHaveClass("active");

    // Settle the run: the terminal broadcast unmounts the strip instead of
    // leaving a completed summary behind.
    running = false;
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
    expect(screen.queryByTestId("index-live-strip")).toBeNull();
    expect(screen.queryByTestId("index-progress-shimmer")).toBeNull();
    expect(screen.queryByText("Completed")).toBeNull();
  });

  it("mounts a fresh strip when the next run starts", async () => {
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
      expect(capture.onMessage).not.toBeNull();
    });

    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting files: 1 indexed, 2 scanned",
      scanned: 2,
      matched: 1,
      elapsedMs: 1500,
    });
    await waitFor(() => {
      expect(screen.getByText("Reading").closest("li")).toHaveClass("active");
    });

    // Settle the first pass: the strip unmounts with no persisted summary.
    running = false;
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: {
        kind: "index",
        status: "ok",
        message: "Index run ok: 1 indexed, 2 scanned",
        response: "Index run ok: 1 indexed, 2 scanned",
      },
    });
    await waitFor(() => {
      expect(screen.queryByTestId("index-live-progress")).toBeNull();
    });

    // The next run begins: a fresh strip mounts with every step pending
    // before new frames rebuild the live state.
    running = true;
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_started",
      run: {
        kind: "index",
        message: "Index run started (onDemand)",
        response: null,
      },
    });

    await waitFor(() => {
      expect(screen.getByTestId("index-live-progress")).toHaveTextContent(
        "Starting…",
      );
    });
    expect(
      screen.getByText("Discovering").closest("li"),
    ).toHaveClass("pending");
    expect(screen.getByText("Reading").closest("li")).toHaveClass("pending");
    expect(screen.getByText("Vectorizing").closest("li")).toHaveClass(
      "pending",
    );
    expect(screen.getByText("Describing images").closest("li")).toHaveClass(
      "pending",
    );
    expect(screen.getByText("Committing").closest("li")).toHaveClass("pending");
    expect(
      within(screen.getByTestId("index-live-progress")).queryByText(/✓/),
    ).toBeNull();
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

  it("renders one icon per mini-card from the shared set", async () => {
    const { fetchMock } = stubFetch({
      settings: { ...indexConfig, enabled: true },
      status: { ...statusPayload, enabled: true, running: true },
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByTestId("index-live-strip")).toBeInTheDocument();
    });

    // Every step id maps to a shared icon component rendering one svg.
    expect(Object.keys(INDEX_STEP_ICONS).sort()).toEqual(
      ["committing", "discovering", "embedding", "extracting", "vision"].sort(),
    );
    for (const step of INDEX_STEPS) {
      const card = screen.getByTestId(`index-mini-card-${step.id}`);
      const icon = card.querySelector(".index-mini-card-icon svg");
      expect(icon).not.toBeNull();
    }
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
      await new Promise((resolve) => setTimeout(resolve, 2300));
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

  it("updates cards mid-run from the polled sequence while frames drive the live line", async () => {
    let documents = 42;
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url === "/index/status") {
        return jsonResponse({
          ...statusPayload,
          enabled: true,
          running: true,
          documents,
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
    // The live strip stays mounted through the committed update.
    expect(screen.getByTestId("index-live-progress")).toBeInTheDocument();
    // Frames remain the in-flight source: a progress frame still drives the
    // stage-aware header after the committed update lands.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "tool_progress",
      callID: "c1",
      toolName: "index",
      message: "Indexing extracting files: 3 indexed (2 vectors), 5 scanned",
      scanned: 5,
      matched: 3,
      elapsedMs: 1500,
    });
    await waitFor(() => {
      expect(screen.getByTestId("index-live-header")).toHaveTextContent("Reading files…");
    });
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
