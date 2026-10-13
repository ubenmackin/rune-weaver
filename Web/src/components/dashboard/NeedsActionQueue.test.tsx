// Rune Weaver Dashboard — Unit tests for the Needs Action queue card list.
// Pins the one-shot decision payload, the "Approve once" / "Deny" labels, the
// Open in Inbox link on every card, the dedicated brake branch, the
// severity-then-filing ordering matrix, and the absence of any bulk control.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import NeedsActionQueue from "./NeedsActionQueue";
import type { Goal, PermissionRequest } from "../../api";
import { jsonResponse } from "../../test-utils/http";

interface DecideCall {
  path: string;
  method: string;
  body: Record<string, unknown>;
}

interface StubbedApi {
  decideCalls: DecideCall[];
}

function makeApproval(
  overrides: Partial<PermissionRequest> & Pick<PermissionRequest, "id" | "toolName">,
): PermissionRequest {
  return {
    description: `${overrides.toolName} requested`,
    input: {
      toolName: overrides.toolName,
      argumentsJSON: "{\"target\":\"origin/main\"}",
      callID: `call-${overrides.id}`,
    },
    suggestedDurations: ["thisTime"],
    sessionID: "session-abc",
    ...overrides,
  };
}

function makeGoal(overrides: Partial<Goal> = {}): Goal {
  return {
    id: "goal-1",
    title: "Develop Crypto Trading Plan",
    statement: "Seed account with $100 and double amount.",
    status: "unplanned",
    progress: { done: 0, total: 0 },
    stepIntervalMinutes: 1440,
    nextDueAt: null,
    originSessionId: null,
    createdAt: 0,
    updatedAt: 0,
    ...overrides,
  };
}

// Stubs the engine surface the queue reads, capturing every decide write so the
// wire payload (not just the call arguments) is asserted.
function stubApi(
  approvals: PermissionRequest[],
  goals: Goal[] = [],
): StubbedApi {
  const decideCalls: DecideCall[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      if (path.startsWith("/approvals") && method === "GET") {
        return jsonResponse({ approvals, count: approvals.length });
      }
      if (path.startsWith("/goals") && method === "GET") {
        return jsonResponse({ goals, count: goals.length });
      }
      if (path.endsWith("/decide")) {
        decideCalls.push({
          path,
          method,
          body: JSON.parse(String(init?.body ?? "{}")),
        });
        return jsonResponse({
          id: "decided",
          approved: true,
          duration: "thisTime",
        });
      }
      if (path.endsWith("/respond")) {
        return jsonResponse({
          id: "answered",
          approved: false,
          duration: "thisTime",
        });
      }
      if (path.includes("/advance")) {
        return jsonResponse({
          runID: "run-1",
          sessionID: "sess-1",
          goalId: "goal-1",
        });
      }
      return jsonResponse({});
    }),
  );
  return { decideCalls };
}

function renderedToolNames(container: HTMLElement): string[] {
  return Array.from(
    container.querySelectorAll(".action-card .tool-name-badge"),
  ).map((node) => node.textContent ?? "");
}

