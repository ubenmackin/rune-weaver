// Rune Weaver Dashboard — Component tests for the App owner-auth gate, lazy
// section mounting, and the mobile shell.
//
// The engine serves the dashboard bundle publicly, so the shell decides the
// posture from the health shape: a full payload mounts the authenticated
// dashboard (or the no-auth loopback surface), while the minimal liveness
// object renders the in-bundle login gate. Child views are stubbed so these
// tests exercise only the gate wiring, never a live socket or data poll. The
// stubs mount behind the shell's route-level lazy boundaries exactly like the
// real chunks do, so every assertion on a lazy surface awaits its Suspense
// boundary through waitFor — the same way these tests already await the async
// health-probe render — and never races a placeholder frame. The shell matrix
// additionally pins the mobile bottom bar: it mounts alongside the content
// with clearance on handheld widths while standalone stays chromeless.

import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";
import { clearAuthToken, getAuthToken, isSessionAuthenticated } from "./api";
import { jsonResponse } from "./test-utils/http";
import { installViewport } from "./test-utils/viewport";

vi.mock("./components/ChatView", () => ({
  default: ({ targetSessionId, initialPrompt }: { targetSessionId?: string; initialPrompt?: string }) => (
    <div data-testid="chat-view" data-session={targetSessionId} data-prompt={initialPrompt}>
      Chat
    </div>
  ),
}));
vi.mock("./components/DashboardView", () => ({
  default: ({ onOpenSession, onOpenChatWithPrompt }: { onOpenSession?: (id: string) => void; onOpenChatWithPrompt?: (p: string) => void }) => (
    <div data-testid="dashboard-view">
      <button data-testid="mock-open-session" onClick={() => onOpenSession?.("sess-test-123")}>
        Open Session
      </button>
      <button data-testid="mock-open-prompt" onClick={() => onOpenChatWithPrompt?.("investigate tests")}>
        Ask Prompt
      </button>
    </div>
  ),
}));
vi.mock("./components/TopNav", () => ({ default: () => <div data-testid="top-nav">TopNav</div> }));
vi.mock("./components/GoalsManager", () => ({
  default: () => <div data-testid="goals-manager">Goals</div>,
}));
vi.mock("./components/RunLogViewer", () => ({
  default: () => <div data-testid="run-log-viewer">Runs</div>,
}));
vi.mock("./components/SettingsManager", () => ({ default: () => <div data-testid="settings-manager">Settings</div> }));
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

  it("fails closed to the login gate when the health probe rejects with a network error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("Network offline");
      }),
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
        if (input === "/auth/session") {
          return new Response(JSON.stringify({ status: "ok" }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
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
    expect(isSessionAuthenticated()).toBe(true);
    expect(getAuthToken()).toBeNull();
  });

  it("renders only SettingsManager without TopNav in standalone mode", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ status: "ok", engine: "Rune Weaver", version: "0.1.0" }),
      ),
    );

    // Set standalone query parameter
    window.history.pushState({}, "", "/?standalone=true#settings");

    render(<App />);
    await waitFor(() =>
      expect(screen.getByTestId("settings-manager")).toBeInTheDocument(),
    );

    // TopNav is completely absent from the DOM
    expect(screen.queryByTestId("top-nav")).toBeNull();
    // Container has standalone-settings class
    expect(document.querySelector(".standalone-settings")).not.toBeNull();

    // Clean up URL
    window.history.pushState({}, "", "/");
  });
});

describe("App goals deep link", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
    window.history.pushState({}, "", "/");
  });

  afterEach(() => {
    window.history.pushState({}, "", "/");
  });

  it("resolves the #goals hash to the mounted goals surface", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ status: "ok", engine: "Rune Weaver", version: "0.1.0" }),
      ),
    );
    // A deep link into the Work group must survive a cold load, so goals has
    // to be a recognized top-level tab when the shell seeds its initial state.
    window.history.pushState({}, "", "/#goals");
    render(<App />);
    await waitFor(() => {
      expect(screen.getByTestId("goals-manager")).toBeInTheDocument();
    });
    expect(document.querySelector(".app-root")).not.toBeNull();
  });
});

describe("App lazy section mounting", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
    window.history.pushState({}, "", "/");
  });

  afterEach(() => {
    window.history.pushState({}, "", "/");
  });

  it("mounts a lazily-loaded section on first visit while chat stays mounted underneath", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({ status: "ok", engine: "Rune Weaver", version: "0.1.0" }),
      ),
    );
    render(<App />);
    // The dashboard tab and the always-mounted chat panel are separate lazy
    // boundaries: both must flush through their Suspense placeholder before
    // any tab-switch assertion below is meaningful.
    await waitFor(() => {
      expect(screen.getByTestId("dashboard-view")).toBeInTheDocument();
      expect(screen.getByTestId("chat-view")).toBeInTheDocument();
    });

    // Route-level splitting must not change tab-switch semantics: a hash
    // navigation to an unvisited section mounts it when its chunk lands, the
    // section being left unmounts, and the display-hidden chat panel survives
    // the switch exactly as it did under static imports.
    await act(async () => {
      window.location.hash = "runs";
    });
    await waitFor(() => {
      expect(screen.getByTestId("run-log-viewer")).toBeInTheDocument();
    });
    expect(screen.queryByTestId("dashboard-view")).toBeNull();
    expect(screen.getByTestId("chat-view")).toBeInTheDocument();
  });
});

