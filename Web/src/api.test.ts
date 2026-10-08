// Rune Weaver Dashboard — Unit tests for same-origin API client functions and error handling.

import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiError,
  AUTH_TOKEN_STORAGE_KEY,
  authHeaders,
  authenticateWithToken,
  cancelChat,
  canonicalRestartHost,
  changeDurationGrant,
  clearAuthToken,
  clearEpisodes,
  concurrentTurnsBusyMessage,
  createJob,
  decideApproval,
  DEFAULT_CONTAINERS_MAX_CONCURRENT,
  DEFAULT_CONTAINERS_MEMORY_MB,
  DEFAULT_CONTAINERS_TTL_MINUTES,
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS,
  deleteEpisode,
  deleteFact,
  deleteGoal,
  deleteJob,
  deleteSecret,
  deleteSessionEpisodes,
  formatGoalNextAdvance,
  formatRunDuration,
  formatToolProgressElapsedMs,
  getAuthToken,
  getFacts,
  getHealth,
  getJob,
  getRun,
  goalCadenceLabel,
  goalProgressPercent,
  goalStatusLabel,
  goalStatusTone,
  isAuthenticatedHealth,
  isGoalNeedsInputProactive,
  isSessionAuthenticated,
  listApprovals,
  listJobs,
  listRecentEpisodes,
  listRuns,
  listTrustGrants,
  MAX_CONCURRENT_CHAT_TURNS,
  MAX_CONCURRENT_CHAT_TURNS_HEADER,
  normalizeServerAllowedHost,
  parseGoalSnapshot,
  parseGoalUpdatedFrame,
  parseMaxConcurrentChatTurns,
  parsePlaceholderCallID,
  parseToolProgress,
  placeholderCallIDsInText,
  postChat,
  resolveMaxConcurrentChatTurns,
  revokeTrustGrant,
  rotateToken,
  runJobNow,
  RUN_LOG_POLL_LIMIT,
  RUN_POLL_INTERVAL_MS,
  searchMemory,
  setAuthToken,
  storeFact,
  storeSecret,
  subscribeAuthState,
  textContainsPlaceholderForCall,
  toolCancel,
  updateJob,
  validateServerAllowedHost,
  validateServerHostname,
  acceptIdea,
  dismissIdea,
  getIdeasSummary,
  ideaKindLabel,
  isIdeaProposedProactive,
  listIdeas,
  parseIdea,
  DEFAULT_GOALS_MAX_TOOL_ITERATIONS,
  DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS,
  TOOL_ROUNDS_MIN,
  TOOL_ROUNDS_MAX,
  goalsMaxToolIterations,
  schedulerMaxToolIterations,
  schedulerJobEffectiveMaxToolIterations,
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

  it("cancels one tool by call identity with an optional reason", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ sessionID: "s1", callID: "call-1", cancelled: true }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const response = await toolCancel("s1", "call-1", "wrong folder");
    expect(response.cancelled).toBe(true);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/chat/tool_cancel");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toMatchObject({
      sessionID: "s1",
      callID: "call-1",
      reason: "wrong folder",
    });
    // A blank reason is omitted so the engine stores absence rather than "".
    await toolCancel("s1", "call-1", "   ");
    const [, blankInit] = fetchMock.mock.calls[1] as unknown as [string, RequestInit];
    expect(JSON.parse(blankInit.body as string)).not.toHaveProperty("reason");
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
      if (input.startsWith("/memory/facts") && init?.method === "POST") {
        return jsonResponse({ id: "f1", content: "dog", source: "dashboard" });
      }
      if (input.startsWith("/memory/facts")) {
        return jsonResponse({
          facts: [],
          total: 0,
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
    // Paged shape carries the window total alongside live tallies so tab
    // labels settle without a second fetch.
    expect(facts.total).toBe(0);
    await deleteFact("f1");
    expect(seen).toContain("/memory/facts/f1");
  });

  it("pages facts with search plus limit plus offset through URLSearchParams", async () => {
    // Windowed reads keep previews bounded: the query names its substring and
    // window explicitly so the pane never pulls an unbounded list to count.
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string) => {
      seen.push(input);
      return jsonResponse({
        facts: [],
        total: 42,
        semanticCount: 7,
        episodeCount: 9,
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const page = await getFacts("  biscuit  ", 20, 20);
    expect(page.total).toBe(42);
    expect(page.semanticCount).toBe(7);
    expect(page.episodeCount).toBe(9);
    const url = new URL(seen[0], "http://localhost");
    expect(url.pathname).toBe("/memory/facts");
    expect(url.searchParams.get("q")).toBe("biscuit");
    expect(url.searchParams.get("limit")).toBe("20");
    expect(url.searchParams.get("offset")).toBe("20");
    // Default paging stays a plain recent-window read with an omitted empty
    // query so legacy callers keep working.
    await getFacts();
    const defaultUrl = new URL(seen[1], "http://localhost");
    expect(defaultUrl.pathname).toBe("/memory/facts");
    expect(defaultUrl.searchParams.get("q")).toBeNull();
    expect(defaultUrl.searchParams.get("limit")).toBe("20");
    expect(defaultUrl.searchParams.get("offset")).toBe("0");
  });

  it("degrades a legacy facts payload without a total to its window length", async () => {
    // Older engines predate the paged total; the client falls back to the
    // window length so counts render instead of blanking.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({
          facts: [
            {
              id: "f1",
              content: "Dog named Biscuit",
              confidence: 1,
              source: "dashboard",
              lastConfirmed: new Date(0).toISOString(),
            },
          ],
          preferences: [],
          semanticCount: 1,
          episodeCount: 2,
        }),
      ),
    );
    const page = await getFacts();
    expect(page.facts).toHaveLength(1);
    expect(page.total).toBe(1);
    expect(page.episodeCount).toBe(2);
  });

  it("lists episodic recency through the canonical finder entrypoint", async () => {
    // The finder owns the same bounded listing shape under its canonical name,
    // so dashboard previews never read the stores directly and stay on one
    // transport with identical query spelling.
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string) => {
      seen.push(input);
      return jsonResponse({
        episodes: [
          {
            id: "11111111-1111-1111-1111-111111111111",
            sessionID: "22222222-2222-2222-2222-222222222222",
            role: "user",
            content: "hello",
            timestamp: 1700000000,
          },
        ],
        count: 1,
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const recent = await listRecentEpisodes();
    expect(recent.count).toBe(1);
    expect(recent.episodes[0].id).toBe("11111111-1111-1111-1111-111111111111");
    const defaultUrl = new URL(seen[0], "http://localhost");
    expect(defaultUrl.pathname).toBe("/memory/episodes/recent");
    expect(defaultUrl.searchParams.get("limit")).toBe("20");
    expect(defaultUrl.searchParams.get("sessionID")).toBeNull();
    await listRecentEpisodes(20, "  22222222-2222-2222-2222-222222222222  ");
    const scopedUrl = new URL(seen[1], "http://localhost");
    expect(scopedUrl.searchParams.get("limit")).toBe("20");
    expect(scopedUrl.searchParams.get("sessionID")).toBe(
      "22222222-2222-2222-2222-222222222222",
    );
  });

  it("surfaces recent listing failures as ApiError", async () => {
    // Malformed limits and sessions reject 400 with the engine reason, while
    // server failures surface the Abort reason through the shared fetchJson
    // path so the finder can render the honest message plus Retry.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "limit must be 1-100" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const badLimit = await listRecentEpisodes(700).catch((error: unknown) => error);
    expect(badLimit).toBeInstanceOf(ApiError);
    expect((badLimit as ApiError).status).toBe(400);
    expect((badLimit as ApiError).message).toContain("limit must be 1-100");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "sessionID must be a UUID" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const badSession = await listRecentEpisodes(20, "nope").catch(
      (error: unknown) => error,
    );
    expect(badSession).toBeInstanceOf(ApiError);
    expect((badSession as ApiError).status).toBe(400);
    expect((badSession as ApiError).message).toContain("sessionID must be a UUID");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "store unavailable" }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const serverError = await listRecentEpisodes().catch((error: unknown) => error);
    expect(serverError).toBeInstanceOf(ApiError);
    expect((serverError as ApiError).status).toBe(500);
    expect((serverError as ApiError).message).toContain("store unavailable");
  });

  it("passes an abort signal through mixed recall", async () => {
    // The Search pane cancels stale recalls on fresh submits; the signal rides
    // the same recall path so no second transport exists.
    const seen: Array<{ path: string; signal?: AbortSignal | null }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({ path: input, signal: init?.signal ?? null });
      return jsonResponse({ query: "dog", count: 0, memories: [] });
    });
    vi.stubGlobal("fetch", fetchMock);
    const controller = new AbortController();
    await searchMemory("dog", 10, controller.signal);
    expect(seen[0].signal).toBe(controller.signal);
  });

  it("clears episodic turns and parses deleted plus remaining counts", async () => {
    // The whole-store clear posts DELETE to the episodes collection and
    // returns both the removed tally and the remaining count so the panel can
    // refresh without a second facts fetch for the number.
    const fetchMock = vi.fn(async () =>
      jsonResponse({ deletedCount: 3, episodeCount: 0 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const cleared = await clearEpisodes();
    expect(cleared.deletedCount).toBe(3);
    expect(cleared.episodeCount).toBe(0);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [
      string,
      RequestInit,
    ];
    expect(path).toBe("/memory/episodes");
    expect(init.method).toBe("DELETE");
    expect(path.startsWith("http")).toBe(false);
  });

  it("deletes one episodic turn with an encoded id", async () => {
    // One row deletes through its collection member route; a bodyless 204
    // resolves to void the same way fact deletes do.
    const seen: Array<{ path: string; method?: string }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({ path: input, method: init?.method });
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    await deleteEpisode("11111111-1111-1111-1111-111111111111");
    expect(seen[0].path).toBe(
      "/memory/episodes/11111111-1111-1111-1111-111111111111",
    );
    expect(seen[0].method).toBe("DELETE");
    // Identifiers travel encoded so reserved characters never split the route.
    await deleteEpisode("a/b c");
    expect(seen[1].path).toBe("/memory/episodes/a%2Fb%20c");
    expect(seen[1].method).toBe("DELETE");
  });

  it("deletes session episodes with an encoded session id", async () => {
    // The literal session segment keeps this route distinct from the id route
    // server-side; the client keeps the same shape so the two never collide.
    const seen: Array<{ path: string; method?: string }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({ path: input, method: init?.method });
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    await deleteSessionEpisodes("22222222-2222-2222-2222-222222222222");
    expect(seen[0].path).toBe(
      "/memory/episodes/session/22222222-2222-2222-2222-222222222222",
    );
    expect(seen[0].method).toBe("DELETE");
    // Session identifiers travel encoded for the same routing reason as ids.
    await deleteSessionEpisodes("s/b c");
    expect(seen[1].path).toBe("/memory/episodes/session/s%2Fb%20c");
    expect(seen[1].method).toBe("DELETE");
  });

  it("surfaces episodic 400 reasons as ApiError", async () => {
    // An invalid UUID rejects with 400 plus the engine reason, surfaced
    // through the shared fetchJson reason parsing so the panel can render the
    // honest message in its error slot.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "id must be a UUID" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const badId = await deleteEpisode("nope").catch((error: unknown) => error);
    expect(badId).toBeInstanceOf(ApiError);
    expect((badId as ApiError).status).toBe(400);
    expect((badId as ApiError).message).toContain("id must be a UUID");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "sessionID must be a UUID" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const badSession = await deleteSessionEpisodes("nope").catch(
      (error: unknown) => error,
    );
    expect(badSession).toBeInstanceOf(ApiError);
    expect((badSession as ApiError).status).toBe(400);
    expect((badSession as ApiError).message).toContain(
      "sessionID must be a UUID",
    );
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
            useCount: 3,
            lastUsedAt: now,
          },
          {
            id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            toolName: "file.write",
            target: "",
            grantedAt: now,
            expiresAt: null,
            duration: "forever",
            useCount: 0,
            lastUsedAt: null,
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
    // Usage counters ride the same payload so the inbox proves liveness
    // without re-deriving it from run history.
    expect(listed.grants[0].useCount).toBe(3);
    expect(listed.grants[0].lastUsedAt).toBe(now);
    // Untouched grants encode the zero baseline explicitly rather than
    // omitting the fields.
    expect(listed.grants[1].useCount).toBe(0);
    expect(listed.grants[1].lastUsedAt).toBeNull();
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/approvals/grants");
    expect(path.startsWith("http")).toBe(false);
  });

  it("tolerates legacy trust grants without usage fields", async () => {
    const now = new Date().toISOString();
    const future = new Date(Date.now() + 3600_000).toISOString();
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        grants: [
          {
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            toolName: "email.send",
            target: "legacy@example.com",
            grantedAt: now,
            expiresAt: future,
            duration: "oneHour",
          },
        ],
        count: 1,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const listed = await listTrustGrants();
    expect(listed.count).toBe(1);
    // Rows minted before tracking carry no counter keys; the client must pass
    // them through as missing so the inbox degrades to untouched.
    expect(listed.grants[0].useCount).toBeUndefined();
    expect(listed.grants[0].lastUsedAt).toBeUndefined();
    expect(listed.grants[0].toolName).toBe("email.send");
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

  it("carries numeric wire shapes for usage timestamps", async () => {
    // SQLite persistence encodes times as Unix seconds while older payloads
    // carry ISO strings; the client must pass both through without coercing
    // null last-use into the epoch.
    const nowSeconds = Math.floor(Date.now() / 1000);
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        grants: [
          {
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            toolName: "email.send",
            target: "numeric@example.com",
            grantedAt: nowSeconds,
            expiresAt: nowSeconds + 3600,
            duration: "oneHour",
            useCount: 1,
            lastUsedAt: nowSeconds,
          },
          {
            id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            toolName: "email.send",
            target: "untouched@example.com",
            grantedAt: nowSeconds,
            expiresAt: null,
            duration: "forever",
            useCount: 0,
            lastUsedAt: null,
          },
        ],
        count: 2,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const listed = await listTrustGrants();
    expect(listed.grants[0].useCount).toBe(1);
    expect(listed.grants[0].lastUsedAt).toBe(nowSeconds);
    expect(listed.grants[1].useCount).toBe(0);
    expect(listed.grants[1].lastUsedAt).toBeNull();
  });

  it("reports already-expired revokes as notFound without retry", async () => {
    // An already-lapsed grant stays 404 with the engine reason so the inbox
    // explains the row expired instead of treating it as a transport error.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "Unknown grant lapsed-id" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const lapsed = await revokeTrustGrant("lapsed-id").catch((error: unknown) => error);
    expect(lapsed).toBeInstanceOf(ApiError);
    expect((lapsed as ApiError).status).toBe(404);
    expect((lapsed as ApiError).message).toContain("Unknown grant lapsed-id");
  });

  it("re-arms a grant with PATCH path, method, and duration body", async () => {
    // The re-arm keeps identity and counters server-side, so the client only
    // sends the replacement tier; the route stays the grant resource with a
    // PATCH verb rather than a sub-action path.
    const seen: Array<{ path: string; method?: string; body?: string }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({
        path: input,
        method: init?.method,
        body: init?.body ? String(init.body) : undefined,
      });
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    await changeDurationGrant(
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "oneHour",
    );
    expect(seen[0].path).toBe(
      "/approvals/grants/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    );
    expect(seen[0].method).toBe("PATCH");
    expect(JSON.parse(seen[0].body ?? "")).toEqual({ duration: "oneHour" });
    // Identifiers travel encoded so reserved characters never split the route.
    await changeDurationGrant("a/b c", "forever");
    expect(seen[1].path).toBe("/approvals/grants/a%2Fb%20c");
    expect(seen[1].method).toBe("PATCH");
    expect(JSON.parse(seen[1].body ?? "")).toEqual({ duration: "forever" });
    // Every durable tier round-trips through the same body shape so the modal
    // can offer all four without per-tier branching.
    await changeDurationGrant(
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "oneDay",
    );
    expect(JSON.parse(seen[2].body ?? "")).toEqual({ duration: "oneDay" });
  });

  it("surfaces re-arm failures as ApiError", async () => {
    // A lapsed grant reports 404 with the engine reason so the duration modal
    // can explain the row is gone instead of retrying blindly.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ reason: "Unknown grant abc" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    const missing = await changeDurationGrant("abc", "oneHour").catch(
      (error: unknown) => error,
    );
    expect(missing).toBeInstanceOf(ApiError);
    expect((missing as ApiError).status).toBe(404);
    expect((missing as ApiError).message).toContain("Unknown grant abc");
    // Transport failures surface with status 0 so callers can distinguish
    // an unreachable engine from a rejected duration tier.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("boom");
      }),
    );
    const offline = await changeDurationGrant("abc", "oneHour").catch(
      (error: unknown) => error,
    );
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
    // FilesConfig/ContainersConfig defaults in Sources/RuneWeaverCore/Config.swift. Update both
    // sides together.
    expect(DEFAULT_CONTAINERS_MEMORY_MB).toBe(512);
    expect(DEFAULT_CONTAINERS_MAX_CONCURRENT).toBe(5);
    expect(DEFAULT_CONTAINERS_TTL_MINUTES).toBe(60);
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
      ".runeweaver/memory/*",
      ".runeweaver/memory/vectors/*",
      ".runeweaver/browser_profiles/*",
      ".runeweaver/policy.toml",
      ".runeweaver/auth_token",
      ".runeweaver/searxng/*",
      ".git-credentials",
      ".gitcookies",
      ".rclone.conf",
      ".npmrc",
      ".pypirc",
      ".Xauthority",
      ".emulator_console_auth_token",
      ".gnupg/*",
      ".kube/*",
      ".docker/*",
      ".config/gcloud/*",
      ".chia_keys/*",
      "*_history",
      ".zsh_sessions/*",
    ]);
  });

  it("keeps the concurrent-turn cap and busy copy pinned to the engine contract", () => {
    // The dashboard cannot import the engine tracker, so the cap stays pinned
    // here; the busy copy shares the engine refusal wording so every layer
    // reads as one outcome.
    expect(MAX_CONCURRENT_CHAT_TURNS).toBe(3);
    expect(concurrentTurnsBusyMessage()).toBe(
      "Already running 3 chat turns — wait for one to finish or cancel it, then retry.",
    );
    expect(concurrentTurnsBusyMessage(2)).toContain("Already running 2 chat turns");
  });

  it("resolves the turn cap from the health advertisement with fallback", () => {
    // Admit and reject agree on one server-owned number: a valid advertisement
    // wins, while absent or drifted shapes degrade to the fallback so older
    // engines never block the dashboard.
    expect(
      resolveMaxConcurrentChatTurns({
        status: "ok",
        engine: "Rune Weaver",
        version: "0.1.0",
        maxConcurrentChatTurns: 5,
      }),
    ).toBe(5);
    expect(resolveMaxConcurrentChatTurns(null)).toBe(
      MAX_CONCURRENT_CHAT_TURNS,
    );
    expect(resolveMaxConcurrentChatTurns(undefined)).toBe(
      MAX_CONCURRENT_CHAT_TURNS,
    );
    expect(
      resolveMaxConcurrentChatTurns({
        status: "ok",
        engine: "Rune Weaver",
        version: "0.1.0",
      }),
    ).toBe(MAX_CONCURRENT_CHAT_TURNS);
    expect(
      resolveMaxConcurrentChatTurns({
        status: "ok",
        engine: "Rune Weaver",
        version: "0.1.0",
        maxConcurrentChatTurns: null,
      }),
    ).toBe(MAX_CONCURRENT_CHAT_TURNS);
    expect(
      resolveMaxConcurrentChatTurns({
        status: "ok",
        engine: "Rune Weaver",
        version: "0.1.0",
        maxConcurrentChatTurns: 0,
      }),
    ).toBe(MAX_CONCURRENT_CHAT_TURNS);
    // The busy copy renders the resolved number so client refusal reads as
    // the same outcome the server enforces.
    expect(
      concurrentTurnsBusyMessage(
        resolveMaxConcurrentChatTurns({
          status: "ok",
          engine: "Rune Weaver",
          version: "0.1.0",
          maxConcurrentChatTurns: 2,
        }),
      ),
    ).toContain("Already running 2 chat turns");
  });

  it("validates advertised turn caps into usable limits", () => {
    // Only finite numbers at least 1 become a cap; fractional values floor so
    // a drifted shape never admits unbounded turns or refuses everything.
    expect(parseMaxConcurrentChatTurns(3)).toBe(3);
    expect(parseMaxConcurrentChatTurns(3.9)).toBe(3);
    expect(parseMaxConcurrentChatTurns("2")).toBe(2);
    expect(parseMaxConcurrentChatTurns(" 4 ")).toBe(4);
    expect(parseMaxConcurrentChatTurns(0)).toBeNull();
    expect(parseMaxConcurrentChatTurns(-1)).toBeNull();
    expect(parseMaxConcurrentChatTurns("")).toBeNull();
    expect(parseMaxConcurrentChatTurns("many")).toBeNull();
    expect(parseMaxConcurrentChatTurns(null)).toBeNull();
    expect(parseMaxConcurrentChatTurns(undefined)).toBeNull();
    expect(parseMaxConcurrentChatTurns(Number.NaN)).toBeNull();
  });

  it("prefers the health body cap, then the probe header, then the fallback", async () => {
    // The JSON field wins when valid so future body-carried caps agree with
    // the header path; the header fills older bodies that carry none, and a
    // probe with neither degrades through the resolver instead of blocking.
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              status: "ok",
              engine: "Rune Weaver",
              version: "0.1.0",
              maxConcurrentChatTurns: 5,
            }),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                [MAX_CONCURRENT_CHAT_TURNS_HEADER]: "7",
              },
            },
          ),
      ),
    );
    expect((await getHealth()).maxConcurrentChatTurns).toBe(5);

    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              status: "ok",
              engine: "Rune Weaver",
              version: "0.1.0",
            }),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                [MAX_CONCURRENT_CHAT_TURNS_HEADER]: "4",
              },
            },
          ),
      ),
    );
    expect((await getHealth()).maxConcurrentChatTurns).toBe(4);

    // A drifted body never masks a valid header; the header keeps admit and
    // reject agreeing on one server-owned number.
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              status: "ok",
              engine: "Rune Weaver",
              version: "0.1.0",
              maxConcurrentChatTurns: 0,
            }),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                [MAX_CONCURRENT_CHAT_TURNS_HEADER]: "6",
              },
            },
          ),
      ),
    );
    expect((await getHealth()).maxConcurrentChatTurns).toBe(6);

    // Neither advertisement degrades to the fallback through the resolver so
    // older engines stay usable instead of refusing everything.
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              status: "ok",
              engine: "Rune Weaver",
              version: "0.1.0",
            }),
            {
              status: 200,
              headers: { "Content-Type": "application/json" },
            },
          ),
      ),
    );
    const legacy = await getHealth();
    expect(resolveMaxConcurrentChatTurns(legacy)).toBe(
      MAX_CONCURRENT_CHAT_TURNS,
    );
  });

  it("shares one run-log poll page and cadence across views", () => {
    // One source for polling keeps badges and history from drifting per call site.
    expect(RUN_LOG_POLL_LIMIT).toBe(50);
    expect(RUN_POLL_INTERVAL_MS).toBe(2500);
  });

  it("parses placeholder lines by shape instead of bracket substrings", () => {
    // Only the persisted narration shape counts as an execution record; prose
    // that merely mentions an identifier must never hide or evict.
    expect(parsePlaceholderCallID("Calling email.search {\"limit\":1} [call_1]")).toBe(
      "call_1",
    );
    expect(parsePlaceholderCallID("Calling email.search [call_2]")).toBe("call_2");
    expect(parsePlaceholderCallID("  Calling email.search {} [call_3]  ")).toBe(
      "call_3",
    );
    expect(parsePlaceholderCallID("You mentioned [call_1] in prose")).toBeNull();
    expect(parsePlaceholderCallID("Calling email.search [bad id]")).toBeNull();
    expect(parsePlaceholderCallID("Not a placeholder [call_1]")).toBeNull();
    expect(parsePlaceholderCallID("")).toBeNull();
  });

  it("matches placeholder coverage by parsed identity", () => {
    const text = [
      "Calling email.search {\"limit\":1} [call_9]",
      "Prose mentioning [call_9] without the narration shape",
      "Calling calendar.list {} [call_10]",
    ].join("\n");
    expect(textContainsPlaceholderForCall(text, "call_9")).toBe(true);
    expect(textContainsPlaceholderForCall(text, "call_10")).toBe(true);
    expect(textContainsPlaceholderForCall(text, "call_missing")).toBe(false);
    expect(textContainsPlaceholderForCall("Prose [call_9] only", "call_9")).toBe(
      false,
    );
    const ids = placeholderCallIDsInText(text);
    expect(ids.has("call_9")).toBe(true);
    expect(ids.has("call_10")).toBe(true);
    expect(ids.has("call_missing")).toBe(false);
    expect(placeholderCallIDsInText("Prose [call_9] only").size).toBe(0);
  });

  it("storeSecret resolves on 204 and posts key plus secret", async () => {
    // A stored secret is write-only: the client resolves on the bodyless 204
    // and never parses a JSON record, so the key plus value must ride the
    // request body exactly once.
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    await expect(
      storeSecret("EMAIL_PRIMARY_PASSWORD", "hunter2"),
    ).resolves.toBeUndefined();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/settings/secrets");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({
      key: "EMAIL_PRIMARY_PASSWORD",
      secret: "hunter2",
    });
  });

  it("deleteSecret resolves on 204 and sends DELETE", async () => {
    // Deletes share the bodyless-success contract, so the removal route must
    // not be expected to carry a JSON record back.
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    await expect(deleteSecret("EMAIL_PRIMARY_PASSWORD")).resolves.toBeUndefined();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/settings/secrets/EMAIL_PRIMARY_PASSWORD");
    expect(init.method).toBe("DELETE");
  });

  it("storeSecret still rejects a bare empty 200 as invalid JSON", async () => {
    // Only 204 counts as a bodyless success: an empty 200 fails closed so a
    // fetch-helper refactor cannot silently tolerate a missing secret
    // response and resurrect the invalid-JSON settings banner.
    const fetchMock = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await expect(
      storeSecret("EMAIL_PRIMARY_PASSWORD", "hunter2"),
    ).rejects.toThrow("Invalid JSON response: /settings/secrets");
  });
});

