// Rune Weaver Dashboard — Shared runtime type guards for engine wire payloads.

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
