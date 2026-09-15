// Rune Weaver Dashboard — Unit tests for RuneMarketplaceModal.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import RuneMarketplaceModal from "./RuneMarketplaceModal";
import { jsonResponse } from "../test-utils/http";

const mockMarketplaceItems = [
  {
    id: "community.playwright-browser",
    name: "Playwright Web Browser",
    version: "1.0.0",
    author: "Rune Weaver Team",
    description: "Automate web browsing and page extraction.",
    downloadURL: "https://example.com/playwright.json",
    tags: ["web", "automation"],
    runtime: "python",
    declaredTools: ["browser.navigate", "browser.read_page"],
    isInstalled: false,
  },
  {
    id: "community.clock-timer",
    name: "World Clock & Timer",
    version: "1.0.0",
    author: "Rune Weaver Team",
    description: "Current time and timezone converter.",
    downloadURL: "https://example.com/clock.json",
    tags: ["utility", "time"],
    runtime: "python",
    declaredTools: ["clock.current_time"],
    isInstalled: true,
  },
];

describe("RuneMarketplaceModal", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("does not render when isOpen is false", () => {
    const { container } = render(
      <RuneMarketplaceModal
        isOpen={false}
        onClose={vi.fn()}
        onPluginInstalled={vi.fn()}
      />
    );
    expect(container.firstChild).toBeNull();
  });

  it("fetches and renders marketplace catalog when opened", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation((input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/marketplace/plugins")) {
          return Promise.resolve(jsonResponse({ items: mockMarketplaceItems, count: 2 }));
        }
        return Promise.resolve(new Response(null, { status: 404 }));
      })
    );

    render(
      <RuneMarketplaceModal
        isOpen={true}
        onClose={vi.fn()}
        onPluginInstalled={vi.fn()}
      />
    );

    expect(screen.getByText("Community Rune Marketplace")).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByText("Playwright Web Browser")).toBeInTheDocument();
      expect(screen.getByText("World Clock & Timer")).toBeInTheDocument();
    });

    expect(screen.getByText("Automate web browsing and page extraction.")).toBeInTheDocument();
    expect(screen.getByText("Installed")).toBeInTheDocument();
  });

  it("filters items by search query", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation((input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/marketplace/plugins")) {
          return Promise.resolve(jsonResponse({ items: mockMarketplaceItems, count: 2 }));
        }
        return Promise.resolve(new Response(null, { status: 404 }));
      })
    );

    render(
      <RuneMarketplaceModal
        isOpen={true}
        onClose={vi.fn()}
        onPluginInstalled={vi.fn()}
      />
    );

    await waitFor(() => {
      expect(screen.getByText("Playwright Web Browser")).toBeInTheDocument();
    });

    const searchInput = screen.getByPlaceholderText(
      "Search runes by name, description, tags, or tools..."
    );
    await user.type(searchInput, "clock");

    expect(screen.queryByText("Playwright Web Browser")).not.toBeInTheDocument();
    expect(screen.getByText("World Clock & Timer")).toBeInTheDocument();
  });

  it("installs an uninstalled rune and triggers callback with quarantine notice", async () => {
    const user = userEvent.setup();
    const onPluginInstalled = vi.fn();

    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        if (url.includes("/marketplace/plugins")) {
          return Promise.resolve(jsonResponse({ items: mockMarketplaceItems, count: 2 }));
        }
        if (url.includes("/marketplace/install") && init?.method === "POST") {
          return Promise.resolve(
            jsonResponse({
              id: "community.playwright-browser",
              name: "Playwright Web Browser",
              status: "discovered",
              isEnabled: false,
              tools: [],
            })
          );
        }
        return Promise.resolve(new Response(null, { status: 404 }));
      })
    );

    render(
      <RuneMarketplaceModal
        isOpen={true}
        onClose={vi.fn()}
        onPluginInstalled={onPluginInstalled}
      />
    );

    await waitFor(() => {
      expect(screen.getByText("Playwright Web Browser")).toBeInTheDocument();
    });

    const installButtons = screen.getAllByRole("button", { name: /Install/i });
    expect(installButtons.length).toBeGreaterThan(0);
    await user.click(installButtons[0]);

    await waitFor(() => {
      expect(onPluginInstalled).toHaveBeenCalledTimes(1);
    });

    expect(
      screen.getByText(/placed in the disabled holding pen/i)
    ).toBeInTheDocument();
  });

  it("surfaces error when catalog fetch fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockRejectedValue(new Error("Network connection refused"))
    );

    render(
      <RuneMarketplaceModal
        isOpen={true}
        onClose={vi.fn()}
        onPluginInstalled={vi.fn()}
      />
    );

    await waitFor(() => {
      expect(screen.getByText("Network connection refused")).toBeInTheDocument();
    });
  });

  it("surfaces error when installation fails", async () => {
    const user = userEvent.setup();

    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        if (url.includes("/marketplace/plugins")) {
          return Promise.resolve(jsonResponse({ items: mockMarketplaceItems, count: 2 }));
        }
        if (url.includes("/marketplace/install") && init?.method === "POST") {
          return Promise.resolve(
            new Response(JSON.stringify({ reason: "Disk quota exceeded." }), {
              status: 500,
              headers: { "Content-Type": "application/json" },
            })
          );
        }
        return Promise.resolve(new Response(null, { status: 404 }));
      })
    );

    render(
      <RuneMarketplaceModal
        isOpen={true}
        onClose={vi.fn()}
        onPluginInstalled={vi.fn()}
      />
    );

    await waitFor(() => {
      expect(screen.getByText("Playwright Web Browser")).toBeInTheDocument();
    });

    const installButtons = screen.getAllByRole("button", { name: /Install/i });
    await user.click(installButtons[0]);

    await waitFor(() => {
      expect(screen.getByText(/Disk quota exceeded|Failed to install/i)).toBeInTheDocument();
    });
  });

  it("calls onClose when close button is clicked", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();

    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(jsonResponse({ items: [], count: 0 }))
    );

    render(
      <RuneMarketplaceModal
        isOpen={true}
        onClose={onClose}
        onPluginInstalled={vi.fn()}
      />
    );

    const closeBtn = screen.getByRole("button", { name: "Close marketplace" });
    await user.click(closeBtn);

    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