describe("parseToolProgress", () => {
  const validFrame = {
    callID: "call-1",
    toolName: "files.glob",
    message: "Find *.txt in ~",
    scanned: 42,
    matched: 3,
    elapsedMs: 4200,
    current: "Documents/notes.txt",
    sessionID: "s1",
  };

  it("normalizes a well-formed frame and keeps the relative tail", () => {
    expect(parseToolProgress(validFrame)).toEqual({
      callID: "call-1",
      toolName: "files.glob",
      message: "Find *.txt in ~",
      warning: null,
      scanned: 42,
      matched: 3,
      elapsedMs: 4200,
      current: "Documents/notes.txt",
    });
  });

  it("carries a dedicated warning and degrades a blank or drifted one to absent", () => {
    expect(
      parseToolProgress({ ...validFrame, warning: "  entire home folder  " }),
    ).toMatchObject({ warning: "entire home folder" });
    // A blank warning must not render an empty span, and a non-string payload
    // must not drop an otherwise complete frame.
    expect(parseToolProgress({ ...validFrame, warning: "   " })).toMatchObject({
      warning: null,
    });
    expect(parseToolProgress({ ...validFrame, warning: 7 })).toMatchObject({
      warning: null,
    });
  });

  it("degrades a blank or absent relative tail to null", () => {
    expect(parseToolProgress({ ...validFrame, current: "" })).toMatchObject({
      current: null,
    });
    expect(parseToolProgress({ ...validFrame, current: "   " })).toMatchObject({
      current: null,
    });
    expect(
      parseToolProgress({ ...validFrame, current: undefined }),
    ).toMatchObject({ current: null });
  });

  it("rejects absolute, home-relative, and traversing tails like the engine", () => {
    // Defense-in-depth: a handcrafted frame must never render a filesystem
    // location the engine's relativeCurrent would have dropped to nil.
    expect(
      parseToolProgress({ ...validFrame, current: "/etc/passwd" }),
    ).toMatchObject({ current: null });
    expect(
      parseToolProgress({ ...validFrame, current: "~/.ssh/id_rsa" }),
    ).toMatchObject({ current: null });
    expect(
      parseToolProgress({ ...validFrame, current: "../../secret" }),
    ).toMatchObject({ current: null });
    expect(
      parseToolProgress({ ...validFrame, current: "Documents/../../secret" }),
    ).toMatchObject({ current: null });
    // A ".." inside a filename is not a traversal segment and stays displayable.
    expect(
      parseToolProgress({ ...validFrame, current: "notes/a..b.txt" }),
    ).toMatchObject({ current: "notes/a..b.txt" });
  });

  it("caps a relative tail at the engine display length", () => {
    // The engine bounds the tail at 240 chars; mirror it so an over-long
    // handcrafted path cannot bloat the rendered line.
    const long = "a".repeat(300);
    expect(parseToolProgress({ ...validFrame, current: long })?.current).toBe(
      "a".repeat(240),
    );
  });

  it("drops a frame with missing identity, counters, or elapsed", () => {
    expect(parseToolProgress(null)).toBeNull();
    expect(parseToolProgress("tool_progress")).toBeNull();
    expect(parseToolProgress({ ...validFrame, callID: "" })).toBeNull();
    expect(parseToolProgress({ ...validFrame, toolName: "  " })).toBeNull();
    expect(parseToolProgress({ ...validFrame, message: 7 })).toBeNull();
    // Counters and elapsed share the engine's non-negative integer contract, so a
    // missing, fractional, or negative value drops the whole frame.
    expect(parseToolProgress({ ...validFrame, scanned: undefined })).toBeNull();
    expect(parseToolProgress({ ...validFrame, scanned: 1.5 })).toBeNull();
    expect(parseToolProgress({ ...validFrame, matched: -1 })).toBeNull();
    expect(parseToolProgress({ ...validFrame, elapsedMs: -1 })).toBeNull();
    expect(
      parseToolProgress({ ...validFrame, elapsedMs: Number.NaN }),
    ).toBeNull();
    expect(parseToolProgress({ ...validFrame, elapsedMs: 4200.5 })).toBeNull();
    expect(parseToolProgress({ ...validFrame, elapsedMs: true })).toBeNull();
  });
});

