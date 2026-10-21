// Rune Weaver Dashboard — Tests for the ephemeral session-trust chip.

import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import EphemeralTrustChip from "./EphemeralTrustChip";
import { resetSharedSocket } from "../hooks/useSharedWebSocket";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
} from "../test-utils/mockWebSocket";

const SESSION_ID = "sess-trust-1";
const TRUST_PATH = "/approvals/session-trust";
const CLEAR_PATH = "/approvals/ephemeral/clear";

// Wire grant payloads mirror the engine session-trust response: a tool, a
// scope, a tier, and clock fields the chip does not render.
function grant(
  toolName: string,
  scope: Record<string, unknown>,
  duration: string,
): Record<string, unknown> {
  return {
    toolName,
    scope,
    duration,
    grantedAt: "2026-01-01T00:00:00Z",
    expiresAt: null,
    useCount: 0,
    lastUsedAt: null,
  };
}

interface ClearCall {
  sessionID: string;
  toolName: string;
  scope: Record<string, unknown>;
}

interface TrustStub {
  // Successful scoped clears, in order.
  clearCalls: ClearCall[];
  // Every session-trust read path, in order.
  trustCalls: () => string[];
  // Every clear attempt, including refused ones.
  clearAttempts: () => string[];
}

// Stubs the engine so the GET serves a mutable live list and a successful POST
// removes exactly the posted grant from it, which is how the chip's post-revoke
// refetch proves the clear landed.
function installTrustStub(
  initial: Array<Record<string, unknown>>,
  options: { clearStatus?: number } = {},
): TrustStub {
  const live = [...initial];
  const clearCalls: ClearCall[] = [];
  const fetchMock = vi.fn(async (input: unknown, init?: RequestInit) => {
    const path = String(input);
    if (init?.method === "POST" && path === CLEAR_PATH) {
      const status = options.clearStatus ?? 204;
      if (status >= 400) {
        return new Response("nope", { status });
      }
      const body = JSON.parse(String(init.body)) as ClearCall;
      clearCalls.push(body);
      const index = live.findIndex(
        (entry) =>
          entry.toolName === body.toolName &&
          JSON.stringify(entry.scope) === JSON.stringify(body.scope),
      );
      if (index >= 0) live.splice(index, 1);
      return new Response(null, { status });
    }
    if (path.startsWith(TRUST_PATH)) {
      return jsonResponse({
        sessionID: SESSION_ID,
        grants: live,
        count: live.length,
      });
    }
    throw new Error(`Unexpected fetch URL: ${path}`);
  });
  vi.stubGlobal("fetch", fetchMock);
  return {
    clearCalls,
    trustCalls: () =>
      fetchMock.mock.calls
        .map((call) => String(call[0]))
        .filter((path) => path.startsWith(TRUST_PATH)),
    clearAttempts: () =>
      fetchMock.mock.calls
        .filter((call) => String(call[0]) === CLEAR_PATH)
        .map((call) => String(call[0])),
  };
}

// Trust lines in rendered order, read from the line spans so the revoke button
// text never pollutes the assertion.
function trustLines(container: HTMLElement): string[] {
  return Array.from(
    container.querySelectorAll<HTMLElement>(".ephemeral-trust-line"),
  ).map((node) => node.textContent ?? "");
}

