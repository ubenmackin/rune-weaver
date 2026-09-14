// Rune Weaver Dashboard — Shared HTTP test helpers for Vitest suites.
// Single source for building JSON fetch responses so component and client
// tests construct identical payloads without duplicating the helper.

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