describe("formatToolProgressElapsedMs", () => {
  it("keeps a tenth under ten seconds and rounds to whole seconds from ten", () => {
    // Pins the documented rule: fast scans keep one decimal for a live feel,
    // while ten seconds and beyond round away the jittering tenth.
    expect(formatToolProgressElapsedMs(0)).toBe("0s");
    expect(formatToolProgressElapsedMs(4200)).toBe("4.2s");
    expect(formatToolProgressElapsedMs(9500)).toBe("9.5s");
    expect(formatToolProgressElapsedMs(10000)).toBe("10s");
    expect(formatToolProgressElapsedMs(12500)).toBe("13s");
  });
});

describe("owner bearer auth client", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
  });

  it("attaches the bearer on every fetch and mirrors it for direct calls", async () => {
    setAuthToken("owner-token");
    const fetchMock = vi.fn(async () =>
      jsonResponse({ status: "ok", engine: "Rune Weaver", version: "0.1.0" }),
    );
    vi.stubGlobal("fetch", fetchMock);
    await getHealth();
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe("Bearer owner-token");
    // Direct same-origin fetch calls use the shared helper so a lifecycle probe
    // never bypasses the gate; caller headers merge last.
    expect(
      authHeaders({ "Content-Type": "application/json" }),
    ).toMatchObject({
      Authorization: "Bearer owner-token",
      "Content-Type": "application/json",
    });
  });

  it("retires the token on a uniform 401 without echoing it", async () => {
    setAuthToken("secret-token-value");
    expect(isSessionAuthenticated()).toBe(true);
    const transitions: boolean[] = [];
    const unsubscribe = subscribeAuthState((authenticated) =>
      transitions.push(authenticated),
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: "unauthorized" }), {
            status: 401,
            headers: { "Content-Type": "application/json" },
          }),
      ),
    );
    const failure = await getHealth().catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(ApiError);
    expect((failure as ApiError).status).toBe(401);
    // The rejected credential is dropped from memory, and
    // holders fall back to the login gate without the value appearing anywhere.
    expect(getAuthToken()).toBeNull();
    expect(isSessionAuthenticated()).toBe(false);
    expect(window.sessionStorage.getItem(AUTH_TOKEN_STORAGE_KEY)).toBeNull();
    expect(transitions).toEqual([false]);
    expect((failure as ApiError).message).not.toContain("secret-token-value");
    unsubscribe();
  });

  it("rotates the token and reveals the replacement without storing in sessionStorage", async () => {
    setAuthToken("old-token");
    const fetchMock = vi.fn(async () => jsonResponse({ token: "new-token" }));
    vi.stubGlobal("fetch", fetchMock);
    const rotated = await rotateToken();
    expect(rotated).toBe("new-token");
    expect(isSessionAuthenticated()).toBe(true);
    // Token is NOT stored in sessionStorage
    expect(window.sessionStorage.getItem(AUTH_TOKEN_STORAGE_KEY)).toBeNull();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/auth/rotate");
    expect(init.method).toBe("POST");
    expect(init.credentials).toBe("same-origin");
  });

  it("clears memory and expires the session cookie on logout and never gates the no-auth posture", () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    setAuthToken("session-token");
    expect(isSessionAuthenticated()).toBe(true);
    clearAuthToken();
    expect(getAuthToken()).toBeNull();
    expect(isSessionAuthenticated()).toBe(false);
    expect(window.sessionStorage.getItem(AUTH_TOKEN_STORAGE_KEY)).toBeNull();
    expect(fetchMock).toHaveBeenCalledWith("/auth/session", {
      method: "DELETE",
      credentials: "same-origin",
    });
    // A logout with no credential present reports no transition, so the
    // loopback no-auth posture is never flipped to a login gate it does not
    // need; the value must not be recoverable from the session mirror either.
    const transitions: boolean[] = [];
    const unsubscribe = subscribeAuthState((authenticated) =>
      transitions.push(authenticated),
    );
    clearAuthToken();
    expect(transitions).toEqual([]);
    unsubscribe();
  });

  it("authenticates a login candidate via POST /auth/session without exposing token to sessionStorage", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ status: "ok" }));
    vi.stubGlobal("fetch", fetchMock);
    const accepted = await authenticateWithToken("  candidate-token  ");
    expect(accepted).toBe("ok");
    expect(isSessionAuthenticated()).toBe(true);
    // Token is NOT stored in sessionStorage or in-memory authToken
    expect(getAuthToken()).toBeNull();
    expect(window.sessionStorage.getItem(AUTH_TOKEN_STORAGE_KEY)).toBeNull();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/auth/session");
    expect(init.method).toBe("POST");
    expect(init.credentials).toBe("same-origin");
    expect(JSON.parse(init.body as string)).toEqual({ token: "candidate-token" });
  });

  it("classifies rejected, throttled, and unreachable logins", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 401 })));
    expect(await authenticateWithToken("bad-token")).toBe("invalid");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 429 })));
    expect(await authenticateWithToken("bad-token")).toBe("throttled");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("engine down");
      }),
    );
    expect(await authenticateWithToken("bad-token")).toBe("unreachable");
  });

  it("treats only a full health payload as an authenticated session", () => {
    // The boot gate reads the health shape: a minimal liveness object proves the
    // probe never cleared the owner gate, while a populated engine label means
    // the session is authenticated or the engine serves no auth.
    expect(
      isAuthenticatedHealth({
        status: "ok",
        engine: "Rune Weaver",
        version: "0.1.0",
      }),
    ).toBe(true);
    expect(
      isAuthenticatedHealth({ status: "ok", engine: "", version: "0.1.0" }),
    ).toBe(false);
    expect(isAuthenticatedHealth(null)).toBe(false);
    expect(isAuthenticatedHealth(undefined)).toBe(false);
  });
});

