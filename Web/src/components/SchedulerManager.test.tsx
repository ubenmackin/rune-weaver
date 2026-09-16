// Rune Weaver Dashboard — Component tests for SchedulerManager job creation, update, and manual run.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SchedulerManager from "./SchedulerManager";
import { jsonResponse } from "../test-utils/http";

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

describe("SchedulerManager", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
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
    expect(screen.getByText("2 jobs")).toBeInTheDocument();
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
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
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
      expect(screen.getByText("0 jobs")).toBeInTheDocument();
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
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [], count: 0 });
        }
        if (input.startsWith("/runs") && !init?.method) {
          return jsonResponse({ runs: [], count: 0 });
        }
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
      expect(screen.getByText("0 jobs")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Create Schedule" }));
    await user.type(screen.getByLabelText("Job Name"), "mail watcher");
    await user.click(screen.getByText("Email Event Watcher"));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    // Step 2: poll configuration (account defaults to icloud, interval defaults to 300)
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
        if (input === "/scheduler/jobs" && !init?.method) {
          return jsonResponse({ jobs: [job()], count: 1 });
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
});
