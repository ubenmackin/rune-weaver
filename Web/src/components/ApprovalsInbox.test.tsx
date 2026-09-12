// Rune Weaver Dashboard — Component tests for ApprovalsInbox listing and decisions.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ApprovalsInbox from "./ApprovalsInbox";

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
      vi.fn(async () =>
        new Response(JSON.stringify(pending), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      ),
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
          return new Response(JSON.stringify(pending), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        calls.push({ path: input, body: String(init?.body ?? "") });
        return new Response(
          JSON.stringify({
            id: pending.approvals[0].id,
            approved: true,
            duration: "oneHour",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
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
          return new Response(JSON.stringify(pending), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(
          JSON.stringify({
            id: pending.approvals[0].id,
            approved: false,
            duration: "thisTime",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
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
});
