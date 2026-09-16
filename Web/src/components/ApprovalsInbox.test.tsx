// Rune Weaver Dashboard — Component tests for ApprovalsInbox listing and decisions.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ApprovalsInbox from "./ApprovalsInbox";
import { jsonResponse } from "../test-utils/http";

const pending = {
  approvals: [
    {
      id: "11111111-1111-1111-1111-111111111111",
      toolName: "email.send",
      description: "Send email",
      input: {
        toolName: "email.send",
        argumentsJSON: '{"to":"a@example.com"}',
        callID: "call-1",
      },
      suggestedDurations: ["thisTime", "oneHour"],
    },
  ],
  count: 1,
};

describe("ApprovalsInbox", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders pending approvals with allow and deny", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        // Active grants load alongside pending; keep this pending-only suite
        // deterministic by answering the grants endpoint as empty.
        if (typeof input === "string" && input.startsWith("/approvals/grants")) {
          return jsonResponse({ grants: [], count: 0 });
        }
        return jsonResponse(pending);
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    expect(
      screen.getByRole("button", { name: "Allow" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Deny" })).toBeInTheDocument();
    expect(screen.getByText("1 pending")).toBeInTheDocument();
  });

  it("allows with a duration and removes the row", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/approvals") {
          return jsonResponse(pending);
        }
        // Grants refetch after decide; answer empty without polluting the
        // decide-call assertions below.
        if (input.startsWith("/approvals/grants") && init?.method !== "DELETE") {
          return jsonResponse({ grants: [], count: 0 });
        }
        calls.push({ path: input, body: String(init?.body ?? "") });
        return jsonResponse({
          id: pending.approvals[0].id,
          approved: true,
          duration: "oneHour",
        });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.selectOptions(
      screen.getByLabelText("Duration for email.send"),
      "oneHour",
    );
    await user.click(screen.getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(calls[0].path).toContain("/decide");
    expect(JSON.parse(calls[0].body)).toMatchObject({
      approved: true,
      duration: "oneHour",
    });
  });

  it("denies a pending approval", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/approvals") {
          return jsonResponse(pending);
        }
        if (input.startsWith("/approvals/grants")) {
          return jsonResponse({ grants: [], count: 0 });
        }
        return jsonResponse({
          id: pending.approvals[0].id,
          approved: false,
          duration: "thisTime",
        });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Deny" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
  });

  it("displays Allowing & resuming spinner while decision is in flight", async () => {
    const user = userEvent.setup();
    let resolveDecide: ((value: Response) => void) | null = null;
    const decidePromise = new Promise<Response>((resolve) => {
      resolveDecide = resolve;
    });

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/approvals") {
          return jsonResponse(pending);
        }
        // Grants load must not hang on the held decision promise; answer
        // empty immediately so only the decide call stays in flight.
        if (input.startsWith("/approvals/grants") && init?.method !== "DELETE") {
          return jsonResponse({ grants: [], count: 0 });
        }
        return decidePromise;
      }),
    );

    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });

    await user.click(screen.getByRole("button", { name: "Allow" }));

    // While in flight, the "Allowing & resuming…" spinner label should appear
    expect(screen.getByText("Allowing & resuming…")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Allow" })).not.toBeInTheDocument();

    // Resolve the decision
    resolveDecide!(
      jsonResponse({
        id: pending.approvals[0].id,
        approved: true,
        duration: "thisTime",
      }),
    );

    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
  });

  it("shows active grants with scope plus revoke and expiry text", async () => {
    const future = new Date(Date.now() + 3600_000).toISOString();
    const now = new Date().toISOString();
    const grants = {
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
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (typeof input === "string" && input.startsWith("/approvals/grants")) {
          return jsonResponse(grants);
        }
        return jsonResponse({ approvals: [], count: 0 });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("2 active")).toBeInTheDocument();
    });
    // Timed grant names the tool plus its narrowed target so scope is explicit.
    expect(screen.getByText("email.send")).toBeInTheDocument();
    expect(
      screen.getByText("email sends to alice@example.com are approved"),
    ).toBeInTheDocument();
    // Timed expiry renders a countdown rather than a bare timestamp.
    expect(screen.getByText(/Expires/)).toBeInTheDocument();
    expect(screen.getByText("Next hour")).toBeInTheDocument();
    // Tool-wide forever grants name every target and never carry an expiry.
    expect(screen.getByText("file.write")).toBeInTheDocument();
    expect(
      screen.getByText("file writes to all targets are approved"),
    ).toBeInTheDocument();
    expect(screen.getByText("Never expires")).toBeInTheDocument();
    expect(screen.getByText("Forever")).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "Revoke" })).toHaveLength(2);
  });

  it("revokes an active grant and removes the card", async () => {
    const user = userEvent.setup();
    const grantId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    const future = new Date(Date.now() + 3600_000).toISOString();
    const now = new Date().toISOString();
    const seen: Array<{ path: string; method?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        seen.push({ path: input, method: init?.method });
        if (input === "/approvals" && !init?.method) {
          return jsonResponse({ approvals: [], count: 0 });
        }
        if (input === `/approvals/grants/${grantId}` && init?.method === "DELETE") {
          return new Response(null, { status: 204 });
        }
        if (typeof input === "string" && input.startsWith("/approvals/grants")) {
          return jsonResponse({
            grants: [
              {
                id: grantId,
                toolName: "email.send",
                target: "alice@example.com",
                grantedAt: now,
                expiresAt: future,
                duration: "oneHour",
              },
            ],
            count: 1,
          });
        }
        return jsonResponse({ approvals: [], count: 0 });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(
        screen.getByText("email sends to alice@example.com are approved"),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Revoke" }));
    await waitFor(() => {
      expect(screen.getByText("No active approvals.")).toBeInTheDocument();
    });
    expect(
      seen.some(
        (entry) => entry.path === `/approvals/grants/${grantId}` && entry.method === "DELETE",
      ),
    ).toBe(true);
    expect(screen.getByText("0 active")).toBeInTheDocument();
  });

  it("keeps one-time approvals out of the active list", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/approvals" && !init?.method) {
          return jsonResponse(pending);
        }
        // Duration decisions would mint a grant server-side, but a one-time
        // decision records nothing, so every grants refetch stays empty.
        if (input.startsWith("/approvals/grants") && init?.method !== "DELETE") {
          return jsonResponse({ grants: [], count: 0 });
        }
        calls.push({ path: input, body: String(init?.body ?? "") });
        return jsonResponse({
          id: pending.approvals[0].id,
          approved: true,
          duration: "thisTime",
        });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toMatchObject({
      approved: true,
      duration: "thisTime",
    });
    // No grant row appears for the one-time tier.
    expect(screen.getByText("No active approvals.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Revoke" })).not.toBeInTheDocument();
    expect(screen.getByText("0 active")).toBeInTheDocument();
  });

  it("hides clock-expired grants without a refetch", async () => {
    const past = new Date(Date.now() - 60_000).toISOString();
    const future = new Date(Date.now() + 3600_000).toISOString();
    const now = new Date().toISOString();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (typeof input === "string" && input.startsWith("/approvals/grants")) {
          return jsonResponse({
            grants: [
              {
                id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
                toolName: "email.send",
                target: "stale@example.com",
                grantedAt: past,
                expiresAt: past,
                duration: "fiveMinutes",
              },
              {
                id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
                toolName: "email.send",
                target: "fresh@example.com",
                grantedAt: now,
                expiresAt: future,
                duration: "oneHour",
              },
            ],
            count: 2,
          });
        }
        return jsonResponse({ approvals: [], count: 0 });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("1 active")).toBeInTheDocument();
    });
    // Lapsed scope hides locally even though the payload still carries it,
    // so skew between server expiry and the next poll never lingers.
    expect(
      screen.queryByText("email sends to stale@example.com are approved"),
    ).not.toBeInTheDocument();
    expect(
      screen.getByText("email sends to fresh@example.com are approved"),
    ).toBeInTheDocument();
  });

  it("locks only the revoking row while a revoke is in flight", async () => {
    const user = userEvent.setup();
    const firstId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    const secondId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    const future = new Date(Date.now() + 3600_000).toISOString();
    const now = new Date().toISOString();
    let resolveRevoke: ((value: Response) => void) | null = null;
    const revokePromise = new Promise<Response>((resolve) => {
      resolveRevoke = resolve;
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === `/approvals/grants/${firstId}` && init?.method === "DELETE") {
          return revokePromise;
        }
        if (typeof input === "string" && input.startsWith("/approvals/grants")) {
          return jsonResponse({
            grants: [
              {
                id: firstId,
                toolName: "email.send",
                target: "alice@example.com",
                grantedAt: now,
                expiresAt: future,
                duration: "oneHour",
              },
              {
                id: secondId,
                toolName: "file.write",
                target: "",
                grantedAt: now,
                expiresAt: null,
                duration: "forever",
              },
            ],
            count: 2,
          });
        }
        return jsonResponse({ approvals: [], count: 0 });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("2 active")).toBeInTheDocument();
    });
    const revokeButtons = screen.getAllByRole("button", { name: "Revoke" });
    await user.click(revokeButtons[0]);
    // The in-flight row reports progress while the sibling stays actionable,
    // so a slow revoke cannot freeze independent grants.
    expect(screen.getByText("Revoking…")).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "Revoke" })).toHaveLength(1);
    resolveRevoke!(new Response(null, { status: 204 }));
    await waitFor(() => {
      expect(screen.getByText("1 active")).toBeInTheDocument();
    });
    expect(
      screen.queryByText("email sends to alice@example.com are approved"),
    ).not.toBeInTheDocument();
    expect(
      screen.getByText("file writes to all targets are approved"),
    ).toBeInTheDocument();
  });
});

