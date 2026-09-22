// Rune Weaver Dashboard — Component tests for SettingsManager search wiring.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager from "./SettingsManager";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";
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
    resetSharedRunsForTesting();
  });

  it("pins frontend search defaults to the engine BrowserConfig", () => {
    expect(DEFAULT_SEARCH_SEARXNG_URL).toBe("http://127.0.0.1:8888");
    expect(DEFAULT_SEARCH_MAX_RESULTS).toBe(10);
  });

  it("renders the Web pane with URL, limits, and the container hint", async () => {
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    const urlInput = screen.getByLabelText(/SearXNG URL/i);
    await user.clear(urlInput);
    await user.type(urlInput, ENGINE_SEARCH_URL);
    const saveButton = screen.getByRole("button", {
      name: /Save Settings/i,
    });
    await user.click(saveButton);
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
    expect(sentPayload).toBeDefined();
    expect(sentPayload?.["searchSearxngURL"]).toBe(ENGINE_SEARCH_URL);
    expect(sentPayload?.["searchTimeoutSeconds"]).toBe(10);
    expect(sentPayload?.["searchMaxResults"]).toBe(10);
  });

  it("toggles search through a single button reading stopped then running", async () => {
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    // Stopped reads as a single Start toggle with no Stop beside it.
    const startToggle = screen.getByRole("button", { name: "Start SearXNG" });
    expect(screen.queryByRole("button", { name: "Stop SearXNG" })).toBeNull();
    // Header placement matches the providers and security panes: the lifecycle
    // toggle sits in the right-aligned title group instead of a pane-level row.
    expect(startToggle.className).toContain("ghost");
    expect(startToggle.className).toContain("icon-text-btn");
    expect(startToggle.closest(".settings-section-header")).not.toBeNull();
    expect(startToggle.querySelector("svg")).not.toBeNull();
    // Full label stays visible with a matching accessible name so the header
    // reads without relying on icon-only affordances.
    expect(startToggle.textContent).toContain("Start SearXNG");
    expect(startToggle.getAttribute("aria-label")).toBe("Start SearXNG");
    await user.click(startToggle);
    await waitFor(() => {
      expect(seen.some((u) => u.includes("/search/ensure"))).toBe(true);
      expect(
        screen.getByTestId("search-health-text").textContent?.toLowerCase()
      ).toContain("reachable");
    });
    // Running flips the same toggle to Stop with no Start beside it.
    const stopToggle = screen.getByRole("button", { name: "Stop SearXNG" });
    expect(screen.queryByRole("button", { name: "Start SearXNG" })).toBeNull();
    expect(stopToggle.className).toContain("ghost");
    expect(stopToggle.className).toContain("icon-text-btn");
    expect(stopToggle.closest(".settings-section-header")).not.toBeNull();
    expect(stopToggle.querySelector("svg")).not.toBeNull();
    expect(stopToggle.textContent).toContain("Stop SearXNG");
    expect(stopToggle.getAttribute("aria-label")).toBe("Stop SearXNG");
    await user.click(stopToggle);
    await waitFor(() => {
      expect(seen.some((u) => u.includes("/search/stop"))).toBe(true);
    });
  });

  it("reads running as a single Stop toggle", async () => {
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    await waitFor(() => {
      expect(
        screen.getByTestId("search-health-text").textContent?.toLowerCase()
      ).toContain("reachable");
    });
    // One toggle only: running offers Stop while Start stays absent.
    const stopToggle = screen.getByRole("button", { name: "Stop SearXNG" });
    expect(screen.queryByRole("button", { name: "Start SearXNG" })).toBeNull();
    expect(stopToggle.textContent).toContain("Stop SearXNG");
    expect(stopToggle.getAttribute("aria-label")).toBe("Stop SearXNG");
    expect(stopToggle.hasAttribute("disabled")).toBe(false);
  });

  it("reads unknown as an enabled Start toggle", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (String(input).includes("/search/health")) {
          return jsonResponse({});
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    await waitFor(() => {
      expect(
        screen.getByTestId("search-health-text").textContent?.toLowerCase()
      ).toContain("unknown");
    });
    // Unknown stays honest gray yet still offers Start so a first probe
    // failure never strands the pane without a recovery action.
    const startToggle = screen.getByRole("button", { name: "Start SearXNG" });
    expect(screen.queryByRole("button", { name: "Stop SearXNG" })).toBeNull();
    expect(startToggle.textContent).toContain("Start SearXNG");
    expect(startToggle.getAttribute("aria-label")).toBe("Start SearXNG");
    expect(startToggle.hasAttribute("disabled")).toBe(false);
  });

  it("locks the single toggle with Starting while a start is in flight", async () => {
    const user = userEvent.setup();
    let resolveEnsure!: (value: Response) => void;
    const ensureGate = new Promise<Response>((resolve) => {
      resolveEnsure = resolve;
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.includes("/search/health")) {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (url.includes("/search/ensure")) {
          return ensureGate;
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    const startToggle = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startToggle);
    // The in-flight start keeps one disabled toggle naming the action so a
    // second click cannot race the minutes-budget pull.
    await waitFor(() => {
      const busy = screen.getByTestId("search-toggle");
      expect(busy.hasAttribute("disabled")).toBe(true);
      expect(busy.textContent).toContain("Starting");
    });
    expect(screen.queryByRole("button", { name: "Stop SearXNG" })).toBeNull();
    resolveEnsure(jsonResponse({ reachable: true, url: ENGINE_SEARCH_URL }));
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Stop SearXNG" })).toBeDefined();
    });
  });

  it("locks the single toggle with Stopping while a stop is in flight", async () => {
    const user = userEvent.setup();
    let resolveStop!: (value: Response) => void;
    const stopGate = new Promise<Response>((resolve) => {
      resolveStop = resolve;
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.includes("/search/health")) {
          return jsonResponse({
            reachable: true,
            url: ENGINE_SEARCH_URL,
          });
        }
        if (url.includes("/search/stop")) {
          return stopGate;
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    const stopToggle = await screen.findByRole("button", {
      name: "Stop SearXNG",
    });
    await user.click(stopToggle);
    // The in-flight stop keeps one disabled toggle naming the action so Start
    // cannot interleave before the container reports stopped.
    await waitFor(() => {
      const busy = screen.getByTestId("search-toggle");
      expect(busy.hasAttribute("disabled")).toBe(true);
      expect(busy.textContent).toContain("Stopping");
    });
    expect(screen.queryByRole("button", { name: "Start SearXNG" })).toBeNull();
    resolveStop(jsonResponse({ reachable: false, url: ENGINE_SEARCH_URL }));
    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: "Start SearXNG" })
      ).toBeDefined();
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
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

  it("renders the pull-timeout cached-retry banner once with collapsed diagnostics", async () => {
    const user = userEvent.setup();
    // Mirrors the engine pullTimeoutBanner: a timed-out pull resumes cached
    // layers, so the banner names the retry instead of a generic pull failure.
    const banner =
      "SearXNG image pull timed out after 300s. Retry — downloaded layers are cached. Run `scripts/searxng-up.sh` to retry.";
    const chained = "stage: pull, (timed out after 300s), detail: download stalled";
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startBtn);
    // Banner holds the cached-retry cause plus one remediation only, rendering
    // once without chained stage fragments.
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
    expect(diagnostics.textContent).toContain("stage: pull");
    expect(diagnostics.textContent).toContain("timed out");
  });

  it("renders the pull-failed Hub banner once with collapsed diagnostics", async () => {
    const user = userEvent.setup();
    // Mirrors the engine pullFailedBanner: a non-timeout pull failure points
    // at Hub reachability rather than the run step.
    const banner =
      "SearXNG image pull failed. Check Docker Hub reachability, then run `scripts/searxng-up.sh` to retry.";
    const chained = "stage: pull, exit: 1, detail: pull access denied";
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startBtn);
    // Hub cause renders once; registry detail stays collapsed, never nested.
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
    expect(diagnostics.textContent).toContain("stage: pull");
  });

  it("renders the run-failed banner once with collapsed diagnostics", async () => {
    const user = userEvent.setup();
    // Mirrors the engine run-only banner: a fresh-run spawn failure names the
    // run step while the exit plus capped tail stay in diagnostics.
    const banner =
      "SearXNG container failed to start (run failed). Run `scripts/searxng-up.sh` to retry.";
    const chained = "stage: run, exit: 1, detail: container exit tail";
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
    await user.click(searchTab);
    const startBtn = screen.getByRole("button", { name: "Start SearXNG" });
    await user.click(startBtn);
    // Banner holds the run cause plus one remediation only, rendering once
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
    const searchTab = screen.getByRole("tab", { name: /Web/i });
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
