// Rune Weaver Dashboard — Web Push API client and wire types for mobile PWA push.

import { fetchJson } from "./http";

export interface VapidPublicKeyResponse {
  publicKey: string;
}

export interface PushSubscriptionPayload {
  endpoint: string;
  p256dh: string;
  auth: string;
  userAgent?: string;
}

export interface PushSubscriptionResponse {
  status: string;
  endpoint: string;
}

export interface PushUnsubscribePayload {
  endpoint: string;
}

export interface PushUnsubscribeResponse {
  status: string;
  removed: boolean;
}

export interface PushTestResponse {
  status: string;
  delivered: number;
}

export async function getVapidPublicKey(options?: RequestInit): Promise<VapidPublicKeyResponse> {
  return fetchJson<VapidPublicKeyResponse>("/push/vapid-public-key", {
    method: "GET",
    ...options,
  });
}

export async function registerPushSubscription(
  payload: PushSubscriptionPayload,
  options?: RequestInit,
): Promise<PushSubscriptionResponse> {
  return fetchJson<PushSubscriptionResponse>("/push/subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    ...options,
  });
}

export async function unregisterPushSubscription(
  endpoint: string,
  options?: RequestInit,
): Promise<PushUnsubscribeResponse> {
  return fetchJson<PushUnsubscribeResponse>("/push/subscriptions", {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ endpoint }),
    ...options,
  });
}

export async function sendTestPushNotification(options?: RequestInit): Promise<PushTestResponse> {
  return fetchJson<PushTestResponse>("/push/test", {
    method: "POST",
    ...options,
  });
}
