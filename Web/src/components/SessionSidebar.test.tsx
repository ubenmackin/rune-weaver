// Rune Weaver Dashboard — Component tests for SessionSidebar.
//
// Covers the submit-plus-blur single-save guard so one rename issues one PATCH,
// plus the live session-list invalidation contract: run lifecycle frames,
// foreground returns, and socket reopens revalidate the history through one
// coalesced refetch while a detached sidebar leaves no pending timer behind.
// Also pins the shell activation contract: the kept-mounted sidebar refetches
// exactly once per false→true Chat-tab transition and never on mount, repeated
// active renders, or a render that omits the activation flag.
// Finally pins the fan-out tree: workers nest behind a collapsed disclosure,
// expansion is per-parent and ephemeral, the active session's whole ancestor
// chain force-opens so a nested worker never vanishes, malformed parent cycles
// terminate safely, and orphaned workers fall back to top-level rows.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import SessionSidebar from "./SessionSidebar";
import {
  listRuns,
  listSessions,
  runningSessionIDsFromRuns,
  updateSessionTitle,
} from "../api";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

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

// Fan-out tree fixture. The parent's id is lowercase while its workers spell
// the same parent in uppercase, mirroring the engine's uppercase UUIDs against
// the dashboard's lowercase mint; the workers are declared newest-first so the
// rendered order can only come from the createdAt sort, and the orphan points
// at a parent absent from the list so it must fall back to a top-level row.
const fanOutSessionsPayload = {
  sessions: [
    {
      id: "parent-1",
      title: "Spawned a swarm",
      messageCount: 4,
      summary: null,
      createdAt: new Date(Date.now() - 120_000).toISOString(),
      updatedAt: new Date().toISOString(),
      source: "chat",
    },
    {
      id: "worker-2",
      title: "Worker: summarize the findings",
      messageCount: 1,
      createdAt: new Date(Date.now() - 30_000).toISOString(),
      updatedAt: new Date().toISOString(),
      source: "fanout_worker",
      parentSessionID: "PARENT-1",
    },
    {
      id: "worker-1",
      title: "Worker: search files",
      messageCount: 1,
      createdAt: new Date(Date.now() - 60_000).toISOString(),
      updatedAt: new Date().toISOString(),
      source: "fanout_worker",
      parentSessionID: "PARENT-1",
    },
    {
      id: "orphan-1",
      title: "Orphaned worker",
      messageCount: 1,
      createdAt: new Date(Date.now() - 10_000).toISOString(),
      updatedAt: new Date().toISOString(),
      source: "fanout_worker",
      parentSessionID: "gone-parent",
    },
    {
      id: "plain-1",
      title: "Ordinary chat",
      messageCount: 1,
      createdAt: new Date(Date.now() - 90_000).toISOString(),
      updatedAt: new Date().toISOString(),
      source: "chat",
    },
  ],
  count: 5,
};

// Deep-nesting fixture: a worker that itself spawned workers, which the engine
// permits when the fan-out tool runs with the full tool registry. The active
// session's ancestor chain spans two links, so only a transitive force-open
// keeps the viewed grandchild on screen. Uppercase parent spellings mirror the
// engine's UUID formatting so normalization is exercised at both depths, and
// the newest row is the grandchild so a collapsed default would bury it.
const nestedFanOutSessionsPayload = {
  sessions: [
    {
      id: "root-1",
      title: "Root swarm",
      messageCount: 4,
      summary: null,
      createdAt: new Date(Date.now() - 240_000).toISOString(),
      updatedAt: new Date(Date.now() - 200_000).toISOString(),
      source: "chat",
    },
    {
      id: "mid-1",
      title: "Worker: nested swarm",
      messageCount: 2,
      summary: null,
      createdAt: new Date(Date.now() - 120_000).toISOString(),
      updatedAt: new Date(Date.now() - 90_000).toISOString(),
      source: "fanout_worker",
      parentSessionID: "ROOT-1",
    },
    {
      id: "grand-1",
      title: "Worker: grandchild task",
      messageCount: 1,
      summary: null,
      createdAt: new Date(Date.now() - 60_000).toISOString(),
      updatedAt: new Date().toISOString(),
      source: "fanout_worker",
      parentSessionID: "MID-1",
    },
    {
      id: "plain-2",
      title: "Ordinary chat",
      messageCount: 1,
      summary: null,
      createdAt: new Date(Date.now() - 300_000).toISOString(),
      updatedAt: new Date(Date.now() - 290_000).toISOString(),
      source: "chat",
    },
  ],
  count: 4,
};

