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

describe("SessionSidebar rename", () => {
  beforeEach(() => {
    vi.clearAllMocks();
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
    fireEvent.submit(form!);
    fireEvent.blur(input);
    await waitFor(() => {
      expect(updateSessionTitle).toHaveBeenCalledTimes(1);
    });
    expect(updateSessionTitle).toHaveBeenCalledWith("session-1", "New title");
  });
});
