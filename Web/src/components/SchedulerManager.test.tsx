// Rune Weaver Dashboard — Component tests for SchedulerManager job creation, update, and manual run.

import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SchedulerManager from "./SchedulerManager";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

function job(overrides: Record<string, unknown> = {}) {
  return {
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
    ...overrides,
  };
}

// The Schedules surface reads booked sends on mount beside the jobs list, so
// the jobs-focused mocks answer that read here instead of letting it fall
// through to a write recorder or an unrelated payload.
const EMPTY_SENDS_RESPONSE = { sends: [], count: 0 };

describe("SchedulerManager", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("lists scheduled jobs with run history linkage hints", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({
          jobs: [
            job(),
            job({
              id: "44444444-4444-4444-4444-444444444444",
              name: "mail watcher",
              schedule: "",
              prompt: "Summarize arrivals",
              pollAccount: "icloud",
              pollQuery: "from:alerts",
              pollMailbox: "INBOX",
              pollIntervalSeconds: 300,
            }),
          ],
          count: 2,
        }),
      ),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    expect(screen.getByText("mail watcher")).toBeInTheDocument();
    expect(
      screen.getByRole("tab", { name: "Automated jobs (2)" }),
    ).toBeInTheDocument();
    expect(screen.getByText(/watches icloud/)).toBeInTheDocument();
    expect(
      screen.getAllByRole("button", { name: "Run now" }).length,
    ).toBeGreaterThan(0);
  });

  it("creates a job with name, cron schedule, and prompt", async () => {
    const user = userEvent.setup();
    const bodies: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          return jsonResponse(EMPTY_SENDS_RESPONSE);
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        bodies.push(String(init?.body ?? ""));
        return jsonResponse(job());
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Automated jobs (0)" }),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Create Schedule" }));
    await user.type(screen.getByLabelText("Job Name"), "morning digest");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    // Step 2: default preset is daily 8am ("0 8 * * *")
    await user.click(screen.getByRole("button", { name: "Continue" }));
    // Step 3: prompt
    await user.type(
      screen.getByLabelText("Agent Task Instructions"),
      "Summarize mail",
    );
    await user.click(screen.getByRole("button", { name: "Continue" }));
    // Step 4: confirm
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    expect(JSON.parse(bodies[0])).toMatchObject({
      name: "morning digest",
      schedule: "0 8 * * *",
      prompt: "Summarize mail",
    });
  });

  it("creates a poll-only event-rule job", async () => {
    const user = userEvent.setup();
    const bodies: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({ emailAccounts: [{ name: "icloud", type: "imap", host: "mail.example.com", port: 993, username: "user" }] });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          return jsonResponse(EMPTY_SENDS_RESPONSE);
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input.startsWith("/email/accounts/") && input.endsWith("/mailboxes") && !init?.method) return jsonResponse({ mailboxes: ["INBOX"], delimiter: "/" });
        bodies.push(String(init?.body ?? ""));
        return jsonResponse(
          job({
            name: "mail watcher",
            schedule: "",
            pollAccount: "icloud",
            pollQuery: "from:alerts",
            pollMailbox: "INBOX",
            pollIntervalSeconds: 300,
          }),
        );
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Automated jobs (0)" }),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Create Schedule" }));
    await user.type(screen.getByLabelText("Job Name"), "mail watcher");
    await user.click(screen.getByText("Email Event Watcher"));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    await screen.findByText("Configure Email Watcher");
    await user.selectOptions(screen.getByLabelText("Mail Account"), "icloud");
    await waitFor(() => {
      expect(within(screen.getByLabelText("Mailbox") as HTMLElement).getAllByRole("option").map((o) => (o as HTMLOptionElement).value)).toContain("INBOX");
    });
    await user.selectOptions(screen.getByLabelText("Mailbox"), "INBOX");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    // Step 3: prompt
    await user.type(
      screen.getByLabelText("Agent Task Instructions"),
      "Summarize arrivals",
    );
    await user.click(screen.getByRole("button", { name: "Continue" }));
    // Step 4: confirm
    await user.click(screen.getByRole("button", { name: "Save Schedule" }));
    await waitFor(() => {
      expect(screen.getByText("mail watcher")).toBeInTheDocument();
    });
    expect(JSON.parse(bodies[0])).toMatchObject({
      name: "mail watcher",
      pollAccount: "icloud",
      pollIntervalSeconds: 300,
    });
  });

  it("disables an enabled job without touching config files", async () => {
    const user = userEvent.setup();
    const seen: Array<{ path: string; body: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          return jsonResponse(EMPTY_SENDS_RESPONSE);
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        seen.push({ path: input, body: String(init?.body ?? "") });
        return jsonResponse(job({ enabled: false }));
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Disable" }));
    await waitFor(() => {
      expect(screen.getByText("disabled")).toBeInTheDocument();
    });
    expect(seen[0].path).toBe(
      "/scheduler/jobs/33333333-3333-3333-3333-333333333333",
    );
    expect(JSON.parse(seen[0].body)).toMatchObject({ enabled: false });
  });

  it("runs a job now and deletes it through the shared modal", async () => {
    const user = userEvent.setup();
    const calls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        calls.push(`${init?.method ?? "GET"} ${input}`);
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input.endsWith("/run")) {
          return jsonResponse({
            text: "digest done",
            sessionID: job().id,
            toolActions: [],
          });
        }
        if (init?.method === "DELETE") {
          return new Response(null, { status: 204 });
        }
        return jsonResponse(job());
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Run now" }));
    await waitFor(() => {
      expect(screen.getByText(/Ran "morning digest"/)).toBeInTheDocument();
    });
    expect(
      calls.includes(
        "POST /scheduler/jobs/33333333-3333-3333-3333-333333333333/run",
      ),
    ).toBe(true);
    await user.click(screen.getByRole("button", { name: "Delete" }));
    // Shared Modal portals the confirmation with the compact delete styling.
    const dialog = screen.getByRole("dialog", { name: "Confirm delete schedule" });
    expect(dialog).toBeInTheDocument();
    expect(document.querySelector(".session-delete-modal")).not.toBeNull();
    // Keep dismisses without a request.
    await user.click(screen.getByRole("button", { name: "Keep" }));
    expect(
      screen.queryByRole("dialog", { name: "Confirm delete schedule" }),
    ).not.toBeInTheDocument();
    expect(screen.getByText("morning digest")).toBeInTheDocument();
    expect(calls.some((call) => call.startsWith("DELETE"))).toBe(false);
    // Delete confirms the persisted removal.
    await user.click(screen.getByRole("button", { name: "Delete" }));
    await user.click(screen.getByRole("button", { name: "Confirm delete" }));
    await waitFor(() => {
      expect(screen.getByText(/No scheduled jobs yet/)).toBeInTheDocument();
    });
  });

  it("shows an empty state when no jobs exist", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ jobs: [], count: 0 })),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText(/No scheduled jobs yet/)).toBeInTheDocument();
    });
  });

  it("detects in-progress run on mount and displays Running… state", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({
            runs: [
              {
                id: "55555555-5555-5555-5555-555555555555",
                kind: "scheduler",
                status: "running",
                message: "Morning digest running",
                jobID: "33333333-3333-3333-3333-333333333333",
                timestamp: new Date().toISOString(),
              },
            ],
            count: 1,
          });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    // The Run Now button should display "Running…" and be disabled
    await waitFor(() => {
      const runBtn = screen.getByRole("button", { name: "Run now" });
      expect(runBtn).toHaveTextContent("Running…");
      expect(runBtn).toBeDisabled();
    });
  });

  it("shows the live scheduler default in the header from GET /settings", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({ schedulerMaxToolIterations: 40 });
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByText(
          "Each run uses 40 consecutive tool rounds by default (per-job override below, range 1-100). Budget-exceeded runs synthesize a summary; only jobs with on_tool_limit set to park request continuation.",
        ),
      ).toBeInTheDocument();
    });
    expect(screen.getByText("Default (40)")).toBeInTheDocument();
  });

  it("shows per-job override versus inherited budget badges", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({ schedulerMaxToolIterations: 33 });
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({
            jobs: [
              job({
                id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                name: "override job",
                maxToolIterations: 50,
              }),
              job({
                id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                name: "inherited job",
                maxToolIterations: null,
              }),
            ],
            count: 2,
          });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("override job")).toBeInTheDocument();
    });
    expect(screen.getByText("inherited job")).toBeInTheDocument();
    expect(screen.getByText("50 rounds")).toBeInTheDocument();
    expect(screen.getByText("Default (33)")).toBeInTheDocument();
  });

  it("still renders the job list when the settings read fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          throw new Error("settings unreachable");
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    // Settings failure falls back to the engine default so the header and the
    // inherited badge stay consistent instead of hiding one side.
    expect(
      screen.getByText(
        "Each run uses 25 consecutive tool rounds by default (per-job override below, range 1-100). Budget-exceeded runs synthesize a summary; only jobs with on_tool_limit set to park request continuation.",
      ),
    ).toBeInTheDocument();
    expect(screen.getByText("Default (25)")).toBeInTheDocument();
  });
});

