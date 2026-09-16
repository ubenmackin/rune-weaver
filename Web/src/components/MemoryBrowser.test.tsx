// Rune Weaver Dashboard — Component tests for MemoryBrowser search and facts management.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import MemoryBrowser from "./MemoryBrowser";

describe("MemoryBrowser", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  function stubFetch() {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input.startsWith("/memory/search")) {
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
        if (input === "/memory/facts" && init?.method === "POST") {
          return new Response(
            JSON.stringify({ id: "f1", content: "dog", source: "dashboard" }),
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
      }),
    );
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
});
