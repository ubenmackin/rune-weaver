// Rune Weaver Dashboard — Mobile bottom navigation matrix for handheld viewports.

import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import MobileBottomNav from "./MobileBottomNav";
import { NAV_GROUPS, formatBadgeCount, normalizeBadgeCount } from "./navigationConfig";

const ORDERED_GROUPS = ["dashboard", "chat", "approvals", "work", "memory"] as const;
const ORDERED_LABELS = ["Dashboard", "Chat", "Inbox", "Work", "Memory"];

describe("MobileBottomNav tab contract", () => {
  it("renders exactly five groups in fixed order with no Settings entry", () => {
    render(<MobileBottomNav currentTab="chat" onSelectTab={() => {}} />);
    const tabs = screen.getAllByRole("button");
    expect(tabs).toHaveLength(5);
    expect(tabs.map((tab) => tab.getAttribute("aria-label"))).toEqual(ORDERED_LABELS);
    expect(tabs.map((tab) => tab.textContent)).toEqual(
      expect.arrayContaining(ORDERED_LABELS),
    );
    // Settings lives in the profile menu only and must never join the bar.
    expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();
    expect(NAV_GROUPS.map((item) => item.id)).toEqual([...ORDERED_GROUPS]);
  });

  it("marks only the selected tab active and fails closed on unknown ids", () => {
    const { rerender } = render(<MobileBottomNav currentTab="runs" onSelectTab={() => {}} />);
    const tabs = screen.getAllByRole("button");
    const active = tabs.filter((tab) => tab.className.includes("active"));
    expect(active).toHaveLength(1);
    expect(active[0].getAttribute("aria-label")).toBe("Work");
    expect(active[0].getAttribute("aria-current")).toBe("page");

    // Memory group active when indexing is selected
    rerender(<MobileBottomNav currentTab="indexing" onSelectTab={() => {}} />);
    const memoryActive = screen
      .getAllByRole("button")
      .filter((tab) => tab.className.includes("active"));
    expect(memoryActive).toHaveLength(1);
    expect(memoryActive[0].getAttribute("aria-label")).toBe("Memory");

    // An unknown id (for example a profile-only tab) highlights nothing
    // instead of guessing a nearby section.
    rerender(<MobileBottomNav currentTab="settings" onSelectTab={() => {}} />);
    expect(
      screen.getAllByRole("button").filter((tab) => tab.className.includes("active")),
    ).toHaveLength(0);
  });

  it("routes direct tabs and toggles drop-up menus for groups", async () => {
    const user = userEvent.setup();
    const onSelectTab = vi.fn();
    render(<MobileBottomNav currentTab="chat" onSelectTab={onSelectTab} />);

    // Direct tab
    await user.click(screen.getByRole("button", { name: "Inbox" }));
    expect(onSelectTab).toHaveBeenCalledWith("approvals");

    // Work drop-up
    await user.click(screen.getByRole("button", { name: "Work" }));
    expect(screen.getByRole("menu", { name: "Work sections" })).toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "Goals" }));
    expect(onSelectTab).toHaveBeenCalledWith("goals");
    expect(screen.queryByRole("menu", { name: "Work sections" })).toBeNull();

    // Memory drop-up
    await user.click(screen.getByRole("button", { name: "Memory" }));
    expect(screen.getByRole("menu", { name: "Memory sections" })).toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "Index Status" }));
    expect(onSelectTab).toHaveBeenCalledWith("indexing");
    expect(screen.queryByRole("menu", { name: "Memory sections" })).toBeNull();
  });

  it("exposes the distinct mobile sections landmark for assistive tech", () => {
    render(<MobileBottomNav currentTab="chat" onSelectTab={() => {}} />);
    expect(
      screen.getByRole("navigation", { name: "Dashboard sections (mobile)" }),
    ).toBeInTheDocument();
  });
});

