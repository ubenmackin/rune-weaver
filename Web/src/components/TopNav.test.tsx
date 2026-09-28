// Rune Weaver Dashboard — Component tests for TopNav health surfacing plus profile menu.
//
// Covers the SearXNG tri-state row and the profile contract: the top bar owns
// section tabs while Settings stays inside the icon-only profile menu, so the
// menu must preserve navigation, health detail, and badge behavior even when
// the handheld stylesheet collapses the trigger to its glyph.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ComponentProps } from "react";
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

  it("shows a green dot and Reachable when search is reachable", async () => {
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
      "Reachable"
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
        "Reachable"
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

  it("renders the pull-timeout cached-retry banner once without stage fragments", async () => {
    const user = userEvent.setup();
    // Mirrors the engine pullTimeoutBanner: a timed-out pull resumes cached
    // layers, so the banner names the retry instead of a generic pull failure.
    const banner =
      "SearXNG image pull timed out after 300s. Retry — downloaded layers are cached. Run `scripts/searxng-up.sh` to retry.";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (String(input) === "/search/ensure" && init?.method === "POST") {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            message: banner,
            diagnostics: "stage: pull, (timed out after 300s), detail: download stalled",
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
    // Banner renders once with the cached-retry cause plus one remediation;
    // chained stage detail stays out of this slot (Settings diagnostics only).
    await waitFor(() => {
      const error = screen.getByTestId("searxng-error");
      expect(error.textContent).toBe(banner);
      expect(error.textContent).not.toContain("stage:");
      expect(error.textContent?.split("searxng-up.sh").length).toBe(2);
    });
    // Tri-state dot stays honest: failed start keeps the red Stopped dot.
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Stopped"
    );
  });

  it("renders the pull-failed Hub banner once without stage fragments", async () => {
    const user = userEvent.setup();
    // Mirrors the engine pullFailedBanner: a non-timeout pull failure points
    // at Hub reachability rather than the run step.
    const banner =
      "SearXNG image pull failed. Check Docker Hub reachability, then run `scripts/searxng-up.sh` to retry.";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (String(input) === "/search/ensure" && init?.method === "POST") {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            message: banner,
            diagnostics: "stage: pull, exit: 1, detail: pull access denied",
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
    // Hub cause renders once; registry detail stays in server warn logs plus
    // the Settings collapsed diagnostics, never nested here.
    await waitFor(() => {
      const error = screen.getByTestId("searxng-error");
      expect(error.textContent).toBe(banner);
      expect(error.textContent).not.toContain("stage:");
      expect(error.textContent?.split("searxng-up.sh").length).toBe(2);
    });
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Stopped"
    );
  });

  it("renders the run-failed banner once without stage fragments", async () => {
    const user = userEvent.setup();
    // Mirrors the engine run-only banner: a fresh-run spawn failure names the
    // run step while the exit plus capped tail stay in diagnostics.
    const banner =
      "SearXNG container failed to start (run failed). Run `scripts/searxng-up.sh` to retry.";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (String(input) === "/search/ensure" && init?.method === "POST") {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            message: banner,
            diagnostics: "stage: run, exit: 1, detail: container exit tail",
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
    // Run cause renders once with one remediation; exit plus tail never leak
    // into this slot.
    await waitFor(() => {
      const error = screen.getByTestId("searxng-error");
      expect(error.textContent).toBe(banner);
      expect(error.textContent).not.toContain("stage:");
      expect(error.textContent?.split("searxng-up.sh").length).toBe(2);
    });
    // Tri-state dot stays honest: failed start keeps the red Stopped dot.
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Stopped"
    );
  });

  it("keeps timeout banners to one remediation command", async () => {
    const user = userEvent.setup();
    const banner =
      "SearXNG is not reachable at http://127.0.0.1:8888. Start it with `scripts/searxng-up.sh`, then retry.";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (String(input) === "/search/ensure" && init?.method === "POST") {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            message: banner,
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
      const error = screen.getByTestId("searxng-error");
      expect(error.textContent).toBe(banner);
      // One hatch command, never the legacy `container start` second command.
      expect(error.textContent).toContain("scripts/searxng-up.sh");
      expect(error.textContent).not.toContain("container start");
    });
  });
});