// Malformed parent metadata: `cycle-a` and `cycle-b` name each other and
// `self-parent` names itself. The ancestor walk must terminate at the first
// repeated key so a corrupt chain cannot spin the render, and a self-link is
// not nesting, so that row keeps its top-level fallback rather than detaching.
const cyclicParentSessionsPayload = {
  sessions: [
    {
      id: "cycle-a",
      title: "Cycle worker A",
      messageCount: 1,
      createdAt: new Date(Date.now() - 120_000).toISOString(),
      updatedAt: new Date(Date.now() - 110_000).toISOString(),
      source: "fanout_worker",
      parentSessionID: "cycle-b",
    },
    {
      id: "cycle-b",
      title: "Cycle worker B",
      messageCount: 1,
      createdAt: new Date(Date.now() - 100_000).toISOString(),
      updatedAt: new Date(Date.now() - 90_000).toISOString(),
      source: "fanout_worker",
      parentSessionID: "cycle-a",
    },
    {
      id: "self-parent",
      title: "Self-parented worker",
      messageCount: 1,
      createdAt: new Date(Date.now() - 80_000).toISOString(),
      updatedAt: new Date(Date.now() - 70_000).toISOString(),
      source: "fanout_worker",
      parentSessionID: "self-parent",
    },
    {
      id: "plain-3",
      title: "Ordinary chat",
      messageCount: 1,
      createdAt: new Date(Date.now() - 60_000).toISOString(),
      updatedAt: new Date(Date.now() - 50_000).toISOString(),
      source: "chat",
    },
  ],
  count: 4,
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

  it("refetches history exactly once when the Chat tab becomes active", async () => {
    // The shell keeps the chat surface mounted behind `display: none`, so a
    // tab return never remounts the sidebar: only the false→true activation
    // edge may refetch, and only for that one transition.
    const sidebar = (isActive: boolean) => (
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
        isActive={isActive}
      />
    );

    const { rerender } = render(sidebar(false));
    await screen.findByText("Old title");
    // An inactive mount still seeds the list, but adds no transition refetch.
    expect(listSessions).toHaveBeenCalledTimes(1);

    rerender(sidebar(true));
    await waitFor(() => expect(listSessions).toHaveBeenCalledTimes(2));

    // A repeated active render is not a transition and adds no refetch.
    rerender(sidebar(true));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(listSessions).toHaveBeenCalledTimes(2);

    // Leaving the tab is not a refresh trigger either.
    rerender(sidebar(false));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(listSessions).toHaveBeenCalledTimes(2);
  });

  it("never adds an activation refetch when the flag is omitted", async () => {
    // Standalone renders have no shell tab state, so an omitted flag must
    // behave as always active and add no transition refetch on rerenders.
    const { rerender } = render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );
    await screen.findByText("Old title");
    expect(listSessions).toHaveBeenCalledTimes(1);

    rerender(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(listSessions).toHaveBeenCalledTimes(1);
  });
});

