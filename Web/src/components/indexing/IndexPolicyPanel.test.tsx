// Rune Weaver Dashboard — Index Policy save-gate coverage.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { IndexPolicyPanel } from "./IndexPolicyPanel";
import { jsonResponse } from "../../test-utils/http";

const indexConfig = {
  enabled: false,
  files: true,
  mail: false,
  messages: false,
  roots: ["~"],
  exclude: [".git", "node_modules"],
  maxFileMB: 20,
  mailVectorWindow: "2y",
  iCloudEvicted: "skip",
  nightlyBudget: 0,
  dbPath: "~/.runeweaver/index.db",
};

const statusPayload = {
  enabled: false,
  running: false,
  documents: 42,
  chunks: 100,
  vectorChunks: 80,
  keywordChunks: 20,
  bytes: 2048,
  indexAsOf: null,
  sources: [
    { kind: "files", enabled: false },
    { kind: "mail", enabled: false },
    { kind: "messages", enabled: false },
  ],
  lastErrors: [],
  bySource: [
    { kind: "files", documents: 30, chunks: 70, bytes: 1500 },
    { kind: "mail", documents: 12, chunks: 30, bytes: 548 },
  ],
  byExtractStatus: [
    { status: "extracted", documents: 30 },
    { status: "partial", documents: 12 },
  ],
  lastRun: {
    status: "ok",
    indexed: 3,
    scanned: 5,
    errors: 0,
    finishedAt: 1,
  },
};

function stubFetch(overrides: { status?: unknown; settings?: unknown } = {}) {
  const calls: Array<{ url: string; method: string; body: unknown }> = [];
  const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    let body: unknown = undefined;
    if (typeof init?.body === "string") {
      try {
        body = JSON.parse(init.body) as unknown;
      } catch {
        body = init.body;
      }
    }
    calls.push({ url, method, body });
    if (url === "/index/status") {
      return jsonResponse(overrides.status ?? statusPayload);
    }
    return jsonResponse({
      engineName: "Test Engine",
      index: overrides.settings ?? indexConfig,
    });
  });
  return { fetchMock, calls };
}

describe("IndexPolicyPanel dirty gate", () => {
  it("keeps Save Index Settings disabled while pristine and on formatting-only edits", async () => {
    const user = userEvent.setup();
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Exclude patterns/)).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Exclude patterns/) as HTMLTextAreaElement).value,
      ).toBe(".git\nnode_modules");
    });

    const saveButton = screen.getByRole("button", {
      name: "Save Index Settings",
    });
    expect(saveButton).toBeDisabled();
    expect(saveButton).toHaveAttribute("title", "No unsaved changes");

    // Trailing blank lines normalize away, so the gate stays closed.
    const exclude = screen.getByLabelText(
      /Exclude patterns/,
    ) as HTMLTextAreaElement;
    fireEvent.change(exclude, { target: { value: `${exclude.value}\n   \n` } });
    expect(saveButton).toBeDisabled();
    expect(saveButton).toHaveAttribute("title", "No unsaved changes");

    await user.click(screen.getByLabelText("Thermal backoff"));
    expect(saveButton).toBeEnabled();
    await user.click(screen.getByLabelText("Thermal backoff"));
    expect(saveButton).toBeDisabled();
    expect(saveButton).toHaveAttribute("title", "No unsaved changes");
  });

  it("returns Save Index Settings to disabled once the save echo lands", async () => {
    const user = userEvent.setup();
    const { fetchMock } = stubFetch();
    vi.stubGlobal("fetch", fetchMock);

    render(<IndexPolicyPanel />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Exclude patterns/)).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Exclude patterns/) as HTMLTextAreaElement).value,
      ).toBe(".git\nnode_modules");
    });

    await user.click(screen.getByLabelText("Thermal backoff"));
    const saveButton = screen.getByRole("button", {
      name: "Save Index Settings",
    });
    expect(saveButton).toBeEnabled();

    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Index settings saved.")).toBeInTheDocument();
    });
    // The persist echo resyncs the snapshot, so the gate closes again.
    expect(saveButton).toBeDisabled();
    expect(saveButton).toHaveAttribute("title", "No unsaved changes");
  });
});