describe("App mobile shell clearance", () => {
  const FULL_HEALTH = { status: "ok", engine: "Rune Weaver", version: "0.1.0" };

  function stubAuthenticatedHealth(): void {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(FULL_HEALTH)),
    );
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
    window.history.pushState({}, "", "/");
  });

  afterEach(() => {
    window.history.pushState({}, "", "/");
    Reflect.deleteProperty(window as unknown as Record<string, unknown>, "matchMedia");
  });

  it("mounts the four-group bottom bar with content clearance on a 375px phone", async () => {
    installViewport(375);
    stubAuthenticatedHealth();
    render(<App />);
    await waitFor(() => {
      expect(document.querySelector(".app-root")).not.toBeNull();
    });
    // The mobile bar owns the canonical order with Settings reserved for
    // profile; the distinct mobile landmark keeps it unique from desktop tabs.
    const bar = screen.getByRole("navigation", { name: "Dashboard sections — mobile" });
    const tabs = Array.from(bar.querySelectorAll("button")).map((tab) =>
      tab.getAttribute("aria-label"),
    );
    expect(tabs).toEqual(["Dashboard", "Chat", "Approvals", "Work", "Memory"]);
    expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();
    // Clearance sibling stays mounted so the fixed bar never covers content.
    expect(document.querySelector(".app-main-content")).not.toBeNull();
    expect(document.querySelector(".mobile-bottom-nav")).not.toBeNull();
  });

  it("keeps the bottom bar mounted on a 1024px desktop with visibility owned by CSS", async () => {
    installViewport(1024);
    stubAuthenticatedHealth();
    render(<App />);
    await waitFor(() => {
      expect(document.querySelector(".app-root")).not.toBeNull();
    });
    // Both tab surfaces stay mounted on every viewport while the stylesheet
    // owns visibility (min-width hides the bar, max-width hides the top
    // links), so a fail-closed viewport probe never leaves zero tab surfaces.
    expect(
      screen.queryByRole("navigation", { name: "Dashboard sections — mobile" }),
    ).not.toBeNull();
    expect(document.querySelector(".mobile-bottom-nav")).not.toBeNull();
    expect(document.querySelector(".app-main-content")).not.toBeNull();
  });

  it("hides badges when notification counts are zero", async () => {
    installViewport(375);
    stubAuthenticatedHealth();
    render(<App />);
    await waitFor(() => {
      expect(document.querySelector(".app-root")).not.toBeNull();
    });
    // Zero counts from the notification hook leave the bar badge-free.
    expect(document.querySelector(".mobile-bottom-tab-badge")).toBeNull();
  });

  it("keeps the login gate chromeless with no bar before authentication", async () => {
    installViewport(375);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: "ok", version: "0.1.0" })),
    );
    render(<App />);
    await waitFor(() =>
      expect(screen.getByLabelText("Access token")).toBeInTheDocument(),
    );
    expect(document.querySelector(".app-root")).toBeNull();
    expect(document.querySelector(".mobile-bottom-nav")).toBeNull();
  });

  it("omits the bottom bar in standalone settings mode", async () => {
    installViewport(375);
    stubAuthenticatedHealth();
    window.history.pushState({}, "", "/?standalone=true#settings");
    render(<App />);
    await waitFor(() =>
      expect(screen.getByTestId("settings-manager")).toBeInTheDocument(),
    );
    expect(document.querySelector(".mobile-bottom-nav")).toBeNull();
    expect(document.querySelector(".standalone-settings")).not.toBeNull();
  });

  it("routes onOpenSession from DashboardView to ChatView with targetSessionId", async () => {
    stubAuthenticatedHealth();
    render(<App />);
    await waitFor(() =>
      expect(screen.getByTestId("dashboard-view")).toBeInTheDocument(),
    );

    const openSessionBtn = screen.getByTestId("mock-open-session");
    await userEvent.click(openSessionBtn);

    await waitFor(() => {
      const chatView = screen.getByTestId("chat-view");
      expect(chatView).toBeInTheDocument();
      expect(chatView).toHaveAttribute("data-session", "sess-test-123");
      expect(window.location.hash).toBe("#chat/sess-test-123");
    });
  });

  it("routes onOpenChatWithPrompt from DashboardView to ChatView with prompt", async () => {
    stubAuthenticatedHealth();
    render(<App />);
    await waitFor(() =>
      expect(screen.getByTestId("dashboard-view")).toBeInTheDocument(),
    );

    const askPromptBtn = screen.getByTestId("mock-open-prompt");
    await userEvent.click(askPromptBtn);

    await waitFor(() => {
      const chatView = screen.getByTestId("chat-view");
      expect(chatView).toBeInTheDocument();
      expect(chatView).toHaveAttribute("data-prompt", "investigate tests");
    });
  });
});
