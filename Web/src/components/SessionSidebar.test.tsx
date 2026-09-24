// Rune Weaver Dashboard — Component tests for SessionSidebar inline renaming.
// Covers the submit-plus-blur single-save guard so one rename issues one PATCH.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SessionSidebar from "./SessionSidebar";
import {
  listRuns,
  listSessions,
  runningSessionIDsFromRuns,
  updateSessionTitle,
} from "../api";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";

// Spread the real module so every export the component tree reaches keeps a
// value — notably the `subscribeAuthState`/`getAuthToken`/`toNonNegativeInt`
// trio the shared WebSocket singleton reads during construction and dialing.
// A hand-listed partial mock silently breaks the moment a consumer picks up a
// new API export, so only the network helpers this suite drives directly are
// overridden below.
vi.mock("../api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api")>();
  return {
    ...actual,
    listSessions: vi.fn(),
    updateSessionTitle: vi.fn(),
    deleteSession: vi.fn(),
    listRuns: vi.fn(),
    runningSessionIDsFromRuns: vi.fn(),
    isActiveRunStatus: vi.fn((status: string) => status === "running"),
  };
});

const sessionsPayload = {
  sessions: [
    {
      id: "session-1",
      title: "Old title",
      messageCount: 2,
      summary: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      source: "chat",
    },
  ],
  count: 1,
};

