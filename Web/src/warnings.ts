// Rune Weaver Dashboard — Shared degraded-tool warning helpers.

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
