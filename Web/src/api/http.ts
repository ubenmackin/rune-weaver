// Rune Weaver Dashboard — HTTP client, authentication state, health, and errors.
import { isRecord } from "../typeGuards";
import type { HealthResponse } from "./types";
import {
  parseMaxConcurrentChatTurns,
  MAX_CONCURRENT_CHAT_TURNS_HEADER,
} from "./types";

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

// Extracts clean, human-readable error text from an HTML response (such as an Apache, Nginx, or
// Cloudflare reverse proxy error page) to prevent raw HTML markup from leaking into user-facing
// error notices.
const maxHtmlErrorSegmentChars = 150;
export function extractHtmlErrorDetail(
  html: string,
  status: number,
  statusText: string,
): string {
  const fallback = `${status} ${statusText}`.trim() || `HTTP ${status}`;
  if (!html || typeof html !== "string") return fallback;

  // Extract explicit reason if present (e.g. Apache "Reason: <strong>...</strong>")
  const reasonMatch = html.match(/Reason:\s*(?:<[^>]+>)*\s*([^<\r\n]+)/i);
  const reason = reasonMatch
    ? reasonMatch[1].trim().slice(0, maxHtmlErrorSegmentChars)
    : null;

  // Extract title if present
  const titleMatch = html.match(/<title[^>]*>([^<]+)<\/title>/i);
  const title = titleMatch
    ? titleMatch[1].trim().slice(0, maxHtmlErrorSegmentChars)
    : null;

  if (reason) {
    const prefix = title && /^\d{3}\b/.test(title) ? title : fallback;
    return `${prefix}: ${reason}`;
  }
  if (title) {
    return title.includes(String(status)) ? title : `${fallback}: ${title}`;
  }

  // Extract h1 if present
  const h1Match = html.match(/<h1[^>]*>([^<]+)<\/h1>/i);
  if (h1Match) {
    const h1 = h1Match[1].trim().slice(0, maxHtmlErrorSegmentChars);
    return h1.includes(String(status)) ? h1 : `${fallback}: ${h1}`;
  }

  // Strip all HTML tags and collapse whitespace as a last resort
  const stripped = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  if (stripped) {
    return `${fallback}: ${stripped.slice(0, maxHtmlErrorSegmentChars)}`;
  }
  return fallback;
}

// Validates an orchestrator turn before it enters chat state: the engine always emits text,
// session, and tool actions together, so a partial object must never render as a completed reply.

// ---------------------------------------------------------------------------
// Single-owner bearer authentication
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Single-owner authentication (HttpOnly session cookie + optional bearer)
// ---------------------------------------------------------------------------


// In-memory bearer token for headless / script callers that explicitly supply one.
// Normal browser UI authentication uses HttpOnly cookies (`rw_session`) so credentials
// cannot be exfiltrated via XSS.
let authToken: string | null = null;
export let sessionAuthenticated = false;

// Listeners awaiting authentication transitions. The boot gate and the shared
// WebSocket subscribe here so a login, logout, rotation, or uniform 401 reaches
// every holder in one pass instead of each polling storage.
type AuthStateListener = (authenticated: boolean) => void;
const authStateListeners = new Set<AuthStateListener>();

// Whether the current session is authenticated via HttpOnly cookie or bearer token.
export function isSessionAuthenticated(): boolean {
  return sessionAuthenticated || authToken !== null;
}

// Notifies auth-state listeners without letting one throwing listener starve the
// others.
function notifyAuthState(): void {
  const authenticated = isSessionAuthenticated();
  for (const listener of authStateListeners) {
    try {
      listener(authenticated);
    } catch {
      // Isolate listener failures.
    }
  }
}

// Returns the live bearer token if explicitly configured (e.g. headless/test usage).
// In normal browser operations with HttpOnly cookies, credentials cannot be read
// by JavaScript to prevent exfiltration, so this returns null.
export function getAuthToken(): string | null {
  return authToken;
}

// Builds request headers for a direct same-origin fetch made outside the shared JSON helper (for
// example a non-JSON lifecycle probe), so those calls carry the owner credential too if one is
// configured.
export function authHeaders(extra?: Record<string, string>): Record<string, string> {
  const token = getAuthToken();
  return {
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(extra ?? {}),
  };
}

// Adopts an explicit bearer token as the live credential (primarily for tests/CLI).
// The token is never stored in persistent or sessionStorage.
export function setAuthToken(token: string): void {
  const trimmed = token.trim();
  if (!trimmed) return;
  authToken = trimmed;
  sessionAuthenticated = true;
  notifyAuthState();
}

// Clears authentication state from memory and instructs the engine to expire the HttpOnly session cookie via DELETE /auth/session.
export function clearAuthToken(): void {
  const hadAuth = isSessionAuthenticated();
  authToken = null;
  sessionAuthenticated = false;
  if (typeof window !== "undefined" && hadAuth) {
    try {
      fetch("/auth/session", {
        method: "DELETE",
        credentials: "same-origin",
      }).catch(() => {});
    } catch {
      // Ignore
    }
  }
  if (hadAuth) {
    notifyAuthState();
  }
}

