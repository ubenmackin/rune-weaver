// Rune Weaver Dashboard — Component tests for the Access pane shell and its
// Rules section.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import AccessPane from "./AccessPane";
import { readAccessDeepLink } from "./access/accessNav";
import { clearAuthToken, type AccessRule, type AccessScopeDTO } from "../api";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

// Fresh ISO clocks built per run so the active-rule header never depends on a
// fixed timestamp drifting into the past.
const nowIso = () => new Date().toISOString();

interface RuleSeed {
  id: string;
  toolName: string;
  scope: AccessScopeDTO;
  effect: "allow" | "deny";
  duration?: AccessRule["duration"];
  useCount?: number;
  expiresAt?: string | null;
  lastUsedAt?: string | null;
  reason?: string | null;
}

// Builds one wire rule mirroring the engine's GET /approvals/rules shape: a
// forever standing rule by default so the header derivation reads it active.
function seedRule(seed: RuleSeed): AccessRule {
  return {
    id: seed.id,
    toolName: seed.toolName,
    scope: seed.scope,
    action: seed.effect,
    effect: seed.effect,
    grantedAt: nowIso(),
    expiresAt: seed.expiresAt ?? null,
    duration: seed.duration ?? "forever",
    useCount: seed.useCount ?? 0,
    lastUsedAt: seed.lastUsedAt ?? null,
    reason: seed.reason ?? null,
  };
}

interface StubRoutesOptions {
  rules?: (AccessRule | Record<string, unknown>)[];
  // Per-write override so a case can return a refusal (for example a widen 409)
  // while every other write answers the engine's bodyless 204.
  onWrite?: (path: string, method: string, body: Record<string, unknown> | undefined) => Response | undefined;
}

