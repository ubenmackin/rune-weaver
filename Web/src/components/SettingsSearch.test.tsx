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
      expect(screen.getByTestId("search-health-text").textContent).toContain(
        "reachable"
      );
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
    await user.click(startBtn);
    await waitFor(() => {
      expect(seen.some((u) => u.includes("/search/ensure"))).toBe(true);
      expect(screen.getByTestId("search-health-text").textContent).toContain(
        "reachable"
      );
    });
    const stopBtn = screen.getByRole("button", { name: "Stop SearXNG" });
    await user.click(stopBtn);
    await waitFor(() => {
      expect(seen.some((u) => u.includes("/search/stop"))).toBe(true);
    });
  });
});