describe("MobileBottomNav badge contract", () => {
  it("hides badges when counts are zero or absent", () => {
    render(<MobileBottomNav currentTab="chat" onSelectTab={() => {}} />);
    expect(screen.queryByText("1")).toBeNull();
    expect(document.querySelector(".mobile-bottom-tab-badge")).toBeNull();
  });

  it.each([
    { count: 1, text: "1" },
    { count: 2, text: "2" },
    { count: 99, text: "99" },
  ])("shows the count verbatim for $count unread", ({ count, text }) => {
    render(<MobileBottomNav currentTab="chat" onSelectTab={() => {}} runsBadge={count} />);
    const badge = document.querySelector(".mobile-bottom-tab-badge");
    expect(badge?.textContent).toBe(text);
    // The visual pill stays presentational while the owning button carries
    // the honest unclamped count in its accessible name.
    expect(badge?.getAttribute("aria-hidden")).toBe("true");
    expect(badge?.getAttribute("aria-label")).toBeNull();
    const workTab = screen.getByRole("button", { name: `Work, ${count} unread` });
    expect(workTab.getAttribute("aria-label")).toBe(`Work, ${count} unread`);
    expect(formatBadgeCount(count)).toBe(text);
  });

  it("caps triple-digit counts at 99+ while keeping the honest accessible count", () => {
    render(
      <MobileBottomNav currentTab="chat" onSelectTab={() => {}} approvalsBadge={100} runsBadge={250} />,
    );
    const badges = Array.from(document.querySelectorAll(".mobile-bottom-tab-badge"));
    expect(badges.map((badge) => badge.textContent)).toEqual(["99+", "99+"]);
    // Presentational pills stay hidden; the buttons announce the unclamped totals.
    expect(badges.map((badge) => badge.getAttribute("aria-hidden"))).toEqual([
      "true",
      "true",
    ]);
    expect(
      screen.getByRole("button", { name: "Inbox, 100 unread" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Work, 250 unread" }),
    ).toBeInTheDocument();
    expect(formatBadgeCount(100)).toBe("99+");
    expect(formatBadgeCount(101)).toBe("99+");
  });

  it("covers the 0 / 1 / 99 / 100 badge edges without regressions", () => {
    expect(formatBadgeCount(0)).toBe("");
    expect(formatBadgeCount(1)).toBe("1");
    expect(formatBadgeCount(99)).toBe("99");
    expect(formatBadgeCount(100)).toBe("99+");
  });

  it("keeps approvals badge on approvals and rolls runs badge into work", () => {
    render(
      <MobileBottomNav currentTab="chat" onSelectTab={() => {}} approvalsBadge={3} runsBadge={5} />,
    );
    const approvalsTab = screen.getByRole("button", { name: "Inbox, 3 unread" });
    const workTab = screen.getByRole("button", { name: "Work, 5 unread" });
    expect(approvalsTab.textContent).toContain("3");
    expect(workTab.textContent).toContain("5");
    expect(screen.getByRole("button", { name: "Chat" }).querySelector(".mobile-bottom-tab-badge")).toBeNull();
    expect(screen.getByRole("button", { name: "Memory" }).querySelector(".mobile-bottom-tab-badge")).toBeNull();
  });

  it("prefers the explicit per-tab badge map over the named props", () => {
    render(
      <MobileBottomNav
        currentTab="chat"
        onSelectTab={() => {}}
        approvalsBadge={7}
        badges={{ approvals: 4 }}
      />,
    );
    const approvalsTab = screen.getByRole("button", { name: "Inbox, 4 unread" });
    expect(approvalsTab.textContent).toContain("4");
    expect(approvalsTab.textContent).not.toContain("7");
  });

  it("fails closed on non-positive and non-finite badge inputs", () => {
    render(
      <MobileBottomNav
        currentTab="chat"
        onSelectTab={() => {}}
        approvalsBadge={Number.NaN}
        runsBadge={-2}
        badges={{ chat: 0, memory: -1 }}
      />,
    );
    expect(document.querySelector(".mobile-bottom-tab-badge")).toBeNull();
  });

  it("announces the badge through the owning button while the pill stays presentational", () => {
    render(
      <MobileBottomNav currentTab="chat" onSelectTab={() => {}} runsBadge={5} />,
    );
    // Buttons without badges keep the plain label as their accessible name.
    expect(screen.getByRole("button", { name: "Chat" })).toBeInTheDocument();
    // Buttons with badges compose the honest count into the accessible name
    // because the pill itself is hidden from assistive tech.
    expect(screen.getByRole("button", { name: "Work, 5 unread" })).toBeInTheDocument();
  });

  it("shares badge normalization with the desktop nav through one helper", () => {
    expect(normalizeBadgeCount(Number.NaN)).toBe(0);
    expect(normalizeBadgeCount(-2)).toBe(0);
    expect(normalizeBadgeCount(0)).toBe(0);
    expect(normalizeBadgeCount(2.7)).toBe(2);
    expect(normalizeBadgeCount(250)).toBe(250);
    expect(normalizeBadgeCount("3" as unknown as number)).toBe(0);
  });
});
