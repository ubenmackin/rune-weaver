// Rune Weaver Dashboard — Unit tests for MobilePushSettingsCard component.

import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MobilePushSettingsCard } from "./MobilePushSettingsCard";
import * as useMobilePushModule from "../../hooks/useMobilePush";

vi.mock("../../hooks/useMobilePush");

describe("MobilePushSettingsCard", () => {
  const defaultHookValues = {
    isStandalone: true,
    isSupported: true,
    isSubscribed: false,
    isLoading: false,
    error: null,
    subscribeMobilePush: vi.fn(),
    unsubscribeMobilePush: vi.fn(),
    sendTestPush: vi.fn().mockResolvedValue({ status: "ok", delivered: 1, totalSubscribers: 1, errors: [] }),
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
    });
  });

  it("renders null when not in mobile standalone mode", () => {
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
      isStandalone: false,
    });

    const { container } = render(<MobilePushSettingsCard />);
    expect(container.firstChild).toBeNull();
  });

  it("renders unsupported message when push is not available in browser", () => {
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
      isSupported: false,
    });

    render(<MobilePushSettingsCard />);
    expect(
      screen.getByText(/Web Push is not available in this browser configuration/i),
    ).toBeInTheDocument();
  });

  it("renders inactive state with enable button and calls subscribe on click", () => {
    const subscribeMock = vi.fn().mockResolvedValue(true);
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
      isSubscribed: false,
      subscribeMobilePush: subscribeMock,
    });

    render(<MobilePushSettingsCard />);
    expect(screen.getByText("Push Notifications Inactive")).toBeInTheDocument();

    const toggleBtn = screen.getByTestId("toggle-mobile-push-btn");
    expect(toggleBtn).toHaveTextContent("Enable Push");

    fireEvent.click(toggleBtn);
    expect(subscribeMock).toHaveBeenCalledTimes(1);
  });

  it("renders active state with disable button and send test button", async () => {
    const unsubscribeMock = vi.fn().mockResolvedValue(true);
    const sendTestMock = vi.fn().mockResolvedValue({ status: "ok", delivered: 2, totalSubscribers: 2, errors: [] });
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
      isSubscribed: true,
      unsubscribeMobilePush: unsubscribeMock,
      sendTestPush: sendTestMock,
    });

    render(<MobilePushSettingsCard />);
    expect(screen.getByText("Push Notifications Active")).toBeInTheDocument();

    const toggleBtn = screen.getByTestId("toggle-mobile-push-btn");
    expect(toggleBtn).toHaveTextContent("Disable Push");

    fireEvent.click(toggleBtn);
    expect(unsubscribeMock).toHaveBeenCalledTimes(1);

    const testBtn = screen.getByTestId("send-test-push-btn");
    expect(testBtn).toBeInTheDocument();

    fireEvent.click(testBtn);
    expect(sendTestMock).toHaveBeenCalledTimes(1);
    expect(await screen.findByText("Test push delivered to 2 devices!")).toBeInTheDocument();
  });

  it("renders server error feedback when test push delivery fails", async () => {
    const sendTestMock = vi.fn().mockResolvedValue({
      status: "failed",
      delivered: 0,
      totalSubscribers: 1,
      errors: ["Apple APNs HTTP 400: BadJwtToken"],
    });
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
      isSubscribed: true,
      sendTestPush: sendTestMock,
    });

    render(<MobilePushSettingsCard />);
    const testBtn = screen.getByTestId("send-test-push-btn");
    fireEvent.click(testBtn);

    expect(await screen.findByText("Delivery failed: Apple APNs HTTP 400: BadJwtToken")).toBeInTheDocument();
  });

  it("renders error banner when error is present", () => {
    vi.mocked(useMobilePushModule.useMobilePush).mockReturnValue({
      ...defaultHookValues,
      error: "Notification permission denied by user.",
    });

    render(<MobilePushSettingsCard />);
    expect(
      screen.getByText("Notification permission denied by user."),
    ).toBeInTheDocument();
  });
});
