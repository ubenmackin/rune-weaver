// Rune Weaver Dashboard — Shared approval session correlation helpers.

import type { PermissionRequest, RunLogEntry } from "./api";
import { isRecord } from "./typeGuards";

// Re-exported so existing callers importing from this module keep working;
// new code should import from `./typeGuards` directly.
export { isRecord };

// Normalizes session identifiers for case-insensitive comparison: the engine
// formats UUIDs uppercase while the dashboard mints lowercase, so both must
// compare equal without leaking cross-session approvals.
export function normalizeSessionID(id?: string | null): string {
  return (id ?? "").trim().toLowerCase();
}

// Reads the owning session from an approval payload across wire shapes: top-level identifiers take
// precedence, with nested input locations honored for forward-compatible engines that tag the gated
// call itself. Unknown fields are probed internally so callers pass a plain approval with no cast.
export function approvalSessionID(
  request: PermissionRequest | null | undefined,
): string | null {
  if (!isRecord(request)) return null;
  const input = isRecord(request.input) ? request.input : undefined;
  const candidates = [
    request.sessionID,
    request.sessionId,
    request.session_id,
    input?.sessionID,
    input?.sessionId,
    input?.session_id,
  ];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate.trim();
    }
  }
  return null;
}

// Reads the owning session from a run log entry. The engine tags interactive
// turns with `sessionID`, so run views share this reader instead of
// reimplementing the lookup per call site.
export function runSessionID(
  run: RunLogEntry | null | undefined,
): string | null {
  if (!run) return null;
  const sid = run.sessionID;
  if (typeof sid !== "string") return null;
  const trimmed = sid.trim();
  return trimmed.length > 0 ? trimmed : null;
}

// Validates an approval prompt before it joins the inbox badge, so a malformed socket frame cannot
// alarm the session with an undecidable entry. Single source for approval validation so chat,
// inbox, and run views filter the same inbox identically.
export function isPermissionRequest(value: unknown): value is PermissionRequest {
  if (!isRecord(value)) return false;
  if (typeof value.id !== "string" || value.id.trim().length === 0) return false;
  if (typeof value.toolName !== "string" || value.toolName.trim().length === 0) return false;
  if (typeof value.description !== "string" || value.description.trim().length === 0)
    return false;
  if (!isRecord(value.input)) return false;
  const input = value.input;
  if (typeof input.toolName !== "string" || input.toolName.trim().length === 0) return false;
  if (typeof input.argumentsJSON !== "string") return false;
  if (typeof input.callID !== "string" || input.callID.trim().length === 0) return false;
  return true;
}

// Validates the WebSocket approval-frame envelope (`{ type: "approval",
// request }`) so views share one guard instead of reimplementing the shape
// check per call site; malformed envelopes drop before touching state.
export function isApprovalFrame(
  value: unknown,
): value is { type: "approval"; request: PermissionRequest } {
  if (!isRecord(value)) return false;
  if (value.type !== "approval") return false;
  return isPermissionRequest(value.request);
}

// Extracts a validated approval request from a WebSocket frame, returning
// null for malformed envelopes so callers merge with one shared helper.
// Deduplication stays with the caller via the returned request identity.
export function mergeApprovalFrame(data: unknown): PermissionRequest | null {
  if (!isApprovalFrame(data)) return null;
  return data.request;
}

// Compares two session identifiers case-insensitively: the engine formats UUIDs uppercase while the
// dashboard mints lowercase, so both spellings must correlate without leaking approvals across
// sessions.
export function isSameSession(
  a: string | null | undefined,
  b: string | null | undefined,
): boolean {
  const left = normalizeSessionID(a);
  const right = normalizeSessionID(b);
  return left.length > 0 && left === right;
}

// Loads a persisted enum filter from localStorage, falling back when storage
// is unavailable or holds a value from an older set of options. The allowed
// list pins the check so stale or tampered values cannot enter view state.
export function getSavedEnum<T extends string>(
  key: string,
  allowed: readonly T[],
  fallback: T,
): T {
  try {
    const saved = localStorage.getItem(key);
    if (saved != null && (allowed as readonly string[]).includes(saved)) {
      return saved as T;
    }
  } catch {
    // Storage is best-effort
  }
  return fallback;
}

// Persists an enum filter choice. Failures stay silent so private-mode or
// quota errors never break filtering; the in-memory state remains valid.
export function persistEnum(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Storage is best-effort
  }
}
