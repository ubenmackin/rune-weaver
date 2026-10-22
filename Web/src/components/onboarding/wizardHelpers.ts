// Rune Weaver Dashboard — Onboarding wizard navigation helpers.
import type { OnboardingStatus as ApiOnboardingStatus } from "../../api/onboarding";
import { WIZARD_STEPS, isSkipped, type WizardStepId } from "./wizardState";
import type { OnboardingStatus as SeedStatus } from "./seedPrompt";

// Server snapshot is the single ack source; the checkbox never persists.
export function toSeedStatus(value: ApiOnboardingStatus | null): SeedStatus | null {
  if (!value) return null;
  // Readiness derives from evidence alone; legacy flags stay unset so stale signals never pass.
  return {
    completedAt: value.completedAt,
    skippedSteps: [...value.skippedSteps],
    checklistDismissed: value.checklistDismissed,
    seedPromptUsed: value.seedPromptUsed,
    calendarStatus: value.calendarStatus,
    emailAccounts: value.emailAccounts.map((account) => ({
      address: account.address,
      fetchSucceeded: account.fetchSucceeded,
    })),
    indexEnabled: value.indexEnabled,
    indexWatermark: value.indexWatermark,
    personaSet: value.personaSet,
    policyAcked: value.policyAcked,
    pendingPermission: false,
  };
}

export function readStandaloneMode(): boolean {
  if (typeof window === "undefined") return false;
  try {
    const params = new URLSearchParams(window.location.search);
    if (params.get("standalone") === "true") return true;
  } catch {
    return false;
  }
  return window.location.hash.includes("standalone=true");
}

export function firstPendingStep(skipped: WizardStepId[]): WizardStepId | null {
  for (const step of WIZARD_STEPS) {
    if (!isSkipped(step, skipped)) return step;
  }
  return null;
}