describe("host parity contract", () => {
  // Pinned cross-language vectors shared with the engine suite. The same JSON
  // literal lives in the Swift host-parity suite so a bracket, case, port, or
  // trailing-dot drift on either side fails its own suite instead of silently
  // forking the restart compare, the Host gate, or validation.
  type HostParityVector = {
    input: string;
    canonical: string;
    normalized: string;
    hostnameValid: boolean;
    allowedHostValid: boolean;
  };

  // Bracketed IPv6 strips only in the canonical form, casing folds in both
  // string forms, `:port` survives the canonical form but strips in the
  // normalized form only for an empty or colon-plus-numeric-port suffix
  // after `]` (trailing junk like `[::1]evil` survives verbatim and fails
  // validation), and a trailing dot survives both string forms while
  // failing validation.
  const fixtureJSON = `[
    {"input":"example.com","canonical":"example.com","normalized":"example.com","hostnameValid":true,"allowedHostValid":true},
    {"input":"  Example.COM  ","canonical":"example.com","normalized":"example.com","hostnameValid":true,"allowedHostValid":true},
    {"input":"[::1]","canonical":"::1","normalized":"[::1]","hostnameValid":true,"allowedHostValid":true},
    {"input":"::1","canonical":"::1","normalized":"::1","hostnameValid":true,"allowedHostValid":true},
    {"input":"[FE80::1]","canonical":"fe80::1","normalized":"[fe80::1]","hostnameValid":true,"allowedHostValid":true},
    {"input":"[Example.COM]","canonical":"[example.com]","normalized":"[example.com]","hostnameValid":false,"allowedHostValid":false},
    {"input":"Example.COM:8082","canonical":"example.com:8082","normalized":"example.com","hostnameValid":false,"allowedHostValid":true},
    {"input":"[::1]:8082","canonical":"[::1]:8082","normalized":"[::1]","hostnameValid":false,"allowedHostValid":true},
    {"input":"[::1]evil","canonical":"[::1]evil","normalized":"[::1]evil","hostnameValid":false,"allowedHostValid":false},
    {"input":"localhost.","canonical":"localhost.","normalized":"localhost.","hostnameValid":false,"allowedHostValid":false},
    {"input":"example.com.","canonical":"example.com.","normalized":"example.com.","hostnameValid":false,"allowedHostValid":false},
    {"input":"LOCALHOST","canonical":"localhost","normalized":"localhost","hostnameValid":true,"allowedHostValid":true},
    {"input":"  [::1]  ","canonical":"::1","normalized":"[::1]","hostnameValid":true,"allowedHostValid":true},
    {"input":"http://evil.com","canonical":"http://evil.com","normalized":"http","hostnameValid":false,"allowedHostValid":false},
    {"input":"*.example.com","canonical":"*.example.com","normalized":"*.example.com","hostnameValid":false,"allowedHostValid":false},
    {"input":"[::1","canonical":"[::1","normalized":"[::1","hostnameValid":false,"allowedHostValid":false},
    {"input":":8082","canonical":":8082","normalized":"","hostnameValid":false,"allowedHostValid":false}
  ]`;

  it("matches the pinned restart, normalize, and exact-host matrix", () => {
    const vectors = JSON.parse(fixtureJSON) as HostParityVector[];
    expect(vectors.length).toBeGreaterThan(0);
    for (const vector of vectors) {
      // The restart compare strips brackets only around a colon-bearing
      // literal so `[::1]` and `::1` agree while `[example.com]` stays distinct.
      expect(canonicalRestartHost(vector.input)).toBe(vector.canonical);
      // The Host gate keeps bracketed IPv6 intact while stripping a
      // `:port` only for an empty or colon-plus-numeric-port suffix
      // after `]`, so the saved allowlist and the request header
      // compare alike without truncating trailing junk to allowlisted.
      expect(normalizeServerAllowedHost(vector.input)).toBe(
        vector.normalized,
      );
      // Hostname validation rejects a `:port` suffix the allowlist strips,
      // while both reject schemes, wildcards, unbalanced or non-IPv6
      // brackets, trailing junk after `]`, and a trailing dot fail-closed.
      expect(validateServerHostname(vector.input) === null).toBe(
        vector.hostnameValid,
      );
      expect(validateServerAllowedHost(vector.input) === null).toBe(
        vector.allowedHostValid,
      );
    }
  });
});