// Fan-out session tree. A chat that spawned workers stays one row until its
// disclosure is opened; children then nest indented under it, the active
// session's whole ancestor chain stays open, and a worker whose parent is gone
// falls back to a top-level row. The suite pins the collapsed default, the
// ephemeral expansion state, the shared row handler used by both tree levels,
// and that malformed parent links never spin the ancestor walk.
describe("fan-out session tree", () => {
  beforeEach(() => {
    resetSharedRunsForTesting();
    vi.clearAllMocks();
    localStorage.clear();
    vi.mocked(listSessions).mockResolvedValue(fanOutSessionsPayload);
    vi.mocked(updateSessionTitle).mockResolvedValue(undefined);
    vi.mocked(listRuns).mockResolvedValue({ runs: [], count: 0 });
    vi.mocked(runningSessionIDsFromRuns).mockReturnValue([]);
  });

  function renderSidebar(
    currentSessionID: string,
    onSelectSession: (id: string) => void = () => {},
  ) {
    return render(
      <SessionSidebar
        currentSessionID={currentSessionID}
        onSelectSession={onSelectSession}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );
  }

  it("collapses fan-out children by default and labels the parent with an agent count", async () => {
    renderSidebar("plain-1");

    await screen.findByText("Spawned a swarm");
    const disclosure = screen.getByTestId("session-fanout-disclosure");
    expect(disclosure).toHaveAttribute("aria-expanded", "false");
    expect(disclosure).toHaveAccessibleName(
      "Expand 2 fan-out agent sessions for Spawned a swarm",
    );
    // Only the swarm parent counts; the ordinary sibling chat carries no tree
    // affordances of its own.
    expect(screen.getByTestId("session-fanout-count")).toHaveTextContent("2 agents");
    expect(screen.getAllByTestId("session-fanout-count")).toHaveLength(1);
    expect(screen.queryByText("Worker: search files")).not.toBeInTheDocument();
    expect(
      screen.queryByText("Worker: summarize the findings"),
    ).not.toBeInTheDocument();
  });

  it("expands a swarm on disclosure click, ordering workers by creation time", async () => {
    const user = userEvent.setup();
    const { container } = renderSidebar("plain-1");

    await screen.findByText("Spawned a swarm");
    await user.click(screen.getByTestId("session-fanout-disclosure"));

    expect(screen.getByTestId("session-fanout-disclosure")).toHaveAttribute(
      "aria-expanded",
      "true",
    );
    expect(screen.getByText("Worker: search files")).toBeInTheDocument();
    expect(screen.getByText("Worker: summarize the findings")).toBeInTheDocument();
    // Exactly the two nested workers render as children: the orphan stays
    // top-level and no child is duplicated outside its parent group.
    expect(container.querySelectorAll(".session-item-child")).toHaveLength(2);
    const childTitles = container.querySelectorAll(
      ".session-item-child .session-title",
    );
    expect(Array.from(childTitles).map((node) => node.textContent)).toEqual([
      "Worker: search files",
      "Worker: summarize the findings",
    ]);
  });

  it("selects a worker child through the shared row handler", async () => {
    const user = userEvent.setup();
    const onSelectSession = vi.fn();
    renderSidebar("plain-1", onSelectSession);

    await screen.findByText("Spawned a swarm");
    await user.click(screen.getByTestId("session-fanout-disclosure"));
    await user.click(screen.getByText("Worker: search files"));

    expect(onSelectSession).toHaveBeenCalledWith("worker-1");
  });

  it("auto-expands the active child's parent", async () => {
    renderSidebar("worker-2");

    await screen.findByText("Spawned a swarm");
    expect(screen.getByTestId("session-fanout-disclosure")).toHaveAttribute(
      "aria-expanded",
      "true",
    );
    expect(screen.getByText("Worker: search files")).toBeInTheDocument();
    expect(screen.getByText("Worker: summarize the findings")).toBeInTheDocument();
  });

  it("auto-expands the active grandchild's entire ancestor chain", async () => {
    vi.mocked(listSessions).mockResolvedValue(nestedFanOutSessionsPayload);
    const { container } = renderSidebar("grand-1");

    await screen.findByText("Root swarm");
    // Every ancestor link force-opens transitively, so the row the owner is
    // reading renders even though neither disclosure was clicked.
    const disclosures = screen.getAllByTestId("session-fanout-disclosure");
    expect(disclosures).toHaveLength(2);
    for (const disclosure of disclosures) {
      expect(disclosure).toHaveAttribute("aria-expanded", "true");
    }
    expect(screen.getByText("Worker: grandchild task")).toBeInTheDocument();
    // The grandchild indents beneath the mid-level worker, so both links carry
    // the child class in top-down order.
    const childTitles = container.querySelectorAll(
      ".session-item-child .session-title",
    );
    expect(Array.from(childTitles).map((node) => node.textContent)).toEqual([
      "Worker: nested swarm",
      "Worker: grandchild task",
    ]);
  });

  it("terminates the ancestor walk when parent links form a cycle", async () => {
    vi.mocked(listSessions).mockResolvedValue(cyclicParentSessionsPayload);
    renderSidebar("cycle-a");

    // The active session sits inside the cycle, so the upsweep must stop at the
    // first repeated key; an unguarded walk would spin here instead of ever
    // returning. The rest of the list rendering proves the walk terminated.
    await screen.findByText("Ordinary chat");
    expect(screen.getByText("Self-parented worker")).toBeInTheDocument();
  });

  it("renders a self-parented worker top-level instead of nesting it", async () => {
    vi.mocked(listSessions).mockResolvedValue(cyclicParentSessionsPayload);
    renderSidebar("plain-3");

    await screen.findByText("Self-parented worker");
    // A self-referential parent is not nesting, so the row keeps its top-level
    // fallback instead of detaching from every group.
    const row = screen.getByText("Self-parented worker").closest(".session-item");
    expect(row).not.toBeNull();
    expect(row).toHaveClass("session-item");
    expect(row).not.toHaveClass("session-item-child");
  });

  it("renders an orphaned worker top-level with the fan-out glyph", async () => {
    renderSidebar("plain-1");

    await screen.findByText("Orphaned worker");
    // The swarm parent is collapsed, so the only visible worker glyph belongs
    // to the orphan standing on its own outside any parent group.
    const icon = screen.getByTestId("session-fanout-child-icon");
    const row = icon.closest(".session-item");
    expect(row).not.toBeNull();
    expect(row).toHaveClass("session-item");
    expect(row).not.toHaveClass("session-item-child");
  });

  it("leaves sessions without children free of disclosure and count", async () => {
    // Ordinary chats with no worker relations must render exactly as they did
    // before the tree existed: no chevron, no agent count, no worker glyph.
    vi.mocked(listSessions).mockResolvedValue(sessionsPayload);
    renderSidebar("session-1");

    await screen.findByText("Old title");
    expect(screen.queryByTestId("session-fanout-disclosure")).toBeNull();
    expect(screen.queryByTestId("session-fanout-count")).toBeNull();
    expect(screen.queryByTestId("session-fanout-child-icon")).toBeNull();
  });

  it("renders a dedicated goal badge with TargetIcon for goal sessions", async () => {
    vi.mocked(listSessions).mockResolvedValue({
      sessions: [
        {
          id: "goal-session-1",
          title: "Optimize Latency",
          messageCount: 5,
          summary: null,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          source: "goal",
          goalId: "g-123",
        },
      ],
      count: 1,
    });
    renderSidebar("goal-session-1");

    await screen.findByText("Optimize Latency");
    const goalIcon = screen.getByTestId("session-goal-icon");
    expect(goalIcon).toBeInTheDocument();
    expect(goalIcon).toHaveClass("session-item-icon", "goal");
    expect(goalIcon).toHaveAttribute("title", "Goal run");
  });

  it("toggles the disclosure on Enter without selecting the session", async () => {
    const user = userEvent.setup();
    const onSelectSession = vi.fn();
    renderSidebar("plain-1", onSelectSession);

    await screen.findByText("Spawned a swarm");
    const disclosure = screen.getByTestId("session-fanout-disclosure");
    await user.click(disclosure);
    expect(disclosure).toHaveAttribute("aria-expanded", "true");

    // Enter activates the focused disclosure natively; the row's key handler
    // must ignore the bubbling event so the opener never selects the session.
    disclosure.focus();
    await user.keyboard("{Enter}");
    expect(disclosure).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText("Worker: search files")).not.toBeInTheDocument();
    expect(onSelectSession).not.toHaveBeenCalled();
  });

  it("hides fan-out children under the Scheduled filter", async () => {
    const user = userEvent.setup();
    renderSidebar("plain-1");

    await screen.findByText("Spawned a swarm");
    await user.click(screen.getByRole("button", { name: "Scheduled" }));

    expect(screen.queryByText("Spawned a swarm")).not.toBeInTheDocument();
    expect(screen.queryByText("Worker: search files")).not.toBeInTheDocument();
    expect(screen.queryByTestId("session-fanout-disclosure")).toBeNull();
    expect(screen.getByText("No scheduled runs")).toBeInTheDocument();
  });
});

