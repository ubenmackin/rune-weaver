// Rune Weaver Dashboard — Onboarding persona names plus goal step.
import { useState } from "react";
import { updateSettings } from "../../api";

export type OnboardingGoal = "inbox" | "day" | "remember";
export type Step3CardId = "email" | "calendar" | "index";

export interface PersonaStepValue {
  assistantName: string;
  userName: string;
  goal: OnboardingGoal;
}

export interface PersonaStepProps {
  initialAssistantName?: string;
  initialUserName?: string;
  initialGoal?: OnboardingGoal | "";
  onBack?: () => void;
  onNext?: (value: PersonaStepValue) => void;
}

export const ONBOARDING_GOALS: Array<{ value: OnboardingGoal; label: string }> = [
  { value: "inbox", label: "Triage my inbox" },
  { value: "day", label: "Stay ahead of my day" },
  { value: "remember", label: "Remember things for me" },
];

export const ONBOARDING_NAME_MIN_LENGTH = 1;
export const ONBOARDING_NAME_MAX_LENGTH = 64;

export function isOnboardingGoal(value: unknown): value is OnboardingGoal {
  return value === "inbox" || value === "day" || value === "remember";
}

// Fail-closed client bounds: trimmed names stay 1-64 chars and the goal
// stays inside the closed set before any network write happens.
export function validatePersonaStep(input: {
  assistantName: string;
  userName: string;
  goal: string;
}): string | null {
  const assistant = (input.assistantName ?? "").trim();
  if (assistant.length < ONBOARDING_NAME_MIN_LENGTH || assistant.length > ONBOARDING_NAME_MAX_LENGTH) {
    return "Assistant name must be 1 to 64 characters.";
  }
  const user = (input.userName ?? "").trim();
  if (user.length < ONBOARDING_NAME_MIN_LENGTH || user.length > ONBOARDING_NAME_MAX_LENGTH) {
    return "Your name must be 1 to 64 characters.";
  }
  if (!isOnboardingGoal((input.goal ?? "").trim())) {
    return "Choose exactly one goal to continue.";
  }
  return null;
}

// Goal pins the first Step 3 card; every card stays visible and selectable
// behind the pinned order so no capability hides.
export function step3CardOrderForGoal(goal: OnboardingGoal): Step3CardId[] {
  if (goal === "day") return ["calendar", "email", "index"];
  if (goal === "remember") return ["index", "email", "calendar"];
  return ["email", "calendar", "index"];
}

export function PersonaStep({
  initialAssistantName = "",
  initialUserName = "",
  initialGoal = "",
  onBack,
  onNext,
}: PersonaStepProps) {
  const [assistantName, setAssistantName] = useState(initialAssistantName);
  const [userName, setUserName] = useState(initialUserName);
  const [goal, setGoal] = useState<OnboardingGoal | "">(initialGoal);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function handleNext() {
    const problem = validatePersonaStep({ assistantName, userName, goal });
    if (problem) {
      setError(problem);
      return;
    }
    setSaving(true);
    setError(null);
    const trimmedAssistant = assistantName.trim();
    const trimmedUser = userName.trim();
    const nextGoal = goal as OnboardingGoal;
    try {
      // Names persist through the existing persona patch; the goal travels
      // with wizard state to order Step 3 with no new server key.
      await updateSettings({
        persona: { assistantName: trimmedAssistant, userName: trimmedUser },
      });
      onNext?.({ assistantName: trimmedAssistant, userName: trimmedUser, goal: nextGoal });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to save persona.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="onboarding-step" data-testid="persona-step" aria-label="Meet your assistant">
      <h2>Meet your assistant</h2>
      <div>
        <label htmlFor="persona-assistant-name">Assistant name</label>
        <input
          id="persona-assistant-name"
          data-testid="persona-assistant-name"
          type="text"
          value={assistantName}
          maxLength={ONBOARDING_NAME_MAX_LENGTH}
          onChange={(e) => setAssistantName(e.target.value)}
          placeholder="Rune Weaver"
        />
      </div>
      <div>
        <label htmlFor="persona-user-name">Your name</label>
        <input
          id="persona-user-name"
          data-testid="persona-user-name"
          type="text"
          value={userName}
          maxLength={ONBOARDING_NAME_MAX_LENGTH}
          onChange={(e) => setUserName(e.target.value)}
          placeholder="Ada"
        />
      </div>
      <fieldset>
        <legend>What should we set up first?</legend>
        <div role="radiogroup" aria-label="Onboarding goal">
          {ONBOARDING_GOALS.map((option) => (
            <label key={option.value}>
              <input
                type="radio"
                name="onboarding-goal"
                value={option.value}
                data-testid={`persona-goal-${option.value}`}
                checked={goal === option.value}
                onChange={() => setGoal(option.value)}
              />
              {option.label}
            </label>
          ))}
        </div>
      </fieldset>
      {error ? (
        <p data-testid="persona-error" role="alert">
          {error}
        </p>
      ) : null}
      <div>
        {onBack ? (
          <button type="button" data-testid="persona-back" onClick={onBack}>
            Back
          </button>
        ) : null}
        <button type="button" data-testid="persona-next" disabled={saving} onClick={() => void handleNext()}>
          {saving ? "Saving…" : "Next"}
        </button>
      </div>
    </section>
  );
}

export default PersonaStep;