// Subscribes to authentication transitions.
export function subscribeAuthState(listener: AuthStateListener): () => void {
  authStateListeners.add(listener);
  return () => {
    authStateListeners.delete(listener);
  };
}

// Retires a credential the engine rejected. The token is dropped and holders are
// told to fall back to login; the value is never logged, echoed in an error, or
// included in the notification, so a rejected credential stays unobserved.
function handleUnauthorized(): void {
  if (!isSessionAuthenticated()) return;
  authToken = null;
  sessionAuthenticated = false;
  notifyAuthState();
}

// Outcome of presenting a candidate token at login. Kept as a small union so the
// login view can render one honest message per case without distinguishing a
// missing credential from a wrong one beyond throttle and transport.
export type AuthenticationResult = "ok" | "invalid" | "throttled" | "unreachable";

// Validates a candidate token against POST /auth/session. On success, the engine sets
// a secure, HttpOnly, SameSite=Strict cookie ('rw_session') on the response. The raw token
// is never saved into sessionStorage, localStorage, or client memory, preventing XSS exfiltration.
export async function authenticateWithToken(token: string): Promise<AuthenticationResult> {
  const candidate = token.trim();
  if (!candidate) return "invalid";
  let response: Response;
  try {
    response = await fetch("/auth/session", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ token: candidate }),
      credentials: "same-origin",
    });
  } catch {
    return "unreachable";
  }
  if (response.ok) {
    sessionAuthenticated = true;
    notifyAuthState();
    return "ok";
  }
  if (response.status === 429) return "throttled";
  // 401 is the uniform rejection; any other status cannot be trusted as a
  // successful login either, so it degrades to the same invalid outcome.
  if (response.status === 401) return "invalid";
  return "unreachable";
}

// One-time rotation response carrying the freshly minted owner token.
export interface RotateTokenResponse {
  token: string;
}

// Rotates the owner bearer through the authenticated route and returns the new token
// for one-time copying by the user. If authenticated via HttpOnly cookie, the engine
// automatically updates the rw_session cookie in the response.
export async function rotateToken(): Promise<string> {
  const response = await fetchJson<RotateTokenResponse>("/auth/rotate", {
    method: "POST",
  });
  const token = typeof response.token === "string" ? response.token.trim() : "";
  if (!token) {
    throw new ApiError("Rotation response did not include a token", 0);
  }
  sessionAuthenticated = true;
  notifyAuthState();
  return token;
}

// Whether a health payload proves the request cleared the owner gate.
export function isAuthenticatedHealth(health: HealthResponse | null | undefined): boolean {
  if (!health) return false;
  return typeof health.engine === "string" && health.engine.length > 0;
}

export async function fetchJsonWithHeaders<T>(
  path: string,
  init?: RequestInit,
): Promise<{ data: T; headers: Headers }> {
  const hasBody = init?.body != null;
  // The owner token rides every request because auth is enforced uniformly across the engine
  // surface: without it a protected route answers the same uniform 401 as a wrong one.
  const token = getAuthToken();
  let response: Response;
  try {
    response = await fetch(path, {
      ...init,
      credentials: "same-origin",
      headers: {
        ...(hasBody ? { "Content-Type": "application/json" } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(init?.headers ?? {}),
      },
    });
  } catch (error) {
    throw new ApiError(
      error instanceof Error ? error.message : "Network request failed",
      0,
    );
  }
  if (!response.ok) {
    if (response.status === 401) {
      // Uniform 401: retire the rejected credential and route the session back to the login gate.
      handleUnauthorized();
    }
    let detail = `${response.status} ${response.statusText}`.trim();
    try {
      const text = await response.text();
      if (text) {
        // Prefer a structured server reason (Vapor `{"reason": ...}`) over a
        // raw JSON blob so callers surface a human-readable message.
        try {
          const parsed: unknown = JSON.parse(text);
          // Guard with a record check so arrays and primitives cannot leak
          // indexed fields into the error detail.
          const record = isRecord(parsed) ? parsed : null;
          const reason =
            record != null
              ? (record.reason ?? record.message ?? record.error)
              : undefined;
          detail =
            typeof reason === "string" && reason.trim()
              ? reason.trim().slice(0, 500)
              : text.slice(0, 500);
        } catch {
          const isHtml =
            text.includes("<html") ||
            text.includes("<!DOCTYPE") ||
            text.includes("<!doctype") ||
            (response.headers?.get("content-type") ?? "").includes("text/html");
          if (isHtml) {
            detail = extractHtmlErrorDetail(text, response.status, response.statusText);
          } else {
            detail = text.slice(0, 500);
          }
        }
      }
    } catch {
      // Keep the status fallback when the body is unreadable.
    }
    throw new ApiError(detail || `Request failed: ${path}`, response.status);
  }
  if (response.status === 204) {
    return { data: undefined as T, headers: response.headers };
  }
  const contentType = response.headers?.get("content-type") ?? "";
  if (contentType && !contentType.includes("application/json")) {
    throw new ApiError(`Expected JSON response: ${path}`, response.status);
  }
  try {
    const data: unknown = await response.json();
    if (data === null || data === undefined) {
      throw new Error("Null response body");
    }
    // Reject malformed engine payloads before they enter typed state:
    // primitives and arrays cannot satisfy any dashboard response shape.
    if (!isRecord(data)) {
      throw new Error("Non-record response body");
    }
    return { data: data as T, headers: response.headers };
  } catch (err) {
    throw new ApiError(
      err instanceof ApiError ? err.message : `Invalid JSON response: ${path}`,
      response.status,
    );
  }
}

export async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  // Single JSON path shared with the header-aware variant so error wording,
  // content-type checks, and record validation cannot drift per call site.
  const { data } = await fetchJsonWithHeaders<T>(path, init);
  return data;
}