// Routes GET /approvals/rules to the seeded list and records every write so a
// case can assert the exact path, method, and body that shipped.
function stubRoutes(options: StubRoutesOptions) {
  const rules = options.rules ?? [];
  const fetchMock = vi.fn(
    async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const path = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      if (path === "/approvals/rules" && method === "GET") {
        return jsonResponse({ rules, count: rules.length });
      }
      if (path.startsWith("/approvals/rules")) {
        let body: Record<string, unknown> | undefined;
        try {
          body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : undefined;
        } catch {
          body = undefined;
        }
        const custom = options.onWrite?.(path, method, body);
        return custom ?? new Response(null, { status: 204 });
      }
      // The shell also mounts sibling sections in the rail test; answer every
      // other route with an empty object so those mounts stay harmless.
      return jsonResponse({});
    },
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

type RecordedWrite = { path: string; method: string; body?: Record<string, unknown> };

function recordedWrites(fetchMock: ReturnType<typeof stubRoutes>): RecordedWrite[] {
  return fetchMock.mock.calls
    .map((call) => {
      const [input, init] = call as [string, RequestInit | undefined];
      let body: Record<string, unknown> | undefined;
      try {
        body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : undefined;
      } catch {
        body = undefined;
      }
      return { path: String(input), method: (init?.method ?? "GET").toUpperCase(), body };
    })
    .filter((recorded) => recorded.method !== "GET");
}

// Module-scoped socket capture so the refetch-on-frame test can dispatch into
// the live shared connection the section subscribes to.
let socketCapture = createMockWebSocketCapture();

describe("AccessPane", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    clearAuthToken();
    // Reset both the hash and the query so a prior test's deep link never leaks.
    window.history.replaceState(null, "", "/settings");
    socketCapture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(socketCapture));
  });

  describe("readAccessDeepLink", () => {
    it("returns null when no access parameter is present", () => {
      expect(readAccessDeepLink()).toBeNull();
    });

    it("returns null for the bare rules section token", () => {
      window.location.hash = "#settings?access=rules";
      expect(readAccessDeepLink()).toBeNull();
    });

    it("returns the rule id from the hash-query access parameter", () => {
      window.location.hash = "#settings?access=rule-42";
      expect(readAccessDeepLink()).toBe("rule-42");
    });

    it("returns the rule id from a bare query access parameter", () => {
      window.history.replaceState(null, "", "/settings?access=rule-9");
      expect(readAccessDeepLink()).toBe("rule-9");
    });
  });

  it("renders the tabs with Rules as the landing section and keeps its selection stable", async () => {
    stubRoutes({ rules: [] });
    const user = userEvent.setup();
    render(<AccessPane />);

    for (const key of ["rules", "bash", "network", "credentials", "files"]) {
      expect(screen.getByTestId(`access-tab-${key}`)).toBeInTheDocument();
    }
    expect(screen.getByTestId("access-tab-rules").getAttribute("aria-selected")).toBe("true");
    await waitFor(() => {
      expect(screen.getByTestId("access-rules-section")).toBeInTheDocument();
    });

    // Selecting another section moves the tabs and mounts only that section.
    await user.click(screen.getByTestId("access-tab-bash"));
    expect(screen.getByTestId("access-tab-bash").getAttribute("aria-selected")).toBe("true");
    expect(screen.getByTestId("access-tab-rules").getAttribute("aria-selected")).toBe("false");
    await waitFor(() => {
      expect(screen.getByTestId("bash-pane")).toBeInTheDocument();
    });
    expect(screen.queryByTestId("access-rules-section")).toBeNull();

    // Returning to Rules keeps the selection under the shell's control.
    await user.click(screen.getByTestId("access-tab-rules"));
    await waitFor(() => {
      expect(screen.getByTestId("access-rules-section")).toBeInTheDocument();
    });
    expect(screen.getByTestId("access-tab-rules").getAttribute("aria-selected")).toBe("true");
  });

  it("derives the plain-English header from active allow rules grouped by tool", async () => {
    stubRoutes({
      rules: [
        seedRule({
          id: "r1",
          toolName: "email.send",
          scope: { kind: "recipientSet", handles: ["a@x.com", "b@x.com", "c@x.com"] },
          effect: "allow",
        }),
        seedRule({ id: "r2", toolName: "bash.exec", scope: { kind: "tool" }, effect: "allow" }),
      ],
    });
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rules-header")).toBeInTheDocument();
    });
    expect(screen.getByTestId("access-rules-header").textContent).toBe(
      "Right now the agent can run shell commands and send email to 3 people.",
    );
  });

  it("reads the approval-only header when no active allow rule remains", async () => {
    stubRoutes({
      rules: [
        seedRule({
          id: "d1",
          toolName: "email.send",
          scope: { kind: "tool" },
          effect: "deny",
        }),
      ],
    });
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rules-header")).toBeInTheDocument();
    });
    expect(screen.getByTestId("access-rules-header").textContent).toContain(
      "Every call needs your approval",
    );
  });

  it("revokes a rule through DELETE /approvals/rules/:id", async () => {
    const fetchMock = stubRoutes({
      rules: [
        seedRule({
          id: "rule-revoke",
          toolName: "web.fetch",
          scope: { kind: "exactTarget", target: "https://example.com" },
          effect: "allow",
        }),
      ],
    });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-rule-revoke")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-rule-revoke-rule-revoke"));
    await user.click(screen.getByTestId("access-revoke-confirm"));

    await waitFor(() => {
      expect(
        recordedWrites(fetchMock).some(
          (recorded) =>
            recorded.method === "DELETE" && recorded.path === "/approvals/rules/rule-revoke",
        ),
      ).toBe(true);
    });
  });

  it("edits an allow rule through the edit modal, replacing it with updated scope", async () => {
    const fetchMock = stubRoutes({
      rules: [
        seedRule({
          id: "rule-edit-1",
          toolName: "bash.exec",
          scope: { kind: "exactTarget", target: "git status" },
          effect: "allow",
        }),
      ],
    });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-rule-edit-1")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-rule-edit-rule-edit-1"));
    expect(screen.getByText("Edit Access Rule")).toBeInTheDocument();

    // Switch scope to tool-wide
    await user.click(screen.getByLabelText("All calls to this tool (tool-wide)"));
    await user.click(screen.getByTestId("access-deny-submit"));

    await waitFor(() => {
      expect(
        recordedWrites(fetchMock).some(
          (recorded) =>
            recorded.method === "DELETE" && recorded.path === "/approvals/rules/rule-edit-1",
        ),
      ).toBe(true);
      const post = recordedWrites(fetchMock).find(
        (recorded) => recorded.method === "POST" && recorded.path === "/approvals/rules",
      );
      expect(post?.body).toMatchObject({
        toolName: "bash.exec",
        scope: { kind: "tool" },
        action: "allow",
      });
    });
  });

  it("surfaces error inside the edit modal when update fails", async () => {
    stubRoutes({
      rules: [
        seedRule({
          id: "rule-send-fail",
          toolName: "email.send",
          scope: { kind: "recipientSet", handles: ["a@x.com"] },
          effect: "allow",
        }),
      ],
      onWrite: (path, method) =>
        method === "POST" && path.endsWith("/rules")
          ? jsonResponse({ reason: "Cannot trust email without valid recipient." }, 400)
          : undefined,
    });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-rule-send-fail")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-rule-edit-rule-send-fail"));
    await user.click(screen.getByTestId("access-deny-submit"));

    await waitFor(() => {
      expect(screen.getByTestId("access-deny-error").textContent).toContain(
        "Cannot trust email without valid recipient.",
      );
    });
  });

  it("edits a rule duration and reason and displays reason in the table row", async () => {
    const fetchMock = stubRoutes({
      rules: [
        seedRule({
          id: "rule-dur",
          toolName: "web.fetch",
          scope: { kind: "exactTarget", target: "https://example.com" },
          effect: "allow",
          duration: "oneHour",
          reason: "Prior check reason",
        }),
      ],
    });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-rule-dur")).toBeInTheDocument();
    });
    expect(screen.getByTestId("access-rule-reason-rule-dur").textContent).toContain("Prior check reason");

    await user.click(screen.getByTestId("access-rule-edit-rule-dur"));

    // Check pre-populated reason input
    const reasonInput = screen.getByTestId("access-deny-reason") as HTMLInputElement;
    expect(reasonInput.value).toBe("Prior check reason");

    // Change duration to Next day
    await user.click(screen.getByLabelText("Next day"));
    await user.clear(reasonInput);
    await user.type(reasonInput, "Updated verification reason");
    await user.click(screen.getByTestId("access-deny-submit"));

    await waitFor(() => {
      expect(
        recordedWrites(fetchMock).some(
          (recorded) =>
            recorded.method === "DELETE" && recorded.path === "/approvals/rules/rule-dur",
        ),
      ).toBe(true);
      const post = recordedWrites(fetchMock).find(
        (recorded) => recorded.method === "POST" && recorded.path === "/approvals/rules",
      );
      expect(post?.body).toMatchObject({
        duration: "oneDay",
        reason: "Updated verification reason",
      });
    });
  });

  it("mints a deny rule with the tool, scope, reason, and forever tier", async () => {
    const fetchMock = stubRoutes({ rules: [] });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-add-rule-btn")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-add-rule-btn"));
    await waitFor(() => {
      expect(screen.getByTestId("access-deny-submit")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-rule-effect-deny"));
    await user.selectOptions(screen.getByTestId("access-rule-tool-select"), "email.send");
    await user.type(screen.getByTestId("access-deny-target"), "spam@evil.com");
    await user.type(screen.getByTestId("access-deny-reason"), "never send here");
    await user.click(screen.getByTestId("access-deny-submit"));

    await waitFor(() => {
      const create = recordedWrites(fetchMock).find(
        (recorded) => recorded.method === "POST" && recorded.path === "/approvals/rules",
      );
      expect(create?.body).toMatchObject({
        toolName: "email.send",
        action: "deny",
        scope: { kind: "exactTarget", target: "spam@evil.com" },
        duration: "forever",
        reason: "never send here",
      });
    });
  });

  it("preselects and highlights the rule named by the access deep link", async () => {
    window.location.hash = "#settings?access=rule-2";
    stubRoutes({
      rules: [
        seedRule({
          id: "rule-1",
          toolName: "web.fetch",
          scope: { kind: "exactTarget", target: "a" },
          effect: "allow",
        }),
        seedRule({
          id: "rule-2",
          toolName: "bash.exec",
          scope: { kind: "exactTarget", target: "b" },
          effect: "allow",
        }),
      ],
    });
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-rule-2")).toBeInTheDocument();
    });
    expect(screen.getByTestId("access-rule-row-rule-2").getAttribute("data-highlighted")).toBe(
      "true",
    );
    expect(screen.getByTestId("access-rule-row-rule-1").getAttribute("data-highlighted")).toBeNull();
  });

  it("refetches the rule list on the access_rules_changed frame", async () => {
    const fetchMock = stubRoutes({
      rules: [
        seedRule({
          id: "rule-a",
          toolName: "web.fetch",
          scope: { kind: "exactTarget", target: "a" },
          effect: "allow",
        }),
      ],
    });
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-rule-a")).toBeInTheDocument();
    });
    const readCount = () =>
      fetchMock.mock.calls.filter((call) => {
        const [input, init] = call as [string, RequestInit | undefined];
        return String(input) === "/approvals/rules" && (init?.method ?? "GET").toUpperCase() === "GET";
      }).length;
    const initialReads = readCount();

    await waitFor(() => {
      expect(socketCapture.onMessage).not.toBeNull();
    });
    await dispatchFrameOrThrow(socketCapture.onMessage, { type: "access_rules_changed" });

    await waitFor(() => {
      expect(readCount()).toBeGreaterThan(initialReads);
    });
  });

  it("mints an allow rule with tool dropdown, scope, and chosen duration", async () => {
    const fetchMock = stubRoutes({ rules: [] });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-add-rule-btn")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-add-rule-btn"));
    await waitFor(() => {
      expect(screen.getByTestId("access-rule-effect-allow")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("access-rule-effect-allow"));
    await user.selectOptions(screen.getByTestId("access-rule-tool-select"), "bash.exec");
    await user.type(screen.getByTestId("access-deny-target"), "git status");
    await user.click(screen.getByRole("radio", { name: "Next hour" }));
    await user.type(screen.getByTestId("access-deny-reason"), "allow git checks");
    await user.click(screen.getByTestId("access-deny-submit"));

    await waitFor(() => {
      const create = recordedWrites(fetchMock).find(
        (recorded) => recorded.method === "POST" && recorded.path === "/approvals/rules",
      );
      expect(create?.body).toMatchObject({
        toolName: "bash.exec",
        action: "allow",
        scope: { kind: "exactTarget", target: "git status" },
        duration: "oneHour",
        reason: "allow git checks",
      });
    });
  });

  it("filters rules table between All, Allow only, and Deny only", async () => {
    stubRoutes({
      rules: [
        seedRule({ id: "allow-1", toolName: "email.send", scope: { kind: "tool" }, effect: "allow" }),
        seedRule({ id: "deny-1", toolName: "bash.exec", scope: { kind: "tool" }, effect: "deny" }),
      ],
    });
    const user = userEvent.setup();
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-allow-1")).toBeInTheDocument();
      expect(screen.getByTestId("access-rule-row-deny-1")).toBeInTheDocument();
    });

    // Filter to Allow only
    await user.click(screen.getByTestId("access-filter-allow"));
    expect(screen.getByTestId("access-rule-row-allow-1")).toBeInTheDocument();
    expect(screen.queryByTestId("access-rule-row-deny-1")).toBeNull();

    // Filter to Deny only
    await user.click(screen.getByTestId("access-filter-deny"));
    expect(screen.queryByTestId("access-rule-row-allow-1")).toBeNull();
    expect(screen.getByTestId("access-rule-row-deny-1")).toBeInTheDocument();

    // Reset to All
    await user.click(screen.getByTestId("access-filter-all"));
    expect(screen.getByTestId("access-rule-row-allow-1")).toBeInTheDocument();
    expect(screen.getByTestId("access-rule-row-deny-1")).toBeInTheDocument();
  });

  it("mounts Network and Credentials views without internal duplicate tabs", async () => {
    stubRoutes({ rules: [] });
    const user = userEvent.setup();
    render(<AccessPane />);

    await user.click(screen.getByTestId("access-tab-network"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-network-section")).toBeInTheDocument();
    });
    // Internal duplicate policy-subtabs are omitted because top Access tab owns view switching
    expect(screen.queryByTestId("policy-subtabs")).toBeNull();

    await user.click(screen.getByTestId("access-tab-credentials"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-credentials-section")).toBeInTheDocument();
    });
    expect(screen.queryByTestId("policy-network-section")).toBeNull();
    expect(screen.queryByTestId("policy-subtabs")).toBeNull();
  });

  it("renders rules when server response provides action instead of effect", async () => {
    stubRoutes({
      rules: [
        {
          id: "server-allow-1",
          toolName: "email.send",
          scope: { kind: "exactTarget", target: "alice@example.com" },
          action: "allow",
          duration: "forever",
          grantedAt: nowIso(),
          expiresAt: null,
          useCount: 0,
          lastUsedAt: null,
        },
        {
          id: "server-deny-1",
          toolName: "bash.exec",
          scope: { kind: "tool" },
          action: "deny",
          grantedAt: nowIso(),
          expiresAt: null,
          useCount: 0,
          lastUsedAt: null,
        },
      ],
    });
    render(<AccessPane />);

    await waitFor(() => {
      expect(screen.getByTestId("access-rule-row-server-allow-1")).toBeInTheDocument();
      expect(screen.getByTestId("access-rule-row-server-deny-1")).toBeInTheDocument();
    });
    expect(screen.getByTestId("access-filter-all")).toHaveTextContent("All (2)");
    expect(screen.getByTestId("access-filter-allow")).toHaveTextContent("Allow (1)");
    expect(screen.getByTestId("access-filter-deny")).toHaveTextContent("Deny (1)");
    expect(screen.getAllByText("Forever").length).toBeGreaterThan(0);
  });
});
