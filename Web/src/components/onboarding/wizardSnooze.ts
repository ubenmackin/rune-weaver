// Rune Weaver Dashboard — Onboarding wizard snooze flag for Settings trips.
export const WIZARD_SNOOZE_KEY = "rw_wizard_snoozed";
export const WIZARD_SNOOZE_CHANGE_EVENT = "rw_wizard_snooze_changed";

function readSnoozed(): boolean {
  try {
    if (typeof window === "undefined" || !window.localStorage) return false;
    return window.localStorage.getItem(WIZARD_SNOOZE_KEY) === "1";
  } catch {
    return false;
  }
}

export function isWizardSnoozed(): boolean {
  return readSnoozed();
}

function emitSnoozed(snoozed: boolean): void {
  try {
    if (typeof window !== "undefined" && typeof window.dispatchEvent === "function") {
      window.dispatchEvent(
        new CustomEvent<boolean>(WIZARD_SNOOZE_CHANGE_EVENT, { detail: snoozed }),
      );
    }
  } catch {
    // Private-mode or test doubles must not break Settings navigation.
  }
}

export function snoozeWizard(): void {
  try {
    if (typeof window !== "undefined" && window.localStorage) {
      window.localStorage.setItem(WIZARD_SNOOZE_KEY, "1");
    }
  } catch {
    // Quota-denied snooze still emits so the current tab hides the wizard.
  }
  emitSnoozed(true);
}

// Single settings-nav owner: snooze first then navigate same-tab.
export type WizardSettingsTab = "email" | "indexing" | "access";

export function goToSettings(tab: WizardSettingsTab): void {
  snoozeWizard();
  if (typeof window !== "undefined") {
    window.location.hash = `#settings/${tab}`;
  }
}

export function clearWizardSnooze(): void {
  try {
    if (typeof window !== "undefined" && window.localStorage) {
      window.localStorage.removeItem(WIZARD_SNOOZE_KEY);
    }
  } catch {
    // Removal failure still emits so listeners converge on unsnoozed.
  }
  emitSnoozed(false);
}

// Resume reopens at the persisted step, so it only clears the snooze flag.
export function resumeWizard(): void {
  clearWizardSnooze();
}

export function subscribeWizardSnooze(listener: (snoozed: boolean) => void): () => void {
  if (typeof window === "undefined" || typeof window.addEventListener !== "function") {
    return () => {};
  }
  const handleCustom = (event: Event) => {
    const detail = (event as CustomEvent<boolean>).detail;
    listener(typeof detail === "boolean" ? detail : readSnoozed());
  };
  const handleStorage = (event: StorageEvent) => {
    if (event.key !== null && event.key !== WIZARD_SNOOZE_KEY) return;
    if (event.key === null) {
      listener(readSnoozed());
      return;
    }
    listener(event.newValue === "1");
  };
  window.addEventListener(WIZARD_SNOOZE_CHANGE_EVENT, handleCustom);
  window.addEventListener("storage", handleStorage);
  return () => {
    window.removeEventListener(WIZARD_SNOOZE_CHANGE_EVENT, handleCustom);
    window.removeEventListener("storage", handleStorage);
  };
}
