// Rune Weaver Dashboard — Unit tests for the Needs Action queue card list.

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import NeedsActionQueue from "./NeedsActionQueue";
import type { Goal, PermissionRequest, ScheduledSend } from "../../api";
import { durationOptionsFor } from "../../approvalsShared";
import { jsonResponse } from "../../test-utils/http";

interface DecideCall {
  path: string;
  method: string;
  body: Record<string, unknown>;
}

interface CancelCall {
  path: string;
  method: string;
}

interface StubbedApi {
  decideCalls: DecideCall[];
  cancelCalls: CancelCall[];
  fetchCalls: string[];
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

function makeSend(overrides: Partial<ScheduledSend> & Pick<ScheduledSend, "id">): ScheduledSend {
  const fireAt = new Date(Date.now() + 3_600_000).toISOString();
  return {
    channel: "email",
    status: "queued",
    recipient: "ops@example.com",
    subject: "Weekly digest",
    bodyText: "Hello",
    bodyHtml: null,
    fireAt,
    createdAt: new Date(Date.now() - 60_000).toISOString(),
    updatedAt: new Date(Date.now() - 60_000).toISOString(),
    settledAt: null,
    failureReason: null,
    ...overrides,
  };
}

// Stubs the engine surface the queue reads, capturing every decide write so the wire payload (not
// just the call arguments) is asserted.
function stubApi(
  approvals: PermissionRequest[],
  goals: Goal[] = [],
  sends: ScheduledSend[] = [],
): StubbedApi {
  const decideCalls: DecideCall[] = [];
  const cancelCalls: CancelCall[] = [];
  const fetchCalls: string[] = [];
  let liveSends = [...sends];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      fetchCalls.push(`${method} ${path}`);
      if (path.startsWith("/approvals") && method === "GET") {
        return jsonResponse({ approvals, count: approvals.length });
      }
      if (path.startsWith("/goals") && method === "GET") {
        return jsonResponse({ goals, count: goals.length });
      }
      if (path === "/scheduler/sends" && method === "GET") {
        return jsonResponse({ sends: liveSends, count: liveSends.length });
      }
      if (path.startsWith("/scheduler/sends/") && method === "DELETE") {
        cancelCalls.push({ path, method });
        const id = decodeURIComponent(path.split("/").pop() ?? "");
        const row = liveSends.find((s) => s.id === id);
        liveSends = liveSends.filter((s) => s.id !== id);
        return jsonResponse({ ...(row ?? makeSend({ id })), status: "cancelled" });
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
  return { decideCalls, cancelCalls, fetchCalls };
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

  it("sends the Allow main payload with duration thisTime, surface dashboard, and no scope", async () => {
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
    // Duration-only quick surface: the picked tier plus the dashboard surface
    // tag, and no scope key so the engine resolves the request's own target.
    expect(decideCalls[0].body).toEqual({ approved: true, duration: "thisTime", surface: "dashboard" });
    expect(decideCalls[0].body).not.toHaveProperty("scope");
  });

  it("sends the Deny main payload as deny-once with surface dashboard and no scope", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({ id: "appr-1", toolName: "git.push" }),
      makeApproval({ id: "appr-2", toolName: "email.send" }),
    ]);

    render(<NeedsActionQueue />);

    const denyBtn = await screen.findByRole("button", { name: /Deny email.send/i });
    await user.click(denyBtn);

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].body).toEqual({ approved: false, duration: "thisTime", surface: "dashboard" });
    expect(decideCalls[0].body).not.toHaveProperty("scope");
  });

  it("sends Deny always as a standing deny with surface dashboard", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({ id: "appr-1", toolName: "git.push" }),
    ]);

    render(<NeedsActionQueue />);

    const denyChevron = await screen.findByRole("button", { name: /Deny options for git.push/i });
    await user.click(denyChevron);
    await user.click(await screen.findByRole("menuitem", { name: /Deny always/i }));

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].path).toBe("/approvals/appr-1/decide");
    expect(decideCalls[0].body).toEqual({ approved: false, duration: "forever", surface: "dashboard" });
    expect(decideCalls[0].body).not.toHaveProperty("scope");
  });

  it("hides the standing-deny control on a coerced-tool continuation card", async () => {
    stubApi([
      makeApproval({ id: "cont-1", toolName: "engine.continue" }),
    ]);

    render(<NeedsActionQueue />);

    // The one-shot card keeps its this-time Deny main button…
    expect(
      await screen.findByRole("button", { name: /Deny engine\.continue/i }),
    ).toBeInTheDocument();
    // …but offers no Deny chevron and no Deny always item: the decision contract coerces any
    // durable tier on a one-shot tool back to thisTime and mints no rule, so a standing deny would
    // be a dead vote — the same semantics the chat banner's dedicated Continue/Stop branch renders.
    expect(
      screen.queryByRole("button", { name: /Deny options for engine\.continue/i }),
    ).toBeNull();
    expect(screen.queryByRole("menuitem", { name: /Deny always/i })).toBeNull();
  });

  it("hides the standing-deny control on a coerced-tool desktop resume card", async () => {
    stubApi([
      makeApproval({ id: "resume-1", toolName: "desktop.resume" }),
    ]);

    render(<NeedsActionQueue />);

    expect(
      await screen.findByRole("button", { name: /Deny desktop\.resume/i }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Deny options for desktop\.resume/i }),
    ).toBeNull();
    expect(screen.queryByRole("menuitem", { name: /Deny always/i })).toBeNull();
  });

  it("sends the coerced-tool Deny main payload as deny-once with surface dashboard", async () => {
    const user = userEvent.setup();
    const { decideCalls } = stubApi([
      makeApproval({ id: "cont-1", toolName: "engine.continue" }),
    ]);

    render(<NeedsActionQueue />);

    await user.click(await screen.findByRole("button", { name: /Deny engine\.continue/i }));

    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].body).toEqual({ approved: false, duration: "thisTime", surface: "dashboard" });
    expect(decideCalls[0].body).not.toHaveProperty("scope");
  });

  it("lists exactly the shared duration options on the Allow chevron and sends each tier duration-only", async () => {
    const user = userEvent.setup();
    const plain = makeApproval({ id: "appr-1", toolName: "git.push" });
    const expected = durationOptionsFor(plain);
    expect(expected).toHaveLength(7);

    // Menu shape: one render asserting the chevron lists every shared tier.
    {
      stubApi([plain]);
      const { unmount } = render(<NeedsActionQueue />);
      await user.click(
        await screen.findByRole("button", { name: /Allow options for git.push/i }),
      );
      const items = await screen.findAllByRole("menuitem");
      expect(items.map((item) => item.textContent)).toEqual(
        expected.map((option) => option.label),
      );
      unmount();
      vi.unstubAllGlobals();
    }

    // Payload shape: a fresh card per tier, so each pick is asserted against
    // its own decide write without the decided card leaving the list.
    for (const option of expected) {
      const { decideCalls } = stubApi([
        makeApproval({ id: `appr-${option.value}`, toolName: "git.push" }),
      ]);
      const { unmount } = render(<NeedsActionQueue />);
      await user.click(
        await screen.findByRole("button", { name: /Allow options for git.push/i }),
      );
      await user.click(screen.getByRole("menuitem", { name: option.label }));
      await waitFor(() => expect(decideCalls).toHaveLength(1));
      expect(decideCalls[0].body).toEqual({
        approved: true,
        duration: option.value,
        surface: "dashboard",
      });
      expect(decideCalls[0].body).not.toHaveProperty("scope");
      unmount();
      vi.unstubAllGlobals();
    }
  });

  it("lists exactly the three egress durations for an egress-parked card", async () => {
    const user = userEvent.setup();
    const egress = makeApproval({
      id: "egress-1",
      toolName: "api.request",
      egressHost: "unlisted.example.com",
    });
    const expected = durationOptionsFor(egress);
    expect(expected.map((option) => option.value)).toEqual([
      "thisTime",
      "forSession",
      "forever",
    ]);
    const { decideCalls } = stubApi([egress]);

    render(<NeedsActionQueue />);

    await user.click(
      await screen.findByRole("button", { name: /Allow options for api.request/i }),
    );
    const items = await screen.findAllByRole("menuitem");
    expect(items).toHaveLength(3);
    expect(items.map((item) => item.textContent)).toEqual(
      expected.map((option) => option.label),
    );

    await user.click(screen.getByRole("menuitem", { name: expected[1].label }));
    await waitFor(() => expect(decideCalls).toHaveLength(1));
    expect(decideCalls[0].body).toEqual({
      approved: true,
      duration: expected[1].value,
      surface: "dashboard",
    });
    expect(decideCalls[0].body).not.toHaveProperty("scope");
  });

  it("moves Allow chevron focus with arrows, Home, End, and Escape", async () => {
    const user = userEvent.setup();
    stubApi([makeApproval({ id: "appr-1", toolName: "git.push" })]);

    render(<NeedsActionQueue />);

    const chevron = await screen.findByRole("button", { name: /Allow options for git.push/i });
    await user.click(chevron);

    const items = await screen.findAllByRole("menuitem");
    expect(items).toHaveLength(7);
    expect(items[0]).toHaveFocus();

    await user.keyboard("{ArrowDown}");
    expect(items[1]).toHaveFocus();

    await user.keyboard("{ArrowUp}");
    expect(items[0]).toHaveFocus();

    await user.keyboard("{ArrowUp}");
    expect(items[items.length - 1]).toHaveFocus();

    await user.keyboard("{End}");
    expect(items[items.length - 1]).toHaveFocus();

    await user.keyboard("{Home}");
    expect(items[0]).toHaveFocus();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(chevron).toHaveFocus();
  });

  it("dismisses an open chevron menu on outside pointer down", async () => {
    const user = userEvent.setup();
    stubApi([makeApproval({ id: "appr-1", toolName: "git.push" })]);

    render(<NeedsActionQueue />);

    await user.click(
      await screen.findByRole("button", { name: /Allow options for git.push/i }),
    );
    expect(await screen.findByRole("menu")).toBeInTheDocument();

    // jsdom ships no PointerEvent constructor, so the outside pointer-down
    // travels as a MouseEvent carrying the same type; listeners dispatch on
    // type, never on event class.
    act(() => {
      document.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
    });
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("renders the derived target line truncated with the full value on title", async () => {
    const longTarget = `file-${"a".repeat(100)}.txt`;
    stubApi([
      makeApproval({
        id: "target-1",
        toolName: "files.read",
        displayTarget: longTarget,
        input: {
          toolName: "files.read",
          argumentsJSON: '{"path":"/other.txt"}',
          callID: "call-target-1",
        },
      }),
    ]);

    const { container } = render(<NeedsActionQueue />);

    await screen.findByRole("button", { name: /Approve once/i });
    const line = container.querySelector(".action-target-line") as HTMLElement;
    expect(line).not.toBeNull();
    expect(line).toHaveTextContent(/Target:/);
    const code = line.querySelector("code") as HTMLElement;
    expect(code).toHaveAttribute("title", longTarget);
    expect(code).toHaveTextContent(`${longTarget.slice(0, 80)}…`);
    // The target line renders above the arguments disclosure.
    const details = container.querySelector(".action-args-details") as HTMLElement;
    expect(details).not.toBeNull();
    expect(
      line.compareDocumentPosition(details) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("renders the legacy argument fallback target when no displayTarget is stored", async () => {
    stubApi([makeApproval({ id: "appr-1", toolName: "git.push" })]);

    const { container } = render(<NeedsActionQueue />);

    await screen.findByRole("button", { name: /Approve once/i });
    const code = container.querySelector(".action-target-line code") as HTMLElement;
    expect(code).not.toBeNull();
    expect(code).toHaveTextContent("origin/main");
    expect(code).toHaveAttribute("title", "origin/main");
  });

  it("labels the quick actions Approve once and Deny with the duration consequence visible", async () => {
    stubApi([makeApproval({ id: "appr-1", toolName: "git.push" })]);

    const { container } = render(<NeedsActionQueue />);

    await screen.findByRole("button", { name: /Approve once/i });
    expect(screen.getByRole("button", { name: /Deny git.push/i })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Allow options for git.push/i }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Deny options for git.push/i }),
    ).toBeInTheDocument();
    // The consequence line names the duration behavior and where scope lives.
    const note = container.querySelector(".action-card-once-note");
    expect(note).not.toBeNull();
    expect(note).toHaveTextContent(/Duration applies to this target only/i);
    expect(note).toHaveTextContent(/Scope editing lives in the Inbox/i);
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
    expect(decideCalls[0].body).toEqual({ approved: true, duration: "thisTime", surface: "dashboard" });
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
    expect(decideCalls[0].body).toEqual({ approved: false, duration: "thisTime", surface: "dashboard" });
  });

  it("renders a filed system notice as the shared surfacing-only card with its mapped remedy", async () => {
    const user = userEvent.setup();
    const { fetchCalls, decideCalls } = stubApi([
      makeApproval({
        id: "notice-1",
        toolName: "sovereign.mismatch",
        description: "Sovereign ceremony could not verify history.",
        sessionID: null,
      }),
    ]);

    render(<NeedsActionQueue />);

    // The notice mounts the shared card beside the queue's approval cards.
    expect(await screen.findByTestId("system-notice-notice-1")).toBeInTheDocument();
    expect(screen.getByTestId("system-notice-chip-notice-1")).toBeInTheDocument();
    // Surfacing-only: no approve or deny control and no duration picker ride
    // the notice, and its whole action is the mapped remedy.
    expect(screen.queryByRole("button", { name: /Approve once/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /Deny/i })).toBeNull();
    expect(screen.queryByRole("combobox")).toBeNull();
    expect(
      screen.getByRole("button", { name: "Re-baseline & re-verify" }),
    ).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Re-baseline & re-verify" }));
    // The one ceremony POST is the whole action; the remedy never rides a
    // decision call, and the queue refetches only through its own onRemedy.
    await waitFor(() =>
      expect(fetchCalls).toContain("POST /health/sovereign/rebaseline"),
    );
    expect(decideCalls).toHaveLength(0);
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

  it("renders the scheduled-sends group below the approval cards ordered by fire time ascending", async () => {
    const now = Date.now();
    stubApi(
      [makeApproval({ id: "appr-1", toolName: "git.push" })],
      [],
      [
        makeSend({
          id: "send-later",
          recipient: "later@example.com",
          fireAt: new Date(now + 86_400_000).toISOString(),
        }),
        makeSend({
          id: "send-sooner",
          channel: "messages",
          recipient: "+15551234567",
          subject: "Reminder",
          fireAt: new Date(now + 3_600_000).toISOString(),
        }),
      ],
    );

    const { container } = render(<NeedsActionQueue />);

    const group = await screen.findByRole("region", { name: /Scheduled sends/i });
    expect(group).toBeInTheDocument();
    // The group lands after the approval cards, never interleaved with them.
    const approvalCard = container.querySelector(".needs-action-list .action-card") as HTMLElement;
    expect(
      approvalCard.compareDocumentPosition(group) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
    // Fire-time ascending: the sooner send leads regardless of payload order.
    const recipients = Array.from(
      group.querySelectorAll(".scheduled-send-card .tool-name-badge"),
    ).map((node) => node.textContent ?? "");
    expect(recipients).toEqual(["+15551234567", "later@example.com"]);
    // Every send card names its channel, its recipient, and its fire time with
    // both the local rendering and the relative countdown.
    expect(within(group).getByText("MESSAGES")).toBeInTheDocument();
    expect(within(group).getByText("EMAIL")).toBeInTheDocument();
    expect(within(group).getByText("Reminder")).toBeInTheDocument();
    expect(group.querySelectorAll(".send-fire-time")).toHaveLength(2);
    expect(group.querySelectorAll(".send-fire-relative")).toHaveLength(2);
    // Each booked send renders its own countdown, so the relative label is
    // asserted across every card rather than as one shared text node.
    expect(within(group).getAllByText(/in \d+[smhd]/)).toHaveLength(2);
  });

  it("gives every send card its own Cancel and no approve, deny, duration, or edit control", async () => {
    stubApi(
      [],
      [],
      [
        makeSend({ id: "send-1", recipient: "ops@example.com" }),
        makeSend({ id: "send-2", recipient: "team@example.com" }),
      ],
    );

    const { container } = render(<NeedsActionQueue />);

    const group = await screen.findByRole("region", { name: /Scheduled sends/i });
    expect(
      within(group).getAllByRole("button", { name: /Cancel scheduled send to/i }),
    ).toHaveLength(2);
    // Monitoring only: no approval semantics ride along on a send card.
    expect(within(group).queryByRole("button", { name: /Approve|Deny/i })).toBeNull();
    expect(within(group).queryByRole("button", { name: /Edit/i })).toBeNull();
    expect(within(group).queryByRole("combobox")).toBeNull();
    expect(within(group).queryByRole("checkbox")).toBeNull();
    const cards = container.querySelectorAll(".scheduled-send-card");
    for (const card of Array.from(cards)) {
      expect(card.querySelector("details")).toBeNull();
    }
    // Send cards never route to the Approvals Inbox; the group owns one Manage
    // shortcut to the Schedules surface instead.
    expect(within(group).queryByRole("link", { name: /Open in Inbox/i })).toBeNull();
  });

  it("cancels a scheduled send with DELETE, refetches, and notifies", async () => {
    const user = userEvent.setup();
    const onActionDecided = vi.fn();
    const { cancelCalls, fetchCalls } = stubApi(
      [],
      [],
      [makeSend({ id: "send-1", recipient: "ops@example.com" })],
    );

    render(<NeedsActionQueue onActionDecided={onActionDecided} />);

    await user.click(
      await screen.findByRole("button", { name: /Cancel scheduled send to ops@example\.com/i }),
    );

    await waitFor(() => expect(cancelCalls).toHaveLength(1));
    expect(cancelCalls[0].method).toBe("DELETE");
    expect(cancelCalls[0].path).toBe("/scheduler/sends/send-1");
    // The cancel refetches the queue and notifies, and the settled row leaves
    // the monitoring group on the fresh snapshot.
    await waitFor(() =>
      expect(fetchCalls.filter((call) => call === "GET /scheduler/sends").length).toBeGreaterThan(1),
    );
    await waitFor(() => expect(onActionDecided).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(
        screen.queryByRole("button", { name: /Cancel scheduled send to/i }),
      ).toBeNull(),
    );
  });

  it("excludes scheduled sends from the attention count, badge, and subtitle", async () => {
    stubApi(
      [],
      [],
      [
        makeSend({ id: "send-1", recipient: "ops@example.com" }),
        makeSend({ id: "send-2", recipient: "team@example.com" }),
      ],
    );

    const { container, unmount } = render(<NeedsActionQueue />);

    await screen.findByRole("region", { name: /Scheduled sends/i });
    // Two booked sends move nothing: no badge, and the subtitle keeps reading
    // as no pending decisions.
    expect(container.querySelector(".dashboard-count-badge")).toBeNull();
    expect(screen.getByText("No pending decisions")).toBeInTheDocument();

    // With approvals present the badge counts approvals alone.
    unmount();
    vi.unstubAllGlobals();
    stubApi(
      [
        makeApproval({ id: "appr-1", toolName: "git.push" }),
        makeApproval({ id: "appr-2", toolName: "email.send" }),
      ],
      [],
      [makeSend({ id: "send-1", recipient: "ops@example.com" })],
    );
    const { container: withApprovals } = render(<NeedsActionQueue />);
    await screen.findByRole("region", { name: /Scheduled sends/i });
    expect(withApprovals.querySelector(".dashboard-count-badge")).toHaveTextContent("2");
  });

  it("shows the all-clear card only when approvals, goals, and sends are all empty", async () => {
    stubApi([], [], []);
    const { unmount } = render(<NeedsActionQueue />);
    expect(await screen.findByText("All Caught Up")).toBeInTheDocument();
    unmount();
    vi.unstubAllGlobals();

    // Sends alone suppress the all-clear without joining the count.
    stubApi([], [], [makeSend({ id: "send-1", recipient: "ops@example.com" })]);
    const sendsOnly = render(<NeedsActionQueue />);
    await screen.findByRole("region", { name: /Scheduled sends/i });
    expect(screen.queryByText("All Caught Up")).toBeNull();
    sendsOnly.unmount();
    vi.unstubAllGlobals();

    // Approvals alone suppress the all-clear.
    stubApi([makeApproval({ id: "appr-1", toolName: "git.push" })], [], []);
    const approvalsOnly = render(<NeedsActionQueue />);
    await screen.findByRole("button", { name: /Approve once/i });
    expect(screen.queryByText("All Caught Up")).toBeNull();
    approvalsOnly.unmount();
    vi.unstubAllGlobals();

    // Blocked goals alone suppress the all-clear.
    stubApi([], [makeGoal()], []);
    const goalsOnly = render(<NeedsActionQueue />);
    await screen.findByText("Develop Crypto Trading Plan");
    expect(screen.queryByText("All Caught Up")).toBeNull();
    goalsOnly.unmount();
  });

  it("routes Manage to the schedules surface through onOpenSchedules", async () => {
    const user = userEvent.setup();
    const onOpenSchedules = vi.fn();
    stubApi([], [], [makeSend({ id: "send-1", recipient: "ops@example.com" })]);

    render(<NeedsActionQueue onOpenSchedules={onOpenSchedules} />);

    await user.click(await screen.findByRole("button", { name: /Manage/i }));
    expect(onOpenSchedules).toHaveBeenCalledTimes(1);
  });

  it("renders approvals when the scheduled-sends endpoint fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        const method = (init?.method ?? "GET").toUpperCase();
        if (path === "/scheduler/sends") {
          throw new Error("sends down");
        }
        if (path.startsWith("/approvals") && method === "GET") {
          const approvals = [makeApproval({ id: "appr-1", toolName: "git.push" })];
          return jsonResponse({ approvals, count: approvals.length });
        }
        if (path.startsWith("/goals") && method === "GET") {
          return jsonResponse({ goals: [], count: 0 });
        }
        return jsonResponse({});
      }),
    );

    render(<NeedsActionQueue />);

    await screen.findByRole("button", { name: /Approve once/i });
    expect(screen.queryByRole("region", { name: /Scheduled sends/i })).toBeNull();
    expect(screen.queryByText("All Caught Up")).toBeNull();
  });

  it("hides the scheduled-sends group while showing only settled sends", async () => {
    stubApi(
      [],
      [],
      [
        makeSend({ id: "send-sent", status: "sent", recipient: "ops@example.com" }),
        makeSend({ id: "send-cancelled", status: "cancelled", recipient: "team@example.com" }),
        makeSend({ id: "send-failed", status: "failed", recipient: "pager@example.com" }),
      ],
    );

    render(<NeedsActionQueue />);

    await screen.findByText("All Caught Up");
    expect(screen.queryByRole("region", { name: /Scheduled sends/i })).toBeNull();
  });
});
