// Rune Weaver Dashboard — Component tests for MemoryBrowser search and facts management.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import MemoryBrowser from "./MemoryBrowser";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";

describe("MemoryBrowser", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    if (typeof window !== "undefined") {
      window.location.hash = "";
    }
  });

  function stubFetch() {
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({
            query: "dog",
            count: 1,
            memories: [
              {
                content: "Dog named Biscuit",
                score: 0.9,
                source: "profile",
                metadata: {},
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url === "/memory/facts" && init?.method === "POST") {
        return new Response(
          JSON.stringify({ id: "f1", content: "dog", source: "dashboard" }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url === "/index/status") {
        return new Response(
          JSON.stringify({
            enabled: false,
            running: false,
            documents: 0,
            chunks: 0,
            vectorChunks: 0,
            keywordChunks: 0,
            bytes: 0,
            indexAsOf: null,
            sources: [],
            lastErrors: [],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url === "/settings") {
        return new Response(
          JSON.stringify({
            engineName: "Test Engine",
            index: {
              enabled: false,
              files: true,
              mail: false,
              messages: false,
              roots: ["~"],
              exclude: [],
              max_file_mb: 20,
              mail_vector_window: "2y",
              icloud_evicted: "skip",
              describe_images_with_llm: false,
              nightly_budget: 0,
              db_path: "~/.runeweaver/index.db",
            },
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response(
        JSON.stringify({
          facts: [
            {
              id: "f1",
              content: "Dog named Biscuit",
              confidence: 1,
              source: "dashboard",
              lastConfirmed: new Date(0).toISOString(),
            },
          ],
          preferences: [],
          semanticCount: 1,
          episodeCount: 2,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  it("searches memories and shows the browser counts", async () => {
    const user = userEvent.setup();
    stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getAllByText("Dog named Biscuit").length).toBeGreaterThan(1);
    });
    expect(screen.getByText(/1 facts/)).toBeInTheDocument();
  });

  it("stores a fact from the facts browser", async () => {
    const user = userEvent.setup();
    stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("New fact"), "Cats like sun");
    await user.click(screen.getByRole("button", { name: "Remember" }));
    await waitFor(() => {
      expect(screen.getByText(/1 facts/)).toBeInTheDocument();
    });
  });

  it("confirms persisted fact deletion through the shared modal", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      if (init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      if (input.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({ query: "dog", count: 0, memories: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response(
        JSON.stringify({
          facts: [
            {
              id: "f1",
              content: "Dog named Biscuit",
              confidence: 1,
              source: "dashboard",
              lastConfirmed: new Date(0).toISOString(),
            },
          ],
          preferences: [],
          semanticCount: 1,
          episodeCount: 2,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });

    // Trash stages a confirmation instead of deleting immediately.
    await user.click(screen.getByRole("button", { name: "Delete fact f1" }));
    const dialog = screen.getByRole("dialog", { name: "Confirm delete fact" });
    expect(dialog).toBeInTheDocument();
    expect(dialog).toHaveTextContent("Dog named Biscuit");
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining("/memory/facts/"),
      expect.objectContaining({ method: "DELETE" }),
    );

    // Keep dismisses without a request.
    await user.click(screen.getByRole("button", { name: "Keep" }));
    expect(screen.queryByRole("dialog", { name: "Confirm delete fact" })).not.toBeInTheDocument();
    expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();

    // Delete confirms the persisted removal.
    await user.click(screen.getByRole("button", { name: "Delete fact f1" }));
    await user.click(screen.getByRole("button", { name: "Confirm delete fact" }));
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/memory/facts/f1",
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    await waitFor(() => {
      expect(
        screen.queryByRole("dialog", { name: "Confirm delete fact" }),
      ).not.toBeInTheDocument();
    });
  });

  it("truncates long fact previews to 120 characters in the modal", async () => {
    const user = userEvent.setup();
    const longContent = "m".repeat(200);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            facts: [
              {
                id: "f-long",
                content: longContent,
                confidence: 1,
                source: "dashboard",
                lastConfirmed: new Date(0).toISOString(),
              },
            ],
            preferences: [],
            semanticCount: 1,
            episodeCount: 1,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Delete fact f-long" })).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Delete fact f-long" }));
    const dialog = screen.getByRole("dialog", { name: "Confirm delete fact" });
    // Bounded preview keeps the dialog compact while identifying the row.
    expect(dialog).toHaveTextContent(`${"m".repeat(120)}…`);
    expect(dialog).not.toHaveTextContent(longContent);
  });

  it("renders Memory search view by default without in-page tab bar", async () => {
    stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    expect(screen.getByRole("heading", { name: "Memory" })).toBeInTheDocument();
    expect(
      screen.getByText(
        "Search episodic recall and semantic memory, manage stored user facts.",
      ),
    ).toBeInTheDocument();
    // Tab bar is removed; views are driven by the Memory dropdown
    expect(screen.queryByRole("tablist", { name: "Memory views" })).toBeNull();
  });

  it("offers no manual Refresh buttons on either view", async () => {
    stubFetch();
    const { rerender } = render(<MemoryBrowser view="memory" />);
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    // Search view has no manual refresh; freshness comes from the socket.
    expect(
      screen.queryByRole("button", { name: /Refresh/i }),
    ).not.toBeInTheDocument();

    // Index view also has no manual refresh.
    rerender(<MemoryBrowser view="indexing" />);
    await waitFor(() => {
      expect(
        screen.getByText("Monitor the local file, mail, and Messages index."),
      ).toBeInTheDocument();
    });
    expect(
      screen.queryByRole("button", { name: /Refresh/i }),
    ).not.toBeInTheDocument();
  });

  it("renders Index Status view with view prop or indexing hash", async () => {
    stubFetch();
    const { rerender } = render(<MemoryBrowser view="indexing" />);
    await waitFor(() => {
      expect(
        screen.getByText("Monitor the local file, mail, and Messages index."),
      ).toBeInTheDocument();
    });
    expect(screen.getByRole("heading", { name: "Index Status" })).toBeInTheDocument();

    // Also supports URL hash change when rendered standalone
    rerender(<MemoryBrowser />);
    window.location.hash = "#indexing";
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    await waitFor(() => {
      expect(
        screen.getByText("Monitor the local file, mail, and Messages index."),
      ).toBeInTheDocument();
    });
    window.location.hash = "";
  });

  it("auto-reloads facts on run_completed without manual refresh", async () => {
    const capture = createMockWebSocketCapture();
    const fetchMock = stubFetch();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    const initialFactsCalls = fetchMock.mock.calls.filter(
      ([url]) => String(url) === "/memory/facts",
    ).length;
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "run_completed",
      run: { status: "ok" },
    });
    await waitFor(() => {
      const nextFactsCalls = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/memory/facts",
      ).length;
      expect(nextFactsCalls).toBeGreaterThan(initialFactsCalls);
    });
  });

  it("renders the episodic cleanup count from facts", async () => {
    // The footer count mirrors the facts payload so the panel never drifts
    // from the stored store; a non-zero store keeps the whole-store path
    // enabled while an empty session input keeps only its own button parked.
    stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
    });
    expect(
      screen.getByRole("heading", { name: "Episodic cleanup" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Clear all episodes" }),
    ).toBeEnabled();
    // Blank session input disables its own button without parking the
    // whole-store path.
    expect(screen.getByRole("button", { name: "Clear session" })).toBeDisabled();
    expect(screen.getByLabelText("Session UUID")).toBeInTheDocument();
  });

  it("disables both danger buttons when no episodic turns are stored", async () => {
    // A zero count disables both destructive footer buttons with an honest
    // title so an empty store cannot confirm a no-op clear.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            facts: [],
            preferences: [],
            semanticCount: 0,
            episodeCount: 0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("0 episodic turns stored")).toBeInTheDocument();
    });
    const clearAll = screen.getByRole("button", { name: "Clear all episodes" });
    const clearSession = screen.getByRole("button", { name: "Clear session" });
    expect(clearAll).toBeDisabled();
    expect(clearSession).toBeDisabled();
    expect(clearAll).toHaveAttribute("title", "No episodic turns stored");
    expect(clearSession).toHaveAttribute("title", "No episodic turns stored");
  });

  it("keeps Clear session disabled on blank input and enables it once typed", async () => {
    // Whitespace-only input counts as blank so padding cannot arm a session
    // clear that would reject server-side.
    const user = userEvent.setup();
    stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
    });
    const clearSession = screen.getByRole("button", { name: "Clear session" });
    expect(clearSession).toBeDisabled();
    await user.type(screen.getByLabelText("Session UUID"), "   ");
    expect(screen.getByRole("button", { name: "Clear session" })).toBeDisabled();
    await user.clear(screen.getByLabelText("Session UUID"));
    await user.type(
      screen.getByLabelText("Session UUID"),
      "22222222-2222-2222-2222-222222222222",
    );
    expect(screen.getByRole("button", { name: "Clear session" })).toBeEnabled();
  });

  it("shows per-hit Delete only for episodic hits carrying an id", async () => {
    // Semantic and id-less episodic rows have no addressable episode row, so
    // only the episodic hit with metadata id offers the trash affordance.
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const url = String(input);
        if (url.startsWith("/memory/search")) {
          return new Response(
            JSON.stringify({
              query: "dog",
              count: 3,
              memories: [
                {
                  content: "Episodic turn with id",
                  score: 0.9,
                  source: "episodic",
                  metadata: { id: "11111111-1111-1111-1111-111111111111" },
                },
                {
                  content: "Episodic turn without id",
                  score: 0.8,
                  source: "episodic",
                  metadata: {},
                },
                {
                  content: "Semantic fact with id",
                  score: 0.7,
                  source: "semantic",
                  metadata: { id: "semantic-1" },
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (init?.method === "DELETE") {
          return new Response(null, { status: 204 });
        }
        return new Response(
          JSON.stringify({
            facts: [],
            preferences: [],
            semanticCount: 1,
            episodeCount: 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Episodic turn with id")).toBeInTheDocument();
    });
    expect(screen.getByText("Episodic turn without id")).toBeInTheDocument();
    expect(screen.getByText("Semantic fact with id")).toBeInTheDocument();
    // Exactly one trash affordance: the addressable episodic hit.
    expect(screen.getAllByLabelText("Delete episodic result")).toHaveLength(1);
  });

  it("confirms per-hit episodic delete by metadata id, drops the row, and reloads facts", async () => {
    // Confirming through the centered modal deletes by metadata id, drops only
    // that row locally, and reloads facts so the footer count settles.
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({
            query: "dog",
            count: 1,
            memories: [
              {
                content: "Deletable episodic turn",
                score: 0.9,
                source: "episodic",
                metadata: { id: "11111111-1111-1111-1111-111111111111" },
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (
        url === "/memory/episodes/11111111-1111-1111-1111-111111111111" &&
        init?.method === "DELETE"
      ) {
        return new Response(null, { status: 204 });
      }
      return new Response(
        JSON.stringify({
          facts: [],
          preferences: [],
          semanticCount: 0,
          episodeCount: 1,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("1 episodic turns stored")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Deletable episodic turn")).toBeInTheDocument();
    });
    await user.click(screen.getByLabelText("Delete episodic result"));
    const dialog = screen.getByRole("dialog", {
      name: "Confirm delete episodic result",
    });
    expect(dialog).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining("/memory/episodes/"),
      expect.objectContaining({ method: "DELETE" }),
    );
    await user.click(
      screen.getByRole("button", { name: "Confirm delete episodic result" }),
    );
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/memory/episodes/11111111-1111-1111-1111-111111111111",
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    // The row drops locally and facts refetch on the same success path.
    await waitFor(() => {
      expect(
        screen.queryByText("Deletable episodic turn"),
      ).not.toBeInTheDocument();
    });
    const factsCalls = fetchMock.mock.calls.filter(
      ([url]) => String(url) === "/memory/facts",
    ).length;
    expect(factsCalls).toBeGreaterThan(1);
    expect(
      screen.queryByRole("dialog", { name: "Confirm delete episodic result" }),
    ).not.toBeInTheDocument();
  });

  it("confirms clear-all behind a modal, calls DELETE, refetches facts, and drops hits", async () => {
    // The whole-store clear stages behind Keep/Clear all, posts DELETE to the
    // collection, then refetches facts and clears stale hits on success.
    const user = userEvent.setup();
    let cleared = false;
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({
            query: "dog",
            count: 1,
            memories: [
              {
                content: "Stale episodic hit",
                score: 0.9,
                source: "episodic",
                metadata: { id: "11111111-1111-1111-1111-111111111111" },
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url === "/memory/episodes" && init?.method === "DELETE") {
        cleared = true;
        return new Response(
          JSON.stringify({ deletedCount: 2, episodeCount: 0 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url === "/memory/facts") {
        return new Response(
          JSON.stringify({
            facts: [],
            preferences: [],
            semanticCount: 0,
            episodeCount: cleared ? 0 : 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Stale episodic hit")).toBeInTheDocument();
    });
    const initialFactsCalls = fetchMock.mock.calls.filter(
      ([url]) => String(url) === "/memory/facts",
    ).length;
    await user.click(screen.getByRole("button", { name: "Clear all episodes" }));
    const dialog = screen.getByRole("dialog", {
      name: "Confirm clear all episodes",
    });
    expect(dialog).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalledWith(
      "/memory/episodes",
      expect.objectContaining({ method: "DELETE" }),
    );
    // Keep dismisses without a request.
    await user.click(screen.getByRole("button", { name: "Keep" }));
    expect(
      screen.queryByRole("dialog", { name: "Confirm clear all episodes" }),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Stale episodic hit")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Clear all episodes" }));
    await user.click(
      screen.getByRole("button", { name: "Confirm clear all episodes" }),
    );
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/memory/episodes",
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    await waitFor(() => {
      const nextFactsCalls = fetchMock.mock.calls.filter(
        ([url]) => String(url) === "/memory/facts",
      ).length;
      expect(nextFactsCalls).toBeGreaterThan(initialFactsCalls);
    });
    await waitFor(() => {
      expect(screen.queryByText("Stale episodic hit")).not.toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText("0 episodic turns stored")).toBeInTheDocument();
    });
  });

  it("confirms session clear with the typed session id and drops hits", async () => {
    // The session path posts to the literal session route with the encoded id,
    // then follows the same refetch plus drop-hits success contract.
    const user = userEvent.setup();
    let cleared = false;
    const sessionID = "22222222-2222-2222-2222-222222222222";
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({
            query: "dog",
            count: 1,
            memories: [
              {
                content: "Session episodic hit",
                score: 0.9,
                source: "episodic",
                metadata: { id: "episode-1" },
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (
        url === `/memory/episodes/session/${sessionID}` &&
        init?.method === "DELETE"
      ) {
        cleared = true;
        return new Response(null, { status: 204 });
      }
      if (url === "/memory/facts") {
        return new Response(
          JSON.stringify({
            facts: [],
            preferences: [],
            semanticCount: 0,
            episodeCount: cleared ? 0 : 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Session episodic hit")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Session UUID"), sessionID);
    await user.click(screen.getByRole("button", { name: "Clear session" }));
    expect(
      screen.getByRole("dialog", { name: "Confirm clear session episodes" }),
    ).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "Confirm clear session episodes" }),
    );
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/memory/episodes/session/${sessionID}`,
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    await waitFor(() => {
      expect(
        screen.queryByText("Session episodic hit"),
      ).not.toBeInTheDocument();
    });
  });
});