describe("EphemeralTrustChip", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    vi.useRealTimers();
    resetSharedSocket();
  });

  it("renders one compact line per live trust across the ephemeral kinds", async () => {
    const stub = installTrustStub([
      grant("email.send", { kind: "exactTarget", target: "bob@x.com" }, "forTask"),
      grant(
        "email.send",
        { kind: "exactTarget", target: "alice@x.com" },
        "forSession",
      ),
      grant(
        "messages.send",
        { kind: "recipientSet", handles: ["bob@x.com"] },
        "forSession",
      ),
      grant(
        "messages.send",
        { kind: "recipientSet", handles: ["a@x.com", "b@x.com", "c@x.com"] },
        "forSession",
      ),
      grant(
        "api.request",
        { kind: "domain", host: "api.example.com" },
        "forSession",
      ),
      grant("files.write", { kind: "tool" }, "forSession"),
    ]);
    const { container } = render(
      <EphemeralTrustChip sessionID={SESSION_ID} />,
    );

    await waitFor(() => {
      expect(screen.getByTestId("ephemeral-trust-chip")).toBeInTheDocument();
    });
    // Gate task grants, gate session grants, and the egress supervisor's
    // domain allowances read by lifetime alone: the chip never claims a
    // provenance the payload does not carry.
    expect(trustLines(container)).toEqual([
      "email.send to bob@x.com (rest of this task)",
      "email.send to alice@x.com (rest of this session)",
      "messages.send to bob@x.com (rest of this session)",
      "messages.send to 3 recipients (rest of this session)",
      "api.request to api.example.com (rest of this session)",
      "files.write to all targets (rest of this session)",
    ]);
    // Every line carries its own revoke; no chip-level or bulk control exists.
    expect(screen.getAllByRole("button", { name: "Revoke" })).toHaveLength(6);
    expect(stub.trustCalls()[0]).toBe(`${TRUST_PATH}?sessionID=${SESSION_ID}`);
  });

  it("renders nothing when the session holds no ephemeral trust", async () => {
    installTrustStub([]);
    const { container } = render(
      <EphemeralTrustChip sessionID={SESSION_ID} />,
    );

    // Drain the empty read first so the assertion covers the settled
    // response, not the pre-response mount.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(trustLines(container)).toHaveLength(0);
    expect(
      screen.queryByTestId("ephemeral-trust-chip"),
    ).not.toBeInTheDocument();
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing without a selected session and reads no trust", () => {
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    const { container } = render(<EphemeralTrustChip sessionID={null} />);

    expect(container).toBeEmptyDOMElement();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("revoke posts the scoped clear and refetches to confirm the line cleared", async () => {
    const stub = installTrustStub([
      grant(
        "email.send",
        { kind: "exactTarget", target: "bob@x.com" },
        "forSession",
      ),
      grant(
        "api.request",
        { kind: "domain", host: "api.example.com" },
        "forSession",
      ),
    ]);
    const { container } = render(
      <EphemeralTrustChip sessionID={SESSION_ID} />,
    );

    await waitFor(() => {
      expect(screen.getAllByTestId("ephemeral-trust-row")).toHaveLength(2);
    });
    // The revoke targets the email row only: the clear names the owning
    // session, the tool, and the scope of exactly that trust.
    const emailRow = screen
      .getAllByTestId("ephemeral-trust-row")
      .find((row) => row.textContent?.includes("email.send")) as HTMLElement;
    fireEvent.click(emailRow.querySelector("button") as HTMLButtonElement);

    await waitFor(() => {
      expect(stub.clearCalls).toHaveLength(1);
    });
    expect(stub.clearCalls[0]).toEqual({
      sessionID: SESSION_ID,
      toolName: "email.send",
      scope: { kind: "exactTarget", target: "bob@x.com" },
    });
    // The refetch is the confirmation: the cleared line is gone and the
    // sibling trust survives untouched.
    await waitFor(() => {
      expect(screen.getAllByTestId("ephemeral-trust-row")).toHaveLength(1);
    });
    expect(trustLines(container)).toEqual([
      "api.request to api.example.com (rest of this session)",
    ]);
    expect(stub.trustCalls().length).toBeGreaterThanOrEqual(2);
  });

  it("keeps the row when the scoped clear fails", async () => {
    const stub = installTrustStub(
      [
        grant(
          "email.send",
          { kind: "exactTarget", target: "bob@x.com" },
          "forSession",
        ),
      ],
      { clearStatus: 500 },
    );
    const { container } = render(
      <EphemeralTrustChip sessionID={SESSION_ID} />,
    );

    await waitFor(() => {
      expect(screen.getByTestId("ephemeral-trust-row")).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("button", { name: "Revoke" }));

    await waitFor(() => {
      expect(stub.clearAttempts()).toHaveLength(1);
    });
    // A refused clear must not read as revoked trust: the line stays until a
    // probe proves otherwise, and the row unlocks for a retry.
    expect(trustLines(container)).toEqual([
      "email.send to bob@x.com (rest of this session)",
    ]);
    expect(screen.getByRole("button", { name: "Revoke" })).not.toBeDisabled();
  });

  it("refetches on the poll cadence while the session holds the chip", async () => {
    // Fake timers keep the cadence assertion honest without a real 30s wait;
    // the async advance drains the fetch chain the way a live browser would.
    vi.useFakeTimers();
    const stub = installTrustStub([
      grant(
        "email.send",
        { kind: "exactTarget", target: "bob@x.com" },
        "forSession",
      ),
    ]);
    render(<EphemeralTrustChip sessionID={SESSION_ID} />);

    // Flush the mount read before the cadence is exercised. The fetch fires
    // synchronously from the effect, but the row still needs the response
    // chain drained before it can assert on the DOM.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.getByTestId("ephemeral-trust-row")).toBeInTheDocument();
    expect(stub.trustCalls()).toHaveLength(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(stub.trustCalls()).toHaveLength(2);
  });

  it("refetches on trust-relevant frames and ignores the rest", async () => {
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    const stub = installTrustStub([
      grant(
        "email.send",
        { kind: "exactTarget", target: "bob@x.com" },
        "forSession",
      ),
    ]);
    render(<EphemeralTrustChip sessionID={SESSION_ID} />);

    await waitFor(() => {
      expect(screen.getByTestId("ephemeral-trust-row")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    expect(stub.trustCalls()).toHaveLength(1);

    // A decided approval for this session can mint session trust, so the chip
    // re-reads.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval_decided",
      sessionID: SESSION_ID,
      id: "req-1",
      approved: true,
    });
    await waitFor(() => {
      expect(stub.trustCalls()).toHaveLength(2);
    });

    // The untagged rules-change broadcast always refreshes.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "access_rules_changed",
    });
    await waitFor(() => {
      expect(stub.trustCalls()).toHaveLength(3);
    });

    // A frame owned by another conversation cannot move this session's trust,
    // and neither can an unrelated frame kind.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval_decided",
      sessionID: "other-session",
      id: "req-2",
      approved: true,
    });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "turn_alive",
      sessionID: SESSION_ID,
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(stub.trustCalls()).toHaveLength(3);
  });
});
