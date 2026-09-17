// Shared staged Start progress for the SearXNG container lifecycle.
// Covers the dual-contract stage resolvers, per-stage copy, pulling-cap
// suspension, and elapsed math so the profile menu and the Settings search
// pane stay in lockstep on one contract instead of duplicating the logic.

import { describe, expect, it } from "vitest";
import {
  SEARCH_START_CAP_MS,
  SEARCH_START_POLL_INTERVAL_MS,
  SEARCH_START_STAGE_COPY,
  isSearchStartPullingStage,
  resolveStartStage,
  resolveStartStartedAt,
  searchStageCopy,
  startElapsedSeconds,
} from "./api";

describe("search start progress resolvers", () => {
  it("pins the client cap past the minutes-budget pull with a 1s poll", () => {
    // The cap bounds a hung Start past the first-run image pull plus the
    // cached cascade; the poll stays about 1s so the stage line tracks the
    // cascade instead of sitting static.
    expect(SEARCH_START_POLL_INTERVAL_MS).toBe(1000);
    expect(SEARCH_START_CAP_MS).toBe(360_000);
  });

  it("resolves the live stage across both health contracts", () => {
    // /search/health uses stage/startedAt while /health nests the same values
    // under searchStage/searchStartedAt; blank or missing steps read as idle.
    expect(resolveStartStage({ stage: "pulling" })).toBe("pulling");
    expect(resolveStartStage({ searchStage: "starting" })).toBe("starting");
    expect(resolveStartStage({ stage: "  ", searchStage: "waiting" })).toBe(
      "waiting",
    );
    expect(resolveStartStage({ stage: "", searchStage: "" })).toBeNull();
    expect(resolveStartStage({})).toBeNull();
    expect(resolveStartStage(null)).toBeNull();
    expect(resolveStartStage(undefined)).toBeNull();
  });

  it("resolves the Start time across both contracts with garbage rejected", () => {
    // Unix seconds ride both keys; missing, non-positive, or non-finite
    // values degrade to unknown so elapsed math falls back to the client
    // Start instant instead of rendering from a garbage epoch.
    const at = 1_700_000_000;
    expect(resolveStartStartedAt({ startedAt: at })).toBe(at);
    expect(resolveStartStartedAt({ searchStartedAt: at })).toBe(at);
    expect(resolveStartStartedAt({ startedAt: 0 })).toBeNull();
    expect(resolveStartStartedAt({ searchStartedAt: -5 })).toBeNull();
    expect(resolveStartStartedAt({ startedAt: Number.NaN })).toBeNull();
    expect(resolveStartStartedAt({ startedAt: Number.POSITIVE_INFINITY })).toBeNull();
    expect(resolveStartStartedAt({})).toBeNull();
    expect(resolveStartStartedAt(null)).toBeNull();
  });

  it("maps every stage to engine copy with drift degrading to Starting", () => {
    // Single-sourced copy mirrors the engine userCopy; unknown or drifted
    // steps fall back to a bare Starting label instead of blanking the line.
    expect(SEARCH_START_STAGE_COPY).toEqual({
      resolving: "Checking container runtime",
      daemon: "Waking container service",
      pulling: "Pulling search image",
      starting: "Starting search container",
      waiting: "Waiting for search to respond",
    });
    expect(searchStageCopy("resolving")).toBe("Checking container runtime");
    expect(searchStageCopy("daemon")).toBe("Waking container service");
    expect(searchStageCopy("pulling")).toBe("Pulling search image");
    expect(searchStageCopy("starting")).toBe("Starting search container");
    expect(searchStageCopy("waiting")).toBe("Waiting for search to respond");
    expect(searchStageCopy("unknown-step")).toBe("Starting");
    expect(searchStageCopy("")).toBe("Starting");
    expect(searchStageCopy(null)).toBe("Starting");
    expect(searchStageCopy(undefined)).toBe("Starting");
  });

  it("computes whole elapsed seconds preferring the engine Start time", () => {
    // The snapshot Start time is pinned at flight creation so elapsed counts
    // the whole Start across stage moves; clock skew never renders negative.
    const startedAt = 1_700_000_000;
    const nowMs = (startedAt + 65) * 1000;
    expect(startElapsedSeconds(startedAt, nowMs - 65_000, nowMs)).toBe(65);
    expect(startElapsedSeconds(null, nowMs - 12_000, nowMs)).toBe(12);
    expect(startElapsedSeconds(undefined, nowMs - 12_000, nowMs)).toBe(12);
    // Fractional seconds floor so the tick advances once per second.
    expect(startElapsedSeconds(startedAt, 0, (startedAt + 1.9) * 1000)).toBe(1);
    // A future-dated Start clamps to zero instead of counting backwards.
    expect(startElapsedSeconds(startedAt + 60, startedAt * 1000, startedAt * 1000)).toBe(0);
  });

  it("suspends the client cap while the stage reports pulling", () => {
    // Past the cap the UI stops the stage line and re-probes the dot while
    // keeping the toggle locked; pulling suspends that path so a first-run
    // pull never trips the hung-Start branch early.
    const pastCap = (ms: number, stage: string | null) =>
      ms > SEARCH_START_CAP_MS && !isSearchStartPullingStage(stage);
    expect(isSearchStartPullingStage("pulling")).toBe(true);
    expect(isSearchStartPullingStage("starting")).toBe(false);
    expect(isSearchStartPullingStage(null)).toBe(false);
    expect(pastCap(SEARCH_START_CAP_MS + 1, "pulling")).toBe(false);
    expect(pastCap(SEARCH_START_CAP_MS + 1, "starting")).toBe(true);
    expect(pastCap(SEARCH_START_CAP_MS + 1, null)).toBe(true);
    expect(pastCap(SEARCH_START_CAP_MS - 1, "starting")).toBe(false);
  });
});
