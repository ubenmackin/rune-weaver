// Rune Weaver Dashboard — Shared runtime type guards for engine wire payloads.
//
// Single source for narrowing unknown wire values to plain records so API,
// approval-session, and socket handlers stay typed without duplicating the
// guard or widening callers to `any`. Arrays are excluded because
// `typeof []` would otherwise pass as a map and let lists flow into typed
// state.

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
