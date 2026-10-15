// Managed browser Python provision contract and Settings Web-pane behavior.
// Pins the dashboard stage copy and pinned Playwright requirement to the
// engine provision wording so a rename or version bump on either side fails
// loudly instead of silently relabeling the Preparing line, and exercises the
// state-aware Browser automation header so Ready, Missing, Unknown, and
// in-flight each render exactly one action.

import React from "react";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager, {
  BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT,
  BROWSER_PYTHON_STAGE_COPY,
  browserStageCopy,
  isBrowserLongStage,
} from "./SettingsManager";
import { jsonResponse } from "../test-utils/http";

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
  memoryEmbeddingBackend: "local",
  voiceSTTProvider: "whisper",
  voiceWhisperModel: "base",
  voiceTTSProvider: "system",
  emailAccounts: [],
  pluginsDir: "~/.runeweaver/plugins",
  pluginsMarketplaceIndexURL:
    "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json",
  pluginsAutoRescan: true,
  configPath: "/Users/test/.runeweaver/config.toml",
};

// Builds a fetch stub that serves the browser health/ensure contracts plus the
// ambient settings/plugins/tools/search routes the Web pane touches. `ensure`
// defaults to a not-ready result and `ensureGate` lets a test hold the
// provision open to observe the in-flight header state.
function browserFetchMock(options: {
  health: unknown;
  ensure?: unknown;
  ensureGate?: Promise<void>;
}) {
  return vi.fn(
    async (input: string | URL | Request) => {
      const url = String(input);
      if (url.includes("/browser/ensure")) {
        if (options.ensureGate) await options.ensureGate;
        return jsonResponse(options.ensure ?? { ready: false, started: false });
      }
      if (url.includes("/browser/health")) {
        return jsonResponse(options.health);
      }
      if (url.includes("/search/health")) {
        return jsonResponse({ reachable: false, url: "http://127.0.0.1:8888" });
      }
      if (url.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      if (url.includes("/tools")) {
        return jsonResponse({ tools: [] });
      }
      return jsonResponse(mockSettings);
    }
  );
}

// Opens the Web pane where the Browser automation subsection lives. The
// internal tab id stays "search"; only the visible label reads Web.
async function openWebPane(user: ReturnType<typeof userEvent.setup>) {
  render(React.createElement(SettingsManager));
  await waitFor(() => {
    expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
  });
  await user.click(screen.getByRole("tab", { name: /Web/i }));
}

describe("browser python stage copy", () => {
  it("mirrors the engine provision copy for every stage", () => {
    // Single source of truth lives beside the engine stages; this table must
    // match it exactly so health polls and boot lines name the same step.
    expect(BROWSER_PYTHON_STAGE_COPY).toEqual({
      resolving: "Finding system Python",
      creating: "Creating managed browser environment",
      installing: "Installing Playwright package",
      browsers: "Installing Chromium browser",
    });
  });

  it("maps every stage to copy with drift degrading to Preparing", () => {
    expect(browserStageCopy("resolving")).toBe("Finding system Python");
    expect(browserStageCopy("creating")).toBe(
      "Creating managed browser environment",
    );
    expect(browserStageCopy("installing")).toBe("Installing Playwright package");
    expect(browserStageCopy("browsers")).toBe("Installing Chromium browser");
    expect(browserStageCopy("unknown-step")).toBe("Preparing");
    expect(browserStageCopy("")).toBe("Preparing");
    expect(browserStageCopy(null)).toBe("Preparing");
    expect(browserStageCopy(undefined)).toBe("Preparing");
  });

  it("suspends the cap only during minutes-budget downloads", () => {
    // Pip and Chromium fetches run minutes, so the hung-provision cap waits
    // through them while faster steps still trip it.
    expect(isBrowserLongStage("installing")).toBe(true);
    expect(isBrowserLongStage("browsers")).toBe(true);
    expect(isBrowserLongStage("resolving")).toBe(false);
    expect(isBrowserLongStage("creating")).toBe(false);
    expect(isBrowserLongStage(null)).toBe(false);
  });

  it("pins the manual fallback to the engine's Playwright requirement", () => {
    // Mirrors PlaywrightPythonEnsurer.pinnedPlaywrightRequirement so a manual
    // recovery installs the same release the managed provision installs.
    expect(BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT).toBe("playwright==1.49.1");
  });
});

describe("browser python state-aware header", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("hides the install action and offers a health re-check when Ready", async () => {
    const user = userEvent.setup();
    const fetchMock = browserFetchMock({
      health: {
        ready: true,
        pythonPath: "/Users/test/.runeweaver/python/bin/python",
        venvPath: "~/.runeweaver/python",
      },
    });
    vi.stubGlobal("fetch", fetchMock);
    await openWebPane(user);

    await waitFor(() => {
      expect(screen.getByTestId("browser-health-text").textContent).toContain(
        "Ready",
      );
    });

    // A ready environment must never offer re-provisioning by accident; only
    // an explicit health re-probe remains.
    expect(
      screen.queryByRole("button", { name: /Ensure browser Python/i }),
    ).toBeNull();
    expect(
      screen.queryByRole("button", { name: /Install browser environment/i }),
    ).toBeNull();
    const recheck = screen.getByRole("button", {
      name: /Re-check browser Python/i,
    });
    expect(recheck).toBeDefined();

    const healthCallsBefore = fetchMock.mock.calls.filter(([url]) =>
      String(url).includes("/browser/health"),
    ).length;
    await user.click(recheck);
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) =>
          String(url).includes("/browser/health"),
        ).length,
      ).toBeGreaterThan(healthCallsBefore);
    });
    // Re-check only re-probes health; it never fires the ensure route.
    expect(
      fetchMock.mock.calls.some(([url]) =>
        String(url).includes("/browser/ensure"),
      ),
    ).toBe(false);
  });

  it("shows the primary install action when browser Python is Missing", async () => {
    const user = userEvent.setup();
    const fetchMock = browserFetchMock({ health: { ready: false } });
    vi.stubGlobal("fetch", fetchMock);
    await openWebPane(user);

    await waitFor(() => {
      expect(screen.getByTestId("browser-health-text").textContent).toContain(
        "Missing",
      );
    });

    const install = screen.getByRole("button", {
      name: /Install browser environment/i,
    });
    expect(install).toBeDefined();
    expect(
      screen.queryByRole("button", { name: /Ensure browser Python/i }),
    ).toBeNull();

    await user.click(install);
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(([url]) =>
          String(url).includes("/browser/ensure"),
        ),
      ).toBe(true);
    });
  });

  it("disables the header action while Preparing and names the live stage", async () => {
    const user = userEvent.setup();
    // Mutable holder keeps the resolver visible across the fetch closure
    // without TypeScript narrowing the local to null at the release site.
    const gate: { release: (() => void) | null } = { release: null };
    const ensureGate = new Promise<void>((resolve) => {
      gate.release = resolve;
    });
    const fetchMock = browserFetchMock({
      health: { ready: false },
      ensure: { ready: false, started: true },
      ensureGate,
    });
    vi.stubGlobal("fetch", fetchMock);
    await openWebPane(user);

    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: /Install browser environment/i }),
      ).toBeDefined();
    });
    await user.click(
      screen.getByRole("button", { name: /Install browser environment/i }),
    );

    // The action collapses into a disabled progress line so a second
    // provision cannot be queued behind the first.
    await waitFor(() => {
      const preparing = screen.getByTestId("browser-preparing");
      expect((preparing as HTMLButtonElement).disabled).toBe(true);
      expect(preparing.textContent).toContain("Preparing…");
    });
    expect(
      screen.queryByRole("button", { name: /Install browser environment/i }),
    ).toBeNull();

    expect(gate.release).not.toBeNull();
    const release = gate.release;
    if (release) release();
    await waitFor(() => {
      expect(screen.queryByTestId("browser-preparing")).toBeNull();
    });
  });

  it("offers Check & install when browser health is Unknown", async () => {
    const user = userEvent.setup();
    // A shape-drifted payload leaves readiness unknown rather than coercing
    // missing to Missing, matching the honest tri-state contract.
    const fetchMock = browserFetchMock({ health: {} });
    vi.stubGlobal("fetch", fetchMock);
    await openWebPane(user);

    await waitFor(() => {
      expect(screen.getByTestId("browser-health-text").textContent).toContain(
        "Unknown",
      );
    });
    expect(
      screen.getByRole("button", { name: /Check & install/i }),
    ).toBeDefined();
  });

  it("keeps the manual fallback collapsed until a provision error needs it", async () => {
    const user = userEvent.setup();
    const fetchMock = browserFetchMock({
      health: { ready: false },
      ensure: { ready: false, message: "Playwright install failed." },
    });
    vi.stubGlobal("fetch", fetchMock);
    await openWebPane(user);

    await waitFor(() => {
      expect(
        screen.getByRole("button", { name: /Install browser environment/i }),
      ).toBeDefined();
    });

    // Setup internals stay collapsed during normal use so the pane shows one
    // action rather than venv paths.
    const advanced = screen.getByTestId("browser-advanced") as HTMLDetailsElement;
    expect(advanced.tagName.toLowerCase()).toBe("details");
    expect(advanced.open).toBe(false);
    expect(advanced.querySelector("summary")?.textContent).toBe("Advanced");
    expect(advanced.textContent).toContain("Managed Python at");
    expect(advanced.textContent).toContain("Manual fallback");
    expect(advanced.textContent).toContain("pip install playwright==1.49.1");

    await user.click(
      screen.getByRole("button", { name: /Install browser environment/i }),
    );

    // An error banner force-opens the disclosure so the venv path and fallback
    // recovery command are visible without another click.
    await waitFor(() => {
      expect(
        screen.getByTestId("browser-health-error").textContent,
      ).toContain("Playwright install failed.");
      expect(
        (screen.getByTestId("browser-advanced") as HTMLDetailsElement).open,
      ).toBe(true);
    });
  });
});
