// Rune Weaver Dashboard — Component tests for the staged changes drawer.
//
// Pins the single-column review contract: one card per staged file with every
// diff collapsed on mount, per-card expansion that reveals only that file's
// diff, the batch Expand all / Collapse all toggle with its label flip, the
// exact per-file Accept target, the empty-state copy, and the count callback
// the nav badge consumes. The shared socket is stubbed so the drawer's live
// refetch wiring is exercised with a real connection stand-in rather than a
// missing WebSocket global.

import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import StagedChangesDrawer from "./StagedChangesDrawer";
import {
  acceptStagedFile,
  discardStagedFile,
  getStagedFiles,
  type StagedFile,
} from "../api";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

// Partial mock: spread the real module so the shared WebSocket singleton keeps
// its auth/token helpers, overriding only the staged-file network calls this
// suite drives directly. Asserting on the mocked functions (rather than a
// fetch double) pins the exact arguments the drawer hands the API layer.
vi.mock("../api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api")>();
  return {
    ...actual,
    getStagedFiles: vi.fn(),
    acceptStagedFile: vi.fn(),
    discardStagedFile: vi.fn(),
  };
});

const getStagedFilesMock = vi.mocked(getStagedFiles);
const acceptStagedFileMock = vi.mocked(acceptStagedFile);
const discardStagedFileMock = vi.mocked(discardStagedFile);

const ALPHA_PATH = "/tmp/review/alpha.txt";
const BETA_PATH = "/tmp/review/beta.txt";

// Two files with distinct diff bodies so an assertion on one file's added line
// can never be satisfied by the other card's expanded body.
const STAGED_FILES: StagedFile[] = [
  {
    path: ALPHA_PATH,
    stagingPath: "/tmp/review/.rune_alpha.txt",
    diff: "@@ -1 +1 @@\n-old alpha\n+new alpha\n",
    additions: 1,
    deletions: 1,
  },
  {
    path: BETA_PATH,
    stagingPath: "/tmp/review/.rune_beta.txt",
    diff: "@@ -1 +1 @@\n-old beta\n+new beta\n",
    additions: 2,
    deletions: 1,
  },
];

function stubSharedSocket() {
  const capture = createMockWebSocketCapture();
  vi.stubGlobal("WebSocket", createMockWebSocket(capture));
  return capture;
}

// Drains one mocked accept -> refetch -> setState chain inside act so a test
// asserts the settled card instead of one mid-flight, mirroring the inline
// review cards' hydration flush.
async function flushAsyncWork() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

// Returns the card that owns `filename` by anchoring on its chevron toggle's
// accessible name, so per-card assertions never depend on DOM order.
function cardFor(filename: string): HTMLElement {
  const toggle = screen.getByRole("button", { name: `Expand diff for ${filename}` });
  const card = toggle.closest(".staged-change-card");
  if (!(card instanceof HTMLElement)) {
    throw new Error(`No staged-change card found for ${filename}`);
  }
  return card;
}

describe("StagedChangesDrawer", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedSocket();
    getStagedFilesMock.mockReset();
    acceptStagedFileMock.mockReset();
    discardStagedFileMock.mockReset();
    getStagedFilesMock.mockResolvedValue({ files: STAGED_FILES });
    acceptStagedFileMock.mockResolvedValue({ status: "ok", count: 1 });
    discardStagedFileMock.mockResolvedValue({ status: "ok", count: 1 });
    stubSharedSocket();
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    resetSharedSocket();
  });

  it("renders every file collapsed by default", async () => {
    render(<StagedChangesDrawer isOpen onClose={vi.fn()} />);
    await screen.findByText("alpha.txt");

    expect(screen.queryByText(/Unified Diff/)).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Expand diff for alpha.txt" }),
    ).toHaveAttribute("aria-expanded", "false");
    expect(
      screen.getByRole("button", { name: "Expand diff for beta.txt" }),
    ).toHaveAttribute("aria-expanded", "false");
  });

  it("expands one card without revealing the other file's diff", async () => {
    render(<StagedChangesDrawer isOpen onClose={vi.fn()} />);
    await screen.findByText("alpha.txt");

    fireEvent.click(screen.getByRole("button", { name: "Expand diff for alpha.txt" }));

    expect(screen.getByText("+new alpha")).toBeInTheDocument();
    expect(screen.queryByText("+new beta")).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Collapse diff for alpha.txt" }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(
      screen.getByRole("button", { name: "Expand diff for beta.txt" }),
    ).toHaveAttribute("aria-expanded", "false");
  });

  it("toggles Expand all to Collapse all across both cards", async () => {
    render(<StagedChangesDrawer isOpen onClose={vi.fn()} />);
    await screen.findByText("alpha.txt");

    fireEvent.click(screen.getByRole("button", { name: "Expand all" }));

    expect(screen.getByText("+new alpha")).toBeInTheDocument();
    expect(screen.getByText("+new beta")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Collapse all" }));

    expect(screen.queryByText(/Unified Diff/)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Expand all" })).toBeInTheDocument();
  });

  it("accepts exactly the clicked file path", async () => {
    render(<StagedChangesDrawer isOpen onClose={vi.fn()} />);
    await screen.findByText("alpha.txt");

    fireEvent.click(within(cardFor("alpha.txt")).getByRole("button", { name: "Accept" }));

    await waitFor(() => {
      expect(acceptStagedFileMock).toHaveBeenCalledWith(ALPHA_PATH);
    });
    expect(discardStagedFileMock).not.toHaveBeenCalled();
    // The post-accept refetch is part of the contract; drain the mocked round
    // trip so the settled card is asserted before teardown.
    await flushAsyncWork();
    expect(getStagedFilesMock).toHaveBeenCalledTimes(2);
  });

  it("renders the empty-state copy when nothing is staged", async () => {
    getStagedFilesMock.mockResolvedValue({ files: [] });
    const onCountChange = vi.fn();
    render(
      <StagedChangesDrawer isOpen onClose={vi.fn()} onCountChange={onCountChange} />,
    );

    expect(await screen.findByText("No staged changes")).toBeInTheDocument();
    expect(screen.getByText("files.write")).toBeInTheDocument();
    await waitFor(() => expect(onCountChange).toHaveBeenCalledWith(0));
  });

  it("reports the staged file count to the owner", async () => {
    const onCountChange = vi.fn();
    render(
      <StagedChangesDrawer isOpen onClose={vi.fn()} onCountChange={onCountChange} />,
    );

    await waitFor(() => expect(onCountChange).toHaveBeenCalledWith(2));
  });
});
