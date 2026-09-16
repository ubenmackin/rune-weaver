// Rune Weaver Dashboard — Unit tests for same-origin API client functions and error handling.

import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiError,
  cancelChat,
  createJob,
  decideApproval,
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS,
  DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES,
  DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE,
  DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES,
  deleteFact,
  deleteJob,
  getFacts,
  getHealth,
  getJob,
  getRun,
  listApprovals,
  listJobs,
  listRuns,
  listTrustGrants,
  postChat,
  revokeTrustGrant,
  runJobNow,
  searchMemory,
  storeFact,
  updateJob,
} from "./api";
import { jsonResponse } from "./test-utils/http";

describe("dashboard api client", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("fetches health from the same origin", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ status: "ok", engine: "Rune Weaver", version: "0.1.0" }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const health = await getHealth();
    expect(health.status).toBe("ok");
    expect(fetchMock).toHaveBeenCalledOnce();
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/health");
    expect(path.startsWith("http")).toBe(false);
  });

  it("posts chat with dashboard source", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ text: "hi", sessionID: "s1", toolActions: [] }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const response = await postChat("hello", "s1");
    expect(response.text).toBe("hi");
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toMatchObject({
      text: "hello",
      sessionID: "s1",
      source: "dashboard",
    });
  });

  it("cancels chat with session ID", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ sessionID: "s1", cancelled: true }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const response = await cancelChat("s1");
    expect(response.cancelled).toBe(true);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/chat/cancel");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toMatchObject({ sessionID: "s1" });
  });

  it("lists approvals and decides with durations", async () => {
    const fetchMock = vi
      .fn(async (input: string, init?: RequestInit) => {
        if (input === "/approvals") {
          return jsonResponse({ approvals: [], count: 0 });
        }
        expect(init?.method).toBe("POST");
        return jsonResponse({ id: "a1", approved: true, duration: "oneHour" });
      });
    vi.stubGlobal("fetch", fetchMock);
    const listed = await listApprovals();
    expect(listed.count).toBe(0);
    const decided = await decideApproval("a1", true, "oneHour");
    expect(decided.duration).toBe("oneHour");
    const [path, init] = fetchMock.mock.calls[1] as [string, RequestInit];
    expect(path).toBe("/approvals/a1/decide");
    expect(JSON.parse(init.body as string)).toMatchObject({
      approved: true,
      duration: "oneHour",
    });
  });

  it("searches memory and manages facts", async () => {
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push(input);
      if (input.startsWith("/memory/search")) {
        return jsonResponse({ query: "dog", count: 1, memories: [] });
      }
      if (input === "/memory/facts" && init?.method === "POST") {
        return jsonResponse({ id: "f1", content: "dog", source: "dashboard" });
      }
      if (input === "/memory/facts") {
        return jsonResponse({
          facts: [],
          preferences: [],
          semanticCount: 0,
          episodeCount: 0,
        });
      }
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    const search = await searchMemory("dog", 10);
    expect(search.query).toBe("dog");
    expect(seen[0]).toContain("/memory/search?q=dog");
    const stored = await storeFact("dog");
    expect(stored.id).toBe("f1");
    const facts = await getFacts();
    expect(facts.episodeCount).toBe(0);
    await deleteFact("f1");
    expect(seen).toContain("/memory/facts/f1");
  });

  it("lists runs and fetches one run", async () => {
    const fetchMock = vi.fn(async (input: string) => {
      if (input.startsWith("/runs?")) {
        return jsonResponse({ runs: [], count: 0 });
      }
      return jsonResponse({
        id: "r1",
        kind: "chat",
        status: "ok",
        message: "hi",
        timestamp: new Date(0).toISOString(),
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const runs = await listRuns(50);
    expect(runs.count).toBe(0);
    const run = await getRun("r1");
    expect(run.kind).toBe("chat");
  });

  it("manages scheduler jobs over relative paths", async () => {
    const seen: Array<{ path: string; method?: string; body?: string }> = [];
    const job = {
      id: "33333333-3333-3333-3333-333333333333",
      name: "morning digest",
      schedule: "0 8 * * *",
      prompt: "Summarize mail",
      enabled: true,
      pollAccount: null,
      pollQuery: null,
      pollMailbox: null,
      pollIntervalSeconds: null,
      createdAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(),
    };
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({
        path: input,
        method: init?.method,
        body: init?.body ? String(init.body) : undefined,
      });
      if (input === "/scheduler/jobs" && !init?.method) {
        return jsonResponse({ jobs: [job], count: 1 });
      }
      if (input === "/scheduler/jobs" && init?.method === "POST") {
        return jsonResponse(job);
      }
      if (input === `/scheduler/jobs/${job.id}` && !init?.method) {
        return jsonResponse(job);
      }
      if (input === `/scheduler/jobs/${job.id}` && init?.method === "PUT") {
        return jsonResponse({ ...job, enabled: false });
      }
      if (
        input === `/scheduler/jobs/${job.id}/run` &&
        init?.method === "POST"
      ) {
        return jsonResponse({ text: "done", sessionID: job.id, toolActions: [] });
      }
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    const listed = await listJobs();
    expect(listed.count).toBe(1);
    expect(listed.jobs[0].schedule).toBe("0 8 * * *");
    const fetched = await getJob(job.id);
    expect(fetched.name).toBe("morning digest");
    const created = await createJob({
      name: "morning digest",
      schedule: "0 8 * * *",
      prompt: "Summarize mail",
      enabled: true,
    });
    expect(created.id).toBe(job.id);
    const updated = await updateJob(job.id, { enabled: false });
    expect(updated.enabled).toBe(false);
    const ran = await runJobNow(job.id);
    expect(ran.text).toBe("done");
    await deleteJob(job.id);
    for (const entry of seen) {
      expect(entry.path.startsWith("http")).toBe(false);
    }
    expect(seen.some((entry) => entry.path === "/scheduler/jobs")).toBe(true);
    expect(
      seen.some((entry) => entry.path === `/scheduler/jobs/${job.id}/run`),
    ).toBe(true);
  });

  it("creates poll-only event-rule jobs", async () => {
    let sentBody = "";
    const fetchMock = vi.fn(async (_input: string, init?: RequestInit) => {
      sentBody = String(init?.body ?? "");
      return jsonResponse({
        id: "44444444-4444-4444-4444-444444444444",
        name: "mail watcher",
        schedule: "",
        prompt: "Summarize arrivals",
        enabled: true,
        pollAccount: "icloud",
        pollQuery: "from:alerts",
        pollMailbox: "INBOX",
        pollIntervalSeconds: 300,
        createdAt: new Date(0).toISOString(),
        updatedAt: new Date(0).toISOString(),
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const created = await createJob({
      name: "mail watcher",
      schedule: "",
      prompt: "Summarize arrivals",
      pollAccount: "icloud",
      pollQuery: "from:alerts",
      pollMailbox: "INBOX",
      pollIntervalSeconds: 300,
    });
    expect(created.pollAccount).toBe("icloud");
    expect(JSON.parse(sentBody)).toMatchObject({
      name: "mail watcher",
      schedule: "",
      pollAccount: "icloud",
      pollIntervalSeconds: 300,
    });
  });

  it("lists trust grants from the grants endpoint", async () => {
    const now = new Date().toISOString();
    const future = new Date(Date.now() + 3600_000).toISOString();
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        grants: [
          {
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            toolName: "email.send",
            target: "alice@example.com",
            grantedAt: now,
            expiresAt: future,
            duration: "oneHour",
          },
          {
            id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            toolName: "file.write",
            target: "",
            grantedAt: now,
            expiresAt: null,
            duration: "forever",
          },
        ],
        count: 2,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const listed = await listTrustGrants();
    expect(listed.count).toBe(2);
    expect(listed.grants[0].toolName).toBe("email.send");
    // Forever grants keep a null expiry through the client so the inbox can
    // branch on never-expires without sentinel-date comparisons.
    expect(listed.grants[1].expiresAt).toBeNull();
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/approvals/grants");
    expect(path.startsWith("http")).toBe(false);
  });

  it("revokes a trust grant with an encoded DELETE", async () => {
    const seen: Array<{ path: string; method?: string }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({ path: input, method: init?.method });
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    await revokeTrustGrant("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    expect(seen[0].path).toBe("/approvals/grants/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    expect(seen[0].method).toBe("DELETE");
    // Identifiers travel encoded so reserved characters never split the route.
    await revokeTrustGrant("a/b c");
    expect(seen[1].path).toBe("/approvals/grants/a%2Fb%20c");
    expect(seen[1].method).toBe("DELETE");
  });

  it("surfaces trust grant failures as ApiError", async () => {
    // A revoked-elsewhere grant reports 404 with the engine reason so the
    // inbox can explain the row already lapsed instead of retrying blindly.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "Unknown grant abc" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const missing = await revokeTrustGrant("abc").catch((error: unknown) => error);
    expect(missing).toBeInstanceOf(ApiError);
    expect((missing as ApiError).status).toBe(404);
    expect((missing as ApiError).message).toContain("Unknown grant abc");
    // Transport failures surface with status 0 so callers can distinguish
    // an unreachable engine from a rejected grant id.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("boom");
      }),
    );
    const offline = await listTrustGrants().catch((error: unknown) => error);
    expect(offline).toBeInstanceOf(ApiError);
    expect((offline as ApiError).status).toBe(0);
  });

  it("throws ApiError with status on failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("nope", { status: 404 })),
    );
    const failure = await getHealth().catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(ApiError);
    expect((failure as ApiError).status).toBe(404);
  });

  it("keeps web default mirrors pinned to the Swift single source", () => {
    // Manual cross-language pin: the dashboard cannot import Swift, so these literals must match
    // FilesConfig/SandboxConfig Tier-3 defaults in Sources/RuneWeaverCore/Config.swift. Update both
    // sides together.
    expect(DEFAULT_SANDBOX_ARCHIVE_SESSION_TTL_MINUTES).toBe(10);
    expect(DEFAULT_SANDBOX_MAX_CONCURRENT_MACHINES).toBe(3);
    expect(DEFAULT_SANDBOX_CONTAINER_BASE_IMAGE).toBe("alpine:latest");
    expect(DEFAULT_FILES_ALLOW_ROOTS).toEqual(["~"]);
    expect(DEFAULT_FILES_DENY_PATTERNS).toEqual([
      ".env*",
      ".netrc",
      "secrets.json",
      "config.toml",
      "*.pem",
      "*.key",
      "*keychain*",
      ".ssh/*",
      ".aws/*",
      ".runeweaver/memory/vectors/*",
    ]);
  });
});
