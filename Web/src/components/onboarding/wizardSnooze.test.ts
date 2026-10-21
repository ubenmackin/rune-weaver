// Rune Weaver Dashboard — Tests for the onboarding wizard snooze flag.
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  WIZARD_SNOOZE_KEY,
  clearWizardSnooze,
  isWizardSnoozed,
  resumeWizard,
  snoozeWizard,
  subscribeWizardSnooze,
} from "./wizardSnooze";

beforeEach(() => {
  window.localStorage.clear();
});

afterEach(() => {
  window.localStorage.clear();
});

describe("wizardSnooze", () => {
  it("starts unsnoozed with no stored flag", () => {
    expect(isWizardSnoozed()).toBe(false);
  });

  it("sets the flag on snooze and clears it on clear", () => {
    snoozeWizard();
    expect(window.localStorage.getItem(WIZARD_SNOOZE_KEY)).toBe("1");
    expect(isWizardSnoozed()).toBe(true);
    clearWizardSnooze();
    expect(window.localStorage.getItem(WIZARD_SNOOZE_KEY)).toBeNull();
    expect(isWizardSnoozed()).toBe(false);
  });

  it("clears the flag on resume", () => {
    snoozeWizard();
    expect(isWizardSnoozed()).toBe(true);
    resumeWizard();
    expect(isWizardSnoozed()).toBe(false);
  });

  it("fails closed on foreign values", () => {
    window.localStorage.setItem(WIZARD_SNOOZE_KEY, "yes");
    expect(isWizardSnoozed()).toBe(false);
  });

  it("notifies subscribers on snooze and clear in the same tab", () => {
    const seen: boolean[] = [];
    const unsubscribe = subscribeWizardSnooze((snoozed) => {
      seen.push(snoozed);
    });
    try {
      snoozeWizard();
      clearWizardSnooze();
    } finally {
      unsubscribe();
    }
    expect(seen).toEqual([true, false]);
  });

  it("does not notify after unsubscribe", () => {
    const seen: boolean[] = [];
    const unsubscribe = subscribeWizardSnooze((snoozed) => {
      seen.push(snoozed);
    });
    unsubscribe();
    snoozeWizard();
    expect(seen).toEqual([]);
  });

  it("syncs across tabs through the storage event", () => {
    const seen: boolean[] = [];
    const unsubscribe = subscribeWizardSnooze((snoozed) => {
      seen.push(snoozed);
    });
    try {
      window.dispatchEvent(
        new StorageEvent("storage", { key: WIZARD_SNOOZE_KEY, newValue: "1" }),
      );
      window.dispatchEvent(
        new StorageEvent("storage", { key: WIZARD_SNOOZE_KEY, newValue: null }),
      );
    } finally {
      unsubscribe();
    }
    expect(seen).toEqual([true, false]);
  });

  it("ignores storage events for unrelated keys", () => {
    const seen: boolean[] = [];
    const unsubscribe = subscribeWizardSnooze((snoozed) => {
      seen.push(snoozed);
    });
    try {
      window.dispatchEvent(
        new StorageEvent("storage", { key: "rw_unrelated", newValue: "1" }),
      );
    } finally {
      unsubscribe();
    }
    expect(seen).toEqual([]);
  });
});
