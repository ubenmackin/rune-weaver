// Rune Weaver Dashboard — Component tests for the IndexingPanel status, policy,
// controls, and live progress.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import IndexingPanel, {
  formatIndexAsOf,
  formatIndexBytes,
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

  it("renders store counts, watermark, and disable/enable state", async () => {
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByText(/42 documents/)).toBeInTheDocument();
    });
    expect(screen.getByText(/100 chunks/)).toBeInTheDocument();
    expect(screen.getByText(/2 KB/)).toBeInTheDocument();
    expect(screen.getByText(/Never indexed/)).toBeInTheDocument();
    expect(screen.getByText("Disabled")).toBeInTheDocument();
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

  it("saves the index policy through a PUT /settings index patch", async () => {
    const user = userEvent.setup();
    const { fetchMock, calls } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexingPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Exclude patterns/)).toBeInTheDocument();
    });

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

    await user.click(screen.getByRole("button", { name: "Prune" }));
    expect(
      screen.getByRole("dialog", { name: "Confirm prune index" }),
    ).toBeInTheDocument();
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