describe("goal client and helpers", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("normalizes a well-formed goal snapshot and degrades drifted fields", () => {
    const snapshot = parseGoalSnapshot({
      id: "  goal-1  ",
      title: "field guide",
      statement: "Publish the field guide",
      status: "active",
      progress: { done: 1.9, total: 4 },
      stepIntervalMinutes: 1440.8,
      nextDueAt: 1700000000,
      // Canonical key wins over the legacy aliases when they ride together.
      originSessionId: "s-canonical",
      originSessionID: "s-legacy",
      createdAt: "2024-01-01T00:00:00.000Z",
      updatedAt: 1700000000,
    });
    expect(snapshot).toMatchObject({
      id: "goal-1",
      title: "field guide",
      progress: { done: 1, total: 4 },
      stepIntervalMinutes: 1440,
      nextDueAt: 1700000000,
      originSessionId: "s-canonical",
      createdAt: "2024-01-01T00:00:00.000Z",
      updatedAt: 1700000000,
    });
  });

  it("accepts the legacy origin spelling and defaults absent fields", () => {
    const snapshot = parseGoalSnapshot({
      id: "goal-1",
      title: "field guide",
      status: "paused",
      origin_session_id: "legacy-session",
    });
    expect(snapshot?.originSessionId).toBe("legacy-session");
    expect(snapshot?.progress).toEqual({ done: 0, total: 0 });
    expect(snapshot?.stepIntervalMinutes).toBe(0);
    expect(snapshot?.nextDueAt).toBeNull();
    expect(snapshot?.createdAt).toBe(0);
    expect(snapshot?.updatedAt).toBe(0);
  });

  it("rejects a snapshot missing identity or core display fields", () => {
    expect(parseGoalSnapshot(null)).toBeNull();
    expect(parseGoalSnapshot("goal")).toBeNull();
    expect(parseGoalSnapshot({})).toBeNull();
    expect(
      parseGoalSnapshot({ id: "  ", title: "x", status: "active" }),
    ).toBeNull();
    expect(parseGoalSnapshot({ id: "g", status: "active" })).toBeNull();
    expect(parseGoalSnapshot({ id: "g", title: "x" })).toBeNull();
  });

  it("never lets a drifted timestamp reach the render path", () => {
    // A non-string/non-number timestamp would throw inside parseRunTimestamp's
    // string path; the parser must fall back instead of letting it through.
    const snapshot = parseGoalSnapshot({
      id: "goal-1",
      title: "field guide",
      status: "active",
      nextDueAt: { nested: true },
      createdAt: false,
      updatedAt: ["nope"],
    });
    expect(snapshot).not.toBeNull();
    expect(snapshot?.nextDueAt).toBeNull();
    expect(snapshot?.createdAt).toBe(0);
    expect(snapshot?.updatedAt).toBe(0);
  });

  it("extracts a goal only from a well-formed goal_updated frame", () => {
    const detail = { id: "goal-1", title: "field guide", status: "active" };
    expect(
      parseGoalUpdatedFrame({ type: "goal_updated", goal: detail })?.id,
    ).toBe("goal-1");
    expect(parseGoalUpdatedFrame({ type: "delta", goal: detail })).toBeNull();
    expect(parseGoalUpdatedFrame({ type: "goal_updated" })).toBeNull();
    expect(parseGoalUpdatedFrame(null)).toBeNull();
  });

  it("recognizes only a needs-input proactive nudge", () => {
    expect(
      isGoalNeedsInputProactive({
        type: "proactive_message",
        kind: "goalNeedsInput",
      }),
    ).toBe(true);
    expect(
      isGoalNeedsInputProactive({
        type: "proactive_message",
        kind: "needs_input",
      }),
    ).toBe(true);
    expect(
      isGoalNeedsInputProactive({
        type: "proactive_message",
        kind: "NEEDS-INPUT",
      }),
    ).toBe(true);
    expect(
      isGoalNeedsInputProactive({
        type: "proactive_message",
        kind: "schedulerError",
      }),
    ).toBe(false);
    expect(
      isGoalNeedsInputProactive({
        type: "run_completed",
        kind: "goalNeedsInput",
      }),
    ).toBe(false);
    expect(
      isGoalNeedsInputProactive({ type: "proactive_message", kind: 7 }),
    ).toBe(false);
    expect(isGoalNeedsInputProactive(null)).toBe(false);
  });

  it("formats the next advance across statuses and due windows", () => {
    const now = Date.UTC(2024, 0, 1, 0, 0, 0);
    expect(formatGoalNextAdvance("paused", now + 3_600_000, now)).toBe("—");
    expect(formatGoalNextAdvance("needs_input", now + 3_600_000, now)).toBe("—");
    expect(formatGoalNextAdvance("achieved", now + 3_600_000, now)).toBe("—");
    expect(formatGoalNextAdvance("abandoned", now + 3_600_000, now)).toBe("—");
    expect(formatGoalNextAdvance("active", null, now)).toBe("No schedule");
    expect(formatGoalNextAdvance("active", now - 1000, now)).toBe("due now");
    expect(formatGoalNextAdvance("active", now + 3 * 3_600_000, now)).toBe(
      "in 3h",
    );
  });

  it("clamps goal progress to whole percentages", () => {
    expect(goalProgressPercent(null)).toBe(0);
    expect(goalProgressPercent({ done: 0, total: 0 })).toBe(0);
    expect(goalProgressPercent({ done: 1, total: 3 })).toBe(33);
    expect(goalProgressPercent({ done: 9, total: 4 })).toBe(100);
    expect(goalProgressPercent({ done: Number.NaN, total: 4 })).toBe(0);
  });

  it("labels and tones every lifecycle state with an honest fallback", () => {
    expect(goalStatusLabel("active")).toBe("Active");
    expect(goalStatusLabel("needs_input")).toBe("Needs input");
    expect(goalStatusLabel("needsInput")).toBe("Needs input");
    expect(goalStatusLabel("mystery")).toBe("mystery");
    expect(goalStatusTone("active")).toBe("running");
    expect(goalStatusTone("needsInput")).toBe("awaiting_approval");
    expect(goalStatusTone("achieved")).toBe("ok");
    expect(goalStatusTone("abandoned")).toBe("error");
    expect(goalStatusTone("paused")).toBe("skipped");
    expect(goalStatusTone("mystery")).toBe("skipped");
  });

  it("labels goal cadences with the create-form words and a plain fallback", () => {
    expect(goalCadenceLabel(1440)).toBe("Daily");
    expect(goalCadenceLabel(10080)).toBe("Weekly");
    expect(goalCadenceLabel(720)).toBe("Every 12 hours");
    expect(goalCadenceLabel(90)).toBe("every 90m");
  });

  it("formats run durations on one shared scale", () => {
    expect(formatRunDuration(0)).toBe("0ms");
    expect(formatRunDuration(345)).toBe("345ms");
    expect(formatRunDuration(1500)).toBe("1.5s");
    expect(formatRunDuration(12_500)).toBe("12.5s");
    expect(formatRunDuration(-1)).toBeNull();
    expect(formatRunDuration(Number.NaN)).toBeNull();
    expect(formatRunDuration(null)).toBeNull();
    expect(formatRunDuration(undefined)).toBeNull();
  });

  it("routes goal deletes with an optional purge flag", async () => {
    const seen: Array<{ path: string; method?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        seen.push({ path: input, method: init?.method });
        return new Response(null, { status: 204 });
      }),
    );
    await deleteGoal("goal/1");
    await deleteGoal("goal/1", true);
    expect(seen[0]).toEqual({ path: "/goals/goal%2F1", method: "DELETE" });
    expect(seen[1]).toEqual({
      path: "/goals/goal%2F1?purge=true",
      method: "DELETE",
    });
  });

  it("parses idea rows and recognizes only idea-proposed frames", () => {
    const parsed = parseIdea({
      id: "idea-1",
      kind: "plan_adjustment",
      title: "Try a shorter loop",
      body: "Run 2km.",
      goalId: "goal-1",
      status: "proposed",
      createdAt: 1,
      updatedAt: 2,
    });
    expect(parsed?.id).toBe("idea-1");
    expect(parsed?.goalId).toBe("goal-1");
    // Padded goal links trim so deep-link equality holds instead of comparing
    // a padded raw value against a canonical identifier.
    expect(
      parseIdea({
        id: "idea-padded",
        kind: "tip",
        title: "Hydrate",
        status: "proposed",
        goalId: "  goal-1  ",
      })?.goalId,
    ).toBe("goal-1");
    expect(
      parseIdea({
        id: "idea-legacy",
        kind: "tip",
        title: "Hydrate",
        status: "proposed",
        goal_id: "  goal-2  ",
      })?.goalId,
    ).toBe("goal-2");
    expect(
      parseIdea({
        id: "idea-blank-goal",
        kind: "tip",
        title: "Hydrate",
        status: "proposed",
        goalId: "   ",
      })?.goalId,
    ).toBeNull();
    // A body-less tip still validates instead of dropping the suggestion.
    expect(
      parseIdea({ id: "idea-2", kind: "tip", title: "Hydrate", status: "proposed" })
        ?.body,
    ).toBe("");
    expect(parseIdea({ id: "  ", kind: "tip", title: "x", status: "proposed" })).toBeNull();
    expect(parseIdea({ id: "idea-3", kind: "tip" })).toBeNull();
    expect(parseIdea(null)).toBeNull();
    // A blank title rejects the row like the engine and wire decoder do,
    // instead of rendering an empty card.
    expect(
      parseIdea({ id: "idea-4", kind: "tip", title: "", status: "proposed" }),
    ).toBeNull();
    expect(
      parseIdea({ id: "idea-5", kind: "tip", title: "   ", status: "proposed" }),
    ).toBeNull();

    expect(ideaKindLabel("plan_adjustment")).toBe("Plan");
    expect(ideaKindLabel("new_goal")).toBe("New goal");
    expect(ideaKindLabel("tip")).toBe("Tip");
    expect(ideaKindLabel("wild_idea")).toBe("wild idea");

    expect(
      isIdeaProposedProactive({
        type: "proactive_message",
        kind: "idea_proposed",
      }),
    ).toBe(true);
    expect(
      isIdeaProposedProactive({
        type: "proactive_message",
        kind: "ideaProposed",
      }),
    ).toBe(true);
    expect(
      isIdeaProposedProactive({
        type: "proactive_message",
        kind: "goalNeedsInput",
      }),
    ).toBe(false);
    expect(isIdeaProposedProactive(null)).toBe(false);
  });

  it("routes idea reads and decisions through the shared JSON client", async () => {
    const seen: Array<{ path: string; method?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        seen.push({ path: input, method: init?.method });
        if (input === "/ideas/summary") {
          return jsonResponse({ total: 2, proposed: 1, accepted: 1, dismissed: 0 });
        }
        if (input === "/ideas?status=proposed") {
          return jsonResponse({ ideas: [], count: 0 });
        }
        return jsonResponse({
          id: "idea-1",
          kind: "tip",
          title: "Hydrate",
          body: "",
          status: "accepted",
        });
      }),
    );
    const listed = await listIdeas("proposed");
    expect(listed.count).toBe(0);
    const summary = await getIdeasSummary();
    expect(summary.proposed).toBe(1);
    const accepted = await acceptIdea("idea/1");
    expect(accepted.status).toBe("accepted");
    await dismissIdea("idea/1");
    expect(seen.map((call) => call.path)).toEqual([
      "/ideas?status=proposed",
      "/ideas/summary",
      "/ideas/idea%2F1/accept",
      "/ideas/idea%2F1/dismiss",
    ]);
    expect(seen[2].method).toBe("POST");
    expect(seen[3].method).toBe("POST");
  });
});

