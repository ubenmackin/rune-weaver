// Rune Weaver Dashboard — Unit tests for useMobilePush hook and helpers.

import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  arrayBufferToBase64Url,
  isMobileStandalonePWA,
  urlBase64ToUint8Array,
  useMobilePush,
} from "./useMobilePush";
import * as pushApi from "../api/push";

vi.mock("../api/push");

describe("useMobilePush helpers", () => {
  it("converts between base64url and Uint8Array correctly", () => {
    // Canonical base64url encoded string
    const raw = "YWJjXzEyMy14eXo"; // btoa("abc_123-xyz")
    const bytes = urlBase64ToUint8Array(raw);
    expect(bytes).toBeInstanceOf(Uint8Array);

    const roundtrip = arrayBufferToBase64Url(bytes.buffer);
    expect(roundtrip).toBe(raw);
  });

  it("detects mobile standalone display-mode", () => {
    const matchMediaMock = vi.fn().mockImplementation((query: string) => ({
      matches: query.includes("display-mode: standalone"),
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }));
    vi.stubGlobal("matchMedia", matchMediaMock);

    expect(isMobileStandalonePWA()).toBe(true);
  });

  it("detects iOS navigator.standalone", () => {
    vi.stubGlobal("matchMedia", () => ({ matches: false }));
    Object.defineProperty(window.navigator, "standalone", {
      value: true,
      configurable: true,
    });

    expect(isMobileStandalonePWA()).toBe(true);

    Object.defineProperty(window.navigator, "standalone", {
      value: false,
      configurable: true,
    });
    expect(isMobileStandalonePWA()).toBe(false);
  });
});

describe("useMobilePush hook", () => {
  let mockPushSubscription: {
    endpoint: string;
    getKey: (name: string) => ArrayBuffer | null;
    unsubscribe: () => Promise<boolean>;
  } | null = null;

  let mockPushManager: {
    getSubscription: () => Promise<typeof mockPushSubscription>;
    subscribe: () => Promise<typeof mockPushSubscription>;
  };

  let mockRegistration: {
    pushManager: typeof mockPushManager;
  };

  beforeEach(() => {
    vi.clearAllMocks();

    mockPushSubscription = null;

    mockPushManager = {
      getSubscription: vi.fn(async () => mockPushSubscription),
      subscribe: vi.fn(async () => {
        mockPushSubscription = {
          endpoint: "https://web.push.apple.com/sub/test-token",
          getKey: vi.fn((name: string) => {
            if (name === "p256dh") return new Uint8Array([1, 2, 3, 4]).buffer;
            if (name === "auth") return new Uint8Array([5, 6, 7, 8]).buffer;
            return null;
          }),
          unsubscribe: vi.fn(async () => {
            mockPushSubscription = null;
            return true;
          }),
        };
        return mockPushSubscription;
      }),
    };

    mockRegistration = {
      pushManager: mockPushManager,
    };

    vi.stubGlobal("matchMedia", (query: string) => ({
      matches: query.includes("display-mode: standalone"),
    }));

    vi.stubGlobal("Notification", {
      permission: "granted",
      requestPermission: vi.fn(async () => "granted"),
    });

    vi.stubGlobal("PushManager", class {});

    const mockServiceWorker = {
      getRegistration: vi.fn(async () => mockRegistration),
      register: vi.fn(async () => mockRegistration),
      ready: Promise.resolve(mockRegistration),
    };

    Object.defineProperty(navigator, "serviceWorker", {
      value: mockServiceWorker,
      configurable: true,
    });

    vi.mocked(pushApi.getVapidPublicKey).mockResolvedValue({
      publicKey: "BMockPublicKeyForTestingPurposes1234567890",
    });

    vi.mocked(pushApi.registerPushSubscription).mockResolvedValue({
      status: "registered",
      endpoint: "https://web.push.apple.com/sub/test-token",
    });

    vi.mocked(pushApi.unregisterPushSubscription).mockResolvedValue({
      status: "unregistered",
      removed: true,
    });

    vi.mocked(pushApi.sendTestPushNotification).mockResolvedValue({
      status: "ok",
      delivered: 1,
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("initializes as subscribed when service worker has active subscription", async () => {
    mockPushSubscription = {
      endpoint: "https://web.push.apple.com/sub/existing-token",
      getKey: vi.fn(),
      unsubscribe: vi.fn(async () => true),
    };

    const { result } = renderHook(() => useMobilePush());

    await waitFor(() => {
      expect(result.current.isSubscribed).toBe(true);
    });
    expect(result.current.isStandalone).toBe(true);
    expect(result.current.isSupported).toBe(true);
  });

  it("subscribes successfully and communicates with push API", async () => {
    const { result } = renderHook(() => useMobilePush());

    await waitFor(() => {
      expect(result.current.isSubscribed).toBe(false);
    });

    let success = false;
    await act(async () => {
      success = await result.current.subscribeMobilePush();
    });

    expect(success).toBe(true);
    expect(result.current.isSubscribed).toBe(true);
    expect(result.current.error).toBeNull();
    expect(pushApi.getVapidPublicKey).toHaveBeenCalledTimes(1);
    expect(pushApi.registerPushSubscription).toHaveBeenCalledWith(
      expect.objectContaining({
        endpoint: "https://web.push.apple.com/sub/test-token",
      }),
    );
  });

  it("sets error when user denies notification permission", async () => {
    vi.stubGlobal("Notification", {
      permission: "denied",
      requestPermission: vi.fn(async () => "denied"),
    });

    const { result } = renderHook(() => useMobilePush());

    let success = false;
    await act(async () => {
      success = await result.current.subscribeMobilePush();
    });

    expect(success).toBe(false);
    expect(result.current.isSubscribed).toBe(false);
    expect(result.current.error).toMatch(/Notification permission denied/);
  });

  it("unsubscribes and calls unregisterPushSubscription", async () => {
    mockPushSubscription = {
      endpoint: "https://web.push.apple.com/sub/existing-token",
      getKey: vi.fn(),
      unsubscribe: vi.fn(async () => true),
    };

    const { result } = renderHook(() => useMobilePush());

    await waitFor(() => {
      expect(result.current.isSubscribed).toBe(true);
    });

    let success = false;
    await act(async () => {
      success = await result.current.unsubscribeMobilePush();
    });

    expect(success).toBe(true);
    expect(result.current.isSubscribed).toBe(false);
    expect(pushApi.unregisterPushSubscription).toHaveBeenCalledWith(
      "https://web.push.apple.com/sub/existing-token",
    );
  });

  it("dispatches test push notification and returns count", async () => {
    const { result } = renderHook(() => useMobilePush());

    let count = 0;
    await act(async () => {
      count = await result.current.sendTestPush();
    });

    expect(count).toBe(1);
    expect(pushApi.sendTestPushNotification).toHaveBeenCalledTimes(1);
  });
});