describe("NeedsActionQueue", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends the one-shot decide payload with duration thisTime and no scope", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({ id: "appr-1", toolName: "git.push" }),
    ]);

    render(<NeedsActionQueue />);

    const approveBtn = await screen.findByRole("button", { name: /Approve once/i });
    await user.click(approveBtn);

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].method).toBe("POST");
    expect(decideCalls[0].path).toBe("/approvals/appr-1/decide");
    // The whole payload: the one-shot tier and nothing else, so no scope can
    // ride along and widen the grant beyond this call.
    expect(decideCalls[0].body).toEqual({ approved: true, duration: "thisTime" });
  });

  it("sends the same one-shot payload when the card is denied", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({ id: "appr-1", toolName: "git.push" }),
      makeApproval({ id: "appr-2", toolName: "email.send" }),
    ]);

    render(<NeedsActionQueue />);

    const denyBtn = await screen.findByRole("button", { name: /Deny email.send/i });
    await user.click(denyBtn);

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].body).toEqual({ approved: false, duration: "thisTime" });
  });

  it("labels the quick actions Approve once and Deny with the one-shot consequence visible", async () => {
    stubApi([makeApproval({ id: "appr-1", toolName: "git.push" })]);

    const { container } = render(<NeedsActionQueue />);

    await screen.findByRole("button", { name: /Approve once/i });
    expect(screen.getByRole("button", { name: /Deny git.push/i })).toBeInTheDocument();
    // The consequence line names what the decision covers and where the
    // durable tiers live.
    const note = container.querySelector(".action-card-once-note");
    expect(note).not.toBeNull();
    expect(note).toHaveTextContent(/One shot/i);
    expect(note).toHaveTextContent(/Open in Inbox/i);
    // A dashboard decision never mints durable trust: no duration picker and no
    // scope editor render on the card.
    const card = container.querySelector(".action-card") as HTMLElement;
    expect(within(card).queryByRole("combobox")).toBeNull();
    expect(within(card).queryByRole("checkbox")).toBeNull();
  });

  it("links every card to the Approvals Inbox", async () => {
    stubApi([
      makeApproval({ id: "appr-1", toolName: "git.push" }),
      makeApproval({ id: "appr-2", toolName: "email.send" }),
      {
        ...makeApproval({ id: "appr-3", toolName: "question.ask" }),
        input: {
          toolName: "question.ask",
          argumentsJSON: JSON.stringify({
            question: "Which environment?",
            options: ["staging", "production"],
          }),
          callID: "call-appr-3",
        },
      },
    ]);

    render(<NeedsActionQueue />);

    await screen.findAllByRole("button", { name: /Approve once/i });
    const links = screen.getAllByRole("link", { name: /Open in Inbox/i });
    expect(links).toHaveLength(3);
    for (const link of links) {
      expect(link).toHaveAttribute("href", "#approvals");
    }
  });

  it("renders the brake card as a Resume plus Keep paused branch with no duration control", async () => {
    stubApi([
      makeApproval({
        id: "brake-1",
        toolName: "behavior.brake",
        description: "brake engaged: rate_spike",
      }),
    ]);

    const { container } = render(<NeedsActionQueue />);

    expect(await screen.findByRole("button", { name: "Resume" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Keep paused" })).toBeInTheDocument();
    // The brake is the sole exception to the approve/deny pair, so neither
    // generic label appears on its card.
    expect(screen.queryByRole("button", { name: /Approve once/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /Deny/i })).toBeNull();

    const card = container.querySelector(".action-card-brake") as HTMLElement;
    // No duration picker and no scope editor: releasing parked turns is the
    // whole decision.
    expect(within(card).queryByRole("combobox")).toBeNull();
    expect(within(card).queryByRole("checkbox")).toBeNull();
    expect(within(card).getByRole("link", { name: /Open in Inbox/i })).toHaveAttribute(
      "href",
      "#approvals",
    );
  });

  it("resumes the brake with the one-shot payload", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({
        id: "brake-1",
        toolName: "behavior.brake",
        description: "brake engaged: rate_spike",
      }),
    ]);

    render(<NeedsActionQueue />);

    await user.click(await screen.findByRole("button", { name: "Resume" }));

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].path).toBe("/approvals/brake-1/decide");
    expect(decideCalls[0].body).toEqual({ approved: true, duration: "thisTime" });
  });

  it("keeps the brake paused with the one-shot payload", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({
        id: "brake-1",
        toolName: "behavior.brake",
        description: "brake engaged: rate_spike",
      }),
    ]);

    render(<NeedsActionQueue />);

    await user.click(await screen.findByRole("button", { name: "Keep paused" }));

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].body).toEqual({ approved: false, duration: "thisTime" });
  });

  it("orders cards by severity descending then filing time descending", async () => {
    // Payload position is the wire's only filing signal, so the stub order is
    // the filing order (oldest first) and a later position is the newer filing.
    stubApi([
      makeApproval({
        id: "safe-1",
        toolName: "files.read",
        assessment: { severity: "safe", outcome: "reads a file" },
      }),
      makeApproval({
        id: "danger-1",
        toolName: "git.push",
        assessment: { severity: "dangerous", outcome: "pushes commits" },
      }),
      makeApproval({
        id: "moderate-1",
        toolName: "email.send",
        assessment: { severity: "moderate", outcome: "sends mail" },
      }),
      makeApproval({
        id: "moderate-2",
        toolName: "messages.send",
        assessment: { severity: "moderate", outcome: "sends a message" },
      }),
    ]);

    const { container } = render(<NeedsActionQueue />);

    await waitFor(() =>
      expect(container.querySelectorAll(".action-card .tool-name-badge")).toHaveLength(4),
    );
    // Dangerous leads, the two moderate cards run newest-first, and safe sinks.
    expect(renderedToolNames(container)).toEqual([
      "git.push",
      "messages.send",
      "email.send",
      "files.read",
    ]);
  });

  it("treats an absent assessment as moderate when ordering", async () => {
    stubApi([
      makeApproval({ id: "quiet-1", toolName: "files.write" }),
      makeApproval({
        id: "loud-1",
        toolName: "git.push",
        assessment: { severity: "dangerous", outcome: "pushes commits" },
      }),
    ]);

    const { container } = render(<NeedsActionQueue />);

    await waitFor(() =>
      expect(container.querySelectorAll(".action-card .tool-name-badge")).toHaveLength(2),
    );
    expect(renderedToolNames(container)).toEqual(["git.push", "files.write"]);
  });

  it("breaks severity ties by filing time descending", async () => {
    stubApi([
      makeApproval({
        id: "older-1",
        toolName: "email.send",
        assessment: { severity: "moderate", outcome: "sends mail" },
      }),
      makeApproval({
        id: "newer-1",
        toolName: "messages.send",
        assessment: { severity: "moderate", outcome: "sends a message" },
      }),
    ]);

    const { container } = render(<NeedsActionQueue />);

    await waitFor(() =>
      expect(container.querySelectorAll(".action-card .tool-name-badge")).toHaveLength(2),
    );
    expect(renderedToolNames(container)).toEqual(["messages.send", "email.send"]);
  });

  it("orders brake and question cards on the same severity scale as tool approvals", async () => {
    stubApi([
      {
        ...makeApproval({ id: "question-1", toolName: "question.ask" }),
        input: {
          toolName: "question.ask",
          argumentsJSON: JSON.stringify({
            question: "Which environment?",
            options: ["staging", "production"],
          }),
          callID: "call-question-1",
        },
      },
      makeApproval({
        id: "brake-1",
        toolName: "behavior.brake",
        description: "brake engaged: rate_spike",
      }),
      makeApproval({
        id: "danger-1",
        toolName: "git.push",
        assessment: { severity: "dangerous", outcome: "pushes commits" },
      }),
    ]);

    const { container } = render(<NeedsActionQueue />);

    await waitFor(() =>
      expect(container.querySelectorAll(".action-card")).toHaveLength(3),
    );
    const cards = Array.from(container.querySelectorAll(".action-card"));
    // Dangerous leads the queue; the brake was filed after the question, so it
    // outranks it at equal severity.
    expect(cards[0]).toHaveTextContent("git.push");
    expect(cards[1].className).toContain("action-card-brake");
    expect(cards[2]).toHaveTextContent("Which environment?");
  });

  it("keeps blocked-goal cards and their Plan Goal and Inspect actions unchanged", async () => {
    stubApi([], [makeGoal()]);

    const { container } = render(<NeedsActionQueue />);

    const goalTitle = await screen.findByText("Develop Crypto Trading Plan");
    expect(goalTitle).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Plan Develop Crypto Trading Plan/i }),
    ).toHaveTextContent("Plan Goal");
    expect(screen.getByRole("button", { name: /Inspect Goal/i })).toBeInTheDocument();
    // Goal cards route through the thread and goals surfaces, never the inbox.
    const goalCardEl = container.querySelector(".goal-input-card") as HTMLElement;
    expect(within(goalCardEl).queryByRole("link", { name: /Open in Inbox/i })).toBeNull();
  });

  it("offers no batch or bulk control anywhere on the queue", async () => {
    stubApi([
      makeApproval({ id: "appr-1", toolName: "git.push" }),
      makeApproval({ id: "appr-2", toolName: "email.send" }),
      makeApproval({
        id: "appr-3",
        toolName: "behavior.brake",
        description: "brake engaged: denial_spike",
      }),
    ]);

    render(<NeedsActionQueue />);

    await screen.findAllByRole("button", { name: /Approve once/i });
    // One decision pair per card, and nothing that decides several cards at
    // once, so no card is ever approved by association.
    expect(screen.getAllByRole("button", { name: /Approve once/i })).toHaveLength(2);
    expect(screen.queryByRole("button", { name: /approve all|deny all|bulk|selected/i })).toBeNull();
  });
});
