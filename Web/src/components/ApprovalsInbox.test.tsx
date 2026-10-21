// Rune Weaver Dashboard — Component tests for ApprovalsInbox grouping,
// ordering, per-card decisions, and the dedicated brake branch.

import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ApprovalsInbox from "./ApprovalsInbox";
import { jsonResponse } from "../test-utils/http";
import { isRecord } from "../typeGuards";

interface StubOptions {
  approvals?: unknown[];
  sessions?: Array<{ id: string; title: string }>;
  onCall?: (path: string, init?: RequestInit) => void;
  // Short-circuits the default response so a test can hold one decision in
  // flight without holding the reads.
  respond?: (
    path: string,
    init?: RequestInit,
  ) => Response | Promise<Response> | null;
}

// Answers the two reads the inbox makes (pending approvals plus session
// titles) and records every call so decision payloads stay assertable.
function stubEngine(options: StubOptions = {}) {
  const approvals = options.approvals ?? [];
  const sessions = options.sessions ?? [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string, init?: RequestInit) => {
      const path = String(input);
      options.onCall?.(path, init);
      const override = options.respond?.(path, init);
      if (override != null) return override;
      if (init?.method === "POST" && path.includes("/decide")) {
        return jsonResponse({
          id: path.split("/")[2],
          approved: true,
          duration: "thisTime",
        });
      }
      if (init?.method === "POST" && path.includes("/respond")) {
        return jsonResponse({
          id: path.split("/")[2],
          approved: true,
          duration: "thisTime",
        });
      }
      if (path === "/sessions") {
        return jsonResponse({ sessions, count: sessions.length });
      }
      return jsonResponse({ approvals, count: approvals.length });
    }),
  );
}

function pendingRequest(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  const toolName =
    (typeof overrides.toolName === "string" && overrides.toolName) ||
    (isRecord(overrides.input) &&
      typeof overrides.input.toolName === "string" &&
      overrides.input.toolName) ||
    "email.send";
  return {
    id: "req-1",
    description: "Send email",
    input: {
      toolName,
      argumentsJSON: '{"to":"a@example.com"}',
      callID: "call-1",
    },
    suggestedDurations: ["thisTime", "oneHour"],
    ...overrides,
    toolName,
  };
}

// Group headers in rendered order.
function groupTitles(container: HTMLElement): string[] {
  return Array.from(
    container.querySelectorAll<HTMLElement>(".approvals-group-header"),
  ).map((node) => node.textContent ?? "");
}

// Approval card ids in rendered order; question cards carry their own test id
// and stay out of this list.
function cardIDs(container: HTMLElement): string[] {
  return Array.from(
    container.querySelectorAll<HTMLElement>(
      '[data-testid^="approval-card-"]',
    ),
  ).map((node) => node.getAttribute("data-testid")?.replace("approval-card-", "") ?? "");
}

