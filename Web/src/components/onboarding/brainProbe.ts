// Rune Weaver Dashboard — Brain server reachability probe.
import { fetchJson } from "../../api/http";

export const BRAIN_SECRET_PROBE_PATTERN = /^[A-Z][A-Z0-9_]*$/;

// Fail-closed: only an explicit reachable flag counts; throws, aborts, and rejections mean unreachable.
export async function probeBrainServer(
  base: string,
  init?: { signal?: AbortSignal },
): Promise<boolean> {
  if (init?.signal?.aborted) return false;
  try {
    const data = await fetchJson<{ reachable: boolean }>("/onboarding/probe", {
      method: "POST",
      body: JSON.stringify({ serverURL: base }),
      signal: init?.signal,
    });
    return data?.reachable === true;
  } catch {
    return false;
  }
}
