// Rune Weaver Dashboard — Component tests for the App owner-auth gate.
//
// The engine serves the dashboard bundle publicly, so the shell decides the
// posture from the health shape: a full payload mounts the authenticated
// dashboard (or the no-auth loopback surface), while the minimal liveness
// object renders the in-bundle login gate. Child views are stubbed so these
// tests exercise only the gate wiring, never a live socket or data poll.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";
import { clearAuthToken, getAuthToken } from "./api";
import { jsonResponse } from "./test-utils/http";

vi.mock("./components/ChatView", () => ({ default: () => null }));
vi.mock("./components/TopNav", () => ({ default: () => null }));
vi.mock("./hooks/useWebNotifications", () => ({
  useWebNotifications: () => ({
    notificationsEnabled: false,
    requestPermission: vi.fn(),
    runsBadge: 0,
    clearRunsBadge: vi.fn(),
    approvalsBadge: 0,
    clearApprovalsBadge: vi.fn(),
    warningsBadge: 0,
    clearWarningsBadge: vi.fn(),
  }),
}));

describe("App owner-auth gate", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
  });

  it("opens the dashboard when the engine serves no auth gate", async () => {
    // A full health payload with no stored token is the loopback no-auth
    // posture: the dashboard mounts and no bogus login form is shown.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ status: "ok", engine: "Rune Weaver", version: "0.1.0" }),
      ),
    );
    render(<App />);
    await waitFor(() =>
      expect(document.querySelector(".app-root")).not.toBeNull(),
    );
    expect(screen.queryByLabelText("Access token")).not.toBeInTheDocument();
  });

  it("shows the login gate when the engine answers with liveness only", async () => {
    // The minimal liveness shape proves the probe never cleared the owner gate,
    // so the public shell replaces the dashboard with the sign-in view.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: "ok", version: "0.1.0" })),
    );
    render(<App />);
    await waitFor(() =>
      expect(screen.getByLabelText("Access token")).toBeInTheDocument(),
    );
    expect(document.querySelector(".app-root")).toBeNull();
  });

  it("opens the dashboard after a successful login", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        if (input === "/settings") {
          return new Response(null, { status: 200 });
        }
        return jsonResponse({ status: "ok", version: "0.1.0" });
      }),
    );
    render(<App />);
    await waitFor(() =>
      expect(screen.getByLabelText("Access token")).toBeInTheDocument(),
    );

    await user.type(screen.getByLabelText("Access token"), "owner-token");
    await user.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() =>
      expect(document.querySelector(".app-root")).not.toBeNull(),
    );
    expect(getAuthToken()).toBe("owner-token");
  });
});