describe("TopNav profile menu", () => {
  const HEALTH = {
    status: "ok",
    engine: "Rune Weaver",
    version: "0.1.0",
    model: "gemma-4-9b",
    provider: "mlx",
  };

  function renderProfileNav(overrides: Record<string, unknown> = {}) {
    const props = {
      currentTab: "chat",
      onSelectTab: () => {},
      health: HEALTH,
      runsBadge: 0,
      approvalsBadge: 0,
      notificationsEnabled: false,
      onRequestNotifications: () => {},
      ...overrides,
    } as unknown as ComponentProps<typeof TopNav>;
    return render(<TopNav {...props} />);
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps five section tabs with Settings reserved for the profile menu", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav();
    // Desktop tabs mirror the bottom-bar order so breakpoints never drift.
    const sections = screen.getByRole("navigation", { name: "Dashboard sections" });
    const tabs = Array.from(sections.querySelectorAll("button")).map((tab) =>
      tab.textContent?.replace(/[0-9+ ]*unread/g, "").trim(),
    );
    expect(tabs).toEqual(["Chat", "Approvals", "Memory", "Runs", "Schedules"]);
    expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();

    // Opening the icon-only trigger reveals Settings inside the menu.
    await openProfile(user);
    expect(screen.getByRole("menuitem", { name: "Settings" })).toBeInTheDocument();
  });

  it("preserves the icon-only trigger semantics while the menu stays reachable", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav();
    const trigger = screen.getByRole("button", { name: /Profile and Settings menu/i });
    // The accessible name survives the handheld collapse to a 32px glyph so
    // assistive tech keeps announcing the menu after the label hides.
    expect(trigger.getAttribute("aria-haspopup")).toBe("menu");
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(trigger.querySelector(".profile-btn-label")).not.toBeNull();
    await user.click(trigger);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    await waitFor(() => {
      expect(screen.getByRole("menu", { name: "Profile and Settings" })).toBeInTheDocument();
    });
    // Health detail travels with the menu so the trigger alone stays useful.
    expect(screen.getByText("gemma-4-9b")).toBeInTheDocument();
    expect(screen.getByTestId("searxng-status-text")).toBeInTheDocument();
  });

  it("routes Settings from the menu and closes it", async () => {
    const user = userEvent.setup();
    const onSelectTab = vi.fn();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav({ onSelectTab });
    await openProfile(user);
    await user.click(screen.getByRole("menuitem", { name: "Settings" }));
    expect(onSelectTab).toHaveBeenCalledWith("settings");
    await waitFor(() => {
      expect(screen.queryByRole("menu", { name: "Profile and Settings" })).toBeNull();
    });
  });

  it("marks the trigger when the settings section is active", () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav({ currentTab: "settings" });
    const trigger = screen.getByRole("button", { name: /Profile and Settings menu/i });
    expect(trigger.className).toContain("settings-active");
  });

  it("closes the menu on Escape and returns focus to the trigger", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav();
    await openProfile(user);
    const trigger = screen.getByRole("button", { name: /Profile and Settings menu/i });
    await user.keyboard("{Escape}");
    await waitFor(() => {
      expect(screen.queryByRole("menu", { name: "Profile and Settings" })).toBeNull();
    });
    expect(document.activeElement).toBe(trigger);
  });

  it("hides section badges at zero and caps triple-digit counts", () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const { rerender } = renderProfileNav({ approvalsBadge: 0, runsBadge: 0 });
    expect(document.querySelector(".nav-badge")).toBeNull();

    rerender(
      <TopNav
        currentTab="chat"
        onSelectTab={() => {}}
        health={HEALTH as never}
        runsBadge={100}
        approvalsBadge={99}
        notificationsEnabled={false}
        onRequestNotifications={() => {}}
      />,
    );
    const badges = Array.from(document.querySelectorAll(".nav-badge"));
    expect(badges.map((badge) => badge.textContent)).toEqual(["99", "99+"]);
    // Pills stay presentational while the owning tab buttons announce the
    // honest unclamped counts.
    expect(badges.map((badge) => badge.getAttribute("aria-hidden"))).toEqual([
      "true",
      "true",
    ]);
    expect(
      screen.getByRole("button", { name: "Approvals, 99 unread" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Runs, 100 unread" }),
    ).toBeInTheDocument();
  });

  it("announces the bell count through the owning button while the pill stays presentational", () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav({ warningsBadge: 3 });
    const bell = screen.getByRole("button", {
      name: "Browser notifications, 3 unread warnings",
    });
    expect(bell).toBeInTheDocument();
    const pill = bell.querySelector(".nav-badge");
    expect(pill?.textContent).toBe("3");
    expect(pill?.getAttribute("aria-hidden")).toBe("true");
  });
});

