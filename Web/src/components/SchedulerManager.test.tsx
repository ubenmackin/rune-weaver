// Rune Weaver Dashboard — Component tests for SchedulerManager job creation, update, and manual run.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SchedulerManager from "./SchedulerManager";

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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("SchedulerManager", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("lists scheduled jobs with run history linkage hints", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        json({
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
          return json({ jobs: [], count: 0 });
        }
        bodies.push(String(init?.body ?? ""));
        return json(job());
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("0 jobs")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Job name"), "morning digest");
    await user.type(screen.getByLabelText("Cron schedule"), "0 8 * * *");
    await user.type(screen.getByLabelText("Job prompt"), "Summarize mail");
    await user.click(screen.getByRole("button", { name: "Create job" }));
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
          return json({ jobs: [], count: 0 });
        }
        bodies.push(String(init?.body ?? ""));
        return json(
          job({
            id: "44444444-4444-4444-4444-444444444444",
            name: "mail watcher",
            schedule: "",
            prompt: "Summarize arrivals",
            pollAccount: "icloud",
            pollIntervalSeconds: 300,
          }),
        );
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("0 jobs")).toBeInTheDocument();
    });
    await user.type(screen.getByLabelText("Job name"), "mail watcher");
    await user.type(screen.getByLabelText("Job prompt"), "Summarize arrivals");
    await user.type(screen.getByLabelText("Poll account"), "icloud");
    await user.type(
      screen.getByLabelText("Poll interval seconds"),
      "300",
    );
    await user.click(screen.getByRole("button", { name: "Create job" }));
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
          return json({ jobs: [job()], count: 1 });
        }
        seen.push({ path: input, body: String(init?.body ?? "") });
        return json(job({ enabled: false }));
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

  it("runs a job now and deletes it", async () => {
    const user = userEvent.setup();
    const calls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        calls.push(`${init?.method ?? "GET"} ${input}`);
        if (input === "/scheduler/jobs" && !init?.method) {
          return json({ jobs: [job()], count: 1 });
        }
        if (input.endsWith("/run")) {
          return json({
            text: "digest done",
            sessionID: job().id,
            toolActions: [],
          });
        }
        if (init?.method === "DELETE") {
          return new Response(null, { status: 204 });
        }
        return json(job());
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
    await waitFor(() => {
      expect(screen.getByText(/No scheduled jobs yet/)).toBeInTheDocument();
    });
  });

  it("shows an empty state when no jobs exist", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => json({ jobs: [], count: 0 })),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText(/No scheduled jobs yet/)).toBeInTheDocument();
    });
  });
});
