// Rune Weaver Dashboard — Onboarding persona names plus goal step.
import { useEffect, useRef } from "react";

export type OnboardingGoal = "inbox" | "day" | "remember";
export type Step3CardId = "email" | "calendar" | "index";

export interface PersonaDraftValue {
  assistantName: string;
  userName: string;
  goal: OnboardingGoal | "";
}

export interface PersonaStepProps {
  value: PersonaDraftValue;
  onChange: (patch: Partial<PersonaDraftValue>) => void;
  error?: string | null;
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

export function PersonaStep({ value, onChange, error = null }: PersonaStepProps) {
  const errorRef = useRef<HTMLParagraphElement>(null);

  // Inline failure steals focus after paint so keyboard users land on the message.
  useEffect(() => {
    if (error) {
      errorRef.current?.scrollIntoView({ block: "nearest" });
      errorRef.current?.focus({ preventScroll: true });
    }
  }, [error]);

  return (
    <section className="onboarding-step" data-testid="persona-step" aria-label="Meet your assistant">
      <h2>Meet your assistant</h2>
      <p className="onboarding-step-subtitle">Choose names and a first goal to personalize Rune Weaver.</p>
      <div className="form-group">
        <label htmlFor="persona-assistant-name">Assistant name</label>
        <input
          id="persona-assistant-name"
          data-testid="persona-assistant-name"
          className="input-field"
          type="text"
          value={value.assistantName}
          maxLength={ONBOARDING_NAME_MAX_LENGTH}
          onChange={(e) => onChange({ assistantName: e.target.value })}
          placeholder="Rune Weaver"
        />
      </div>
      <div className="form-group">
        <label htmlFor="persona-user-name">Your name</label>
        <input
          id="persona-user-name"
          data-testid="persona-user-name"
          className="input-field"
          type="text"
          value={value.userName}
          maxLength={ONBOARDING_NAME_MAX_LENGTH}
          onChange={(e) => onChange({ userName: e.target.value })}
          placeholder="Ada"
        />
      </div>
      <fieldset className="form-group persona-goal-group">
        <legend>What should we set up first?</legend>
        <div role="radiogroup" aria-label="Onboarding goal">
          {ONBOARDING_GOALS.map((option) => (
            <label key={option.value} className="onboarding-radio-card">
              <input
                type="radio"
                name="onboarding-goal"
                value={option.value}
                data-testid={`persona-goal-${option.value}`}
                checked={value.goal === option.value}
                onChange={() => onChange({ goal: option.value })}
              />
              {option.label}
            </label>
          ))}
        </div>
      </fieldset>
      {error ? (
        <p
          ref={errorRef}
          tabIndex={-1}
          data-testid="persona-error"
          role="alert"
          className="error-banner"
        >
          {error}
        </p>
      ) : null}
    </section>
  );
}

export default PersonaStep;
