// Rune Weaver Dashboard — Component tests for the IndexingPanel status
// dashboard (layout, charts, no-refresh updates, destructive modals) and the
// IndexPolicyPanel form.

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import IndexingPanel, {
  IndexPolicyPanel,
  formatIndexAge,
  formatIndexAsOf,
  formatIndexBytes,
  indexDonutArcs,
  isIndexProgressFrame,
  resolveIndexPhase,
} from "./IndexingPanel";
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
    expect(resolveIndexPhase("Indexing unknownphase: 0")).toBeNull();
    expect(resolveIndexPhase(null)).toBeNull();
  });

  it("adopts index frames by tool name or during an active run", () => {
    expect(isIndexProgressFrame({ toolName: "index" }, false)).toBe(true);
    expect(isIndexProgressFrame({ toolName: "email.search" }, true)).toBe(false);
    expect(isIndexProgressFrame({ toolName: "" }, true)).toBe(true);
    expect(isIndexProgressFrame({ toolName: "" }, false)).toBe(false);
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
    expect(screen.getByText("Never indexed")).toBeInTheDocument();
    expect(screen.getByText("Disabled")).toBeInTheDocument();
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
      run: { status: "ok" },
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

  it("renders the donut and per-source bars from the stubbed status", async () => {
    const { fetchMock } = stubFetch({
      status: {
        ...statusPayload,
        sources: [
          { kind: "files", enabled: true },
          { kind: "mail", enabled: false },
          { kind: "messages", enabled: false },
        ],
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
    // Bars reflect per-source enablement; pills mirror the same state.
    expect(screen.getByTestId("index-bar-files")).toHaveStyle({ width: "100%" });
    expect(screen.getByTestId("index-bar-mail")).toHaveStyle({ width: "0%" });
    expect(screen.getByText("Files · On")).toBeInTheDocument();
    expect(screen.getByText("Mail · Off")).toBeInTheDocument();
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

    await waitFor(() => {
      expect(screen.getByTestId("index-progress-current")).toHaveTextContent(
        "notes/ideas.md",
      );
    });
    // The extracting phase step is highlighted and the shimmer proves liveness.
    // The step renders the plain-language copy ("Reading") for the wire token.
    expect(screen.getByText("Reading")).toBeInTheDocument();
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

    expect(screen.queryByTestId("index-progress-current")).not.toBeInTheDocument();
  });
});
