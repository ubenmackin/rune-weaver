// Rune Weaver Dashboard — Shared approvals vocabulary tests.

import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  clearApprovalHistory,
  decideApproval,
  listApprovalHistory,
  trustDurationOptions,
  type PermissionRequest,
} from "./api";
import {
  deriveRequestTarget,
  durationOptionsFor,
  EGRESS_DURATIONS,
  truncateTarget,
  widenableBaseDomain,
} from "./approvalsShared";
import { jsonResponse } from "./test-utils/http";

function makeRequest(
  overrides: Partial<PermissionRequest> & Pick<PermissionRequest, "id" | "toolName">,
): PermissionRequest {
  return {
    description: "test request",
    input: {
      toolName: overrides.toolName,
      argumentsJSON: "{}",
      callID: "call-1",
    },
    suggestedDurations: [...EGRESS_DURATIONS],
    ...overrides,
  };
}

describe("approvalsShared", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("exposes all seven egress tiers", () => {
    expect(EGRESS_DURATIONS).toEqual([
      "thisTime",
      "forTask",
      "forSession",
      "fiveMinutes",
      "oneHour",
      "oneDay",
      "forever",
    ]);
  });

  it("returns all seven durations for a plain request", () => {
    const options = durationOptionsFor(
      makeRequest({ id: "r1", toolName: "files.read" }),
    );
    expect(options).toHaveLength(7);
    expect(options.map((option) => option.value)).toEqual(
      trustDurationOptions.map((option) => option.value),
    );
  });

  it("returns all seven egress tiers for an egress-parked request", () => {
    const options = durationOptionsFor(
      makeRequest({
        id: "r2",
        toolName: "api.request",
        egressHost: "api.example.com",
      }),
    );
    expect(options.map((option) => option.value)).toEqual([
      "thisTime",
      "forTask",
      "forSession",
      "fiveMinutes",
      "oneHour",
      "oneDay",
      "forever",
    ]);
  });

  it("computes widenableBaseDomain for standard and multi-part public suffix domains while rejecting literals", () => {
    expect(widenableBaseDomain("api.example.com")).toBe("example.com");
    expect(widenableBaseDomain("v1.api.example.com")).toBe("example.com");
    expect(widenableBaseDomain("example.com")).toBe("example.com");
    expect(widenableBaseDomain("api.bbc.co.uk")).toBe("bbc.co.uk");
    expect(widenableBaseDomain("co.uk")).toBeNull();
    expect(widenableBaseDomain("localhost")).toBeNull();
    expect(widenableBaseDomain("93.184.216.34")).toBeNull();
    expect(widenableBaseDomain("[::1]")).toBeNull();
  });

  it("rejects bare multi-tenant public suffixes exactly like the engine", () => {
    expect(widenableBaseDomain("web.app")).toBeNull();
    expect(widenableBaseDomain("blogspot.com")).toBeNull();
    expect(widenableBaseDomain("amazonaws.com")).toBeNull();
    // A tenant base three labels deep stays widenable on both sides.
    expect(widenableBaseDomain("tenant.web.app")).toBe("tenant.web.app");
    expect(widenableBaseDomain("docs.pages.dev")).toBe("docs.pages.dev");
    // A three-label registrant in the amazonaws family widens under its own
    // base, which the engine's widenability mirror must accept too.
    expect(widenableBaseDomain("bucket.s3.amazonaws.com")).toBe(
      "s3.amazonaws.com",
    );
  });

  it("rejects all-numeric dotted hosts the resolver accepts but the engine refuses", () => {
    expect(widenableBaseDomain("1.2.3.999")).toBeNull();
    expect(widenableBaseDomain("123.456")).toBeNull();
    expect(widenableBaseDomain("999.999.999.999")).toBeNull();
  });

  it("refuses sibling-tenant widening onto bare shared-parent suffixes", () => {
    // A bare shared parent never bases a wildcard, while evil.<suffix>
    // widens only under its own tenant base on both sides of the mirror.
    const suffixes = [
      "co.at",
      "co.id",
      "co.il",
      "co.ke",
      "co.th",
      "ltd.uk",
      "plc.uk",
      "sch.uk",
      "asn.au",
      "id.au",
      "wordpress.com",
      "tumblr.com",
      "myshopify.com",
      "github.dev",
      "githubusercontent.com",
      "googleusercontent.com",
      "deno.dev",
      "repl.co",
      "duckdns.org",
      "ngrok.io",
      "trycloudflare.com",
    ];
    for (const suffix of suffixes) {
      expect(widenableBaseDomain(suffix)).toBeNull();
      expect(widenableBaseDomain(`evil.${suffix}`)).toBe(`evil.${suffix}`);
    }
  });

  it("prefers the stored displayTarget", () => {
    const target = deriveRequestTarget(
      makeRequest({
        id: "r3",
        toolName: "files.read",
        displayTarget: "/tmp/report.txt",
        input: {
          toolName: "files.read",
          argumentsJSON: JSON.stringify({ path: "/other.txt" }),
          callID: "call-1",
        },
      }),
    );
    expect(target).toBe("/tmp/report.txt");
  });

  it("falls back to the egress host before arguments", () => {
    const target = deriveRequestTarget(
      makeRequest({
        id: "r4",
        toolName: "api.request",
        egressHost: "api.example.com",
        input: {
          toolName: "api.request",
          argumentsJSON: JSON.stringify({ url: "https://other.example/" }),
          callID: "call-1",
        },
      }),
    );
    expect(target).toBe("api.example.com");
  });

  it("falls back to command, recipient, path, and url keys", () => {
    expect(
      deriveRequestTarget(
        makeRequest({
          id: "r5",
          toolName: "bash.exec",
          input: {
            toolName: "bash.exec",
            argumentsJSON: JSON.stringify({ command: "ls -la" }),
            callID: "call-1",
          },
        }),
      ),
    ).toBe("ls -la");
    expect(
      deriveRequestTarget(
        makeRequest({
          id: "r6",
          toolName: "email.send",
          input: {
            toolName: "email.send",
            argumentsJSON: JSON.stringify({ to: "alice@example.com" }),
            callID: "call-1",
          },
        }),
      ),
    ).toBe("alice@example.com");
    expect(
      deriveRequestTarget(
        makeRequest({
          id: "r7",
          toolName: "files.read",
          input: {
            toolName: "files.read",
            argumentsJSON: JSON.stringify({ path: "/tmp/a.txt" }),
            callID: "call-1",
          },
        }),
      ),
    ).toBe("/tmp/a.txt");
    expect(
      deriveRequestTarget(
        makeRequest({
          id: "r8",
          toolName: "web.fetch",
          input: {
            toolName: "web.fetch",
            argumentsJSON: JSON.stringify({ url: "https://example.com" }),
            callID: "call-1",
          },
        }),
      ),
    ).toBe("https://example.com");
  });

  it("returns null when no target is derivable", () => {
    expect(
      deriveRequestTarget(
        makeRequest({
          id: "r9",
          toolName: "files.read",
          input: {
            toolName: "files.read",
            argumentsJSON: "not-json",
            callID: "call-1",
          },
        }),
      ),
    ).toBeNull();
    expect(
      deriveRequestTarget(
        makeRequest({
          id: "r10",
          toolName: "files.read",
          displayTarget: "   ",
          input: {
            toolName: "files.read",
            argumentsJSON: JSON.stringify({ other: 1 }),
            callID: "call-1",
          },
        }),
      ),
    ).toBeNull();
  });

  it("truncates at exactly 80 characters with an ellipsis", () => {
    expect(truncateTarget("a".repeat(80))).toBe("a".repeat(80));
    expect(truncateTarget("a".repeat(79))).toBe("a".repeat(79));
    expect(truncateTarget("a".repeat(81))).toBe(`${"a".repeat(80)}…`);
    expect(truncateTarget("short")).toBe("short");
  });

  it("appends the surface tag to the decide body", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ id: "a1", approved: true, duration: "thisTime" }),
    );
    vi.stubGlobal("fetch", fetchMock);
    await decideApproval("a1", true, "thisTime", undefined, "chat");
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(JSON.parse(init.body as string)).toEqual({
      approved: true,
      duration: "thisTime",
      surface: "chat",
    });
    await decideApproval("a1", true, "thisTime");
    const [, bareInit] = fetchMock.mock.calls[1] as unknown as [
      string,
      RequestInit,
    ];
    expect(JSON.parse(bareInit.body as string)).toEqual({
      approved: true,
      duration: "thisTime",
    });
  });

  it("lists approval history through GET /approvals/history", async () => {
    const seen: string[] = [];
    const fetchMock = vi.fn(async (input: string) => {
      seen.push(input);
      return jsonResponse({ entries: [], count: 0 });
    });
    vi.stubGlobal("fetch", fetchMock);
    await listApprovalHistory();
    expect(seen[0]).toBe("/approvals/history");
    await listApprovalHistory({ limit: 25, tool: "email.send", action: "denied" });
    const url = new URL(seen[1], "http://localhost");
    expect(url.pathname).toBe("/approvals/history");
    expect(url.searchParams.get("limit")).toBe("25");
    expect(url.searchParams.get("tool")).toBe("email.send");
    expect(url.searchParams.get("action")).toBe("denied");
  });

  it("clears approval history through DELETE /approvals/history", async () => {
    const seen: Array<{ path: string; method?: string }> = [];
    const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
      seen.push({ path: input, method: init?.method });
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);
    await clearApprovalHistory();
    expect(seen[0].path).toBe("/approvals/history");
    expect(seen[0].method).toBe("DELETE");
  });
});