describe("TopNav staged drawer trigger", () => {
  function renderStagedNav(overrides: Record<string, unknown> = {}) {
    const props = {
      currentTab: "chat",
      onSelectTab: () => {},
      health: null,
      runsBadge: 0,
      approvalsBadge: 0,
      notificationsEnabled: false,
      onRequestNotifications: () => {},
      stagedFilesCount: 0,
      onOpenStagedDrawer: () => {},
      ...overrides,
    } as unknown as ComponentProps<typeof TopNav>;
    return render(<TopNav {...props} />);
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps the Files button plus zero badge visible and focusable at zero", () => {
    // Always-visible contract: zero never hides the trigger, so review stays
    // reachable on fetch failure and reload while the drawer owns the
    // `No staged changes` empty state.
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderStagedNav({ stagedFilesCount: 0 });
    const trigger = screen.getByTestId("top-nav-staged-btn");
    expect(trigger).toBeInTheDocument();
    expect(trigger.textContent).toContain("Files");
    expect(trigger.getAttribute("title")).toBe(
      "0 staged file changes waiting for review"
    );
    expect(trigger.getAttribute("aria-label")).toBe(
      "Open staged changes drawer (0 files)"
    );
    const badge = trigger.querySelector(".top-nav-staged-badge");
    expect(badge).not.toBeNull();
    expect(badge?.textContent).toBe("0");
    // The zero badge keeps the shared class with a muted inline style so the
    // trigger reads idle without disappearing.
    expect(badge?.className).toContain("top-nav-staged-badge");
    expect(trigger.tagName).toBe("BUTTON");
    expect(trigger.hasAttribute("disabled")).toBe(false);
    trigger.focus();
    expect(document.activeElement).toBe(trigger);
  });

  it("opens the drawer empty state on click at zero", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const onOpenStagedDrawer = vi.fn();
    renderStagedNav({ stagedFilesCount: 0, onOpenStagedDrawer });
    await user.click(screen.getByTestId("top-nav-staged-btn"));
    // Clicking at zero delegates upstream where the drawer renders its
    // existing empty state; the trigger never swallows the open.
    expect(onOpenStagedDrawer).toHaveBeenCalledTimes(1);
  });

  it("counts up the badge with pluralized title through the staged count", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const onOpenStagedDrawer = vi.fn();
    const { rerender } = renderStagedNav({
      stagedFilesCount: 2,
      onOpenStagedDrawer,
    });
    const trigger = screen.getByTestId("top-nav-staged-btn");
    expect(trigger.querySelector(".top-nav-staged-badge")?.textContent).toBe(
      "2"
    );
    expect(trigger.getAttribute("title")).toBe(
      "2 staged file changes waiting for review"
    );
    expect(trigger.getAttribute("aria-label")).toBe(
      "Open staged changes drawer (2 files)"
    );
    await user.click(trigger);
    expect(onOpenStagedDrawer).toHaveBeenCalledTimes(1);

    // Singular matches the drawer header (`1 file`): no trailing `s`.
    rerender(
      <TopNav
        currentTab="chat"
        onSelectTab={() => {}}
        health={null as never}
        runsBadge={0}
        approvalsBadge={0}
        notificationsEnabled={false}
        onRequestNotifications={() => {}}
        stagedFilesCount={1}
        onOpenStagedDrawer={() => {}}
      />
    );
    const singular = screen.getByTestId("top-nav-staged-btn");
    expect(singular.querySelector(".top-nav-staged-badge")?.textContent).toBe(
      "1"
    );
    expect(singular.getAttribute("title")).toBe(
      "1 staged file change waiting for review"
    );
  });

  it("keeps a stable test id across zero and nonzero states", () => {
    // Regression guard: visibility states share one test id so selectors and
    // the `onCountChange` count-up path never fork the trigger.
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const { unmount } = renderStagedNav({ stagedFilesCount: 0 });
    expect(screen.getByTestId("top-nav-staged-btn")).toBeInTheDocument();
    unmount();
    renderStagedNav({ stagedFilesCount: 3 });
    expect(screen.getByTestId("top-nav-staged-btn")).toBeInTheDocument();
    expect(
      screen
        .getByTestId("top-nav-staged-btn")
        .querySelector(".top-nav-staged-badge")?.textContent
    ).toBe("3");
  });
});
