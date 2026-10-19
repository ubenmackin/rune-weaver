// Rune Weaver Dashboard — Onboarding allowlist contract pinning the Swift set.
import { describe, expect, it } from "vitest";
import { ONBOARDING_STEP_IDS, isOnboardingStepId } from "./onboarding";
import { WIZARD_STEPS } from "../components/onboarding/wizardState";

describe("onboarding allowlist contract", () => {
  it("pins the four-value step union in canonical order", () => {
    expect([...ONBOARDING_STEP_IDS]).toEqual(["brain", "persona", "connect", "protect"]);
  });

  it("matches the Swift allowedSteps snapshot as a set", () => {
    expect([...ONBOARDING_STEP_IDS].sort()).toEqual([
      "brain",
      "connect",
      "persona",
      "protect",
    ]);
    expect(isOnboardingStepId("brain")).toBe(true);
    expect(isOnboardingStepId("persona")).toBe(true);
    expect(isOnboardingStepId("connect")).toBe(true);
    expect(isOnboardingStepId("protect")).toBe(true);
    expect(isOnboardingStepId("unknown")).toBe(false);
    expect(isOnboardingStepId(42)).toBe(false);
  });

  it("keeps a single web source shared with the wizard", () => {
    expect([...WIZARD_STEPS]).toEqual([...ONBOARDING_STEP_IDS]);
  });
});
