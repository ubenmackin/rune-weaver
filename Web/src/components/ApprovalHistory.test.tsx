// Rune Weaver Dashboard — Component tests for ApprovalHistory listing,
// filters, debounce settling, truncation, the two-step clear flow, and empty
// plus error states.

import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ApprovalHistory from "./ApprovalHistory";
import { jsonResponse } from "../test-utils/http";

function historyEntry(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    id: "entry-1",
    toolName: "email.send",
    scopeKind: "exactTarget",
    scopeData: "ops@example.com",
    allowed: true,
    duration: "thisTime",
    surface: "inbox",
    sessionID: "sess-a",
    displayTarget: "ops@example.com",
    decidedAt: new Date(Date.now() - 60_000).toISOString(),
    ...overrides,
  };
}

// Answers GET /approvals/history with the given entries while recording every
// request URL plus method so filter params and the DELETE gate stay assertable.
function stubHistory(
  entries: Record<string, unknown>[],
  onCall?: (url: string, init?: RequestInit) => void,
) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string, init?: RequestInit) => {
      const url = String(input);
      onCall?.(url, init);
      if (init?.method === "DELETE" && url === "/approvals/history") {
        return new Response(null, { status: 204 });
      }
      if (url.startsWith("/approvals/history")) {
        return jsonResponse({
          entries,
          count: entries.length,
        });
      }
      return jsonResponse({ entries: [], count: 0 });
    }),
  );
}

