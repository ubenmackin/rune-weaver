// Rune Weaver Dashboard — Phantom badge regression coverage for parked-flight signals.

import { describe, expect, it } from "vitest";
import {
  isActiveRunStatus,
  runningSessionIDsFromRuns,
} from "../../api";
import { normalizeSessionID } from "../../approvalsSession";
import {
  canAdoptFromLive,
  canAdoptFromPoll,
  isParkableTurn,
  parkedFlightKey,
  settleParkedFlight,
  storeParkedFlight,
} from "./chatHelpers";
import { mergeLiveSnapshotIntoInFlightTurn } from "./useChatHistoryLoader";
import type { InFlightTurn, ParkedFlight } from "./chatTypes";

function parkedShell(overrides: Partial<ParkedFlight> = {}): ParkedFlight {
  return {
    turn: null,
    pending: false,
    warnings: [],
    turnTokens: null,
    base: 0,
    cancelled: false,
    updatedAt: Date.now(),
    ...overrides,
  };
}

describe("chat phantom badge regression", () => {
  it("compares session identity trimmed and lowercased", () => {
    expect(normalizeSessionID("  SESSION-1 ")).toBe("session-1");
    expect(normalizeSessionID("Session-1")).toBe(normalizeSessionID("SESSION-1"));
    expect(normalizeSessionID(null)).toBe("");
    expect(normalizeSessionID(undefined)).toBe("");
  });

  it("lights the badge only for running status", () => {
    expect(isActiveRunStatus("running")).toBe(true);
    expect(isActiveRunStatus("awaiting_approval")).toBe(false);
    expect(isActiveRunStatus("ok")).toBe(false);
    expect(isActiveRunStatus("completed")).toBe(false);
    expect(isActiveRunStatus("Running")).toBe(false);
    expect(isActiveRunStatus(undefined)).toBe(false);
    const ids = runningSessionIDsFromRuns([
      { status: "running", sessionID: "  SESSION-1 " },
      { status: "awaiting_approval", sessionID: "session-2" },
      { status: "ok", sessionID: "session-3" },
      { status: "running", sessionID: "   " },
      { status: "running", sessionID: "session-1" },
    ]);
    expect(ids).toEqual(["session-1"]);
  });

  it("parks only a live turn bound to the outgoing session", () => {
    // Idle switches fail the production park gate, so no shell is stored.
    const outgoingID = "session-1";
    expect(isParkableTurn(false, null, outgoingID)).toBe(false);
    expect(isParkableTurn(true, "other-session", outgoingID)).toBe(false);
    const flights = new Map<string, ParkedFlight>();
    const key = parkedFlightKey(outgoingID);
    if (isParkableTurn(false, null, outgoingID)) {
      storeParkedFlight(flights, key, parkedShell({ pending: true }));
    }
    expect(flights.size).toBe(0);
    // Control: a live turn bound to the outgoing session passes the same gate.
    expect(isParkableTurn(true, outgoingID, outgoingID)).toBe(true);
    const activeFlights = new Map<string, ParkedFlight>();
    const active: InFlightTurn = {
      toolActions: [],
      text: "hello",
      held: "",
      segments: [{ kind: "text", text: "hello" }],
    };
    if (isParkableTurn(true, "SESSION-1", outgoingID)) {
      storeParkedFlight(
        activeFlights,
        parkedFlightKey("SESSION-1"),
        parkedShell({ turn: active, pending: true, updatedAt: Date.now() }),
      );
    }
    expect(activeFlights.get("session-1")?.pending).toBe(true);
  });

  it("keeps pending false when restoring a missing flight", () => {
    // Missing keys settle as no-ops instead of reviving a bubble.
    const flights = new Map<string, ParkedFlight>();
    settleParkedFlight(flights, normalizeSessionID("missing-session"));
    expect(flights.get(normalizeSessionID("missing-session"))?.pending ?? false).toBe(false);
    expect(flights.size).toBe(0);
    // Control: settling a completed shell clears its timeline and pending flag.
    const key = normalizeSessionID("Session-A");
    storeParkedFlight(flights, key, parkedShell({ pending: false }));
    settleParkedFlight(flights, key);
    expect(flights.get(key)?.pending).toBe(false);
    expect(flights.get(key)?.turn).toBeNull();
  });

  it("requires an active live-turn even when the poll says running", async () => {
    // Poll says running, so the pre-live gate passes but inactive live blocks adopt.
    const sessionID = "Reload-Session-9";
    const normalized = normalizeSessionID(sessionID);
    const runningIDs = runningSessionIDsFromRuns([{ status: "running", sessionID }]);
    expect(runningIDs).toContain(normalized);
    const parkedFlights = new Map<string, ParkedFlight>();
    const pendingRef = { current: false };
    const canPoll = canAdoptFromPoll({
      pending: pendingRef.current,
      cancelled: false,
      isDraft: false,
      runningIncludesActive: runningIDs.includes(normalized),
      parkedPending: parkedFlights.get(normalized)?.pending === true,
    });
    expect(canPoll).toBe(true);
    const mockedGetLiveTurn = async () => ({ active: false, text: "", reasoning: "", toolActions: [] });
    const inactiveLive = await mockedGetLiveTurn();
    expect(canAdoptFromLive(inactiveLive)).toBe(false);
    // Control: an active live-turn with text passes the same gate and merges.
    const mockedActiveGetLiveTurn = async () => ({ active: true, text: "partial reply", reasoning: "", toolActions: [] });
    const activeLive = await mockedActiveGetLiveTurn();
    expect(canAdoptFromLive(activeLive)).toBe(true);
    const merged = mergeLiveSnapshotIntoInFlightTurn(null, {
      reasoning: "",
      text: "partial reply",
      toolActions: [],
    });
    expect(merged.text).toBe("partial reply");
    expect(merged.segments.some((segment) => segment.kind === "text")).toBe(true);
    // Rejection control: a throwing probe maps to no live-turn, so adopt stays false.
    const mockedRejectingGetLiveTurn = async (): Promise<null> => {
      try {
        throw new Error("probe failed");
      } catch {
        return null;
      }
    };
    const rejectedLive = await mockedRejectingGetLiveTurn();
    expect(canAdoptFromLive(rejectedLive)).toBe(false);
    expect(pendingRef.current).toBe(false);
  });
});