describe("SessionSidebar", () => {
  beforeEach(() => {
    // Drop the shared poller's timer and cache so one suite's interval never
    // leaks into the next and late subscribers never badge from stale rows.
    resetSharedRunsForTesting();
    vi.clearAllMocks();
    localStorage.clear();
    vi.mocked(listSessions).mockResolvedValue(sessionsPayload);
    vi.mocked(updateSessionTitle).mockResolvedValue(undefined);
    // Newer run-history helpers stay mocked so background-badge polling
    // resolves empty instead of throwing on a missing export.
    vi.mocked(listRuns).mockResolvedValue({ runs: [], count: 0 });
    vi.mocked(runningSessionIDsFromRuns).mockReturnValue([]);
  });

  it("issues a single PATCH when submit and blur race", async () => {
    const user = userEvent.setup();
    render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );
    await screen.findByText("Old title");
    await user.click(screen.getByTitle("Rename session"));
    const input = screen.getByDisplayValue("Old title");
    await user.clear(input);
    await user.type(input, "New title");
    const form = input.closest("form");
    expect(form).not.toBeNull();
    // Real browsers blur the input on submit, so both the form submit
    // and the input blur fire for one save; only one PATCH may go out.
    if (form === null) {
      throw new Error("Expected rename form to be present");
    }
    fireEvent.submit(form);
    fireEvent.blur(input);
    await waitFor(() => {
      expect(updateSessionTitle).toHaveBeenCalledTimes(1);
    });
    expect(updateSessionTitle).toHaveBeenCalledWith("session-1", "New title");
  });

  it("immediately renders an optimistic active 'New Chat' entry when currentSessionID is not in history", async () => {
    render(
      <SessionSidebar
        currentSessionID="brand-new-session"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );
    await screen.findByText("Old title");
    // "New Chat" should appear immediately in the sidebar
    expect(screen.getByTitle("New Chat")).toBeInTheDocument();
    // It should have the active class
    const activeItem = screen.getByTitle("New Chat").closest(".session-item");
    expect(activeItem).toHaveClass("active");
  });

  it("filters sessions between Chats and Scheduled runs", async () => {
    const user = userEvent.setup();
    const mixedPayload = {
      sessions: [
        {
          id: "chat-1",
          title: "User conversation",
          messageCount: 1,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          source: "chat",
        },
        {
          id: "scheduled-1",
          title: "Daily Digest (Run)",
          messageCount: 1,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          source: "scheduler",
        },
      ],
      count: 2,
    };
    vi.mocked(listSessions).mockResolvedValue(mixedPayload);

    render(
      <SessionSidebar
        currentSessionID="chat-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );

    // By default, filter is "chat", so "User conversation" is visible and "Daily Digest" is not
    await screen.findByText("User conversation");
    expect(screen.queryByText("Daily Digest (Run)")).not.toBeInTheDocument();

    // Click "Scheduled" tab
    await user.click(screen.getByRole("button", { name: "Scheduled" }));
    expect(screen.getByText("Daily Digest (Run)")).toBeInTheDocument();
    expect(screen.queryByText("User conversation")).not.toBeInTheDocument();

    // Click "All" tab
    await user.click(screen.getByRole("button", { name: "All" }));
    expect(screen.getByText("Daily Digest (Run)")).toBeInTheDocument();
    expect(screen.getByText("User conversation")).toBeInTheDocument();
  });

  it("opens centered delete confirmation modal and confirms deletion", async () => {
    const user = userEvent.setup();
    render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );

    await screen.findByText("Old title");
    await user.click(screen.getByTitle("Delete session"));

    // Modal dialog should appear in document.body
    const dialog = screen.getByRole("dialog", { name: "Confirm delete session" });
    expect(dialog).toBeInTheDocument();
    expect(screen.getByText("Delete chat session?")).toBeInTheDocument();

    // Confirm deletion
    await user.click(screen.getByRole("button", { name: "Confirm delete session" }));
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Confirm delete session" })).not.toBeInTheDocument();
    });
  });

  it("renders amber warning icon when a session has an unresolved pending approval", async () => {
    const pendingApprovals = [
      {
        id: "approval-1",
        toolName: "email.attachment",
        description: "Allow email.attachment",
        input: { toolName: "email.attachment", argumentsJSON: "{}", callID: "call-1" },
        suggestedDurations: ["thisTime" as const],
        sessionID: "session-1",
      },
    ];

    render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        pendingApprovals={pendingApprovals}
      />,
    );

    await screen.findByText("Old title");
    const warningIcon = screen.getByTestId("session-approval-pending-icon");
    expect(warningIcon).toBeInTheDocument();
    expect(warningIcon).toHaveClass("pending-approval");
  });

  it("badges a background session whose turn is still running", async () => {
    // Parked flights reach the sidebar as running identifiers so a turn left
    // running while browsing elsewhere stays visible without opening Runs.
    render(
      <SessionSidebar
        currentSessionID="other-session"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        runningSessionIDs={new Set(["session-1"])}
      />,
    );

    await screen.findByText("Old title");
    const badge = screen.getByTestId("session-running-badge");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveTextContent("Running");
  });

  it("badges polled running sessions without a live broadcast", async () => {
    // Reloads have no live socket yet, so the run-log poll alone must light
    // the badge for sessions the engine still marks running.
    vi.mocked(listRuns).mockResolvedValue({
      runs: [
        {
          id: "run-1",
          kind: "chat",
          status: "running",
          message: "thinking",
          timestamp: new Date().toISOString(),
          sessionID: "session-1",
        },
      ],
      count: 1,
    });
    vi.mocked(runningSessionIDsFromRuns).mockReturnValue(["session-1"]);

    render(
      <SessionSidebar
        currentSessionID="other-session"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );

    await screen.findByText("Old title");
    expect(await screen.findByTestId("session-running-badge")).toBeInTheDocument();
  });

  it("groups drifted scheduler sources under Scheduled", async () => {
    // Stored sources may carry casing or whitespace drift; the tabs normalize
    // before classifying so scheduled runs never strand under Chats.
    const user = userEvent.setup();
    vi.mocked(listSessions).mockResolvedValue({
      sessions: [
        {
          id: "chat-1",
          title: "User conversation",
          messageCount: 1,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          source: "chat",
        },
        {
          id: "scheduled-drift",
          title: "Nightly job",
          messageCount: 1,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          source: " Scheduler ",
        },
      ],
      count: 2,
    });

    render(
      <SessionSidebar
        currentSessionID="chat-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );

    await screen.findByText("User conversation");
    expect(screen.queryByText("Nightly job")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Scheduled" }));
    expect(screen.getByText("Nightly job")).toBeInTheDocument();
  });

  it("exposes the mobile drawer as a modal dialog only while handheld and open", async () => {
    const { rerender } = render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        isMobile
      />,
    );
    await screen.findByText("Old title");
    const dialog = screen.getByRole("dialog", { name: "Session history" });
    expect(dialog).toBeInTheDocument();
    expect(dialog.getAttribute("aria-modal")).toBe("true");

    // Closing the drawer drops the dialog semantics so the inline column
    // never advertises a modal contract.
    rerender(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen={false}
        onToggleOpen={() => {}}
        isMobile
      />,
    );
    expect(screen.queryByRole("dialog", { name: "Session history" })).toBeNull();
  });

  it("keeps the desktop sidebar as an inline region with no dialog semantics", async () => {
    render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        isMobile={false}
      />,
    );
    await screen.findByText("Old title");
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("locks background scroll while the mobile drawer is open and restores on close", async () => {
    document.body.style.overflow = "";
    const { rerender, unmount } = render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        isMobile
      />,
    );
    await screen.findByText("Old title");
    expect(document.body.style.overflow).toBe("hidden");
    rerender(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen={false}
        onToggleOpen={() => {}}
        isMobile
      />,
    );
    expect(document.body.style.overflow).toBe("");
    // Reopen then unmount to cover the cleanup path.
    rerender(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        isMobile
      />,
    );
    expect(document.body.style.overflow).toBe("hidden");
    unmount();
    expect(document.body.style.overflow).toBe("");
  });

  it("traps Tab inside the mobile drawer instead of reaching the background", async () => {
    render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        isMobile
      />,
    );
    await screen.findByText("Old title");
    const dialog = screen.getByRole("dialog", { name: "Session history" });
    const focusable = Array.from(
      dialog.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    );
    expect(focusable.length).toBeGreaterThan(0);
    // Focus outside the drawer, then Tab: the trap pulls focus to the first
    // drawer control instead of leaking to the dimmed background.
    (document.activeElement as HTMLElement | null)?.blur();
    fireEvent.keyDown(window, { key: "Tab" });
    expect(dialog.contains(document.activeElement)).toBe(true);
  });
});

