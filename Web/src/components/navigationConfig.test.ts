// Rune Weaver Dashboard — Unit tests for the shared navigation contract.
//
// Pins the desktop group composition, the membership-based active rule, and the
// fail-closed badge roll-up directly against navigationConfig rather than only
// through a TopNav render, so the contract the top nav and the mobile bottom
// bar both consume cannot drift underneath them.

import { describe, expect, it } from "vitest";
import {
  NAV_GROUPS,
  formatBadgeCount,
  isGroupActive,
  normalizeBadgeCount,
  rolledUpBadge,
} from "./navigationConfig";

describe("navigation contract", () => {
  it("exposes the canonical desktop order with Work folding goals, schedules, and runs", () => {
    expect(NAV_GROUPS.map((entry) => entry.id)).toEqual([
      "chat",
      "approvals",
      "work",
      "memory",
    ]);
    const work = NAV_GROUPS.find((entry) => entry.id === "work");
    expect(work?.kind).toBe("group");
    if (!work || work.kind !== "group") {
      throw new Error("Work must be a folding group");
    }
    expect(work.label).toBe("Work");
    expect(work.children.map((child) => child.id)).toEqual([
      "goals",
      "schedules",
      "runs",
    ]);
    expect(work.children.map((child) => child.label)).toEqual([
      "Goals",
      "Schedules",
      "Runs",
    ]);
  });

  it("treats group membership as active and unknown groups as inactive", () => {
    expect(isGroupActive("work", "goals")).toBe(true);
    expect(isGroupActive("work", "schedules")).toBe(true);
    expect(isGroupActive("work", "runs")).toBe(true);
    expect(isGroupActive("work", "chat")).toBe(false);
    expect(isGroupActive("approvals", "approvals")).toBe(true);
    expect(isGroupActive("approvals", "runs")).toBe(false);
  });

  it("rolls normalized child counts up and reports leaf badges", () => {
    expect(rolledUpBadge("work", { goals: 2, runs: 3 })).toBe(5);
    expect(rolledUpBadge("work", { goals: -1, runs: 2.9, schedules: 1 })).toBe(3);
    expect(rolledUpBadge("work", {})).toBe(0);
    expect(rolledUpBadge("approvals", { approvals: 7 })).toBe(7);
    expect(rolledUpBadge("approvals", {})).toBe(0);
  });

  it("normalizes and formats badge counts fail-closed", () => {
    expect(normalizeBadgeCount(2.9)).toBe(2);
    expect(normalizeBadgeCount(-4)).toBe(0);
    expect(normalizeBadgeCount(Number.NaN)).toBe(0);
    expect(normalizeBadgeCount("3")).toBe(0);
    expect(formatBadgeCount(0)).toBe("");
    expect(formatBadgeCount(7)).toBe("7");
    expect(formatBadgeCount(120)).toBe("99+");
  });
});
