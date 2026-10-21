// Rune Weaver Dashboard — Onboarding wizard shared skip-to-dismiss helper.
import { skipOnboardingStep } from "../../api/onboarding";
import type { WizardStepId } from "./wizardState";
import { snoozeWizard } from "./wizardSnooze";

// Single skip owner: records the server skip then snoozes so resume lands past it.
export async function recordSkipAndSnooze(
  step: WizardStepId,
  recordSkip?: (step: WizardStepId) => Promise<void>,
): Promise<void> {
  if (recordSkip) await recordSkip(step);
  else await skipOnboardingStep(step);
  snoozeWizard();
}