// Live session-list invalidation. The sidebar revalidates history on run
// lifecycle frames, foreground returns, and socket reopens, but a swarm's
// parent/child bursts must collapse into one `listSessions()` call and no
// pending tick may survive unmount. Every case drives the real shared socket
// singleton through a stubbed transport so the production message path is
// exercised instead of a pre-sanitized handler.
describe("live session invalidation", () => {
  let capture: ReturnType<typeof createMockWebSocketCapture>;

  beforeEach(() => {
    // The preceding describes drive the same shared socket singleton (their
    // renders subscribe), so detach any handle or pending reconnect before
    // stubbing this case's transport; a stale dial's open event would add a
    // refetch these cases would misattribute to their own trigger.
    vi.unstubAllGlobals();
    resetSharedSocket();
    // The fan-out suite's Scheduled click persists `rw_session_filter` and
    // leaves its own mock payloads installed, so this suite clears storage and
    // reseeds the API mocks its mount path reads instead of inheriting either:
    // the saved scheduler filter would hide the chat fixture, and an
    // unconfigured `listRuns` would reject before anything renders.
    resetSharedRunsForTesting();
    vi.clearAllMocks();
    localStorage.clear();
    vi.mocked(listSessions).mockResolvedValue(sessionsPayload);
    vi.mocked(updateSessionTitle).mockResolvedValue(undefined);
    // Run-history helpers stay mocked so background-badge polling resolves
    // empty instead of throwing on a missing export.
    vi.mocked(listRuns).mockResolvedValue({ runs: [], count: 0 });
    vi.mocked(runningSessionIDsFromRuns).mockReturnValue([]);
    capture = createMockWebSocketCapture();
    vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  // One run lifecycle frame, complete enough for the badge path to parse.
  function runLifecycleFrame(type: "run_started" | "run_completed") {
    return {
      type,
      run: {
        id: "run-1",
        kind: "chat",
        status: type === "run_started" ? "running" : "ok",
        message: "thinking",
        timestamp: new Date().toISOString(),
        sessionID: "session-1",
      },
    };
  }

  function renderSidebar() {
    return render(
      <SessionSidebar
        currentSessionID="session-1"
        onSelectSession={() => {}}
        onNewSession={() => {}}
        isOpen
        onToggleOpen={() => {}}
      />,
    );
  }

  // Mounts the sidebar and settles both the mount refetch and the socket-open
  // refetch the mock fires on every dial, so each case can attribute the next
  // refetch to its own trigger.
  async function renderSidebarWithSettledSocket() {
    const view = renderSidebar();
    await screen.findByText("Old title");
    await waitFor(() => expect(capture.onMessage).not.toBeNull());
    await waitFor(() => expect(listSessions).toHaveBeenCalledTimes(2), {
      timeout: 2500,
    });
    vi.mocked(listSessions).mockClear();
    return view;
  }

  it("refetches the session list after a run lifecycle frame", async () => {
    await renderSidebarWithSettledSocket();
    await dispatchFrameOrThrow(
      capture.onMessage,
      runLifecycleFrame("run_started"),
    );
    await waitFor(() => expect(listSessions).toHaveBeenCalledTimes(1), {
      timeout: 2500,
    });
  });

  it("coalesces a burst of run lifecycle frames into one refetch", async () => {
    await renderSidebarWithSettledSocket();
    await dispatchFrameOrThrow(
      capture.onMessage,
      runLifecycleFrame("run_started"),
    );
    await dispatchFrameOrThrow(
      capture.onMessage,
      runLifecycleFrame("run_completed"),
    );
    await waitFor(() => expect(listSessions).toHaveBeenCalledTimes(1), {
      timeout: 2500,
    });
    // Wait beyond a full coalesce window so a wrongly scheduled second timer
    // would have fired; the burst must stay absorbed into the one refetch.
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(listSessions).toHaveBeenCalledTimes(1);
  });

  it("refetches the session list when the tab returns to the foreground", async () => {
    await renderSidebarWithSettledSocket();
    const visibilitySpy = vi
      .spyOn(document, "visibilityState", "get")
      .mockReturnValue("visible");
    fireEvent(document, new Event("visibilitychange"));
    await waitFor(() => expect(listSessions).toHaveBeenCalledTimes(1), {
      timeout: 2500,
    });
    visibilitySpy.mockRestore();
  });

  it("refetches the session list when the shared socket reopens", async () => {
    // Unmounting releases the shared socket; the fresh subscriber redials and
    // the reopened transport's open event must revalidate the history.
    const { unmount } = await renderSidebarWithSettledSocket();
    unmount();
    vi.mocked(listSessions).mockClear();

    renderSidebar();
    await waitFor(() => expect(listSessions).toHaveBeenCalledTimes(1));
    await waitFor(
      () => expect(vi.mocked(listSessions).mock.calls.length).toBeGreaterThan(1),
      { timeout: 2500 },
    );
  });
});

