// Rune Weaver Dashboard — Shared degraded-tool warning helpers.
// Single source for sanitizing engine warning payloads so REST validation,
// WebSocket frame guards, and chat banners degrade malformed shapes to absent
// identically instead of drifting per call site.

// Keeps degraded-tool notices honest: only non-blank strings reach the banner,
// so drifted payloads degrade to no banner instead of blank rows.
export function sanitizeWarnings(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const cleaned: string[] = [];
  for (const entry of value) {
    if (typeof entry !== "string") continue;
    if (entry.trim().length === 0) continue;
    cleaned.push(entry.trim());
  }
  return cleaned;
}