describe("SchedulerManager scheduled sends", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  function send(overrides: Record<string, unknown> = {}) {
    return {
      id: "66666666-6666-6666-6666-666666666666",
      channel: "email",
      status: "queued",
      account: null,
      recipient: "sam@example.com",
      subject: "Hello",
      bodyText: "hi",
      bodyHtml: null,
      fireAt: new Date(Date.now() + 3_600_000).toISOString(),
      createdAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(),
      settledAt: null,
      failureReason: null,
      ...overrides,
    };
  }

  function stubSchedulerFetch(
    sendsPayload: unknown[] | (() => unknown[]),
    calls: string[] = [],
  ) {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          const sends =
            typeof sendsPayload === "function" ? sendsPayload() : sendsPayload;
          return jsonResponse({ sends, count: sends.length });
        }
        if (
          input.startsWith("/scheduler/sends/") &&
          init?.method === "DELETE"
        ) {
          calls.push(`DELETE ${input}`);
          return jsonResponse(send({ status: "cancelled" }));
        }
        return jsonResponse({});
      }),
    );
    return calls;
  }

  function installSocket() {
    const capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
    return capture;
  }

  it("lists pending sends earliest first with channel, recipient, fire time, and status", async () => {
    installSocket();
    stubSchedulerFetch([
      send({
        id: "77777777-7777-7777-7777-777777777777",
        recipient: "later@example.com",
        channel: "messages",
        status: "sending",
        fireAt: new Date(Date.now() + 7_200_000).toISOString(),
      }),
      send({
        id: "66666666-6666-6666-6666-666666666666",
        recipient: "sam@example.com",
        channel: "email",
        status: "queued",
        fireAt: new Date(Date.now() + 3_600_000).toISOString(),
      }),
    ]);
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Scheduled sends (2)" }),
      ).toBeInTheDocument();
    });
    expect(
      screen.getByRole("tab", { name: "Automated jobs (0)" }),
    ).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "Scheduled sends (2)" }));
    await waitFor(() => {
      expect(screen.getByText("sam@example.com")).toBeInTheDocument();
    });
    expect(screen.getByText("later@example.com")).toBeInTheDocument();
    expect(screen.getByText("Email")).toBeInTheDocument();
    expect(screen.getByText("Messages")).toBeInTheDocument();
    expect(screen.getByText("queued")).toBeInTheDocument();
    expect(screen.getByText("sending")).toBeInTheDocument();
    const rows = screen.getAllByText(/@example\.com/);
    expect(rows[0]).toHaveTextContent("sam@example.com");
    expect(rows[1]).toHaveTextContent("later@example.com");
  });

  it("drops terminal sends from the list and shows the empty state", async () => {
    installSocket();
    stubSchedulerFetch([
      send({
        id: "88888888-8888-8888-8888-888888888888",
        recipient: "gone@example.com",
        status: "sent",
      }),
      send({
        id: "99999999-9999-9999-9999-999999999999",
        recipient: "bounced@example.com",
        status: "failed",
      }),
      send({
        id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        recipient: "stopped@example.com",
        status: "cancelled",
      }),
    ]);
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Scheduled sends (0)" }),
      ).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: "Scheduled sends (0)" }));
    await waitFor(() => {
      expect(screen.getByText("No scheduled sends")).toBeInTheDocument();
    });
    expect(screen.queryByText("gone@example.com")).not.toBeInTheDocument();
    expect(screen.queryByText("bounced@example.com")).not.toBeInTheDocument();
    expect(screen.queryByText("stopped@example.com")).not.toBeInTheDocument();
  });

  it("cancels a send with one click, names it in the toast, and refetches", async () => {
    const user = userEvent.setup();
    installSocket();
    let cancelled = false;
    const calls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          const sends = cancelled ? [] : [send()];
          return jsonResponse({ sends, count: sends.length });
        }
        if (
          input === "/scheduler/sends/66666666-6666-6666-6666-666666666666" &&
          init?.method === "DELETE"
        ) {
          calls.push(`DELETE ${input}`);
          cancelled = true;
          return jsonResponse(send({ status: "cancelled" }));
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Scheduled sends (1)" }),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("tab", { name: "Scheduled sends (1)" }));
    await waitFor(() => {
      expect(screen.getByText("sam@example.com")).toBeInTheDocument();
    });
    await user.click(
      screen.getByRole("button", { name: "Cancel send to sam@example.com" }),
    );
    await waitFor(() => {
      expect(screen.getByText("Cancelled send to sam@example.com")).toBeInTheDocument();
    });
    expect(calls).toContain(
      "DELETE /scheduler/sends/66666666-6666-6666-6666-666666666666",
    );
    await waitFor(() => {
      expect(screen.getByText("No scheduled sends")).toBeInTheDocument();
    });
  });

  it("renders no Edit control and no booking entry point in the sends section", async () => {
    installSocket();
    stubSchedulerFetch([send()]);
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Scheduled sends (1)" }),
      ).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: "Scheduled sends (1)" }));
    await waitFor(() => {
      expect(screen.getByText("sam@example.com")).toBeInTheDocument();
    });
    const section = screen.getByLabelText("Scheduled sends");
    expect(
      within(section).queryByRole("button", { name: /edit/i }),
    ).not.toBeInTheDocument();
    expect(
      within(section).queryByRole("button", { name: /book/i }),
    ).not.toBeInTheDocument();
    expect(
      within(section).queryByRole("button", { name: /new send/i }),
    ).not.toBeInTheDocument();
    expect(
      within(section).queryByRole("button", { name: /schedule send/i }),
    ).not.toBeInTheDocument();
    expect(
      within(section).getByRole("button", { name: "Cancel send to sam@example.com" }),
    ).toBeInTheDocument();
  });

  it("refetches sends on scheduled_sends_changed frames, foreground returns, and socket reopen", async () => {
    const capture = installSocket();
    let sendsCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          sendsCalls += 1;
          return jsonResponse({ sends: [send()], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    const view = render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Scheduled sends (1)" }),
      ).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: "Scheduled sends (1)" }));
    await waitFor(() => {
      expect(screen.getByText("sam@example.com")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    const settledCalls = sendsCalls;
    expect(settledCalls).toBeGreaterThan(0);

    await dispatchFrameOrThrow(capture.onMessage, { type: "scheduled_sends_changed" });
    await waitFor(() => {
      expect(sendsCalls).toBeGreaterThan(settledCalls);
    });

    const afterFrameCalls = sendsCalls;
    const visibilitySpy = vi
      .spyOn(document, "visibilityState", "get")
      .mockReturnValue("visible");
    fireEvent(document, new Event("visibilitychange"));
    await waitFor(() => {
      expect(sendsCalls).toBeGreaterThan(afterFrameCalls);
    });
    visibilitySpy.mockRestore();

    const afterForegroundCalls = sendsCalls;
    view.unmount();
    resetSharedSocket();
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(sendsCalls).toBeGreaterThan(afterForegroundCalls);
    });
  });

  it("retains the sends list when a lifecycle refetch fails", async () => {
    const capture = installSocket();
    let shouldFail = false;
    let sendsCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          sendsCalls += 1;
          if (shouldFail) throw new Error("sends unreachable");
          return jsonResponse({ sends: [send()], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Scheduled sends (1)" }),
      ).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: "Scheduled sends (1)" }));
    await waitFor(() => {
      expect(screen.getByText("sam@example.com")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    const settledCalls = sendsCalls;
    shouldFail = true;
    await dispatchFrameOrThrow(capture.onMessage, { type: "scheduled_sends_changed" });
    await waitFor(() => {
      expect(sendsCalls).toBeGreaterThan(settledCalls);
    });
    // Settle the failed refetch inside act so retained rows assert quietly.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(screen.getByText("sam@example.com")).toBeInTheDocument();
  });

  it("switches between jobs and sends tabs with shared header actions", async () => {
    const user = userEvent.setup();
    installSocket();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          return jsonResponse({ sends: [send()], count: 1 });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: "Automated jobs (1)" }),
      ).toBeInTheDocument();
    });
    expect(
      screen.getByRole("tab", { name: "Scheduled sends (1)" }),
    ).toBeInTheDocument();
    // Jobs pane owns its tabpanel while sends stays unmounted.
    expect(screen.getByText("morning digest")).toBeInTheDocument();
    expect(screen.queryByText("sam@example.com")).not.toBeInTheDocument();
    expect(document.getElementById("panel-jobs")).not.toBeNull();
    expect(document.getElementById("panel-sends")).toBeNull();
    await user.click(screen.getByRole("tab", { name: "Scheduled sends (1)" }));
    await waitFor(() => {
      expect(screen.getByText("sam@example.com")).toBeInTheDocument();
    });
    expect(screen.queryByText("morning digest")).not.toBeInTheDocument();
    expect(document.getElementById("panel-sends")).not.toBeNull();
    expect(document.getElementById("panel-jobs")).toBeNull();
    // Shared header actions stay visible in both views with no standalone counts.
    // Live frames plus reopen and foreground resync are the only refresh
    // paths, so no manual Refresh control remains.
    expect(screen.queryByRole("button", { name: "Refresh" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Refresh/i })).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Create Schedule" }),
    ).toBeInTheDocument();
    expect(screen.queryByText("1 jobs")).not.toBeInTheDocument();
    expect(screen.queryByText("1 pending")).not.toBeInTheDocument();
    await user.click(screen.getByRole("tab", { name: "Automated jobs (1)" }));
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    expect(screen.queryByText("sam@example.com")).not.toBeInTheDocument();
  });

  it("refetches jobs on scheduler lifecycle frames", async () => {
    const capture = installSocket();
    let jobsCalls = 0;
    let sendsCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          jobsCalls += 1;
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          sendsCalls += 1;
          return jsonResponse(EMPTY_SENDS_RESPONSE);
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await waitFor(() => expect(jobsCalls).toBeGreaterThan(0));
    const settledJobs = jobsCalls;
    const settledSends = sendsCalls;

    // Each scheduler wake-up is type-only, so every matching frame refetches
    // the same GET pair without patching rows from the frame.
    await dispatchFrameOrThrow(capture.onMessage, { type: "scheduler_jobs_changed" });
    await waitFor(() => {
      expect(jobsCalls).toBeGreaterThan(settledJobs);
    });

    const afterJobsFrame = sendsCalls;
    await dispatchFrameOrThrow(capture.onMessage, { type: "scheduled_sends_changed" });
    await waitFor(() => {
      expect(sendsCalls).toBeGreaterThan(afterJobsFrame);
    });

    // A fired job's settlement advances its next due date, so run frames wake
    // the same joined refetch as scheduler frames; unknown types stay ignored.
    const afterSendsFrame = jobsCalls;
    await dispatchFrameOrThrow(capture.onMessage, { type: "run_started" });
    await waitFor(() => {
      expect(jobsCalls).toBeGreaterThan(afterSendsFrame);
    });

    const afterRunStarted = jobsCalls;
    await dispatchFrameOrThrow(capture.onMessage, { type: "run_completed" });
    await waitFor(() => {
      expect(jobsCalls).toBeGreaterThan(afterRunStarted);
    });
    expect(settledSends).toBeGreaterThanOrEqual(0);
  });

  it("refetches jobs on socket reopen and foreground return", async () => {
    const capture = installSocket();
    let jobsCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          jobsCalls += 1;
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          return jsonResponse(EMPTY_SENDS_RESPONSE);
        }
        return jsonResponse({});
      }),
    );
    const view = render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await waitFor(() => expect(jobsCalls).toBeGreaterThan(0));
    const settledCalls = jobsCalls;

    const visibilitySpy = vi
      .spyOn(document, "visibilityState", "get")
      .mockReturnValue("visible");
    fireEvent(document, new Event("visibilitychange"));
    await waitFor(() => {
      expect(jobsCalls).toBeGreaterThan(settledCalls);
    });
    visibilitySpy.mockRestore();

    const afterForegroundCalls = jobsCalls;
    view.unmount();
    resetSharedSocket();
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(jobsCalls).toBeGreaterThan(afterForegroundCalls);
    });
  });

  it("ignores unknown and unrelated frames without refetching", async () => {
    const capture = installSocket();
    let jobsCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        if (input === "/settings" && !init?.method) {
          return jsonResponse({});
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
        if (input === "/scheduler/jobs" && !init?.method) {
          jobsCalls += 1;
          return jsonResponse({ jobs: [job()], count: 1 });
        }
        if (input === "/scheduler/sends" && !init?.method) {
          return jsonResponse(EMPTY_SENDS_RESPONSE);
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("morning digest")).toBeInTheDocument();
    });
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await waitFor(() => expect(jobsCalls).toBeGreaterThan(0));
    // Drain the mount-plus-reopen coalesced refresh before snapshotting so
    // the ignored-frame assertion proves no new GET fires.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 300));
    });
    const settledCalls = jobsCalls;
    // Settings and goal pushes belong to other surfaces, so they leave the
    // schedules list still alongside truly unknown types.
    await dispatchFrameOrThrow(capture.onMessage, { type: "settings_changed" });
    await dispatchFrameOrThrow(capture.onMessage, {
      type: "goal_updated",
      goal: job(),
    });
    await dispatchFrameOrThrow(capture.onMessage, { type: "definitely_unknown_xyz" });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 300));
    });
    expect(jobsCalls).toBe(settledCalls);
  });
});
