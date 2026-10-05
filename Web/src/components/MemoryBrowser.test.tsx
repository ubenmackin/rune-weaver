// Rune Weaver Dashboard — Component tests for tabbed Memory search, facts paging, and episodic recency.
// Purpose: pins the three inner tabs, Title Case headings, windowed reads,
// search timing, and scoped deletes without an unbounded list.
// Scope: tab labels with live counts, hash deep links, paged facts preview
// with More, and episodic cleanup behind modals only.
// Architectural role: guards the thin dashboard client so future edits cannot
// widen reads, lose timing, or collapse per-tab isolated state.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import MemoryBrowser, { getInitialMemoryTab } from "./MemoryBrowser";

describe("MemoryBrowser", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    if (typeof window !== "undefined") {
      window.location.hash = "";
      window.history.replaceState(null, "", "/");
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
      if (url.startsWith("/memory/facts") && init?.method === "POST") {
        return new Response(
          JSON.stringify({ id: "f1", content: "dog", source: "dashboard" }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(
          JSON.stringify({ episodes: [], count: 0 }),
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
      if (init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      // Paged facts window with live tallies for tab labels.
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
          total: 1,
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

  it("resolves the starting tab from memory hash suffixes", () => {
    window.location.hash = "#memory/search";
    expect(getInitialMemoryTab()).toBe("search");
    window.location.hash = "#memory/facts";
    expect(getInitialMemoryTab()).toBe("facts");
    window.location.hash = "#memory/episodes";
    expect(getInitialMemoryTab()).toBe("episodes");
    // Bare memory links open on Search so the first paint never strands.
    window.location.hash = "#memory";
    expect(getInitialMemoryTab()).toBe("search");
    // Unknown suffixes degrade to Search rather than blanking the pane.
    window.location.hash = "#memory/unknown";
    expect(getInitialMemoryTab()).toBe("search");
    window.location.hash = "";
  });

  it("renders three inner tabs with counts from facts tallies", async () => {
    stubFetch();
    render(<MemoryBrowser />);
    const tablist = await screen.findByRole("tablist", { name: "Memory views" });
    expect(tablist).toBeInTheDocument();
    // Tab labels carry live counts so the owner sees stored sizes at a glance.
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: /Facts \(1\)/ })).toBeInTheDocument();
    });
    expect(screen.getByRole("tab", { name: /Episodes \(2\)/ })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Search" })).toBeInTheDocument();
    // Search owns the default pane with its Title Case heading.
    expect(screen.getByRole("heading", { name: "Search" })).toBeInTheDocument();
  });

  it("searches memories, shows timing, and keeps facts untouched", async () => {
    const user = userEvent.setup();
    const fetchMock = stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: /Facts \(1\)/ })).toBeInTheDocument();
    });
    const factsCallsBefore = fetchMock.mock.calls.filter(([url]) =>
      String(url).startsWith("/memory/facts"),
    ).length;
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    // Timing line reports fetch milliseconds honestly.
    await waitFor(() => {
      expect(screen.getByText(/1 hits in \d+ms/)).toBeInTheDocument();
    });
    expect(screen.getAllByText("Dog named Biscuit").length).toBeGreaterThan(0);
    // Recall never refetches stored facts: the counts path stays quiet.
    const factsCallsAfter = fetchMock.mock.calls.filter(([url]) =>
      String(url).startsWith("/memory/facts"),
    ).length;
    expect(factsCallsAfter).toBe(factsCallsBefore);
  });

  it("disables Search while busy to prevent double submits", async () => {
    const user = userEvent.setup();
    let resolveSearch!: (value: Response) => void;
    const gate = new Promise<Response>((resolve) => {
      resolveSearch = resolve;
    });
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return gate;
      }
      return new Response(
        JSON.stringify({
          facts: [],
          total: 0,
          preferences: [],
          semanticCount: 0,
          episodeCount: 0,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByLabelText("Memory search")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    const searchButton = screen.getByRole("button", { name: "Search" });
    await user.click(searchButton);
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Search" })).toBeDisabled();
    });
    resolveSearch(
      new Response(JSON.stringify({ query: "dog", count: 0, memories: [] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Search" })).toBeEnabled();
    });
  });

  it("shows per-hit Delete only for episodic hits carrying an id", async () => {
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
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(JSON.stringify({ episodes: [], count: 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
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
      expect(screen.getByLabelText("Memory search")).toBeInTheDocument();
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

  it("confirms per-hit Search delete by metadata id and refreshes counts only", async () => {
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
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(JSON.stringify({ episodes: [], count: 0 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(
        JSON.stringify({
          facts: [],
          total: 0,
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
      expect(screen.getByLabelText("Memory search")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Deletable episodic turn")).toBeInTheDocument();
    });
    const factsCallsBefore = fetchMock.mock.calls.filter(([url]) =>
      String(url).startsWith("/memory/facts"),
    ).length;
    await user.click(screen.getByLabelText("Delete episodic result"));
    const dialog = screen.getByRole("dialog", {
      name: "Confirm delete episodic result",
    });
    expect(dialog).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "Confirm delete episodic result" }),
    );
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/memory/episodes/11111111-1111-1111-1111-111111111111",
        expect.objectContaining({ method: "DELETE" }),
      );
    });
    await waitFor(() => {
      expect(screen.queryByText("Deletable episodic turn")).not.toBeInTheDocument();
    });
    // Counts refresh on delete while the facts window itself is not re-paged
    // by the Search pane.
    await waitFor(() => {
      const factsCallsAfter = fetchMock.mock.calls.filter(([url]) =>
        String(url).startsWith("/memory/facts"),
      ).length;
      expect(factsCallsAfter).toBeGreaterThan(factsCallsBefore);
    });
  });

  it("loads Facts as a windowed preview with More and never unbounded", async () => {
    const user = userEvent.setup();
    const seenFacts: string[] = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/facts") && init?.method === "POST") {
        return new Response(
          JSON.stringify({ id: "f-new", content: "new", source: "dashboard" }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/facts")) {
        seenFacts.push(url);
        const parsed = new URL(url, "http://localhost");
        const offset = Number(parsed.searchParams.get("offset") ?? "0");
        const all = [
          {
            id: "f1",
            content: "First fact",
            confidence: 1,
            source: "dashboard",
            lastConfirmed: new Date(0).toISOString(),
          },
          {
            id: "f2",
            content: "Second fact",
            confidence: 1,
            source: "dashboard",
            lastConfirmed: new Date(0).toISOString(),
          },
        ];
        const windowed = all.slice(offset, offset + 1);
        return new Response(
          JSON.stringify({
            facts: windowed,
            total: all.length,
            preferences: [],
            semanticCount: 1,
            episodeCount: 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({ query: "", count: 0, memories: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(JSON.stringify({ episodes: [], count: 0 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Facts/ }));
    // Title Case headings own the Facts pane plus its Knowledge section.
    await waitFor(() => {
      expect(screen.getByRole("heading", { name: "Facts" })).toBeInTheDocument();
    });
    expect(screen.getByRole("heading", { name: "Knowledge" })).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByText("First fact")).toBeInTheDocument();
    });
    expect(screen.queryByText("Second fact")).not.toBeInTheDocument();
    // Every facts read stays windowed; no unbounded list-all ever fires.
    expect(seenFacts.length).toBeGreaterThan(0);
    for (const entry of seenFacts) {
      const parsed = new URL(entry, "http://localhost");
      expect(parsed.searchParams.get("limit")).toBe("20");
      expect(parsed.searchParams.get("offset")).not.toBeNull();
    }
    await user.click(screen.getByRole("button", { name: "More" }));
    await waitFor(() => {
      expect(screen.getByText("Second fact")).toBeInTheDocument();
    });
    expect(
      seenFacts.some((entry) => entry.includes("offset=1")),
    ).toBe(true);
  });

  it("searches Facts by substring and offers Show Recent 20", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/facts") && init?.method !== "POST") {
        seen.push(url);
        const parsed = new URL(url, "http://localhost");
        const q = parsed.searchParams.get("q") ?? "";
        const facts =
          q === "biscuit"
            ? [
                {
                  id: "f1",
                  content: "Dog named Biscuit",
                  confidence: 1,
                  source: "dashboard",
                  lastConfirmed: new Date(0).toISOString(),
                },
              ]
            : [];
        return new Response(
          JSON.stringify({
            facts,
            total: facts.length,
            preferences: [],
            semanticCount: 1,
            episodeCount: 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(JSON.stringify({ episodes: [], count: 0 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({ query: "", count: 0, memories: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Facts/ }));
    await waitFor(() => {
      expect(screen.getByLabelText("Search facts")).toBeInTheDocument();
    });
    // Blank search stays disabled so padding cannot fire an empty query.
    expect(screen.getByRole("button", { name: "Search" })).toBeDisabled();
    await user.type(screen.getByLabelText("Search facts"), "biscuit");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    expect(seen.some((entry) => entry.includes("q=biscuit"))).toBe(true);
    expect(
      screen.getByRole("button", { name: "Show Recent 20" }),
    ).toBeInTheDocument();
  });

  it("stores a fact from the Facts tab and keeps Add blank-disabled", async () => {
    const user = userEvent.setup();
    stubFetch();
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Facts/ }));
    await waitFor(() => {
      expect(screen.getByLabelText("New fact")).toBeInTheDocument();
    });
    // Whitespace-only input counts as blank so padding cannot store empties.
    expect(screen.getByRole("button", { name: "Remember" })).toBeDisabled();
    await user.type(screen.getByLabelText("New fact"), "   ");
    expect(screen.getByRole("button", { name: "Remember" })).toBeDisabled();
    await user.clear(screen.getByLabelText("New fact"));
    await user.type(screen.getByLabelText("New fact"), "Cats like sun");
    expect(screen.getByRole("button", { name: "Remember" })).toBeEnabled();
    await user.click(screen.getByRole("button", { name: "Remember" }));
    await waitFor(() => {
      expect(screen.getByText(/1 total/)).toBeInTheDocument();
    });
  });

  it("confirms persisted fact deletion through the shared modal", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({ query: "dog", count: 0, memories: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(JSON.stringify({ episodes: [], count: 0 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
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
          total: 1,
          preferences: [],
          semanticCount: 1,
          episodeCount: 2,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Facts/ }));
    await waitFor(() => {
      expect(screen.getByText("Dog named Biscuit")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Delete fact f1" }));
    const dialog = screen.getByRole("dialog", { name: "Confirm delete fact" });
    expect(dialog).toBeInTheDocument();
    expect(dialog).toHaveTextContent("Dog named Biscuit");
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining("/memory/facts/"),
      expect.objectContaining({ method: "DELETE" }),
    );
    await user.click(screen.getByRole("button", { name: "Keep" }));
    expect(
      screen.queryByRole("dialog", { name: "Confirm delete fact" }),
    ).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Delete fact f1" }));
    await user.click(screen.getByRole("button", { name: "Confirm delete fact" }));
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/memory/facts/f1",
        expect.objectContaining({ method: "DELETE" }),
      );
    });
  });

  it("truncates long fact previews to 120 characters in the modal", async () => {
    const user = userEvent.setup();
    const longContent = "m".repeat(200);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(JSON.stringify({ episodes: [], count: 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        if (url.startsWith("/memory/search")) {
          return new Response(
            JSON.stringify({ query: "", count: 0, memories: [] }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response(
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
            total: 1,
            preferences: [],
            semanticCount: 1,
            episodeCount: 1,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Facts/ }));
    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: "Delete fact f-long" }),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Delete fact f-long" }));
    const dialog = screen.getByRole("dialog", { name: "Confirm delete fact" });
    expect(dialog).toHaveTextContent(`${"m".repeat(120)}…`);
    expect(dialog).not.toHaveTextContent(longContent);
  });

  it("renders Episodes recency with Title Case cleanup controls", async () => {
    const user = userEvent.setup();
    stubFetch();
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: "Episodic Cleanup" }),
      ).toBeInTheDocument();
    });
    expect(screen.getByLabelText("Session UUID")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Clear all episodes" }),
    ).toBeInTheDocument();
    // Blank session input disables only its own button.
    expect(screen.getByRole("button", { name: "Clear session" })).toBeDisabled();
  });

  it("disables both danger buttons when no episodic turns are stored", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(JSON.stringify({ episodes: [], count: 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
            preferences: [],
            semanticCount: 0,
            episodeCount: 0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
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
    const user = userEvent.setup();
    stubFetch();
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
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

  it("confirms clear-all behind a modal and reloads recency", async () => {
    const user = userEvent.setup();
    let cleared = false;
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({ query: "dog", count: 0, memories: [] }),
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
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(
          JSON.stringify({ episodes: [], count: 0 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.startsWith("/memory/facts")) {
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
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
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Clear all episodes" }));
    const dialog = screen.getByRole("dialog", {
      name: "Confirm clear all episodes",
    });
    expect(dialog).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalledWith(
      "/memory/episodes",
      expect.objectContaining({ method: "DELETE" }),
    );
    await user.click(screen.getByRole("button", { name: "Keep" }));
    expect(
      screen.queryByRole("dialog", { name: "Confirm clear all episodes" }),
    ).not.toBeInTheDocument();
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
      expect(screen.getByText("0 episodic turns stored")).toBeInTheDocument();
    });
  });

  it("confirms session clear with the typed session id", async () => {
    const user = userEvent.setup();
    const sessionID = "22222222-2222-2222-2222-222222222222";
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/search")) {
        return new Response(
          JSON.stringify({ query: "dog", count: 0, memories: [] }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (
        url === `/memory/episodes/session/${sessionID}` &&
        init?.method === "DELETE"
      ) {
        return new Response(null, { status: 204 });
      }
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(JSON.stringify({ episodes: [], count: 0 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(
        JSON.stringify({
          facts: [],
          total: 0,
          preferences: [],
          semanticCount: 0,
          episodeCount: 2,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(screen.getByText("2 episodic turns stored")).toBeInTheDocument();
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
  });

  it("syncs inner tabs from hash changes while open", async () => {
    stubFetch();
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: "Search" })).toBeInTheDocument();
    });
    window.location.hash = "#memory/facts";
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    await waitFor(() => {
      expect(screen.getByRole("heading", { name: "Facts" })).toBeInTheDocument();
    });
    window.location.hash = "#memory/episodes";
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: "Episodic Cleanup" }),
      ).toBeInTheDocument();
    });
    window.location.hash = "";
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

  it("keeps isolated errors per tab", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.startsWith("/memory/search")) {
          return new Response("nope", { status: 500 });
        }
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(JSON.stringify({ episodes: [], count: 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
            preferences: [],
            semanticCount: 0,
            episodeCount: 0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await waitFor(() => {
      expect(screen.getByLabelText("Memory search")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Memory search"), "dog");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => {
      // Search owns its failure without spilling into other panes.
      expect(screen.getByText(/Search failed|500|nope/)).toBeInTheDocument();
    });
    await user.click(screen.getByRole("tab", { name: /Facts/ }));
    await waitFor(() => {
      expect(screen.getByRole("heading", { name: "Facts" })).toBeInTheDocument();
    });
    // Facts stays clean while Search holds its error: the pane settles to its
    // own empty copy (initial hint or windowed counts) without the recall
    // failure, so either copy proves isolation from the Search tab error.
    await waitFor(() => {
      const panel = screen.getByRole("tabpanel", { name: "Facts" });
      expect(
        within(panel).queryByText(/Search failed|500|nope/),
      ).not.toBeInTheDocument();
      expect(
        within(panel).queryByText(/Search or show recent|0 shown/),
      ).toBeInTheDocument();
    });
  });

  it("finds episodic turns by contents and filters to episodic source", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.startsWith("/memory/search")) {
          seen.push(url);
          return new Response(
            JSON.stringify({
              query: "biscuit",
              count: 2,
              memories: [
                {
                  content: "Biscuit episode",
                  score: 0.9,
                  source: "episodic",
                  metadata: {
                    id: "11111111-1111-1111-1111-111111111111",
                    session_id: "22222222-2222-2222-2222-222222222222",
                    role: "user",
                  },
                },
                {
                  content: "Biscuit fact",
                  score: 0.8,
                  source: "semantic",
                  metadata: { id: "semantic-1" },
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(JSON.stringify({ episodes: [], count: 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
            preferences: [],
            semanticCount: 1,
            episodeCount: 1,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(
        screen.getByLabelText("Search episodic contents"),
      ).toBeInTheDocument();
    });
    // Blank contents query disables its own Search so padding never fires.
    const panel = screen.getByRole("tabpanel", { name: "Episodes" });
    expect(
      within(panel).getByRole("button", { name: "Search" }),
    ).toBeDisabled();
    await user.type(
      screen.getByLabelText("Search episodic contents"),
      "biscuit",
    );
    await user.click(within(panel).getByRole("button", { name: "Search" }));
    await waitFor(() => {
      expect(screen.getByText("Biscuit episode")).toBeInTheDocument();
    });
    // Semantic hits never enter the finder window.
    expect(screen.queryByText("Biscuit fact")).not.toBeInTheDocument();
    expect(screen.getByText(/1 turns shown/)).toBeInTheDocument();
    const searched = seen.find((entry) => entry.startsWith("/memory/search"));
    expect(searched).toBeDefined();
    const parsed = new URL(searched as string, "http://localhost");
    expect(parsed.searchParams.get("limit")).toBe("50");
  });

  it("shows recent finder turns and previews one session", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string) => {
      const url = String(input);
      seen.push(url);
      if (url.startsWith("/memory/episodes/recent")) {
        const parsed = new URL(url, "http://localhost");
        const sessionID = parsed.searchParams.get("sessionID");
        const episodes =
          sessionID === "22222222-2222-2222-2222-222222222222"
            ? [
                {
                  id: "33333333-3333-3333-3333-333333333333",
                  sessionID,
                  role: "user",
                  content: "Session preview turn",
                  timestamp: 1700000000,
                },
              ]
            : [
                {
                  id: "11111111-1111-1111-1111-111111111111",
                  sessionID: "22222222-2222-2222-2222-222222222222",
                  role: "user",
                  content: "Recent turn one",
                  timestamp: 1700000000,
                },
                {
                  id: "44444444-4444-4444-4444-444444444444",
                  sessionID: "55555555-5555-5555-5555-555555555555",
                  role: "assistant",
                  content: "Recent turn two",
                  timestamp: 1700000100,
                },
              ];
        return new Response(JSON.stringify({ episodes, count: episodes.length }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(
        JSON.stringify({
          facts: [],
          total: 0,
          preferences: [],
          semanticCount: 0,
          episodeCount: 2,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(screen.getByText("Recent turn one")).toBeInTheDocument();
    });
    expect(screen.getByText(/2 turns shown/)).toBeInTheDocument();
    expect(seen.some((entry) => entry.includes("limit=20"))).toBe(true);
    await user.type(
      screen.getByLabelText("Session UUID"),
      "22222222-2222-2222-2222-222222222222",
    );
    await user.click(screen.getByRole("button", { name: "Preview" }));
    await waitFor(() => {
      expect(screen.getByText("Session preview turn")).toBeInTheDocument();
    });
    expect(
      seen.some((entry) =>
        entry.includes("sessionID=22222222-2222-2222-2222-222222222222"),
      ),
    ).toBe(true);
  });

  it("deletes exactly the shown finder set behind confirm and refetches", async () => {
    const user = userEvent.setup();
    const deleted: string[] = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("/memory/episodes/recent")) {
        return new Response(
          JSON.stringify({
            episodes:
              deleted.length > 0
                ? []
                : [
                    {
                      id: "11111111-1111-1111-1111-111111111111",
                      sessionID: "22222222-2222-2222-2222-222222222222",
                      role: "user",
                      content: "Shown turn one",
                      timestamp: 1700000000,
                    },
                    {
                      id: "44444444-4444-4444-4444-444444444444",
                      sessionID: "22222222-2222-2222-2222-222222222222",
                      role: "assistant",
                      content: "Shown turn two",
                      timestamp: 1700000100,
                    },
                  ],
            count: deleted.length > 0 ? 0 : 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (
        url.startsWith("/memory/episodes/") &&
        init?.method === "DELETE" &&
        !url.includes("/session/")
      ) {
        deleted.push(url);
        return new Response(null, { status: 204 });
      }
      return new Response(
        JSON.stringify({
          facts: [],
          total: 0,
          preferences: [],
          semanticCount: 0,
          episodeCount: 2,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(screen.getByText("Shown turn one")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Delete All Shown" }));
    const dialog = screen.getByRole("dialog", {
      name: "Confirm delete shown episodes",
    });
    expect(dialog).toHaveTextContent("2 episodic turns");
    await user.click(
      screen.getByRole("button", { name: "Confirm delete shown episodes" }),
    );
    await waitFor(() => {
      expect(deleted).toContain(
        "/memory/episodes/11111111-1111-1111-1111-111111111111",
      );
    });
    await waitFor(() => {
      expect(deleted).toContain(
        "/memory/episodes/44444444-4444-4444-4444-444444444444",
      );
    });
    expect(deleted).toHaveLength(2);
  });

  it("stops a shown-set delete on the first failure", async () => {
    const user = userEvent.setup();
    const deleted: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const url = String(input);
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(
            JSON.stringify({
              episodes: [
                {
                  id: "11111111-1111-1111-1111-111111111111",
                  sessionID: "22222222-2222-2222-2222-222222222222",
                  role: "user",
                  content: "Shown turn one",
                  timestamp: 1700000000,
                },
                {
                  id: "44444444-4444-4444-4444-444444444444",
                  sessionID: "22222222-2222-2222-2222-222222222222",
                  role: "assistant",
                  content: "Shown turn two",
                  timestamp: 1700000100,
                },
              ],
              count: 2,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (
          url === "/memory/episodes/11111111-1111-1111-1111-111111111111" &&
          init?.method === "DELETE"
        ) {
          deleted.push(url);
          return new Response(JSON.stringify({ reason: "denied" }), {
            status: 403,
            headers: { "Content-Type": "application/json" },
          });
        }
        if (url.startsWith("/memory/episodes/") && init?.method === "DELETE") {
          deleted.push(url);
          return new Response(null, { status: 204 });
        }
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
            preferences: [],
            semanticCount: 0,
            episodeCount: 2,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(screen.getByText("Shown turn one")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Delete All Shown" }));
    await user.click(
      screen.getByRole("button", { name: "Confirm delete shown episodes" }),
    );
    await waitFor(() => {
      expect(deleted).toHaveLength(1);
    });
    expect(deleted[0]).toBe(
      "/memory/episodes/11111111-1111-1111-1111-111111111111",
    );
  });

  it("shows the finder empty state and separates Clear All behind a divider", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.startsWith("/memory/episodes/recent")) {
          return new Response(JSON.stringify({ episodes: [], count: 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        if (url.startsWith("/memory/search")) {
          return new Response(
            JSON.stringify({ query: "zzz", count: 0, memories: [] }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response(
          JSON.stringify({
            facts: [],
            total: 0,
            preferences: [],
            semanticCount: 0,
            episodeCount: 0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );
    render(<MemoryBrowser />);
    await user.click(screen.getByRole("tab", { name: /Episodes/ }));
    await waitFor(() => {
      expect(
        screen.getByText("No episodic turns match with current query"),
      ).toBeInTheDocument();
    });
    // Spacing contract keeps section cards apart and the whole-store clear
    // behind its own divider instead of crowding the session row.
    expect(
      document.querySelector(".memory-section-card"),
    ).not.toBeNull();
    expect(document.querySelector(".episodic-session-row")).not.toBeNull();
    expect(document.querySelector(".episodic-clear-all-row")).not.toBeNull();
  });
});
