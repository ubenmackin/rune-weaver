// Rune Weaver Dashboard — Onboarding wizard step order and skip-aware navigation.
import { ONBOARDING_STEP_IDS, isOnboardingStepId, type OnboardingStepId } from "../../api/onboarding";

export type WizardStepId = OnboardingStepId;

export const WIZARD_STEPS: readonly WizardStepId[] = ONBOARDING_STEP_IDS;

// Single wizard advance contract so persona plus brain Next stay in lockstep.
export interface WizardNextOptions {
  current: WizardStepId;
  skipped: WizardStepId[];
  onAdvanced: (next: WizardStepId) => void;
  onFinished: () => Promise<void>;
}

export function isSkipped(step: WizardStepId, skipped: WizardStepId[]): boolean {
  if (!isOnboardingStepId(step)) return false;
  if (!Array.isArray(skipped)) return false;
  return skipped.includes(step);
}

export function nextStep(current: WizardStepId, skipped: WizardStepId[]): WizardStepId | null {
  const safeSkipped: WizardStepId[] = Array.isArray(skipped) ? skipped.filter(isOnboardingStepId) : [];
  if (!isOnboardingStepId(current) || WIZARD_STEPS.indexOf(current) === -1) {
    // Unknown step resumes at the first non-skipped entry so reload never strands.
    for (const step of WIZARD_STEPS) {
      if (!safeSkipped.includes(step)) return step;
    }
    return null;
  }
  const index = WIZARD_STEPS.indexOf(current);
  for (let i = index + 1; i < WIZARD_STEPS.length; i += 1) {
    const candidate = WIZARD_STEPS[i];
    if (!safeSkipped.includes(candidate)) return candidate;
  }
  return null;
}
