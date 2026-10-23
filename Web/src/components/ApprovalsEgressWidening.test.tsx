// Rune Weaver Dashboard — Component tests for network egress domain widening across Inbox and Chat banner.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { PermissionRequest } from "../api";
import { jsonResponse } from "../test-utils/http";
import ApprovalsInbox from "./ApprovalsInbox";
import InlineApprovalBanner from "./InlineApprovalBanner";

function makeEgressRequest(overrides: Partial<PermissionRequest> = {}): PermissionRequest {
  return {
    id: "req-egress-widen",
    toolName: "api.request",
    description: "Send HTTP GET to api.example.com",
    input: {
      toolName: "api.request",
      argumentsJSON: '{"method":"GET","url":"https://api.example.com/v1"}',
      callID: "call-egress-widen",
    },
    suggestedDurations: [
      "thisTime",
      "forTask",
      "forSession",
      "fiveMinutes",
      "oneHour",
      "oneDay",
      "forever",
    ],
    egressHost: "api.example.com",
    ...overrides,
  };
}

describe("Network egress domain widening", () => {
  it("passes widened subdomain scope when Include subdomains is checked on InlineApprovalBanner", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    const request = makeEgressRequest({
      id: "app-egress-widen",
      egressHost: "api.example.com",
    });
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const checkbox = screen.getByRole("checkbox", {
      name: /Include subdomains \(\*\.example\.com\)/i,
    });
    await user.click(checkbox);
    await user.click(screen.getByRole("button", { name: "Allow Once" }));
    expect(onDecide).toHaveBeenCalledWith("app-egress-widen", true, "thisTime", {
      kind: "domain",
      host: "example.com",
      subdomains: true,
    });
  });

  it("widens an ApprovalsInbox egress card to *.baseDomain when Include subdomains is selected", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    const approval = makeEgressRequest();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const path = String(input);
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
          return jsonResponse({
            id: approval.id,
            approved: true,
            duration: "forever",
          });
        }
        if (path === "/sessions") {
          return jsonResponse({ sessions: [], count: 0 });
        }
        return jsonResponse({ approvals: [approval], count: 1 });
      }),
    );

    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("api.request")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-egress-widen");
    await user.click(
      within(card).getByRole("radio", {
        name: /Include subdomains \*\.example\.com/i,
      }),
    );
    await user.selectOptions(
      within(card).getByLabelText("Duration for api.request"),
      "forever",
    );
    await user.click(within(card).getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "forever",
      scope: { kind: "domain", host: "example.com", subdomains: true },
      surface: "inbox",
    });
  });

  it("sends no scope on deny even when Include subdomains is checked on InlineApprovalBanner", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    const request = makeEgressRequest({
      id: "app-egress-deny",
      egressHost: "api.example.com",
    });
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const checkbox = screen.getByRole("checkbox", {
      name: /Include subdomains \(\*\.example\.com\)/i,
    });
    await user.click(checkbox);
    await user.click(screen.getByRole("button", { name: "Deny" }));
    expect(onDecide).toHaveBeenCalledWith("app-egress-deny", false, "thisTime");
    expect(onDecide.mock.calls[0]).toHaveLength(3);
  });

  it("sends Deny always with no scope from the banner widening box", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    const request = makeEgressRequest({
      id: "app-egress-deny-always",
      egressHost: "api.example.com",
    });
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    await user.click(
      screen.getByRole("checkbox", {
        name: /Include subdomains \(\*\.example\.com\)/i,
      }),
    );
    const denyChevron = screen.getByRole("button", {
      name: "Deny options for api.request to api.example.com",
    });
    await user.click(denyChevron);
    await user.click(screen.getByRole("menuitem", { name: "Deny always" }));
    expect(onDecide).toHaveBeenCalledWith(
      "app-egress-deny-always",
      false,
      "forever",
    );
    expect(onDecide.mock.calls[0]).toHaveLength(3);
  });

  it("sends no scope on inbox deny when Include subdomains is selected", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    const approval = makeEgressRequest();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const path = String(input);
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
          return jsonResponse({
            id: approval.id,
            approved: false,
            duration: "forever",
          });
        }
        if (path === "/sessions") {
          return jsonResponse({ sessions: [], count: 0 });
        }
        return jsonResponse({ approvals: [approval], count: 1 });
      }),
    );

    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("api.request")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-egress-widen");
    await user.click(
      within(card).getByRole("radio", {
        name: /Include subdomains \*\.example\.com/i,
      }),
    );
    await user.selectOptions(
      within(card).getByLabelText("Duration for api.request"),
      "forever",
    );
    await user.click(within(card).getByRole("button", { name: "Deny" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    // Deny stays exact-host: no scope rides the refusal, so the engine
    // resolves the dialed host exactly.
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: false,
      duration: "forever",
      surface: "inbox",
    });
  });
});
