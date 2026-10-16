// Rune Weaver Dashboard — Shared decision-surface approvals vocabulary.

import {
  trustDurationOptions,
  type PermissionRequest,
  type TrustDuration,
} from "./api";
import { isRecord } from "./typeGuards";

// The egress tier mapping names exactly three durations: thisTime allows the
// host once, forSession allows it for the session, and forever mints the
// durable domain rule.
export const EGRESS_DURATIONS: TrustDuration[] = [
  "thisTime",
  "forSession",
  "forever",
];

// Visible target length before the shared ellipsis cut. Rendering truncates
// here with the full value on the title tooltip while the full arguments
// stay in the View arguments disclosure.
const MAX_TARGET_LENGTH = 80;

// Argument keys the legacy target derivation reads, in the engine's priority
// order, so the preview line names the same thing a stored rule would cover.
const TARGET_ARGUMENT_KEYS = [
  "to",
  "recipient",
  "email",
  "target",
  "path",
  "url",
  "address",
  "destination",
];

// Reports whether a request is egress-parked: a non-blank host tag means the
// call dialed an unlisted network host and rides the three-tier mapping.
function isEgressParked(request: PermissionRequest): boolean {
  return (
    typeof request.egressHost === "string" &&
    request.egressHost.trim().length > 0
  );
}

// Picks the durations one request offers: the full shared vocabulary for an
// ordinary request, exactly the three egress tiers for an egress-parked one.
export function durationOptionsFor(
  request: PermissionRequest,
): Array<{ value: TrustDuration; label: string }> {
  if (!isEgressParked(request)) return trustDurationOptions;
  return EGRESS_DURATIONS.map((value) =>
    trustDurationOptions.find((option) => option.value === value),
  ).filter(
    (option): option is { value: TrustDuration; label: string } =>
      option !== undefined,
  );
}

// Reads one trimmed string field from a parsed arguments record. Blank and
// non-string shapes name no target and fall through to the next key.
function trimmedArg(record: Record<string, unknown>, key: string): string | null {
  const value = record[key];
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

// Best-effort preview of the request's own target. The stored displayTarget wins when present;
// older payloads predating the field fall back to the egress host first, then the bash command, then
// the legacy key scan.
export function deriveRequestTarget(
  request: PermissionRequest,
): string | null {
  const stored = request.displayTarget;
  if (typeof stored === "string" && stored.trim().length > 0) {
    return stored.trim();
  }
  if (isEgressParked(request)) {
    return (request.egressHost as string).trim();
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(request.input?.argumentsJSON ?? "");
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (request.toolName === "bash.exec") {
    const command = trimmedArg(parsed, "command");
    if (command) return command;
  }
  for (const key of TARGET_ARGUMENT_KEYS) {
    const value = trimmedArg(parsed, key);
    if (value) return value;
  }
  return null;
}

// Truncates a target for one-line rendering. Values at or under the bound
// pass through untouched; longer values cut at the bound with an ellipsis.
export function truncateTarget(value: string): string {
  if (typeof value !== "string" || value.length <= MAX_TARGET_LENGTH) {
    return value;
  }
  return `${value.slice(0, MAX_TARGET_LENGTH)}…`;
}