describe("ApprovalHistory", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    // A debounced timer must never leak a late commit into the next test.
    vi.useRealTimers();
  });

  it("renders every column with truncation plus full title and the session link", async () => {
    const longTarget = `file-${"a".repeat(100)}.txt`;
    stubHistory([
      historyEntry({
        id: "entry-allowed",
        toolName: "files.read",
        scopeKind: "exactTarget",
        scopeData: "/tmp/report.txt",
        allowed: true,
        duration: "forSession",
        surface: "chat",
        sessionID: "sess-chat",
        displayTarget: longTarget,
        decidedAt: new Date(Date.now() - 120_000).toISOString(),
      }),
      historyEntry({
        id: "entry-denied",
        toolName: "api.request",
        scopeKind: "domain",
        scopeData: "blocked.example.com",
        allowed: false,
        duration: "forever",
        surface: "dashboard",
        sessionID: null,
        displayTarget: null,
        decidedAt: new Date(Date.now() - 60_000).toISOString(),
      }),
    ]);
    render(<ApprovalHistory />);
    await waitFor(() => {
      expect(
        screen.getByTestId("approval-history-row-entry-allowed"),
      ).toBeInTheDocument();
    });
    const allowedRow = screen.getByTestId("approval-history-row-entry-allowed");
    expect(within(allowedRow).getByText("files.read")).toBeInTheDocument();
    expect(within(allowedRow).getByText("Allowed")).toBeInTheDocument();
    expect(within(allowedRow).getByText("forSession")).toBeInTheDocument();
    expect(within(allowedRow).getByText("chat")).toBeInTheDocument();
    expect(within(allowedRow).getByText("/tmp/report.txt")).toBeInTheDocument();
    // Long targets cut at 80 chars with an ellipsis while the title keeps the
    // full value for hover.
    const target = within(allowedRow).getByTitle(longTarget);
    expect(target).toHaveTextContent(`${longTarget.slice(0, 80)}…`);
    // Decided renders relative time with the absolute date on the title.
    expect(within(allowedRow).getByText(/ago|just now/)).toBeInTheDocument();
    // The session link rides along only when the row carries a session tag.
    const sessionLink = within(allowedRow).getByRole("link", {
      name: "Open session",
    });
    expect(sessionLink).toHaveAttribute("href", "#chat/sess-chat");
    const deniedRow = screen.getByTestId("approval-history-row-entry-denied");
    expect(within(deniedRow).getByText("Denied")).toBeInTheDocument();
    expect(
      within(deniedRow).getByText("blocked.example.com"),
    ).toBeInTheDocument();
    expect(
      within(deniedRow).queryByRole("link", { name: "Open session" }),
    ).not.toBeInTheDocument();
  });

  it("passes the tool and decision filters as query params", async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    stubHistory([historyEntry()], (url) => {
      seen.push(url);
    });
    render(<ApprovalHistory />);
    await waitFor(() => {
      expect(
        screen.getByTestId("approval-history-row-entry-1"),
      ).toBeInTheDocument();
    });
    expect(seen[0]).toBe("/approvals/history");
    // Selecting through the combobox fires a filtered read.
    fireEvent.change(screen.getByLabelText("Filter by decision"), {
      target: { value: "denied" },
    });
    await waitFor(() => {
      const filtered = seen.find((url) => url.includes("action=denied"));
      expect(filtered).toBeDefined();
    });
    await user.clear(screen.getByLabelText("Filter by tool"));
    await user.type(screen.getByLabelText("Filter by tool"), "email.send");
    await waitFor(() => {
      const filtered = seen.find((url) =>
        url.includes(`tool=${encodeURIComponent("email.send")}`),
      );
      expect(filtered).toBeDefined();
    });
    // Both filters combine on one request.
    const combined = seen[seen.length - 1];
    const parsed = new URL(combined, "http://localhost");
    expect(parsed.searchParams.get("tool")).toBe("email.send");
    expect(parsed.searchParams.get("action")).toBe("denied");
  });

  it("debounces tool typing into exactly one fetch after the input settles", async () => {
    vi.useFakeTimers();
    const seen: string[] = [];
    stubHistory([historyEntry()], (url) => {
      seen.push(url);
    });
    render(<ApprovalHistory />);
    // The mount read fires immediately, not behind the settle window.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(seen).toEqual(["/approvals/history"]);

    // A burst of keystrokes re-arms the settle timer on every change; reads
    // stay silent while the input is still moving.
    const input = screen.getByLabelText("Filter by tool");
    await act(async () => {
      fireEvent.change(input, { target: { value: "a" } });
      await vi.advanceTimersByTimeAsync(100);
      fireEvent.change(input, { target: { value: "api" } });
      await vi.advanceTimersByTimeAsync(100);
      fireEvent.change(input, { target: { value: "api.request" } });
      await vi.advanceTimersByTimeAsync(299);
    });
    expect(seen).toEqual(["/approvals/history"]);

    // Once typing settles, exactly one filtered read fires — one per settle,
    // never one per keystroke.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(seen).toEqual([
      "/approvals/history",
      `/approvals/history?tool=${encodeURIComponent("api.request")}`,
    ]);
  });

  it("refetches immediately through the Refresh button while a debounce is pending", async () => {
    vi.useFakeTimers();
    const seen: string[] = [];
    stubHistory([historyEntry()], (url) => {
      seen.push(url);
    });
    render(<ApprovalHistory />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    fireEvent.change(screen.getByLabelText("Filter by tool"), {
      target: { value: "api.request" },
    });
    // Refresh bypasses the settle window and reads the current input value.
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(seen).toEqual([
      "/approvals/history",
      `/approvals/history?tool=${encodeURIComponent("api.request")}`,
    ]);
    // The pending debounce commits the same values, so it never doubles the
    // read after Refresh already fetched them.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(300);
    });
    expect(seen).toHaveLength(2);
  });

  it("drops a stale response that lands after a newer filtered read", async () => {
    // The mount read is held pending so it can land late — after a newer
    // committed-filter read has already rendered its rows.
    let releaseStale: ((response: Response) => void) | null = null;
    const staleResponse = new Promise<Response>((resolve) => {
      releaseStale = resolve;
    });
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        seen.push(url);
        if (seen.length === 1) return staleResponse;
        return jsonResponse({
          entries: [historyEntry({ id: "entry-new", toolName: "api.request" })],
          count: 1,
        });
      }),
    );
    render(<ApprovalHistory />);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(seen).toEqual(["/approvals/history"]);
    expect(
      screen.queryByTestId("approval-history-row-entry-1"),
    ).not.toBeInTheDocument();

    // Committing a new filter supersedes the still-pending mount read.
    fireEvent.change(screen.getByLabelText("Filter by tool"), {
      target: { value: "api.request" },
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 350));
    });
    expect(seen).toEqual([
      "/approvals/history",
      `/approvals/history?tool=${encodeURIComponent("api.request")}`,
    ]);
    expect(
      screen.getByTestId("approval-history-row-entry-new"),
    ).toBeInTheDocument();

    // The stale mount response lands last: it must not overwrite the rows
    // that match the committed filter, and it must not touch the loading
    // state the newer request owns.
    await act(async () => {
      releaseStale?.(
        jsonResponse({
          entries: [
            historyEntry({ id: "entry-stale", toolName: "email.send" }),
          ],
          count: 1,
        }),
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(
      screen.queryByTestId("approval-history-row-entry-stale"),
    ).not.toBeInTheDocument();
    expect(
      screen.getByTestId("approval-history-row-entry-new"),
    ).toBeInTheDocument();
    expect(seen).toHaveLength(2);
  });

  it("gates the DELETE behind confirmation and refetches afterwards", async () => {
    const user = userEvent.setup();
    const calls: Array<{ url: string; method?: string }> = [];
    stubHistory([historyEntry()], (url, init) => {
      calls.push({ url, method: init?.method });
    });
    render(<ApprovalHistory />);
    await waitFor(() => {
      expect(
        screen.getByTestId("approval-history-row-entry-1"),
      ).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Clear logs" }));
    expect(
      screen.getByRole("dialog", { name: "Clear decision history" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("Clearing will permanently delete all decision history."),
    ).toBeInTheDocument();
    // Opening the modal alone sends no DELETE.
    expect(
      calls.filter((call) => call.method === "DELETE"),
    ).toHaveLength(0);
    await user.click(
      screen.getByRole("button", { name: "Confirm clear all decisions" }),
    );
    await waitFor(() => {
      expect(
        calls.filter(
          (call) =>
            call.method === "DELETE" && call.url === "/approvals/history",
        ),
      ).toHaveLength(1);
    });
    // The confirm closes the dialog and refetches the list.
    await waitFor(() => {
      expect(
        screen.queryByRole("dialog", { name: "Clear decision history" }),
      ).not.toBeInTheDocument();
    });
    expect(
      calls.filter((call) => call.url.startsWith("/approvals/history"))
        .length,
    ).toBeGreaterThan(2);
  });

  it("renders the empty state when no decisions are recorded", async () => {
    stubHistory([]);
    render(<ApprovalHistory />);
    await waitFor(() => {
      expect(screen.getByText("No recorded decisions.")).toBeInTheDocument();
    });
  });

  it("renders the existing error pattern when the list fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("boom");
      }),
    );
    render(<ApprovalHistory />);
    await waitFor(() => {
      expect(screen.getByText("No recorded decisions.")).toBeInTheDocument();
    });
    const error = document.querySelector("p.error");
    expect(error).not.toBeNull();
  });
});
