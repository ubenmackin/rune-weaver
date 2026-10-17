// Rune Weaver Dashboard — Tests for the shared surfacing-only system-notice card.

import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import SystemNoticeCard from "./SystemNoticeCard";
import type { PermissionRequest } from "../api";
import { jsonResponse } from "../test-utils/http";

function makeNotice(
  overrides: Partial<PermissionRequest> & Pick<PermissionRequest, "id" | "toolName">,
): PermissionRequest {
  return {
    description: `${overrides.toolName} detected a problem requiring a mapped remedy.`,
    input: {
      toolName: overrides.toolName,
      argumentsJSON: "{}",
      callID: `call-${overrides.id}`,
    },
    suggestedDurations: ["thisTime"],
    sessionID: null,
    ...overrides,
  };
}

interface StubbedApi {
  fetchCalls: string[];
}

// Stubs the engine surface: the re-baseline POST answers a passing ceremony
// while every call is recorded so fetch-and-discard reads stay assertable.
function stubApi(options: { rebaselineStatus?: number } = {}): StubbedApi {
  const fetchCalls: string[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      fetchCalls.push(`${method} ${path}`);
      if (path === "/health/sovereign/rebaseline" && method === "POST") {
        return jsonResponse(
          { outcome: "verified", primaryTip: "tip-1", episodeCount: 3, decision: "rebaseline" },
          options.rebaselineStatus ?? 200,
        );
      }
      return jsonResponse({});
    }),
  );
  return { fetchCalls };
}

describe("SystemNoticeCard", () => {
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders the notice identity and narrative with no decision controls", () => {
    render(
      <SystemNoticeCard
        request={makeNotice({ id: "n-1", toolName: "sovereign.mismatch" })}
      />,
    );
    expect(screen.getByTestId("system-notice-n-1")).toBeInTheDocument();
    expect(screen.getByText("sovereign.mismatch")).toBeInTheDocument();
    expect(screen.getByTestId("system-notice-chip-n-1")).toHaveTextContent("System notice");
    // Surfacing-only: the inbox is a channel, not a second gate, so no
    // approve, deny, duration, or scope control rides the card.
    expect(screen.queryByRole("button", { name: /allow/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /deny/i })).toBeNull();
    expect(screen.queryByRole("combobox")).toBeNull();
    expect(screen.queryByRole("radio")).toBeNull();
  });

  it("maps sovereign.mismatch to the re-baseline ceremony remedy", async () => {
    const user = userEvent.setup();
    const { fetchCalls } = stubApi();
    const onRemedy = vi.fn();
    render(
      <SystemNoticeCard
        request={makeNotice({ id: "n-2", toolName: "sovereign.mismatch" })}
        onRemedy={onRemedy}
      />,
    );
    await user.click(screen.getByRole("button", { name: "Re-baseline & re-verify" }));
    // The single ceremony POST is the whole action: settlement drops the card
    // through the decided frame plus the owning surface's refetch, so the
    // card performs no fetch-and-discard reads of its own.
    await waitFor(() => expect(onRemedy).toHaveBeenCalledWith(expect.objectContaining({ id: "n-2" })));
    expect(fetchCalls).toEqual(["POST /health/sovereign/rebaseline"]);
    // The card stays mounted with the busy state cleared; only the owning
    // surface's refetch removes the settled notice.
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Re-baseline & re-verify" })).toBeEnabled(),
    );
  });

  it("maps security.probe to the Open Policy deep link", () => {
    stubApi();
    render(
      <SystemNoticeCard
        request={makeNotice({ id: "n-3", toolName: "security.probe" })}
      />,
    );
    const link = screen.getByRole("link", { name: /open policy/i });
    expect(link).toHaveAttribute("href", "#settings/access");
    expect(screen.queryByRole("button")).toBeNull();
  });

  it("renders no remedy for an unknown system tool name", () => {
    stubApi();
    render(
      <SystemNoticeCard
        request={makeNotice({ id: "n-4", toolName: "sovereign.somethingelse" })}
      />,
    );
    expect(screen.getByTestId("system-notice-n-4")).toBeInTheDocument();
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.queryByRole("link")).toBeNull();
  });

  it("renders a refused ceremony as a visible error and keeps the card", async () => {
    const user = userEvent.setup();
    const { fetchCalls } = stubApi({ rebaselineStatus: 500 });
    const onRemedy = vi.fn();
    render(
      <SystemNoticeCard
        request={makeNotice({ id: "n-5", toolName: "sovereign.mismatch" })}
        onRemedy={onRemedy}
      />,
    );
    await user.click(screen.getByRole("button", { name: "Re-baseline & re-verify" }));
    // A refused ceremony stays visible instead of vanishing.
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
    expect(screen.getByTestId("system-notice-n-5")).toBeInTheDocument();
    expect(onRemedy).not.toHaveBeenCalled();
    expect(fetchCalls).toEqual(["POST /health/sovereign/rebaseline"]);
  });
});
