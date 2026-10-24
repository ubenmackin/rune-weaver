// Rune Weaver Dashboard — Tests for TopNav bell acknowledgment and badge clearing.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import TopNav from "./TopNav";
import { resetPersonaSignalsForTesting } from "./PersonaAvatar";

function jsonResponse(payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

describe("TopNav bell badge acknowledgment", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetPersonaSignalsForTesting();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
  });

  it("shows Zero unread warnings without requesting browser notification permission", async () => {
    const user = userEvent.setup();
    const requestPermission = vi.fn(async () => "denied" as NotificationPermission);
    vi.stubGlobal("Notification", {
      permission: "denied",
      requestPermission,
    });
    const onClearBadges = vi.fn();

    render(
      <TopNav
        currentTab="dashboard"
        onSelectTab={() => {}}
        health={null}
        onClearBadges={onClearBadges}
      />,
    );

    const bell = screen.getByRole("button", { name: "Alerts" });
    await user.click(bell);

    expect(onClearBadges).toHaveBeenCalledTimes(1);
    expect(requestPermission).not.toHaveBeenCalled();
    await waitFor(() => {
      expect(screen.getByText("Zero unread warnings.")).toBeInTheDocument();
    });
    expect(screen.queryByText(/Notifications blocked/i)).toBeNull();
  });

  it("clears unread badges and toasts Unread badges cleared when runs or approvals have unread counts", async () => {
    const user = userEvent.setup();
    const onClearBadges = vi.fn();

    render(
      <TopNav
        currentTab="dashboard"
        onSelectTab={() => {}}
        health={null}
        runsBadge={2}
        approvalsBadge={1}
        onClearBadges={onClearBadges}
      />,
    );

    await user.click(screen.getByRole("button", { name: "Alerts" }));
    expect(onClearBadges).toHaveBeenCalledTimes(1);
    await waitFor(() => {
      expect(screen.getByText("Unread badges cleared.")).toBeInTheDocument();
    });
  });

  it("navigates to chat and announces warning count when warningsBadge is positive", async () => {
    const user = userEvent.setup();
    const onSelectTab = vi.fn();
    const onClearBadges = vi.fn();

    render(
      <TopNav
        currentTab="dashboard"
        onSelectTab={onSelectTab}
        health={null}
        warningsBadge={2}
        onClearBadges={onClearBadges}
      />,
    );

    const bell = screen.getByRole("button", {
      name: "Alerts, 2 unread warnings",
    });
    expect(bell.className).toContain("active");
    await user.click(bell);

    expect(onClearBadges).toHaveBeenCalledTimes(1);
    expect(onSelectTab).toHaveBeenCalledWith("chat");
    await waitFor(() => {
      expect(screen.getByText("2 warnings shown in chat.")).toBeInTheDocument();
    });
  });
});
