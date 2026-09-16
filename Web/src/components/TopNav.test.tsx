// Rune Weaver Dashboard — Component tests for TopNav SearXNG health surfacing.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import TopNav from "./TopNav";
import {
  DEFAULT_SEARCH_MAX_RESULTS,
  DEFAULT_SEARCH_SEARXNG_URL,
} from "../api";
import { jsonResponse } from "../test-utils/http";

const ENGINE_SEARCH_URL = "http://127.0.0.1:8888";

function renderNav(health: Record<string, unknown> | null) {
  return render(
    <TopNav
      currentTab="chat"
      onSelectTab={() => {}}
      health={health as never}
      runsBadge={0}
      approvalsBadge={0}
      notificationsEnabled={false}
      onRequestNotifications={() => {}}
    />
  );
}

async function openProfile(user: ReturnType<typeof userEvent.setup>) {
  const profileBtn = screen.getByRole("button", {
    name: /Profile and Settings menu/i,
  });
  await user.click(profileBtn);
  await waitFor(() => {
    expect(screen.getByTestId("searxng-status-dot")).toBeInTheDocument();
  });
}

describe("TopNav SearXNG row", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("pins frontend search defaults to the engine BrowserConfig", () => {
    // Mirrors BrowserConfig.defaultSearxngURL and defaultMaxResults in
    // Sources/RuneWeaverCore/Config.swift plus config.toml.example/CONFIG.md
    // so a drift fails here instead of shipping a mismatched exemption.
    expect(DEFAULT_SEARCH_SEARXNG_URL).toBe("http://127.0.0.1:8888");
    expect(DEFAULT_SEARCH_MAX_RESULTS).toBe(10);
  });

  it("shows a green dot and Running when search is reachable", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reachable: true, url: "http://x" }))
    );
    renderNav({
      status: "ok",
      engine: "Rune Weaver",
      version: "0.1.0",
      model: "gemma-4-9b",
      provider: "mlx",
      searchReachable: true,
      searchURL: ENGINE_SEARCH_URL,
    });
    await openProfile(user);
    const dot = screen.getByTestId("searxng-status-dot");
    expect(dot.getAttribute("aria-label")).toBe("SearXNG reachable");
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Running"
    );
    // Green dot for the reachable state.
    expect(dot.style.backgroundColor).toContain("52, 211, 153");
    expect(screen.getByText("SearXNG")).toBeInTheDocument();
    expect(dot.getAttribute("title")).toContain(ENGINE_SEARCH_URL);
  });

  it("shows a red dot and Stopped when search is unreachable", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reachable: false, url: "http://x" }))
    );
    renderNav({
      status: "ok",
      engine: "Rune Weaver",
      version: "0.1.0",
      searchReachable: false,
      searchURL: ENGINE_SEARCH_URL,
    });
    await openProfile(user);
    const dot = screen.getByTestId("searxng-status-dot");
    expect(dot.getAttribute("aria-label")).toBe("SearXNG stopped");
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Stopped"
    );
    // Red dot for the stopped state.
    expect(dot.style.backgroundColor).toContain("245, 101, 101");
  });

  it("falls back to unknown with the default URL when health lacks search fields", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderNav({
      status: "ok",
      engine: "Rune Weaver",
      version: "0.1.0",
    });
    await openProfile(user);
    const dot = screen.getByTestId("searxng-status-dot");
    // Older engines predate search fields: unknown renders gray Unknown,
    // never red Stopped.
    expect(dot.getAttribute("aria-label")).toBe("SearXNG status unknown");
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Unknown"
    );
    expect(dot.getAttribute("title")).toContain(ENGINE_SEARCH_URL);
    expect(dot.getAttribute("title")).toContain(DEFAULT_SEARCH_SEARXNG_URL);
  });

  it("shows unknown gray when the health probe fails", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("Network request failed");
      })
    );
    renderNav({
      status: "ok",
      engine: "Rune Weaver",
      version: "0.1.0",
    });
    await openProfile(user);
    const dot = screen.getByTestId("searxng-status-dot");
    expect(dot.getAttribute("aria-label")).toBe("SearXNG status unknown");
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Unknown"
    );
  });

  it("hits the ensure path when starting from stopped", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        seen.push(String(input));
        if (String(input) === "/search/ensure" && init?.method === "POST") {
          return jsonResponse({
            reachable: true,
            url: ENGINE_SEARCH_URL,
          });
        }
        return jsonResponse({});
      })
    );
    renderNav({
      status: "ok",
      engine: "Rune Weaver",
      version: "0.1.0",
      searchReachable: false,
      searchURL: ENGINE_SEARCH_URL,
    });
    await openProfile(user);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startBtn);
    await waitFor(() => {
      expect(seen).toContain("/search/ensure");
      expect(screen.getByTestId("searxng-status-text").textContent).toBe(
        "Running"
      );
    });
  });

  it("hits the stop path when stopping from running", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        seen.push(String(input));
        if (String(input) === "/search/stop" && init?.method === "POST") {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        return jsonResponse({});
      })
    );
    renderNav({
      status: "ok",
      engine: "Rune Weaver",
      version: "0.1.0",
      searchReachable: true,
      searchURL: ENGINE_SEARCH_URL,
    });
    await openProfile(user);
    const stopBtn = screen.getByRole("button", { name: "Stop SearXNG" });
    await user.click(stopBtn);
    await waitFor(() => {
      expect(seen).toContain("/search/stop");
      expect(screen.getByTestId("searxng-status-text").textContent).toBe(
        "Stopped"
      );
    });
  });
});
