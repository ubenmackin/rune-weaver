// Rune Weaver Dashboard — Hook managing Web Push registration for standalone mobile PWAs.

import { useCallback, useEffect, useState } from "react";
import {
  getVapidPublicKey,
  PushTestResponse,
  registerPushSubscription,
  sendTestPushNotification,
  unregisterPushSubscription,
} from "../api/push";

// Detects standalone display mode on mobile devices (e.g. iOS Home Screen PWA).
export function isMobileStandalonePWA(): boolean {
  if (typeof window === "undefined") return false;
  const isStandaloneDisplay =
    window.matchMedia?.("(display-mode: standalone)")?.matches ?? false;
  const isIosStandalone =
    (window.navigator as unknown as { standalone?: boolean })?.standalone === true;
  return isStandaloneDisplay || isIosStandalone;
}

// Converts a base64url string (RFC 4648) to a Uint8Array suitable for applicationServerKey.
export function urlBase64ToUint8Array(base64String: string): Uint8Array {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

// Converts an ArrayBuffer to a base64url string without trailing padding.
export function arrayBufferToBase64Url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function useMobilePush() {
  const isStandalone = isMobileStandalonePWA();
  const isSupported =
    typeof window !== "undefined" &&
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window;

  const [isSubscribed, setIsSubscribed] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Sync current subscription status with ServiceWorkerRegistration
  const syncSubscription = useCallback(async () => {
    if (!isSupported) return;
    try {
      const registration = await navigator.serviceWorker.getRegistration();
      if (!registration) {
        setIsSubscribed(false);
        return;
      }
      const existing = await registration.pushManager.getSubscription();
      setIsSubscribed(existing !== null);
    } catch {
      setIsSubscribed(false);
    }
  }, [isSupported]);

  useEffect(() => {
    if (isStandalone && isSupported) {
      void syncSubscription();
    }
  }, [isStandalone, isSupported, syncSubscription]);

  const subscribeMobilePush = useCallback(async (): Promise<boolean> => {
    if (!isSupported) {
      setError("Web Push is not supported in this browser.");
      return false;
    }

    // On iOS Safari PWA, Notification.requestPermission() MUST be invoked synchronously
    // in direct response to the user gesture before any await ticks expire transient activation.
    let permission = Notification.permission;
    if (permission !== "granted") {
      try {
        permission = await Notification.requestPermission();
      } catch (err) {
        const message = err instanceof Error ? err.message : "Failed to request notification permission.";
        setError(message);
        return false;
      }
    }
    if (permission !== "granted") {
      setError("Notification permission was not granted.");
      return false;
    }

    setIsLoading(true);
    setError(null);
    try {
      let registration = await navigator.serviceWorker.getRegistration();
      if (!registration) {
        registration = await navigator.serviceWorker.register("/sw.js", { scope: "/" });
      }
      await navigator.serviceWorker.ready;

      const { publicKey } = await getVapidPublicKey();
      if (!publicKey) {
        throw new Error("VAPID public key unavailable from server.");
      }

      const applicationServerKey = urlBase64ToUint8Array(publicKey);
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: applicationServerKey as BufferSource,
      });

      const p256dhKey = subscription.getKey("p256dh");
      const authKey = subscription.getKey("auth");
      if (!p256dhKey || !authKey) {
        throw new Error("Failed to extract subscription encryption keys.");
      }

      const p256dh = arrayBufferToBase64Url(p256dhKey);
      const auth = arrayBufferToBase64Url(authKey);

      await registerPushSubscription({
        endpoint: subscription.endpoint,
        p256dh,
        auth,
        userAgent: navigator.userAgent,
      });

      setIsSubscribed(true);
      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to subscribe to push alerts.";
      setError(message);
      return false;
    } finally {
      setIsLoading(false);
    }
  }, [isSupported]);

  const unsubscribeMobilePush = useCallback(async (): Promise<boolean> => {
    if (!isSupported) return false;
    setIsLoading(true);
    setError(null);
    try {
      const registration = await navigator.serviceWorker.getRegistration();
      if (registration) {
        const subscription = await registration.pushManager.getSubscription();
        if (subscription) {
          await subscription.unsubscribe();
          await unregisterPushSubscription(subscription.endpoint);
        }
      }
      setIsSubscribed(false);
      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to unsubscribe.";
      setError(message);
      return false;
    } finally {
      setIsLoading(false);
    }
  }, [isSupported]);

  const sendTestPush = useCallback(async (): Promise<PushTestResponse> => {
    setIsLoading(true);
    setError(null);
    try {
      const res = await sendTestPushNotification();
      return res;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to send test push notification.";
      setError(message);
      return { status: "failed", delivered: 0, totalSubscribers: 0, errors: [message] };
    } finally {
      setIsLoading(false);
    }
  }, []);

  return {
    isStandalone,
    isSupported,
    isSubscribed,
    isLoading,
    error,
    subscribeMobilePush,
    unsubscribeMobilePush,
    sendTestPush,
  };
}
