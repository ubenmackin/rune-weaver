// Rune Weaver Dashboard — Component tests for TopNav health surfacing, group
// dropdowns, and the profile menu.

import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ComponentProps } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import TopNav from "./TopNav";
import { isGroupActive, rolledUpBadge } from "./navigationConfig";
import {
  peekPersonaSignals,
  publishPersonaFromSettings,
  resetPersonaSignalsForTesting,
} from "./PersonaAvatar";
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
      "SearXNG image pull timed out after 300s. Retry: downloaded layers are cached. Run `scripts/searxng-up.sh` to retry.";
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
      onRequestNotifications: () => {},
      ...overrides,
    } as unknown as ComponentProps<typeof TopNav>;
    return render(<TopNav {...props} />);
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("groups the work sections under one dropdown while Settings stays in profile", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav();
    // Desktop top level is four entries; the Work dropdown folds goals,
    // schedules, and runs so the bar stays short as operational views grow.
    const sections = screen.getByRole("navigation", { name: "Dashboard sections" });
    const topLevel = Array.from(sections.querySelectorAll(".top-nav-item")).map(
      (tab) => tab.textContent?.trim(),
    );
    expect(topLevel).toEqual(["Dashboard", "Chat", "Inbox", "Work", "Memory"]);
    expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();

    // The Work trigger reveals its children in canonical order.
    await user.click(screen.getByRole("button", { name: "Work" }));
    const menu = screen.getByRole("menu", { name: "Work sections" });
    expect(
      Array.from(menu.querySelectorAll('[role="menuitem"]')).map((item) =>
        item.textContent?.trim(),
      ),
    ).toEqual(["Goals", "Schedules", "Runs"]);

    // The Memory trigger reveals its children in canonical order.
    await user.click(screen.getByRole("button", { name: "Memory" }));
    const memoryMenu = screen.getByRole("menu", { name: "Memory sections" });
    expect(
      Array.from(memoryMenu.querySelectorAll('[role="menuitem"]')).map((item) =>
        item.textContent?.trim(),
      ),
    ).toEqual(["Search and Memory", "Index Status"]);

    // Opening the icon-only profile trigger reveals Settings inside that menu.
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
      screen.getByRole("button", { name: "Inbox, 99 unread" }),
    ).toBeInTheDocument();
    // Runs now lives inside Work, so its unread count rolls into that trigger
    // rather than surfacing as a top-level tab.
    expect(
      screen.getByRole("button", { name: "Work, 100 unread" }),
    ).toBeInTheDocument();
  });

  it("announces the bell count through the owning button while the pill stays presentational", () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    renderProfileNav({ warningsBadge: 3 });
    const bell = screen.getByRole("button", {
      name: "Alerts, 3 unread warnings",
    });
    expect(bell).toBeInTheDocument();
    const pill = bell.querySelector(".nav-badge");
    expect(pill?.textContent).toBe("3");
    expect(pill?.getAttribute("aria-hidden")).toBe("true");
  });
});

