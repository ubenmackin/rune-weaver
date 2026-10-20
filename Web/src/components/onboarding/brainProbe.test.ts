// Rune Weaver Dashboard — Brain probe onboarding endpoint tests.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { probeBrainServer } from "./brainProbe";
import { clearAuthToken } from "../../api/http";
import { jsonResponse } from "../../test-utils/http";

describe("probeBrainServer", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("posts the serverURL to the same-origin probe and resolves true on reachable", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ reachable: true }));
    vi.stubGlobal("fetch", fetchMock);
    const result = await probeBrainServer("https://brain.example.com");
    expect(result).toBe(true);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/onboarding/probe");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({ serverURL: "https://brain.example.com" });
  });

  it("forwards the caller abort signal on the single probe POST", async () => {
    const seen: Array<AbortSignal | null | undefined> = [];
    const fetchMock = vi.fn(async (_input: string, init?: RequestInit) => {
      seen.push(init?.signal ?? null);
      return jsonResponse({ reachable: true });
    });
    vi.stubGlobal("fetch", fetchMock);
    const controller = new AbortController();
    const result = await probeBrainServer("https://brain.example.com", {
      signal: controller.signal,
    });
    expect(result).toBe(true);
    expect(seen[0]).toBe(controller.signal);
  });

  it("resolves false when the probe reports reachable false", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({ reachable: false })));
    const result = await probeBrainServer("https://brain.example.com");
    expect(result).toBe(false);
  });

  it("resolves false when the probe request throws", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("unreachable");
      }),
    );
    const result = await probeBrainServer("https://brain.example.com");
    expect(result).toBe(false);
  });
});