export function newSessionId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export async function getHealth(): Promise<HealthResponse> {
  // Single health path prefers the server-advertised cap so admit and reject agree: the JSON
  // field wins when valid for future body-carried caps, otherwise the probe header fills it in,
  // and older engines with neither degrade to the fallback constant via the resolver.
  const { data, headers } = await fetchJsonWithHeaders<HealthResponse>("/health");
  if (isAuthenticatedHealth(data)) {
    // A restored HttpOnly cookie is invisible to JavaScript, so this probe is
    // the only observable proof of an unauthenticated to authenticated flip;
    // already-authenticated polls and unauthenticated payloads stay silent.
    const wasAuthenticated = isSessionAuthenticated();
    sessionAuthenticated = true;
    if (!wasAuthenticated) notifyAuthState();
  }
  const fromBody = parseMaxConcurrentChatTurns(data.maxConcurrentChatTurns as unknown);
  if (fromBody != null) {
    data.maxConcurrentChatTurns = fromBody;
    return data;
  }
  const fromHeader = parseMaxConcurrentChatTurns(
    headers?.get(MAX_CONCURRENT_CHAT_TURNS_HEADER),
  );
  if (fromHeader != null) {
    data.maxConcurrentChatTurns = fromHeader;
  }
  return data;
}

// Closed recovery mapping for a red pulse: exactly one primary action.
export type PulseRemediation = "none" | "rebaseline" | "openInbox" | "openPolicy";

// Re-baseline verdict mirroring the sovereign ceremony shape.
export interface RebaselineResponse {
  outcome: string;
  primaryTip: string;
  sovereignTip?: string | null;
  checkpointTip?: string | null;
  episodeCount: number;
  decision: string;
}

// Sole POST client for the sovereign re-baseline ceremony. Card and view
// delegate here so no second fetch path can drift the endpoint or payload.
export function postSovereignRebaseline(): Promise<RebaselineResponse> {
  return fetchJson<RebaselineResponse>("/health/sovereign/rebaseline", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Single recovery: mismatch above brake above policy above probe failure.
// Server value wins when known; reason text decides otherwise, unmatched
// reds park at openInbox so every red renders one action.
export function resolvePulseRemediation(
  health: HealthResponse | null | undefined,
): PulseRemediation {
  const raw =
    typeof health?.remediation === "string" ? health.remediation.trim() : "";
  if (
    raw === "none" ||
    raw === "rebaseline" ||
    raw === "openInbox" ||
    raw === "openPolicy"
  ) {
    return raw;
  }
  if (!health || health.status !== "red") return "none";
  const reasons = Array.isArray(health.degradedReasons)
    ? health.degradedReasons
    : [];
  const haystack = reasons
    .filter((entry): entry is string => typeof entry === "string")
    .join("\n")
    .toLowerCase();
  if (
    haystack.includes("sovereign") ||
    haystack.includes("ledger") ||
    haystack.includes("mismatch") ||
    haystack.includes("re-verification") ||
    haystack.includes("reverification")
  ) {
    return "rebaseline";
  }
  if (
    haystack.includes("brake") ||
    haystack.includes("anomaly") ||
    haystack.includes("trusted-tool")
  ) {
    return "openInbox";
  }
  if (
    haystack.includes("policy") ||
    haystack.includes("invariant") ||
    haystack.includes("blocked") ||
    haystack.includes("allowlist") ||
    haystack.includes("credential")
  ) {
    return "openPolicy";
  }
  if (
    haystack.includes("probe") ||
    haystack.includes("fail") ||
    haystack.includes("suite") ||
    haystack.includes("verifier")
  ) {
    return "openInbox";
  }
  return "openInbox";
}