describe("tool-round budget readers", () => {
  const goalsBase = {
    enabled: true,
    step_interval_minutes: 1440,
    max_active_goals: 10,
  };

  const settingsBase = {
    engineName: "Rune Weaver",
    logLevel: "info",
    defaultProvider: "mlx",
    providers: {},
    memoryVectorDBPath: "memory/vectors",
    memoryEpisodesDBPath: "memory/episodes.db",
    memoryEmbeddingModel: "bge-small-en-v1.5",
    memoryEmbeddingBackend: "apple",
    voiceSTTProvider: "whisper",
    voiceWhisperModel: "base.en",
    voiceTTSProvider: "system",
    emailAccounts: [],
    pluginsDir: "~/.runeweaver/plugins",
    pluginsMarketplaceIndexURL: "https://example.com/index.json",
    pluginsAutoRescan: true,
    configPath: "/Users/test/.runeweaver/config.toml",
  };

  const jobBase = {
    id: "33333333-3333-3333-3333-333333333333",
    name: "morning digest",
    schedule: "0 8 * * *",
    prompt: "Summarize mail",
    enabled: true,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
  };

  it("keeps budget defaults and bounds pinned to the engine contract", () => {
    expect(DEFAULT_GOALS_MAX_TOOL_ITERATIONS).toBe(35);
    expect(DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS).toBe(25);
    expect(TOOL_ROUNDS_MIN).toBe(1);
    expect(TOOL_ROUNDS_MAX).toBe(100);
  });

  it("prefers snake_case over camelCase with fallback to the goals default", () => {
    expect(
      goalsMaxToolIterations({
        ...goalsBase,
        max_tool_iterations: 40,
        maxToolIterations: 50,
      }),
    ).toBe(40);
    expect(goalsMaxToolIterations({ ...goalsBase, maxToolIterations: 50 })).toBe(
      50,
    );
    expect(goalsMaxToolIterations(undefined)).toBe(35);
    expect(goalsMaxToolIterations(null)).toBe(35);
    expect(goalsMaxToolIterations({ ...goalsBase })).toBe(35);
  });

  it("clamps goal budgets into 1-100 with floor", () => {
    expect(goalsMaxToolIterations({ ...goalsBase, max_tool_iterations: 0 })).toBe(
      1,
    );
    expect(
      goalsMaxToolIterations({ ...goalsBase, max_tool_iterations: 200 }),
    ).toBe(100);
    expect(
      goalsMaxToolIterations({ ...goalsBase, max_tool_iterations: 10.9 }),
    ).toBe(10);
    expect(
      goalsMaxToolIterations({ ...goalsBase, max_tool_iterations: Number.NaN }),
    ).toBe(35);
  });

  it("reads the scheduler section default with fallback and clamp", () => {
    expect(schedulerMaxToolIterations(undefined)).toBe(25);
    expect(schedulerMaxToolIterations(null)).toBe(25);
    expect(schedulerMaxToolIterations({ ...settingsBase })).toBe(25);
    expect(
      schedulerMaxToolIterations({ ...settingsBase, schedulerMaxToolIterations: 30 }),
    ).toBe(30);
    expect(
      schedulerMaxToolIterations({ ...settingsBase, schedulerMaxToolIterations: 0 }),
    ).toBe(1);
    expect(
      schedulerMaxToolIterations({
        ...settingsBase,
        schedulerMaxToolIterations: 200,
      }),
    ).toBe(100);
    expect(
      schedulerMaxToolIterations({
        ...settingsBase,
        schedulerMaxToolIterations: 12.9,
      }),
    ).toBe(12);
  });

  it("resolves per-job override with section-default inheritance and clamp", () => {
    expect(schedulerJobEffectiveMaxToolIterations(null, 30)).toBe(30);
    expect(schedulerJobEffectiveMaxToolIterations(undefined, 30)).toBe(30);
    expect(
      schedulerJobEffectiveMaxToolIterations(
        { ...jobBase, maxToolIterations: null },
        30,
      ),
    ).toBe(30);
    expect(
      schedulerJobEffectiveMaxToolIterations(
        { ...jobBase, maxToolIterations: 40 },
        30,
      ),
    ).toBe(40);
    expect(
      schedulerJobEffectiveMaxToolIterations(
        { ...jobBase, maxToolIterations: 0 },
        30,
      ),
    ).toBe(1);
    expect(
      schedulerJobEffectiveMaxToolIterations(
        { ...jobBase, maxToolIterations: 200 },
        30,
      ),
    ).toBe(100);
  });
});
