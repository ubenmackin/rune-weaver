// Rune Weaver Dashboard — Component tests for SettingsManager search wiring.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager from "./SettingsManager";
import {
  DEFAULT_SEARCH_MAX_RESULTS,
  DEFAULT_SEARCH_SEARXNG_URL,
} from "../api";
import { jsonResponse } from "../test-utils/http";

const ENGINE_SEARCH_URL = "http://127.0.0.1:8888";

const mockSettings = {
  engineName: "Test Engine",
  logLevel: "info",
  defaultProvider: "mlx",
  fallbackProvider: "",
  providers: {
    mlx: {
      enabled: true,
      model: "gemma-4-9b",
      server_url: "http://localhost:8080",
    },
  },
  memoryVectorDBPath: "memory/vectors",
  memoryEpisodesDBPath: "memory/episodes.db",
  memoryEmbeddingModel: "all-MiniLM-L6-v2",
  memoryEmbeddingBackend: "apple",
  voiceSTTProvider: "whisper",
  voiceWhisperModel: "base",
  voiceTTSProvider: "system",
  searchSearxngURL: ENGINE_SEARCH_URL,
  searchTimeoutSeconds: 10,
  searchMaxResults: 10,
  emailAccounts: [],
  pluginsDir: "~/.runeweaver/plugins",
  pluginsMarketplaceIndexURL:
    "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json",
  pluginsAutoRescan: true,
  configPath: "/Users/test/.runeweaver/config.toml",
};

