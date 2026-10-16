// Rune Weaver Dashboard — writeReviewOwnership helper tests.

import { describe, expect, it } from "vitest";
import type { ToolAction, ToolResult } from "../api";
import { writeReviewKey } from "./DiffCard";
import {
  collectWriteHydrationTargets,
  collectWriteReviewOwners,
  isWriteReviewOwner,
} from "./writeReviewOwnership";

// Mirrors the engine wire shape the cards parse: a reviewable files.write
// envelope carries a string path and diff plus a staged/live status.
function writeResult(
  callID: string,
  status: "staged" | "live",
  path: string,
): ToolResult {
  return {
    toolCallID: callID,
    content: JSON.stringify({
      status,
      path,
      backupPath: null,
      diff: "@@ -1 +1 @@\n-old\n+new\n",
      additions: 1,
      deletions: 1,
      message: status,
    }),
    isError: false,
  };
}

function writeAction(
  callID: string,
  status: "staged" | "live",
  path: string,
): ToolAction {
  return {
    toolName: "files.write",
    callID,
    argumentsJSON: "{}",
    result: writeResult(callID, status, path),
  };
}

function readAction(callID: string): ToolAction {
  return {
    toolName: "files.read",
    callID,
    argumentsJSON: "{}",
    result: { toolCallID: callID, content: "ok", isError: false },
  };
}

function erroredWriteAction(callID: string, path: string): ToolAction {
  return {
    toolName: "files.write",
    callID,
    argumentsJSON: "{}",
    result: {
      toolCallID: callID,
      content: `write failed: ${path}`,
      isError: true,
    },
  };
}

describe("collectWriteReviewOwners", () => {
  it("keeps the last card per path and envelope kind", () => {
    const olderLive = writeAction("call-1", "live", "/tmp/a.txt");
    const newerLive = writeAction("call-2", "live", "/tmp/a.txt");
    const staged = writeAction("call-3", "staged", "/tmp/a.txt");
    const otherPath = writeAction("call-4", "live", "/tmp/b.txt");

    const owners = collectWriteReviewOwners([
      olderLive,
      newerLive,
      staged,
      otherPath,
    ]);

    // One owner per (path, kind): the same path still carries two owners when
    // its staged and live envelopes each track their own ledger row.
    expect(owners.size).toBe(3);
    expect(owners.get(writeReviewKey(newerLive.result) ?? "")).toBe(newerLive);
    expect(owners.get(writeReviewKey(staged.result) ?? "")).toBe(staged);
    expect(owners.get(writeReviewKey(otherPath.result) ?? "")).toBe(otherPath);
  });

  it("ignores non-write rows and unreviewable envelopes", () => {
    const noResult: ToolAction = {
      toolName: "files.write",
      callID: "call-no-result",
      argumentsJSON: "{}",
      result: null,
    };
    const malformed: ToolAction = {
      toolName: "files.write",
      callID: "call-malformed",
      argumentsJSON: "{}",
      result: {
        toolCallID: "call-malformed",
        content: "not an envelope",
        isError: false,
      },
    };

    const owners = collectWriteReviewOwners([
      readAction("call-read"),
      erroredWriteAction("call-error", "/tmp/a.txt"),
      noResult,
      malformed,
    ]);

    expect(owners.size).toBe(0);
  });
});

describe("collectWriteHydrationTargets", () => {
  it("collects one target per card in display order", () => {
    const targets = collectWriteHydrationTargets([
      writeAction("call-staged", "staged", "/tmp/a.txt"),
      readAction("call-read"),
      writeAction("call-live", "live", "/tmp/a.txt"),
    ]);

    expect(targets).toEqual([
      { kind: "staged", path: "/tmp/a.txt", cardKey: "call-staged" },
      { kind: "live", path: "/tmp/a.txt", cardKey: "call-live" },
    ]);
  });

  it("dedupes one call identity but keeps replacement writes", () => {
    const targets = collectWriteHydrationTargets([
      writeAction("call-1", "staged", "/tmp/a.txt"),
      writeAction("call-1", "staged", "/tmp/a.txt"),
      writeAction("call-2", "staged", "/tmp/a.txt"),
    ]);

    // A repeated card contributes one target; a replacement write for the same
    // path keeps its own identity so it starts a fresh hydration batch.
    expect(targets).toEqual([
      { kind: "staged", path: "/tmp/a.txt", cardKey: "call-1" },
      { kind: "staged", path: "/tmp/a.txt", cardKey: "call-2" },
    ]);
  });

  it("skips non-write rows and unreviewable envelopes", () => {
    const targets = collectWriteHydrationTargets([
      readAction("call-read"),
      erroredWriteAction("call-error", "/tmp/a.txt"),
      {
        toolName: "files.write",
        callID: "call-no-result",
        argumentsJSON: "{}",
        result: null,
      },
    ]);

    expect(targets).toEqual([]);
  });
});

describe("isWriteReviewOwner", () => {
  it("gates only cards shadowed by a newer write for the same path and kind", () => {
    const olderLive = writeAction("call-1", "live", "/tmp/a.txt");
    const newerLive = writeAction("call-2", "live", "/tmp/a.txt");
    const staged = writeAction("call-3", "staged", "/tmp/a.txt");

    const owners = collectWriteReviewOwners([olderLive, newerLive, staged]);

    expect(isWriteReviewOwner(owners, olderLive)).toBe(false);
    expect(isWriteReviewOwner(owners, newerLive)).toBe(true);
    // A staged card for the same path tracks a different ledger row, so the
    // live shadow never gates it.
    expect(isWriteReviewOwner(owners, staged)).toBe(true);
  });

  it("never gates non-write rows or unreviewable envelopes", () => {
    const owners = collectWriteReviewOwners([
      writeAction("call-1", "live", "/tmp/a.txt"),
    ]);

    expect(isWriteReviewOwner(owners, readAction("call-read"))).toBe(true);
    expect(
      isWriteReviewOwner(owners, erroredWriteAction("call-error", "/tmp/a.txt")),
    ).toBe(true);
  });
});
