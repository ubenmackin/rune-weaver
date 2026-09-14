// Rune Weaver Dashboard — Component tests for SessionSidebar inline renaming.
// Covers the submit-plus-blur single-save guard so one rename issues one PATCH.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SessionSidebar from "./SessionSidebar";
import { listSessions, updateSessionTitle } from "../api";

vi.mock("../api", () => ({
  listSessions: vi.fn(),
  updateSessionTitle: vi.fn(),
  deleteSession: vi.fn(),
}));

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
    vi.clearAllMocks();
    localStorage.clear();
    vi.mocked(listSessions).mockResolvedValue(sessionsPayload);
    vi.mocked(updateSessionTitle).mockResolvedValue(undefined);
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
});