describe("ApprovalsInbox", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders pending approvals with allow, deny, and the standing-rules deep link", async () => {
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: "Allow" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Deny" })).toBeInTheDocument();
    expect(screen.getByText("1 pending")).toBeInTheDocument();
    // Standing rules live in Settings → Access, so the inbox links there
    // instead of managing grants itself.
    const link = screen.getByRole("link", { name: "Manage standing rules" });
    expect(link).toHaveAttribute("href", "#settings?access=rules");
  });

  it("groups cards under session titles from GET /sessions ordered by maximum severity", async () => {
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-danger",
          toolName: "desktop.action",
          sessionID: "SESS-CHAT",
          assessment: { severity: "dangerous", outcome: "Clicks", warnings: [] },
          input: {
            toolName: "desktop.action",
            argumentsJSON: '{"action":"click"}',
            callID: "call-danger",
          },
        }),
        pendingRequest({
          id: "req-moderate",
          toolName: "files.write",
          sessionID: "sess-ops",
          assessment: { severity: "moderate", outcome: "Writes", warnings: [] },
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/notes.txt"}',
            callID: "call-moderate",
          },
        }),
        pendingRequest({
          id: "req-safe",
          assessment: { severity: "safe", outcome: "Reads", warnings: [] },
          input: {
            toolName: "email.send",
            argumentsJSON: '{"to":"safe@example.com"}',
            callID: "call-safe",
          },
        }),
      ],
      sessions: [
        { id: "sess-chat", title: "Deploy chat" },
        { id: "SESS-OPS", title: "Ops chat" },
      ],
    });
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("desktop.action")).toBeInTheDocument();
    });
    // Dangerous group first, then moderate, then the unattributed safe card.
    // Session identifiers compare case-insensitively against GET /sessions.
    expect(groupTitles(container)).toEqual([
      "Deploy chat",
      "Ops chat",
      "Unattributed",
    ]);
    // Every group header is sticky and no group is collapsed.
    const headers = container.querySelectorAll(".approvals-group-header");
    expect(headers).toHaveLength(3);
    for (const header of Array.from(headers)) {
      expect(header.tagName).toBe("H3");
    }
    expect(cardIDs(container)).toEqual([
      "req-danger",
      "req-moderate",
      "req-safe",
    ]);
  });

  it("renders engine-filed system notices under a System header with no decision controls", async () => {
    stubEngine({
      approvals: [
        pendingRequest({
          id: "notice-1",
          toolName: "sovereign.mismatch",
          description: "Sovereign ceremony could not verify history.",
          input: {
            toolName: "sovereign.mismatch",
            argumentsJSON: "{}",
            callID: "call-notice",
          },
        }),
        pendingRequest({ id: "req-plain" }),
      ],
    });
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByTestId("system-notice-notice-1")).toBeInTheDocument();
    });
    // The notice groups under its own System header, not Unattributed.
    const systemGroup = container.querySelector(
      '[data-testid="approvals-group-__system__"]',
    );
    expect(systemGroup).not.toBeNull();
    expect(
      within(systemGroup as HTMLElement).getByText("System"),
    ).toBeInTheDocument();
    expect(
      within(systemGroup as HTMLElement).getByTestId("system-notice-chip-notice-1"),
    ).toBeInTheDocument();
    // Surfacing-only: the whole action is the mapped remedy, so no allow,
    // deny, duration, or scope control rides the notice card.
    expect(
      within(systemGroup as HTMLElement).getByRole("button", {
        name: "Re-baseline & re-verify",
      }),
    ).toBeInTheDocument();
    expect(
      within(systemGroup as HTMLElement).queryByRole("button", { name: "Allow" }),
    ).toBeNull();
    expect(
      within(systemGroup as HTMLElement).queryByRole("button", { name: "Deny" }),
    ).toBeNull();
    expect(
      within(systemGroup as HTMLElement).queryByRole("combobox"),
    ).toBeNull();
    expect(
      within(systemGroup as HTMLElement).queryByRole("radio"),
    ).toBeNull();
    // The ordinary approval still renders its decision controls beside the notice.
    expect(screen.getByRole("button", { name: "Allow" })).toBeInTheDocument();
  });

  it("orders cards within a group by severity then filing time descending", async () => {
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-danger-first",
          assessment: { severity: "dangerous", outcome: "Clicks", warnings: [] },
          input: {
            toolName: "desktop.action",
            argumentsJSON: '{"action":"click"}',
            callID: "call-a",
          },
        }),
        pendingRequest({
          id: "req-moderate-early",
          assessment: { severity: "moderate", outcome: "Writes", warnings: [] },
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/a.txt"}',
            callID: "call-b",
          },
        }),
        pendingRequest({
          id: "req-moderate-late",
          assessment: { severity: "moderate", outcome: "Writes", warnings: [] },
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/b.txt"}',
            callID: "call-c",
          },
        }),
        pendingRequest({
          id: "req-safe-last",
          assessment: { severity: "safe", outcome: "Reads", warnings: [] },
          input: {
            toolName: "email.send",
            argumentsJSON: '{"to":"late@example.com"}',
            callID: "call-d",
          },
        }),
      ],
      sessions: [{ id: "sess-chat", title: "Deploy chat" }],
    });
    // The wire carries no filing timestamp, so payload position is the filing
    // order: the later moderate card is the more recent filing and reads first.
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("desktop.action")).toBeInTheDocument();
    });
    expect(cardIDs(container)).toEqual([
      "req-danger-first",
      "req-moderate-late",
      "req-moderate-early",
      "req-safe-last",
    ]);
  });

  it("falls back to the raw session id when GET /sessions carries no title", async () => {
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-untitled",
          sessionID: "SESS-RAW",
          assessment: { severity: "moderate", outcome: "Writes", warnings: [] },
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/raw.txt"}',
            callID: "call-raw",
          },
        }),
        pendingRequest({
          id: "req-orphan",
          sessionID: null,
          assessment: { severity: "safe", outcome: "Reads", warnings: [] },
          input: {
            toolName: "email.send",
            argumentsJSON: '{"to":"orphan@example.com"}',
            callID: "call-orphan",
          },
        }),
      ],
      sessions: [{ id: "sess-other", title: "Other chat" }],
    });
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("SESS-RAW")).toBeInTheDocument();
    });
    expect(groupTitles(container)).toEqual(["SESS-RAW", "Unattributed"]);
    expect(cardIDs(container)).toEqual(["req-untitled", "req-orphan"]);
  });

  it("orders a nil assessment as moderate", async () => {
    stubEngine({
      approvals: [
        pendingRequest({ id: "req-nil", assessment: null }),
        pendingRequest({
          id: "req-dangerous",
          assessment: { severity: "dangerous", outcome: "Clicks", warnings: [] },
          input: {
            toolName: "desktop.action",
            argumentsJSON: '{"action":"click"}',
            callID: "call-dangerous",
          },
        }),
        pendingRequest({
          id: "req-safe",
          assessment: { severity: "safe", outcome: "Reads", warnings: [] },
          input: {
            toolName: "email.send",
            argumentsJSON: '{"to":"safe@example.com"}',
            callID: "call-safe",
          },
        }),
      ],
      sessions: [{ id: "sess-chat", title: "Deploy chat" }],
    });
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("desktop.action")).toBeInTheDocument();
    });
    // The unassessed card outranks the valued safe one but never the valued
    // dangerous one, so enrichment cannot reorder the queue under the owner.
    expect(cardIDs(container)).toEqual([
      "req-dangerous",
      "req-nil",
      "req-safe",
    ]);
  });

  it("renders no collapsed group, no group-level control, and no bulk approve", async () => {
    stubEngine({
      approvals: [
        pendingRequest({ id: "req-one", sessionID: "sess-a" }),
        pendingRequest({
          id: "req-two",
          sessionID: "sess-a",
          toolName: "files.write",
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/a.txt"}',
            callID: "call-two",
          },
        }),
        pendingRequest({ id: "req-three", sessionID: "sess-b" }),
      ],
      sessions: [
        { id: "sess-a", title: "Alpha" },
        { id: "sess-b", title: "Beta" },
      ],
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("Alpha")).toBeInTheDocument();
    });
    // No group-level or bulk control exists anywhere on the surface.
    expect(
      screen.queryByRole("button", {
        name: /approve all|allow all|deny all|bulk|collapse|expand|select all/i,
      }),
    ).toBeNull();
    // Every card renders its own controls with nothing hidden behind a
    // disclosure: three cards mean three Allow and three Deny buttons.
    expect(screen.getAllByRole("button", { name: "Allow" })).toHaveLength(3);
    expect(screen.getAllByRole("button", { name: "Deny" })).toHaveLength(3);
  });

  it("carries zero grant-management UI", async () => {
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    // Grant management moved to Settings → Access: no active-grants section,
    // widen, revoke, or duration re-arm control survives on this surface.
    expect(screen.queryByText("Active approvals")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Widen to all targets/ }),
    ).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Revoke" })).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Change duration" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Allow for all targets/ }),
    ).not.toBeInTheDocument();
  });

  it("sends the unified payload with the one-shot default and no scope for this target", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [pendingRequest()],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].path).toContain("/decide");
    // The scope stays omitted so the engine resolves the request's own
    // target, the one-shot tier stores nothing, and the surface tag names
    // the inbox card as the deciding origin.
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "thisTime",
      surface: "inbox",
    });
  });

  it("sends the tool-wide scope when All targets is chosen", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [pendingRequest()],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("radio", { name: "All targets" }));
    await user.click(screen.getByRole("button", { name: "Deny" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: false,
      duration: "thisTime",
      scope: { kind: "tool" },
      surface: "inbox",
    });
  });

  it("renders no Edit scope button on any card", async () => {
    stubEngine({
      approvals: [
        pendingRequest({ id: "req-one" }),
        pendingRequest({
          id: "req-egress-no-edit",
          toolName: "api.request",
          egressHost: "api.example.com",
          input: {
            toolName: "api.request",
            argumentsJSON: '{"method":"GET","url":"https://api.example.com/v1"}',
            callID: "call-egress-no-edit",
          },
        }),
      ],
    });
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    // The Custom scope radio opens the editor on select, so no separate
    // ghost button survives on any card.
    expect(
      screen.queryByRole("button", { name: "Edit scope" }),
    ).toBeNull();
    for (const card of Array.from(
      container.querySelectorAll('[data-testid^="approval-card-"]'),
    )) {
      expect(
        within(card as HTMLElement).queryByRole("button", {
          name: "Edit scope",
        }),
      ).toBeNull();
    }
  });

  it("renders the engine-derived target truncated at 80 chars with full title", async () => {
    const longTarget = `file-${"a".repeat(100)}.txt`;
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-derived",
          toolName: "files.read",
          displayTarget: "short-target.txt",
          input: {
            toolName: "files.read",
            argumentsJSON: '{"path":"/other.txt"}',
            callID: "call-derived",
          },
        }),
        pendingRequest({
          id: "req-long",
          toolName: "files.read",
          displayTarget: longTarget,
          input: {
            toolName: "files.read",
            argumentsJSON: '{"path":"/other.txt"}',
            callID: "call-long",
          },
        }),
      ],
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByTestId("approval-card-req-derived")).toBeInTheDocument();
    });
    // The stored displayTarget wins over the arguments fallback.
    const shortCode = within(
      screen.getByTestId("approval-card-req-derived"),
    ).getByText("short-target.txt");
    expect(shortCode).toHaveClass("approval-scope-target");
    expect(shortCode).toHaveAttribute("title", "short-target.txt");
    // Longer values cut at 80 chars with an ellipsis while the title keeps
    // the full value for hover.
    const longCode = screen
      .getByTestId("approval-card-req-long")
      .querySelector(".approval-scope-target");
    expect(longCode).not.toBeNull();
    expect(longCode).toHaveTextContent(`${longTarget.slice(0, 80)}…`);
    expect(longCode).toHaveAttribute("title", longTarget);
  });

  it("opens the scope editor when Custom scope is selected", async () => {
    const user = userEvent.setup();
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    expect(
      screen.queryByRole("dialog", { name: "Edit decision scope" }),
    ).not.toBeInTheDocument();
    await user.click(screen.getByRole("radio", { name: "Custom scope" }));
    await waitFor(() => {
      expect(
        screen.getByRole("dialog", { name: "Edit decision scope" }),
      ).toBeInTheDocument();
    });
  });

  it("reopens the scope editor from the checked Custom radio after a cancel", async () => {
    const user = userEvent.setup();
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("radio", { name: "Custom scope" }));
    const dialog = () =>
      screen.queryByRole("dialog", { name: "Edit decision scope" });
    await waitFor(() => {
      expect(dialog()).not.toBeNull();
    });
    // Cancelling stages nothing, so the card stays on Custom with no scope.
    await user.click(
      within(screen.getByRole("dialog", { name: "Edit decision scope" })).getByRole(
        "button",
        { name: "Cancel" },
      ),
    );
    await waitFor(() => {
      expect(dialog()).toBeNull();
    });
    expect(screen.getByRole("radio", { name: "Custom scope" })).toBeChecked();
    expect(screen.getByRole("button", { name: "Allow" })).toBeDisabled();
    // The already-checked radio fires no onChange on a re-click, so the
    // click handler itself must reopen the editor or Custom could never be
    // described after a cancel.
    await user.click(screen.getByRole("radio", { name: "Custom scope" }));
    await waitFor(() => {
      expect(dialog()).not.toBeNull();
    });
  });

  it("pins the disabled decision tooltip to the Custom scope radio after a cancel", async () => {
    const user = userEvent.setup();
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("radio", { name: "Custom scope" }));
    await user.click(
      within(
        screen.getByRole("dialog", { name: "Edit decision scope" }),
      ).getByRole("button", { name: "Cancel" }),
    );
    await waitFor(() => {
      expect(
        screen.queryByRole("dialog", { name: "Edit decision scope" }),
      ).not.toBeInTheDocument();
    });
    // Custom is selected with nothing staged, so both decisions stay locked
    // and the tooltip points at the Custom scope radio, the sole entry point.
    const expected =
      "Pick a custom scope first. Select the Custom scope radio to open the editor.";
    expect(screen.getByRole("button", { name: "Allow" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Allow" })).toHaveAttribute(
      "title",
      expected,
    );
    expect(screen.getByRole("button", { name: "Deny" })).toHaveAttribute(
      "title",
      expected,
    );
  });

  it("ships the edited recipient set from the scope editor", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          toolName: "messages.send",
          input: {
            toolName: "messages.send",
            argumentsJSON: '{"recipient":"+15551234567"}',
            callID: "call-send",
          },
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("messages.send")).toBeInTheDocument();
    });
    // Picking custom opens the editor immediately so a half-described scope
    // can never reach a decision.
    await user.click(screen.getByRole("radio", { name: "Custom scope" }));
    const dialog = screen.getByRole("dialog", { name: "Edit decision scope" });
    const editor = within(dialog).getByLabelText("Recipients");
    // The editor prefills with the request's own recipient.
    expect(editor).toHaveValue("+15551234567");
    fireEvent.change(editor, {
      target: { value: "+15551234567\nops@example.com" },
    });
    await user.click(within(dialog).getByRole("button", { name: "Save scope" }));
    await waitFor(() => {
      expect(
        screen.queryByRole("dialog", { name: "Edit decision scope" }),
      ).not.toBeInTheDocument();
    });
    // The card names the staged scope so the owner sees what will ship.
    expect(screen.getByText("2 recipients")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "thisTime",
      scope: {
        kind: "recipientSet",
        handles: ["+15551234567", "ops@example.com"],
      },
      surface: "inbox",
    });
  });

  it("derives an edited domain scope from the hosts editor on an egress card", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-egress-edit",
          toolName: "api.request",
          egressHost: "api.example.com",
          input: {
            toolName: "api.request",
            argumentsJSON: '{"method":"GET","url":"https://api.example.com/v1"}',
            callID: "call-egress-edit",
          },
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("api.request")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-egress-edit");
    await user.click(within(card).getByRole("radio", { name: "Custom scope" }));
    const dialog = screen.getByRole("dialog", { name: "Edit decision scope" });
    const editor = within(dialog).getByLabelText("Hosts / domains");
    // The editor opens on the parked host, and the owner narrows or moves the
    // rule to the host they actually mean.
    expect(editor).toHaveValue("api.example.com");
    fireEvent.change(editor, { target: { value: "cdn.example.com" } });
    await user.click(within(dialog).getByRole("button", { name: "Save scope" }));
    await waitFor(() => {
      expect(
        screen.queryByRole("dialog", { name: "Edit decision scope" }),
      ).not.toBeInTheDocument();
    });
    await user.click(within(card).getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "thisTime",
      scope: { kind: "domain", host: "cdn.example.com" },
      surface: "inbox",
    });
  });

  it("collapses a paths list onto the first exact target for file tools", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-paths",
          toolName: "files.write",
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/a.txt"}',
            callID: "call-paths",
          },
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("files.write")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-paths");
    await user.click(within(card).getByRole("radio", { name: "Custom scope" }));
    const dialog = screen.getByRole("dialog", { name: "Edit decision scope" });
    const editor = within(dialog).getByLabelText("Paths");
    expect(editor).toHaveValue("/tmp/a.txt");
    // One decision carries one scope, so the first entry names the rule.
    fireEvent.change(editor, {
      target: { value: "/tmp/x.txt\n/tmp/y.txt" },
    });
    await user.click(within(dialog).getByRole("button", { name: "Save scope" }));
    await waitFor(() => {
      expect(
        within(card).getByTestId("approval-scope-summary-req-paths"),
      ).toHaveTextContent("/tmp/x.txt");
    });
    await user.click(within(card).getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "thisTime",
      scope: { kind: "exactTarget", target: "/tmp/x.txt" },
      surface: "inbox",
    });
  });

  it("carries a bash pattern editor as the exact-target scope", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-pattern",
          toolName: "bash.exec",
          input: {
            toolName: "bash.exec",
            argumentsJSON: '{"command":"ls /tmp"}',
            callID: "call-pattern",
          },
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("bash.exec")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-pattern");
    await user.click(within(card).getByRole("radio", { name: "Custom scope" }));
    const dialog = screen.getByRole("dialog", { name: "Edit decision scope" });
    // The editor prefills from the engine-derived command.
    expect(within(dialog).getByLabelText("Pattern")).toHaveValue("ls /tmp");
    fireEvent.change(within(dialog).getByLabelText("Pattern"), {
      target: { value: "ls *" },
    });
    await user.click(within(dialog).getByRole("button", { name: "Save scope" }));
    await waitFor(() => {
      expect(
        within(card).getByTestId("approval-scope-summary-req-pattern"),
      ).toHaveTextContent("ls *");
    });
    await user.click(within(card).getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "thisTime",
      scope: { kind: "exactTarget", target: "ls *" },
      surface: "inbox",
    });
  });

  it("refuses a blank scope save and holds the decision controls", async () => {
    const user = userEvent.setup();
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("radio", { name: "Custom scope" }));
    const dialog = screen.getByRole("dialog", { name: "Edit decision scope" });
    await user.clear(within(dialog).getByLabelText("Recipients"));
    await user.click(within(dialog).getByRole("button", { name: "Save scope" }));
    // A blank editor names no target, so the modal stays open with the reason
    // and the card's decisions stay locked instead of shipping a scope the
    // owner never described.
    await waitFor(() => {
      expect(within(dialog).getByRole("alert")).toHaveTextContent(
        "Enter at least one entry.",
      );
    });
    expect(screen.getByRole("dialog", { name: "Edit decision scope" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeDisabled();
  });

  it("offers an egress card only the mapped tiers and derives the domain scope", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-egress",
          toolName: "api.request",
          egressHost: "api.example.com",
          input: {
            toolName: "api.request",
            argumentsJSON: '{"method":"GET","url":"https://api.example.com/v1"}',
            callID: "call-egress",
          },
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("api.request")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-egress");
    const duration = within(card).getByLabelText("Duration for api.request");
    // The tier mapping reads exactly thisTime, forSession, and forever, so the
    // picker offers those three in the shared vocabulary and nothing else.
    expect(
      Array.from(duration.querySelectorAll("option")).map((option) => option.value),
    ).toEqual(["thisTime", "forSession", "forever"]);
    // The mapping is stated on the card instead of a second control language.
    expect(
      within(card).getByText(
        "Tiers map to api.example.com: once, for this session, or a durable rule.",
      ),
    ).toBeInTheDocument();
    await user.selectOptions(duration, "forSession");
    await user.click(within(card).getByRole("radio", { name: /This host/ }));
    await user.click(within(card).getByRole("button", { name: "Allow" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "forSession",
      scope: { kind: "domain", host: "api.example.com" },
      surface: "inbox",
    });
  });

  it("maps an egress forever denial to the durable domain scope", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-egress-deny",
          toolName: "api.request",
          egressHost: "blocked.example.com",
          input: {
            toolName: "api.request",
            argumentsJSON: '{"method":"GET","url":"https://blocked.example.com/v1"}',
            callID: "call-egress-deny",
          },
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("api.request")).toBeInTheDocument();
    });
    const card = screen.getByTestId("approval-card-req-egress-deny");
    await user.selectOptions(
      within(card).getByLabelText("Duration for api.request"),
      "forever",
    );
    await user.click(within(card).getByRole("button", { name: "Deny" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    // A forever refusal on a parked host carries the domain scope so the
    // durable deny rule covers the host the owner refused.
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: false,
      duration: "forever",
      scope: { kind: "domain", host: "blocked.example.com" },
      surface: "inbox",
    });
  });

  it("renders the brake card as a dedicated Resume plus Keep paused branch", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-brake",
          toolName: "behavior.brake",
          description:
            "Behavior brake engaged: email.send executed 18 times in the trailing hour (baseline 3).",
          // The watchdog parks every running turn, so a tagged session must
          // not pull the card out of Unattributed.
          sessionID: "sess-chat",
        }),
      ],
      sessions: [{ id: "sess-chat", title: "Deploy chat" }],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    const { container } = render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("behavior.brake")).toBeInTheDocument();
    });
    expect(groupTitles(container)).toEqual(["Unattributed"]);
    const card = screen.getByTestId("approval-card-req-brake");
    // Dangerous badge and red accent, description shown.
    expect(within(card).getByTestId("approval-severity-req-brake")).toHaveTextContent(
      "🔴 Dangerous",
    );
    expect(card).toHaveClass("approval-brake-card");
    expect(
      within(card).getByText(
        "Behavior brake engaged: email.send executed 18 times in the trailing hour (baseline 3).",
      ),
    ).toBeInTheDocument();
    // Releasing the park is the complete decision: no duration picker, no
    // scope editor, no Open Thread.
    expect(
      within(card).queryByLabelText("Duration for behavior.brake"),
    ).not.toBeInTheDocument();
    expect(within(card).queryByRole("radiogroup")).not.toBeInTheDocument();
    expect(within(card).queryByText("Open Thread")).not.toBeInTheDocument();
    await user.click(within(card).getByRole("button", { name: "Resume" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: true,
      duration: "thisTime",
      surface: "inbox",
    });
  });

  it("keeps the park on Keep paused with the one-shot denial", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-brake-hold",
          toolName: "behavior.brake",
          description: "Behavior brake engaged.",
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST" && path.includes("/decide")) {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("behavior.brake")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Keep paused" }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(JSON.parse(calls[0].body)).toEqual({
      approved: false,
      duration: "thisTime",
      surface: "inbox",
    });
  });

  it("renders severity badge, intent, outcome, and warnings while hiding the static description", async () => {
    stubEngine({
      approvals: [
        pendingRequest({
          id: "22222222-2222-2222-2222-222222222222",
          toolName: "desktop.action",
          description: "Perform mouse and keyboard actions",
          intent: "Closing inactive background tab",
          assessment: {
            severity: "dangerous",
            outcome: "Simulates mouse click on close button",
            warnings: ["Hardware CGEvent input simulation"],
          },
          input: {
            toolName: "desktop.action",
            argumentsJSON: '{"action":"click"}',
            callID: "call-2",
          },
          suggestedDurations: ["thisTime"],
        }),
      ],
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("desktop.action")).toBeInTheDocument();
    });
    expect(
      screen.getByTestId("approval-severity-22222222-2222-2222-2222-222222222222"),
    ).toHaveTextContent("🔴 Dangerous");
    expect(screen.getByText("Closing inactive background tab")).toBeInTheDocument();
    expect(
      screen.getByText("Simulates mouse click on close button"),
    ).toBeInTheDocument();
    expect(screen.getByText(/Hardware CGEvent input simulation/)).toBeInTheDocument();
    // Static description must NOT be present once the assessment is valued.
    expect(
      screen.queryByText("Perform mouse and keyboard actions"),
    ).not.toBeInTheDocument();
  });

  it("renders the pending badge with spinner copy and enabled controls", async () => {
    stubEngine({
      approvals: [
        pendingRequest({
          id: "33333333-3333-3333-3333-333333333333",
          description: "Send email to ops",
          intent: "Notifying ops of deploy",
          assessment: null,
          input: {
            toolName: "email.send",
            argumentsJSON: '{"to":"ops@example.com"}',
            callID: "call-3",
          },
          suggestedDurations: ["thisTime"],
        }),
      ],
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    const pending = screen.getByTestId(
      "approval-assessment-pending-33333333-3333-3333-3333-333333333333",
    );
    expect(pending).toBeInTheDocument();
    expect(pending).toHaveClass("severity-pending");
    expect(pending).toHaveTextContent("Checking safety…");
    expect(
      pending.querySelector(
        ".approval-assessment-pending, .approval-assessment-pending-spinner",
      ),
    ).not.toBeNull();
    // Valued badge, outcome, and warnings stay hidden while pending.
    expect(
      screen.queryByTestId(
        "approval-severity-33333333-3333-3333-3333-333333333333",
      ),
    ).not.toBeInTheDocument();
    expect(screen.queryByText(/Expected outcome/)).not.toBeInTheDocument();
    // Intent, arguments disclosure, and live decisions stay available.
    expect(screen.getByText("Notifying ops of deploy")).toBeInTheDocument();
    expect(screen.getByText("View arguments")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeEnabled();
  });

  it("renders the question picker through the shared card", async () => {
    const user = userEvent.setup();
    const calls: Array<{ path: string; body: string }> = [];
    stubEngine({
      approvals: [
        pendingRequest({
          id: "req-question",
          toolName: "question.ask",
          description: "Which environment?",
          input: {
            toolName: "question.ask",
            argumentsJSON:
              '{"question":"Which environment?","options":["staging","production"]}',
            callID: "call-question",
          },
          suggestedDurations: ["thisTime"],
        }),
      ],
      onCall: (path, init) => {
        if (init?.method === "POST") {
          calls.push({ path, body: String(init?.body ?? "") });
        }
      },
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(
        screen.getByTestId("inline-question-req-question"),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("radio", { name: "staging" }));
    await user.click(screen.getByRole("button", { name: /submit choice/i }));
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(calls[0].path).toContain("/respond");
    expect(JSON.parse(calls[0].body)).toMatchObject({
      answer: "staging",
      cancelled: false,
    });
  });

  it("locks only the deciding row while a decision is in flight", async () => {
    const user = userEvent.setup();
    let resolveDecide: ((value: Response) => void) | null = null;
    const decidePromise = new Promise<Response>((resolve) => {
      resolveDecide = resolve;
    });
    stubEngine({
      approvals: [
        pendingRequest({ id: "req-slow", sessionID: "sess-a" }),
        pendingRequest({
          id: "req-fast",
          sessionID: "sess-a",
          toolName: "files.write",
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/a.txt"}',
            callID: "call-fast",
          },
        }),
      ],
      sessions: [{ id: "sess-a", title: "Alpha" }],
      // Hold only the first decision; the reads and the sibling card answer
      // through the default branch.
      respond: (path, init) =>
        init?.method === "POST" && path.includes("req-slow")
          ? decidePromise
          : null,
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    const slowCard = screen.getByTestId("approval-card-req-slow");
    const fastCard = screen.getByTestId("approval-card-req-fast");
    await user.click(within(slowCard).getByRole("button", { name: "Allow" }));
    // The in-flight row reports progress while the sibling stays actionable,
    // so a slow decision cannot freeze independent approvals.
    await waitFor(() => {
      expect(within(slowCard).getByText("Allowing & resuming…")).toBeInTheDocument();
    });
    expect(
      within(slowCard).queryByRole("button", { name: "Allow" }),
    ).not.toBeInTheDocument();
    expect(
      within(fastCard).getByRole("button", { name: "Allow" }),
    ).toBeEnabled();
    resolveDecide!(
      jsonResponse({
        id: "req-slow",
        approved: true,
        duration: "thisTime",
      }),
    );
    await waitFor(() => {
      expect(screen.queryByTestId("approval-card-req-slow")).not.toBeInTheDocument();
    });
  });

  it("keeps no Refresh button in the Pending header", async () => {
    stubEngine({ approvals: [pendingRequest()] });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    // Live frames, socket reopen, and visibility resync are the only refresh
    // paths, so the Pending header carries no manual control and keeps the
    // pending count.
    expect(
      screen.queryByRole("button", { name: "Refresh" }),
    ).not.toBeInTheDocument();
    expect(screen.getByText("1 pending")).toBeInTheDocument();
  });

  it("upserts identical-id approval frames so enrichment swaps pending for valued", async () => {
    const { resetSharedSocket } = await import("../hooks/useSharedWebSocket");
    const {
      createMockWebSocket,
      createMockWebSocketCapture,
      dispatchFrameOrThrow,
    } = await import("../test-utils/mockWebSocket");
    resetSharedSocket();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    const pendingID = "55555555-5555-5555-5555-555555555555";
    stubEngine({
      approvals: [
        pendingRequest({
          id: pendingID,
          description: "Send email to ops",
          intent: "Notifying ops of deploy",
          assessment: null,
          input: {
            toolName: "email.send",
            argumentsJSON: '{"to":"ops@example.com"}',
            callID: "call-5",
          },
        }),
      ],
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(
        screen.getByTestId(`approval-assessment-pending-${pendingID}`),
      ).toBeInTheDocument();
    });
    const allowBefore = screen.getByRole("button", { name: "Allow" });
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    // Enrichment rebroadcast for the identical id replaces the stored entry
    // in place: no duplicate card, pending swaps for the valued copy, and the
    // Allow control persists without remounting.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval",
      request: {
        id: pendingID,
        toolName: "email.send",
        description: "Send email to ops",
        intent: "Notifying ops of deploy",
        assessment: {
          severity: "moderate",
          outcome: "Sends deploy notice to ops",
          warnings: ["External recipient"],
        },
        input: {
          toolName: "email.send",
          argumentsJSON: '{"to":"ops@example.com"}',
          callID: "call-5",
        },
        suggestedDurations: ["thisTime"],
      },
    });
    await waitFor(() => {
      expect(
        screen.getByTestId(`approval-severity-${pendingID}`),
      ).toBeInTheDocument();
    });
    expect(
      screen.queryByTestId(`approval-assessment-pending-${pendingID}`),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Sends deploy notice to ops")).toBeInTheDocument();
    expect(screen.getByText(/External recipient/)).toBeInTheDocument();
    expect(screen.getByText("1 pending")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBe(allowBefore);
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
    // Static description stays hidden once valued.
    expect(screen.queryByText("Send email to ops")).not.toBeInTheDocument();
    resetSharedSocket();
  });

  it("evicts decided approvals over the socket and drops rules-change frames", async () => {
    const { resetSharedSocket } = await import("../hooks/useSharedWebSocket");
    const {
      createMockWebSocket,
      createMockWebSocketCapture,
      dispatchFrameOrThrow,
    } = await import("../test-utils/mockWebSocket");
    resetSharedSocket();
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    const decidedID = "66666666-6666-6666-6666-666666666666";
    stubEngine({
      approvals: [
        pendingRequest({ id: decidedID, sessionID: "sess-a" }),
        pendingRequest({
          id: "77777777-7777-7777-7777-777777777777",
          sessionID: "sess-a",
          toolName: "files.write",
          input: {
            toolName: "files.write",
            argumentsJSON: '{"path":"/tmp/a.txt"}',
            callID: "call-keep",
          },
        }),
      ],
      sessions: [{ id: "sess-a", title: "Alpha" }],
    });
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByTestId(`approval-card-${decidedID}`)).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(capture.onMessage).not.toBeNull();
    });
    // Standing rules changed: the inbox manages no grants, so the frame
    // refreshes nothing and leaves the pending queue untouched.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "access_rules_changed",
    });
    expect(
      screen.getByTestId(`approval-card-${decidedID}`),
    ).toBeInTheDocument();
    // A decision elsewhere evicts only its own card.
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "approval_decided",
      id: decidedID,
    });
    await waitFor(() => {
      expect(screen.queryByTestId(`approval-card-${decidedID}`)).not.toBeInTheDocument();
    });
    expect(
      screen.getByTestId("approval-card-77777777-7777-7777-7777-777777777777"),
    ).toBeInTheDocument();
    resetSharedSocket();
  });

  it("shows the filtered session's ephemeral trust above the pending groups", async () => {
    const trustGrants = [
      {
        toolName: "email.send",
        scope: { kind: "exactTarget", target: "bob@x.com" },
        duration: "forSession",
        grantedAt: "2026-01-01T00:00:00Z",
        expiresAt: null,
      },
    ];
    const fetchMock = vi.fn(async (input: string) => {
      const path = String(input);
      if (path.startsWith("/approvals/session-trust")) {
        return jsonResponse({
          sessionID: "sess-a",
          grants: trustGrants,
          count: 1,
        });
      }
      if (path === "/sessions") {
        return jsonResponse({ sessions: [{ id: "sess-a", title: "Alpha" }], count: 1 });
      }
      return jsonResponse({ approvals: [], count: 0 });
    });
    vi.stubGlobal("fetch", fetchMock);
    const { container } = render(<ApprovalsInbox sessionID="sess-a" />);

    await waitFor(() => {
      expect(screen.getByTestId("ephemeral-trust-chip")).toBeInTheDocument();
    });
    const line = container.querySelector<HTMLElement>(".ephemeral-trust-line");
    expect(line?.textContent).toBe(
      "email.send to bob@x.com (rest of this session)",
    );
    // The chip sits above the pending groups, and its revoke is per line.
    const chip = screen.getByTestId("ephemeral-trust-chip");
    const groups = container.querySelector(".approvals-groups");
    expect(
      chip.compareDocumentPosition(groups as Node) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
    expect(screen.getByRole("button", { name: "Revoke" })).toBeInTheDocument();
    // With no session filtered, the chip never mounts and no trust is read.
    cleanup();
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("No pending approvals.")).toBeInTheDocument();
    });
    expect(
      screen.queryByTestId("ephemeral-trust-chip"),
    ).not.toBeInTheDocument();
    expect(
      fetchMock.mock.calls.filter(([url]) =>
        String(url).startsWith("/approvals/session-trust"),
      ),
    ).toHaveLength(1);
  });

  it("defaults to Pending and swaps the groups for History on the segmented control", async () => {
    const user = userEvent.setup();
    const historyEntries = [
      {
        id: "hist-1",
        toolName: "email.send",
        scopeKind: "exactTarget",
        scopeData: "ops@example.com",
        allowed: true,
        duration: "thisTime",
        surface: "inbox",
        sessionID: null,
        displayTarget: "ops@example.com",
        decidedAt: new Date(Date.now() - 60_000).toISOString(),
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, _init?: RequestInit) => {
        const path = String(input);
        if (path === "/sessions") {
          return jsonResponse({ sessions: [], count: 0 });
        }
        if (path.startsWith("/approvals/history")) {
          return jsonResponse({
            entries: historyEntries,
            count: historyEntries.length,
          });
        }
        return jsonResponse({ approvals: [pendingRequest()], count: 1 });
      }),
    );
    render(<ApprovalsInbox />);
    await waitFor(() => {
      expect(screen.getByText("email.send")).toBeInTheDocument();
    });
    // Pending is the default view.
    expect(screen.getByTestId("inbox-view-pending")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    expect(screen.getByTestId("inbox-view-history")).toHaveAttribute(
      "aria-pressed",
      "false",
    );
    expect(screen.getByText("1 pending")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBeInTheDocument();
    await user.click(screen.getByTestId("inbox-view-history"));
    expect(screen.getByTestId("inbox-view-history")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    expect(screen.getByTestId("inbox-view-pending")).toHaveAttribute(
      "aria-pressed",
      "false",
    );
    // History replaces the pending queue while the header row stays.
    await waitFor(() => {
      expect(screen.getByTestId("approval-history")).toBeInTheDocument();
    });
    expect(
      screen.queryByRole("button", { name: "Allow" }),
    ).not.toBeInTheDocument();
    expect(screen.queryByText("1 pending")).not.toBeInTheDocument();
    expect(screen.getByText("Inbox")).toBeInTheDocument();
    // Back to Pending restores the queue.
    await user.click(screen.getByTestId("inbox-view-pending"));
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Allow" })).toBeInTheDocument();
    });
    expect(screen.getByText("1 pending")).toBeInTheDocument();
    expect(screen.queryByTestId("approval-history")).not.toBeInTheDocument();
  });

  it("hides the ephemeral chip on the History view", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (input: string) => {
      const path = String(input);
      if (path.startsWith("/approvals/session-trust")) {
        return jsonResponse({
          sessionID: "sess-a",
          grants: [
            {
              toolName: "email.send",
              scope: { kind: "exactTarget", target: "bob@x.com" },
              duration: "forSession",
              grantedAt: "2026-01-01T00:00:00Z",
              expiresAt: null,
            },
          ],
          count: 1,
        });
      }
      if (path.startsWith("/approvals/history")) {
        return jsonResponse({ entries: [], count: 0 });
      }
      if (path === "/sessions") {
        return jsonResponse({ sessions: [], count: 0 });
      }
      return jsonResponse({ approvals: [], count: 0 });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<ApprovalsInbox sessionID="sess-a" />);
    await waitFor(() => {
      expect(screen.getByTestId("ephemeral-trust-chip")).toBeInTheDocument();
    });
    await user.click(screen.getByTestId("inbox-view-history"));
    await waitFor(() => {
      expect(screen.getByText("No recorded decisions.")).toBeInTheDocument();
    });
    expect(
      screen.queryByTestId("ephemeral-trust-chip"),
    ).not.toBeInTheDocument();
  });
});
