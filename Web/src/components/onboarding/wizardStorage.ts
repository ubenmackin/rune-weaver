// Rune Weaver Dashboard — Onboarding wizard session step persistence.
import { WIZARD_STEPS, type WizardStepId } from "./wizardState";
import { firstPendingStep } from "./wizardHelpers";

const WIZARD_STORAGE_KEY = "rw_wizard_step_v1";

export function readStoredWizardState(): {
  current: WizardStepId;
  history: WizardStepId[];
} | null {
  try {
    if (typeof window === "undefined" || !window.sessionStorage) return null;
    const raw = window.sessionStorage.getItem(WIZARD_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { current?: unknown; history?: unknown };
    if (!(WIZARD_STEPS as readonly string[]).includes(parsed?.current as string)) return null;
    const current = parsed.current as WizardStepId;
    const rawHistory = Array.isArray(parsed.history) ? parsed.history : [current];
    const history = rawHistory.filter((step): step is WizardStepId =>
      (WIZARD_STEPS as readonly string[]).includes(step as string),
    );
    if (history.length === 0) return { current, history: [current] };
    if (history[history.length - 1] !== current) return { current, history: [...history, current] };
    return { current, history };
  } catch {
    return null;
  }
}

export function persistWizardState(current: WizardStepId, history: WizardStepId[]): void {
  try {
    if (typeof window === "undefined" || !window.sessionStorage) return;
    window.sessionStorage.setItem(WIZARD_STORAGE_KEY, JSON.stringify({ current, history }));
  } catch {
    // Private-mode quota failures must not break step navigation.
  }
}

export function clearWizardState(): void {
  try {
    if (typeof window === "undefined" || !window.sessionStorage) return;
    window.sessionStorage.removeItem(WIZARD_STORAGE_KEY);
  } catch {
    // Removal failure never blocks completion.
  }
}

// Stored current wins only while still pending; history restores verbatim.
export function resolveInitialWizardState(clean: WizardStepId[] | null): {
  current: WizardStepId;
  history: WizardStepId[];
} {
  const first = clean ? (firstPendingStep(clean) ?? WIZARD_STEPS[0]) : WIZARD_STEPS[0];
  if (!clean) return { current: first, history: [first] };
  const stored = readStoredWizardState();
  if (!stored || clean.includes(stored.current)) return { current: first, history: [first] };
  const history = stored.history.filter((step): step is WizardStepId =>
    (WIZARD_STEPS as readonly string[]).includes(step as string),
  );
  if (history.length === 0) return { current: first, history: [first] };
  if (history[history.length - 1] !== stored.current) history.push(stored.current);
  return { current: stored.current, history };
}
