// Rune Weaver Dashboard — Wizard-owned persona draft plus save state.
import { useEffect, useRef, useState } from "react";
import { updateSettings } from "../../api";
import { fetchJson } from "../../api/http";
import {
  validatePersonaStep,
  type OnboardingGoal,
  type PersonaDraftValue,
} from "./PersonaStep";
import { nextStep, type WizardNextOptions } from "./wizardState";

export interface UsePersonaWizardOptions {
  setStepError: (message: string | null) => void;
  setError: (message: string | null) => void;
  standalone?: boolean;
  hydrated?: boolean;
}

// Single state owner stays the wizard shell; this only groups the
// draft plus save fields behind one call site.
export function usePersonaWizard(options: UsePersonaWizardOptions) {
  const { setStepError, setError, standalone, hydrated } = options;
  const [draft, setDraft] = useState<PersonaDraftValue>({
    assistantName: "",
    userName: "",
    goal: "",
  });
  const [saving, setSaving] = useState(false);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const personaDirtyRef = useRef(false);

  // Stored names prefill a pristine draft; typed input always wins.
  useEffect(() => {
    if (standalone) return;
    if (hydrated === false) return;
    let cancelled = false;
    void (async () => {
      try {
        const settings = await fetchJson<{
          persona?: { assistantName?: unknown; userName?: unknown };
        }>("/settings");
        if (cancelled) return;
        if (personaDirtyRef.current) return;
        const rawAssistant = settings?.persona?.assistantName;
        const rawUser = settings?.persona?.userName;
        const assistantName = typeof rawAssistant === "string" ? rawAssistant.trim() : "";
        const userName = typeof rawUser === "string" ? rawUser.trim() : "";
        if (!assistantName && !userName) return;
        setDraft((prev) => ({
          ...prev,
          assistantName: assistantName || prev.assistantName,
          userName: userName || prev.userName,
        }));
      } catch {
        // Keep the blank draft when the persona read fails.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [standalone, hydrated]);

  function handlePatch(patch: Partial<PersonaDraftValue>) {
    personaDirtyRef.current = true;
    setDraft((prev) => ({ ...prev, ...patch }));
    // Any edit clears the inline message so a fixed field never keeps stale text.
    setFieldError(null);
    setStepError(null);
  }

  function clearErrors() {
    setFieldError(null);
    setStepError(null);
  }

  // Persona failures stay local so the wizard banner never mirrors inline text.
  async function handleNext(nextOptions: WizardNextOptions) {
    const { current, onAdvanced, onFinished } = nextOptions;
    const problem = validatePersonaStep({
      assistantName: draft.assistantName,
      userName: draft.userName,
      goal: draft.goal,
    });
    if (problem) {
      setFieldError(problem);
      return;
    }
    const trimmedAssistant = draft.assistantName.trim();
    const trimmedUser = draft.userName.trim();
    const goal = draft.goal as OnboardingGoal;
    setSaving(true);
    setFieldError(null);
    setStepError(null);
    try {
      await updateSettings({
        persona: { assistantName: trimmedAssistant, userName: trimmedUser },
      });
      setDraft({ assistantName: trimmedAssistant, userName: trimmedUser, goal });
      setError(null);
      setStepError(null);
      setFieldError(null);
      const next = nextStep(current);
      if (!next) {
        await onFinished();
        return;
      }
      onAdvanced(next);
    } catch (err) {
      setFieldError(err instanceof Error ? err.message : "Failed to save persona.");
    } finally {
      setSaving(false);
    }
  }

  return {
    draft,
    saving,
    fieldError,
    onPatch: handlePatch,
    onNext: handleNext,
    clearErrors,
  };
}