describe("TopNav Work group menu", () => {
  function groupProps(overrides: Record<string, unknown> = {}) {
    return {
      currentTab: "chat",
      onSelectTab: () => {},
      health: null,
      runsBadge: 0,
      approvalsBadge: 0,
      goalsBadge: 0,
      onRequestNotifications: () => {},
      ...overrides,
    } as unknown as ComponentProps<typeof TopNav>;
  }

  function renderGroupNav(overrides: Record<string, unknown> = {}) {
    return render(<TopNav {...groupProps(overrides)} />);
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
  });

  it("rolls normalized child badges up and reports leaf badges", () => {
    // Membership math is shared contract, not view state: Work sums every
    // child through the same fail-closed normalizer the flat tabs use, while a
    // non-nesting entry (approvals) simply reports its own badge.
    expect(rolledUpBadge("work", { goals: 2, runs: 3 })).toBe(5);
    // Fractions floor, negatives collapse to zero, and schedules contributes.
    expect(rolledUpBadge("work", { goals: -1, runs: 2.9, schedules: 1 })).toBe(3);
    expect(rolledUpBadge("work", {})).toBe(0);
    expect(rolledUpBadge("approvals", { approvals: 7 })).toBe(7);
  });

  it("treats group membership as active and unknown groups as inactive", () => {
    expect(isGroupActive("work", "goals")).toBe(true);
    expect(isGroupActive("work", "runs")).toBe(true);
    expect(isGroupActive("work", "chat")).toBe(false);
    expect(isGroupActive("approvals", "approvals")).toBe(true);
    expect(isGroupActive("approvals", "runs")).toBe(false);
  });

  it("marks the Work trigger active whenever any child tab is selected", () => {
    const { rerender } = renderGroupNav({ currentTab: "goals" });
    expect(screen.getByRole("button", { name: "Work" }).className).toContain(
      "active",
    );

    rerender(<TopNav {...groupProps({ currentTab: "schedules" })} />);
    expect(screen.getByRole("button", { name: "Work" }).className).toContain(
      "active",
    );

    // A tab outside the group leaves the trigger inactive.
    rerender(<TopNav {...groupProps({ currentTab: "memory" })} />);
    expect(screen.getByRole("button", { name: "Work" }).className).not.toContain(
      "active",
    );
  });

  it("switches tab and closes the menu when a child is selected", async () => {
    const user = userEvent.setup();
    const onSelectTab = vi.fn();
    renderGroupNav({ onSelectTab });
    await user.click(screen.getByRole("button", { name: "Work" }));
    await user.click(screen.getByRole("menuitem", { name: "Goals" }));
    expect(onSelectTab).toHaveBeenCalledWith("goals");
    expect(screen.queryByRole("menu", { name: "Work sections" })).toBeNull();
  });

  it("highlights the active child inside the menu", async () => {
    const user = userEvent.setup();
    renderGroupNav({ currentTab: "runs" });
    // The active child must be reachable even while the parent menu is closed
    // on first render: opening Work reveals Runs already highlighted.
    await user.click(screen.getByRole("button", { name: "Work" }));
    expect(screen.getByRole("menuitem", { name: "Runs" }).className).toContain(
      "active",
    );
  });

  it("closes the menu on Escape and returns focus to the trigger", async () => {
    const user = userEvent.setup();
    renderGroupNav();
    const trigger = screen.getByRole("button", { name: "Work" });
    await user.click(trigger);
    expect(
      screen.getByRole("menu", { name: "Work sections" }),
    ).toBeInTheDocument();
    await user.keyboard("{Escape}");
    await waitFor(() => {
      expect(screen.queryByRole("menu", { name: "Work sections" })).toBeNull();
    });
    expect(document.activeElement).toBe(trigger);
  });

  it("does not open the Work menu on mouseenter", () => {
    renderGroupNav();
    const trigger = screen.getByRole("button", { name: "Work" });
    // No hover-open path: pointer hover must never toggle the menu, which is
    // what removes the hover-plus-click ordering race the profile menu fixed.
    fireEvent.mouseEnter(trigger);
    fireEvent.mouseOver(trigger);
    expect(screen.queryByRole("menu", { name: "Work sections" })).toBeNull();
  });

  it("rolls child badges into the Work trigger display", () => {
    renderGroupNav({ goalsBadge: 2, runsBadge: 3 });
    const trigger = screen.getByRole("button", { name: "Work, 5 unread" });
    expect(trigger.querySelector(".nav-badge")?.textContent).toBe("5");
    expect(trigger.getAttribute("aria-haspopup")).toBe("menu");
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
  });

  it("pushes the rolled-up total down to each unread Work child", async () => {
    // Collapsed and expanded readings stay auditable together: the trigger keeps the rolled-up
    // total while the open menu attributes the same unread share to its owning child, so the driver
    // of the count is visible without opening another surface.
    const user = userEvent.setup();
    renderGroupNav({ runsBadge: 3 });
    const trigger = screen.getByRole("button", { name: "Work, 3 unread" });
    expect(trigger.querySelector(".nav-badge")?.textContent).toBe("3");
    await user.click(trigger);
    const runsItem = screen.getByRole("menuitem", {
      name: "Runs, 3 unread",
    });
    expect(
      runsItem.querySelector(".nav-dropdown-item-badge")?.textContent,
    ).toBe("3");
    expect(
      runsItem
        .querySelector(".nav-dropdown-item-badge")
        ?.getAttribute("aria-hidden"),
    ).toBe("true");
    // Children without an unread share stay pill-free so only actionable
    // rows draw the eye.
    expect(
      screen
        .getByRole("menuitem", { name: "Goals" })
        .querySelector(".nav-dropdown-item-badge"),
    ).toBeNull();
    expect(
      screen
        .getByRole("menuitem", { name: "Schedules" })
        .querySelector(".nav-dropdown-item-badge"),
    ).toBeNull();
  });

  it("matches each Work child pill to its own unread share", async () => {
    // Split totals stay attributable: each child pill renders its own count
    // while the trigger keeps the summed total for the collapsed reading.
    const user = userEvent.setup();
    renderGroupNav({ goalsBadge: 2, runsBadge: 1 });
    const trigger = screen.getByRole("button", { name: "Work, 3 unread" });
    expect(trigger.querySelector(".nav-badge")?.textContent).toBe("3");
    await user.click(trigger);
    expect(
      screen
        .getByRole("menuitem", { name: "Goals, 2 unread" })
        .querySelector(".nav-dropdown-item-badge")?.textContent,
    ).toBe("2");
    expect(
      screen
        .getByRole("menuitem", { name: "Runs, 1 unread" })
        .querySelector(".nav-dropdown-item-badge")?.textContent,
    ).toBe("1");
    expect(
      screen
        .getByRole("menuitem", { name: "Schedules" })
        .querySelector(".nav-dropdown-item-badge"),
    ).toBeNull();
  });

  it("renders no child pills when Work has no unread", async () => {
    // Zero stays quiet: the open rows mint no pill until work arrives, so the
    // menu reads as plain navigation at rest.
    const user = userEvent.setup();
    renderGroupNav();
    await user.click(screen.getByRole("button", { name: "Work" }));
    expect(
      screen.getByRole("menu", { name: "Work sections" }),
    ).toBeInTheDocument();
    expect(document.querySelector(".nav-dropdown-item-badge")).toBeNull();
  });

  it("closes the menu when a click lands outside the group", async () => {
    const user = userEvent.setup();
    renderGroupNav();
    await user.click(screen.getByRole("button", { name: "Work" }));
    expect(
      screen.getByRole("menu", { name: "Work sections" }),
    ).toBeInTheDocument();
    // A click on the document body (outside the container) dismisses the menu.
    fireEvent.mouseDown(document.body);
    await waitFor(() => {
      expect(screen.queryByRole("menu", { name: "Work sections" })).toBeNull();
    });
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

describe("TopNav operator profile", () => {
  const HEALTH = {
    status: "ok",
    engine: "Rune Weaver",
    version: "0.1.0",
    model: "gemma-4-9b",
    provider: "mlx",
  };

  function renderPersonaNav(overrides: Record<string, unknown> = {}) {
    const props = {
      currentTab: "chat",
      onSelectTab: () => {},
      health: HEALTH,
      runsBadge: 0,
      approvalsBadge: 0,
      goalsBadge: 0,
      onRequestNotifications: () => {},
      ...overrides,
    } as unknown as ComponentProps<typeof TopNav>;
    return render(<TopNav {...props} />);
  }

  async function openProfileMenu(user: ReturnType<typeof userEvent.setup>) {
    await user.click(
      screen.getByRole("button", { name: /Profile and Settings menu/i }),
    );
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    // The persona store is a module singleton: every test starts detached so a
    // prior publish can never leak a saved identity into a fallback check.
    resetPersonaSignalsForTesting();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
  });

  it("keeps the trigger label static Profile with a persona set", async () => {
    const user = userEvent.setup();
    publishPersonaFromSettings({
      assistantName: "Weaver",
      tone: "warm",
      style: "",
      userName: "Kupan",
      avatar: "rose",
    });
    renderPersonaNav();
    // The trigger never shows the assistant name: it stays a static label
    // even when a persona is saved.
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
    await openProfileMenu(user);
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    // The menu header carries operator identity, so the owner name renders
    // there while the assistant name stays absent.
    expect(document.querySelector(".profile-name")?.textContent).toBe("Kupan");
    expect(document.querySelector(".profile-avatar img")).toBeNull();
    // The health model line stays exactly where it was beside the new identity.
    expect(screen.getByText("gemma-4-9b")).toBeInTheDocument();
  });

  it("keeps the trigger label static Profile without a persona", async () => {
    const user = userEvent.setup();
    renderPersonaNav();
    // An absent persona leaves the trigger on its static label with no
    // avatar image anywhere in the profile block.
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    await openProfileMenu(user);
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(document.querySelector(".profile-name")?.textContent).toBe(
      "Operator",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-avatar img")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
  });

  it("shows the stored owner name in the menu header", async () => {
    const user = userEvent.setup();
    publishPersonaFromSettings({
      assistantName: "Weaver",
      tone: "warm",
      style: "",
      userName: "Kupan",
      avatar: "rose",
    });
    renderPersonaNav();
    await openProfileMenu(user);
    // Operator space shows operator identity only: the owner name renders in
    // the header while the assistant name appears nowhere in this bar.
    expect(document.querySelector(".profile-name")?.textContent).toBe("Kupan");
    expect(screen.getByText("Kupan")).toBeInTheDocument();
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
  });

  it("falls back to Operator when no owner name exists", async () => {
    const user = userEvent.setup();
    renderPersonaNav();
    await openProfileMenu(user);
    // Absent persona is an operator fallback, not an empty string: the header
    // reads "Operator" while the trigger keeps its static label.
    expect(document.querySelector(".profile-name")?.textContent).toBe(
      "Operator",
    );
    expect(screen.getByText("Operator")).toBeInTheDocument();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
  });

  it("falls back to Operator when the owner name is blank", async () => {
    const user = userEvent.setup();
    // Blank normalizes like absent (same trim rule as the greeting row), so a
    // whitespace-only owner name never renders an empty header.
    publishPersonaFromSettings({
      assistantName: "Weaver",
      userName: "   ",
      avatar: "rose",
    });
    renderPersonaNav();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    await openProfileMenu(user);
    expect(document.querySelector(".profile-name")?.textContent).toBe(
      "Operator",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
  });

  it("never renders the assistant name in any TopNav state", async () => {
    const user = userEvent.setup();
    // With a persona set: the owner name shows, the assistant name does not —
    // neither on the trigger nor in the open menu.
    publishPersonaFromSettings({
      assistantName: "Weaver",
      userName: "Kupan",
      avatar: "rose",
    });
    const { unmount } = renderPersonaNav();
    expect(screen.queryByText("Weaver")).toBeNull();
    await openProfileMenu(user);
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-name")?.textContent).toBe("Kupan");
    unmount();
    // Without a persona: the assistant name is still absent and the header
    // falls back to the operator stock label.
    resetPersonaSignalsForTesting();
    renderPersonaNav();
    // The second mount starts the one-shot settings probe (personaLoaded is
    // false after the reset). Await its publish so the store-driven re-render
    // settles inside act instead of after the test.
    await waitFor(() => {
      expect(peekPersonaSignals().personaLoaded).toBe(true);
    });
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
  });

  it("keeps text identity with zero avatar nodes for an assistant-only persona", async () => {
    const user = userEvent.setup();
    // An assistant-only save still shows operator fallback here: the owner
    // slot has no value, so the header reads "Operator" and the assistant
    // name never leaks into either surface.
    publishPersonaFromSettings({ assistantName: "Weaver", avatar: "chartreuse" });
    renderPersonaNav();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    await openProfileMenu(user);
    expect(document.querySelector(".profile-name")?.textContent).toBe(
      "Operator",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
  });

  it("renders zero avatar nodes when the approvals badge counts pending filings", () => {
    // The badge still publishes the shared attention signal for the greeting
    // cluster, but this bar never renders the image itself.
    publishPersonaFromSettings({
      assistantName: "Weaver",
      userName: "Kupan",
      avatar: "cyan",
    });
    renderPersonaNav({ approvalsBadge: 2 });
    expect(document.querySelector(".persona-avatar")).toBeNull();
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
  });

  it("renders zero avatar nodes for an unread goal nudge alone", () => {
    publishPersonaFromSettings({
      assistantName: "Weaver",
      userName: "Kupan",
      avatar: "cyan",
    });
    renderPersonaNav({ goalsBadge: 1 });
    expect(document.querySelector(".persona-avatar")).toBeNull();
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(screen.queryByText("Weaver")).toBeNull();
  });

  it("mirrors an owner rename saved elsewhere into the mounted profile block without a remount", async () => {
    const user = userEvent.setup();
    renderPersonaNav();
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    await openProfileMenu(user);
    // The open menu starts on the operator fallback before any owner name is
    // stored.
    expect(document.querySelector(".profile-name")?.textContent).toBe(
      "Operator",
    );
    // The shared store notifies outside the render cycle, so the publish runs
    // inside act to keep the state update attached to this test's render.
    act(() => {
      publishPersonaFromSettings({
        assistantName: "Weaver",
        userName: "Kupan",
        avatar: "emerald",
      });
    });
    // The live rename mirrors the owner name only; the assistant name never
    // mounts alongside it and no image mounts either.
    await waitFor(() => {
      expect(document.querySelector(".profile-name")?.textContent).toBe(
        "Kupan",
      );
    });
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    expect(document.querySelector(".persona-avatar")).toBeNull();
  });

  it("keeps the Operator identity when the settings read fails on mount", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("offline");
      }),
    );
    renderPersonaNav();
    expect(document.querySelector(".profile-btn-label")?.textContent).toBe(
      "Profile",
    );
    await openProfileMenu(user);
    // Trigger plus header share the operator fallback when the read fails.
    expect(document.querySelector(".profile-name")?.textContent).toBe(
      "Operator",
    );
    expect(screen.getByText("Operator")).toBeInTheDocument();
    expect(screen.queryByText("Weaver")).toBeNull();
    expect(document.querySelector(".profile-dropdown-btn img")).toBeNull();
    expect(document.querySelector(".persona-avatar")).toBeNull();
  });
});
