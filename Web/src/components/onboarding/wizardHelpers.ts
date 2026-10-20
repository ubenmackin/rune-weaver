// Rune Weaver Dashboard — Onboarding wizard navigation plus footer text helpers.
import type { OnboardingStatus as ApiOnboardingStatus } from "../../api/onboarding";
import { WIZARD_STEPS, isSkipped, type WizardStepId } from "./wizardState";
import type { OnboardingStatus as SeedStatus } from "./seedPrompt";

// Footer mirror bound keeps the bar to one compact line, ellipsis inclusive.
export const WIZARD_FOOTER_ERROR_MAX_LENGTH = 140;

// Overlong messages cut within the bound with an ellipsis; empty stays empty
// so the footer reserves space without rendering text.
export function truncateWizardFooterError(value: string | null | undefined): string {
  if (typeof value !== "string" || value.length === 0) return "";
  if (value.length <= WIZARD_FOOTER_ERROR_MAX_LENGTH) return value;
  return `${value.slice(0, WIZARD_FOOTER_ERROR_MAX_LENGTH - 1)}…`;
}

// Server snapshot is the single ack source; the checkbox never persists.
export function toSeedStatus(value: ApiOnboardingStatus | null): SeedStatus | null {
  if (!value) return null;
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
    calendarReady: value.calendarReady,
    emailReady: value.emailReady,
    indexReady: value.indexReady,
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
