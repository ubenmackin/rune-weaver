// Rune Weaver Dashboard — Misfire policy normalization and manager card rendering tests.

import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { normalizeSchedulerJob, type SchedulerJob } from "../api";
import SchedulerManager from "./SchedulerManager";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

function makeJob(overrides: Record<string, unknown> = {}) {
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

describe("Scheduler misfire policy UI and normalization", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("normalizes missing or strict values to strict and preserves catch_up across casings", () => {
    const omitted = normalizeSchedulerJob(makeJob() as unknown as SchedulerJob);
    expect(omitted.misfirePolicy).toBe("strict");

    const snake = normalizeSchedulerJob(
      makeJob({ misfire_policy: "catch_up" }) as unknown as SchedulerJob,
    );
    expect(snake.misfirePolicy).toBe("catch_up");

    const camel = normalizeSchedulerJob(
      makeJob({ misfirePolicy: "catch_up" }) as unknown as SchedulerJob,
    );
    expect(camel.misfirePolicy).toBe("catch_up");
  });

  it("displays catch-up detail only on cron jobs configured with catch_up", async () => {
    vi.stubGlobal("WebSocket", createMockWebSocket(createMockWebSocketCapture()));
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/settings") return jsonResponse({});
        if (input.startsWith("/runs")) return jsonResponse({ runs: [], count: 0 });
        if (input === "/scheduler/sends") return jsonResponse({ sends: [], count: 0 });
        if (input === "/scheduler/jobs") {
          return jsonResponse({
            jobs: [
              makeJob({ id: "strict-1", name: "strict cron", misfirePolicy: "strict" }),
              makeJob({ id: "catch-1", name: "catchup cron", misfire_policy: "catch_up" }),
            ],
            count: 2,
          });
        }
        return jsonResponse({});
      }),
    );
    render(<SchedulerManager />);
    await waitFor(() => {
      expect(screen.getByText("catchup cron")).toBeInTheDocument();
    });
    expect(screen.getAllByText(/Catch up if missed/).length).toBe(1);
    expect(screen.getByText("strict cron")).toBeInTheDocument();
  });
});
