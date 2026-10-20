// Rune Weaver Dashboard — Brain server reachability probe.
export const BRAIN_SECRET_PROBE_PATTERN = /^[A-Z][A-Z0-9_]*$/;

// Any HTTP response proves reachability; throws and aborts mean unreachable.
export async function probeBrainServer(
  base: string,
  init?: { signal?: AbortSignal },
): Promise<boolean> {
  const normalized = base.replace(/\/+$/, "");
  const baseRoot = normalized.replace(/\/v1\/models$/, "").replace(/\/v1$/, "");
  const candidates = [...new Set([normalized, `${baseRoot}/v1/models`])];
  for (const url of candidates) {
    if (init?.signal?.aborted) return false;
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    init?.signal?.addEventListener("abort", onAbort, { once: true });
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
      await fetch(url, { method: "GET", signal: controller.signal });
      return true;
    } catch {
      if (init?.signal?.aborted) return false;
      continue;
    } finally {
      clearTimeout(timer);
      init?.signal?.removeEventListener("abort", onAbort);
    }
  }
  return false;
}
