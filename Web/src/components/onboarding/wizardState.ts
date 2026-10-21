// Rune Weaver Dashboard — Onboarding wizard fixed-order step navigation.
import { ONBOARDING_STEP_IDS, isOnboardingStepId, type OnboardingStepId } from "../../api/onboarding";

export type WizardStepId = OnboardingStepId;

export const WIZARD_STEPS: readonly WizardStepId[] = ONBOARDING_STEP_IDS;

// Single wizard advance contract so persona plus brain Next stay in lockstep.
export interface WizardNextOptions {
  current: WizardStepId;
  onAdvanced: (next: WizardStepId) => void;
  onFinished: () => Promise<void>;
}

export function isSkipped(step: WizardStepId, skipped: WizardStepId[]): boolean {
  if (!isOnboardingStepId(step)) return false;
  if (!Array.isArray(skipped)) return false;
  return skipped.includes(step);
}

// Fixed neighbor lookup so skipped steps still re-show on demand.
export function prevStep(current: WizardStepId): WizardStepId | null {
  const index = WIZARD_STEPS.indexOf(current);
  if (index <= 0) return null;
  return WIZARD_STEPS[index - 1];
}

export function nextStep(current: WizardStepId): WizardStepId | null {
  const index = WIZARD_STEPS.indexOf(current);
  if (index === -1 || index >= WIZARD_STEPS.length - 1) return null;
  return WIZARD_STEPS[index + 1];
}