describe("SettingsManager search", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("pins frontend search defaults to the engine BrowserConfig", () => {
    expect(DEFAULT_SEARCH_SEARXNG_URL).toBe("http://127.0.0.1:8888");
    expect(DEFAULT_SEARCH_MAX_RESULTS).toBe(10);
  });

  it("renders the Search pane with URL, limits, and the container hint", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (String(input).includes("/search/health")) {
          return jsonResponse({
            reachable: true,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (String(input).includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (String(input).includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        return jsonResponse(mockSettings);
      })
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const searchTab = screen.getByRole("tab", { name: /Search/i });
    await user.click(searchTab);
    expect(screen.getByLabelText(/SearXNG URL/i)).toBeDefined();
    expect(screen.getByLabelText(/Timeout \(seconds\)/i)).toBeDefined();
    expect(screen.getByLabelText(/Max Results/i)).toBeDefined();
    expect(screen.getByDisplayValue(ENGINE_SEARCH_URL)).toBeDefined();
    // Docker-free hint names the Apple Container runtime and first-pull size.
    expect(screen.getByText(/No Docker needed/i)).toBeDefined();
    expect(screen.getByText(/Apple Container/i)).toBeDefined();
    expect(screen.getByText(/150 MB/i)).toBeDefined();
    // Health text reflects the probed container state.
    await waitFor(() => {
      expect(
        screen.getByTestId("search-health-text").textContent?.toLowerCase()
      ).toContain("reachable");
    });
  });

  it("sends search fields on save", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const url = String(input);
        if (url.includes("/search/health")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (url.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (url.includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        if (init?.method === "PUT") {
          sentPayload = JSON.parse(init.body as string) as Record<
            string,
            unknown
          >;
          return jsonResponse({ ...mockSettings, ...sentPayload });
        }
        return jsonResponse(mockSettings);
      })
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const searchTab = screen.getByRole("tab", { name: /Search/i });
    await user.click(searchTab);
    const urlInput = screen.getByLabelText(/SearXNG URL/i);
    await user.clear(urlInput);
    await user.type(urlInput, ENGINE_SEARCH_URL);
    const saveButton = screen.getByRole("button", {
      name: /Save Settings/i,
    });
    await user.click(saveButton);
    await waitFor(() => {
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
    });
    expect(sentPayload).toBeDefined();
    expect(sentPayload?.["searchSearxngURL"]).toBe(ENGINE_SEARCH_URL);
    expect(sentPayload?.["searchTimeoutSeconds"]).toBe(10);
    expect(sentPayload?.["searchMaxResults"]).toBe(10);
  });

  it("starts and stops search through the ensure and stop paths", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        seen.push(url);
        if (url.includes("/search/health")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (url.includes("/search/ensure")) {
          return jsonResponse({
            reachable: true,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (url.includes("/search/stop")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (url.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (url.includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        return jsonResponse(mockSettings);
      })
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const searchTab = screen.getByRole("tab", { name: /Search/i });
    await user.click(searchTab);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    const stopBtn = screen.getByRole("button", { name: "Stop SearXNG" });
    // Header placement matches the providers and security panes: lifecycle
    // actions sit in the right-aligned title group instead of a pane-level row.
    for (const btn of [startBtn, stopBtn]) {
      expect(btn.className).toContain("ghost");
      expect(btn.className).toContain("icon-text-btn");
      expect(btn.closest(".settings-section-header")).not.toBeNull();
      expect(btn.querySelector("svg")).not.toBeNull();
    }
    // Full labels stay visible with matching accessible names so the header
    // reads without relying on icon-only affordances.
    expect(startBtn.textContent).toContain("Start SearXNG");
    expect(stopBtn.textContent).toContain("Stop SearXNG");
    expect(startBtn.getAttribute("aria-label")).toBe("Start SearXNG");
    expect(stopBtn.getAttribute("aria-label")).toBe("Stop SearXNG");
    await user.click(startBtn);
    await waitFor(() => {
      expect(seen.some((u) => u.includes("/search/ensure"))).toBe(true);
      expect(
        screen.getByTestId("search-health-text").textContent?.toLowerCase()
      ).toContain("reachable");
    });
    await user.click(stopBtn);
    await waitFor(() => {
      expect(seen.some((u) => u.includes("/search/stop"))).toBe(true);
    });
  });

  it("keeps the global header Refresh as the only manual refresh", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (String(input).includes("/search/health")) {
          return jsonResponse({
            reachable: true,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (String(input).includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (String(input).includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        return jsonResponse(mockSettings);
      })
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const searchTab = screen.getByRole("tab", { name: /Search/i });
    await user.click(searchTab);
    // Health still probes automatically on pane open without a manual control.
    await waitFor(() => {
      expect(
        screen.getByTestId("search-health-text").textContent?.toLowerCase()
      ).toContain("reachable");
    });
    // Pane-level refresh is gone; the global Settings header Refresh remains
    // the single manual refresh so probes stay automatic otherwise.
    expect(
      screen.queryByRole("button", { name: "Refresh search health" })
    ).toBeNull();
    const refreshButtons = screen.getAllByRole("button", { name: /Refresh/i });
    expect(refreshButtons).toHaveLength(1);
    expect(refreshButtons[0].textContent).toMatch(/Refresh/);
  });

  it("renders a trimmed banner once with collapsed diagnostics on failed start", async () => {
    const user = userEvent.setup();
    const banner =
      "SearXNG container failed to start (image pull or run failed). Run `scripts/searxng-up.sh` to retry.";
    const chained = "stage: run, exit: 1, detail: pull access denied; stage: poll, (timed out after 10s)";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (String(input).includes("/search/health")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (String(input).includes("/search/ensure")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            message: banner,
            diagnostics: chained,
          });
        }
        if (String(input).includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (String(input).includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        return jsonResponse(mockSettings);
      })
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const searchTab = screen.getByRole("tab", { name: /Search/i });
    await user.click(searchTab);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startBtn);
    // Banner holds the terminal cause plus one remediation only, rendering once
    // without chained stage fragments.
    await waitFor(() => {
      const error = screen.getByTestId("search-health-error");
      expect(error.textContent).toBe(banner);
      expect(error.textContent).not.toContain("stage:");
      // One remediation command in the banner.
      expect(error.textContent?.split("searxng-up.sh").length).toBe(2);
    });
    // Chained detail lives in the optional collapsed element, not the banner.
    const diagnostics = screen.getByTestId("search-health-diagnostics");
    expect(diagnostics.tagName.toLowerCase()).toBe("details");
    expect(diagnostics.textContent).toContain("stage: run");
    expect(diagnostics.textContent).toContain("stage: poll");
  });

  it("hides the diagnostics element when the banner carries no chain", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (String(input).includes("/search/health")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (String(input).includes("/search/ensure")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            message: "SearXNG is not reachable. Start it with `scripts/searxng-up.sh`, then retry.",
          });
        }
        if (String(input).includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (String(input).includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        return jsonResponse(mockSettings);
      })
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const searchTab = screen.getByRole("tab", { name: /Search/i });
    await user.click(searchTab);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startBtn);
    await waitFor(() => {
      expect(screen.getByTestId("search-health-error")).toBeDefined();
    });
    // No chain means no collapsed element, so the banner still renders once alone.
    expect(screen.queryByTestId("search-health-diagnostics")).toBeNull();
  });
});
