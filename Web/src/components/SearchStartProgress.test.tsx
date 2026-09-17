// Shared staged Start progress for the SearXNG container lifecycle.
// Proves the profile menu keeps the status text mounted beside the Starting
// pill with per-stage copy and elapsed ticks while the toggle stays locked
// until the terminal ensure result lands.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import TopNav from "./TopNav";
import { SEARCH_START_STAGE_COPY, searchStageCopy } from "../api";
import { jsonResponse } from "../test-utils/http";

const ENGINE_SEARCH_URL = "http://127.0.0.1:8888";

function renderNav() {
  return render(
    <TopNav
      currentTab="chat"
      onSelectTab={() => {}}
      health={
        {
          status: "ok",
          engine: "Rune Weaver",
          version: "0.1.0",
          searchReachable: false,
          searchURL: ENGINE_SEARCH_URL,
        } as never
      }
      runsBadge={0}
      approvalsBadge={0}
      notificationsEnabled={false}
      onRequestNotifications={() => {}}
    />,
  );
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

describe("Search start pill and persistent status text", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("maps every stage to its pill copy without blanking on drift", () => {
    // The pill renders through the shared copy helper so CLI and dashboard
    // never drift; drifted steps degrade to a bare Starting label.
    expect(searchStageCopy("resolving")).toBe(
      SEARCH_START_STAGE_COPY["resolving"],
    );
    expect(searchStageCopy("daemon")).toBe(SEARCH_START_STAGE_COPY["daemon"]);
    expect(searchStageCopy("pulling")).toBe(
      SEARCH_START_STAGE_COPY["pulling"],
    );
    expect(searchStageCopy("starting")).toBe(
      SEARCH_START_STAGE_COPY["starting"],
    );
    expect(searchStageCopy("waiting")).toBe(
      SEARCH_START_STAGE_COPY["waiting"],
    );
    expect(SEARCH_START_STAGE_COPY["pulling"]).toBe("Pulling search image");
    expect(searchStageCopy("unknown-step")).toBe("Starting");
    expect(searchStageCopy(null)).toBe("Starting");
  });

  it("keeps the status text mounted beside the Starting pill while busy stays locked", async () => {
    const user = userEvent.setup();
    const startedAt = Math.floor(Date.now() / 1000);
    const ensureDeferred = deferred<Response>();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        // Health polls feed the stage line only; the dot moves solely on the
        // terminal ensure result so mid-flight flaps never flip it early.
        if (String(input) === "/search/health") {
          return jsonResponse({
            reachable: false,
            url: ENGINE_SEARCH_URL,
            stage: "pulling",
            startedAt,
          });
        }
        if (String(input) === "/search/ensure") {
          return ensureDeferred.promise;
        }
        return jsonResponse({});
      }),
    );
    renderNav();
    await user.click(
      screen.getByRole("button", { name: /Profile and Settings menu/i }),
    );
    await waitFor(() => {
      expect(screen.getByTestId("searxng-status-dot")).toBeInTheDocument();
    });
    await user.click(screen.getByRole("button", { name: "Start SearXNG" }));

    // The Starting pill plus stage and elapsed render additively beside the
    // persistent status text, which stays mounted so consumers keep one id.
    await waitFor(() => {
      expect(screen.getByTestId("searxng-starting-pill")).toBeInTheDocument();
    });
    expect(screen.getByTestId("searxng-status-text")).toBeInTheDocument();
    expect(screen.getByTestId("searxng-status-text").textContent).toBe(
      "Stopped",
    );
    expect(screen.getByTestId("searxng-starting-pill").textContent).toBe(
      "Starting",
    );
    // Busy stays locked until the terminal result lands so Start and Stop
    // cannot race the hung pull; the toggle names the in-flight action.
    const toggle = screen.getByTestId("searxng-toggle");
    expect(toggle.hasAttribute("disabled")).toBe(true);
    expect(toggle.textContent).toContain("Starting");

    // The 1s poll resolves the live step through the shared copy helper with
    // a ticking elapsed count while the pull suspends the client cap.
    await waitFor(
      () => {
        expect(screen.getByTestId("searxng-start-stage").textContent).toBe(
          SEARCH_START_STAGE_COPY["pulling"],
        );
        expect(screen.getByTestId("searxng-start-elapsed").textContent).toMatch(
          /\d+s/,
        );
      },
      { timeout: 4000 },
    );
    expect(screen.getByTestId("searxng-status-text")).toBeInTheDocument();

    // Terminal success stops the Starting line while the status text persists
    // with the honest Reachable state.
    ensureDeferred.resolve(
      jsonResponse({ reachable: true, url: ENGINE_SEARCH_URL }),
    );
    await waitFor(
      () => {
        expect(screen.getByTestId("searxng-status-text").textContent).toBe(
          "Reachable",
        );
        expect(
          screen.queryByTestId("searxng-starting-pill"),
        ).toBeNull();
      },
      { timeout: 4000 },
    );
  });
});
