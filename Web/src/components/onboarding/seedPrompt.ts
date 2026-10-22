// Rune Weaver Dashboard — Onboarding seed prompt selector.

import {
  completeOnboarding as apiCompleteOnboarding,
  isValidIndexWatermark,
  neverStartedOnboardingStatus,
  parseOnboardingStatus as parseApiOnboardingStatus,
  type OnboardingEmailAccount,
  type OnboardingStatus,
} from "../../api/onboarding";
import type { OnboardingGoal } from "./PersonaStep";

export type { OnboardingEmailAccount, OnboardingStatus };
export { neverStartedOnboardingStatus };

export type OnboardingBadge =
  | "Ready"
  | "Configured"
  | "Not connected"
  | "Needs permission";

export const CALENDAR_SEED_PROMPT =
  "Show my schedule for today and flag any conflicts.";
export const EMAIL_SEED_PROMPT =
  "Summarize my unread email from today and flag anything urgent.";
export const INDEX_SEED_PROMPT =
  "Search my indexed notes for the quarterly plan and summarize it.";
export const GENERIC_SEED_PROMPT =
  "What can you help me with?\n\nTry: Give me a Morning briefing of my day.";

// Single owner for digest text plus fixed name plus cron; schedule module imports.
export const ONBOARDING_EMAIL_SCHEDULE_NAME = "Morning email briefing";
export const ONBOARDING_EMAIL_SCHEDULE_CRON = "0 8 * * *";
export const ONBOARDING_EMAIL_DIGEST_PROMPT =
  "Summarize unread email from the last 24 hours and flag anything urgent. This is a read-only digest — do not send anything.";

export type OnboardingFinishDestination =
  | { kind: "schedules" }
  | { kind: "dashboard"; prompt: string }
  | { kind: "indexing"; highlightRun: boolean };

// Verified goal routes to its surface; anything unverified falls back to generic dashboard.
export function selectFinishDestination(
  status: OnboardingStatus | null | undefined,
  goal?: OnboardingGoal | null,
): OnboardingFinishDestination {
  if (goal === "inbox" && isGoalReady(status, goal)) {
    return { kind: "schedules" };
  }
  if (goal === "day" && isGoalReady(status, goal)) {
    return { kind: "dashboard", prompt: CALENDAR_SEED_PROMPT };
  }
  if (goal === "remember" && isGoalReady(status, goal)) {
    return { kind: "indexing", highlightRun: true };
  }
  return { kind: "dashboard", prompt: GENERIC_SEED_PROMPT };
}

// Single-parser adapter failing closed to never-started for legacy callers.
export function parseOnboardingStatus(value: unknown): OnboardingStatus {
  return parseApiOnboardingStatus(value) ?? neverStartedOnboardingStatus();
}

// Exact granted token alone counts; every other posture stays unverified.
export function isCalendarGranted(
  status: OnboardingStatus | null | undefined,
): boolean {
  if (!status || typeof status.calendarStatus !== "string") return false;
  return status.calendarStatus.trim().toLowerCase() === "granted";
}

// At least one account with a successful fetch proves the email path live.
export function isEmailReady(
  status: OnboardingStatus | null | undefined,
): boolean {
  if (!status || !Array.isArray(status.emailAccounts)) return false;
  return status.emailAccounts.some((account) => account.fetchSucceeded === true);
}

// Enabled plus a post-epoch watermark proves the index path; epoch
// or blank never counts.
export function isIndexReady(
  status: OnboardingStatus | null | undefined,
): boolean {
  if (!status) return false;
  if (status.indexEnabled !== true) return false;
  return isValidIndexWatermark(status.indexWatermark);
}

// Goal-scoped readiness gates verified routes so seed and destination agree.
export function isGoalReady(
  status: OnboardingStatus | null | undefined,
  goal: OnboardingGoal | null | undefined,
): boolean {
  if (goal === "inbox") return isEmailReady(status);
  if (goal === "day") return isCalendarGranted(status);
  if (goal === "remember") return isIndexReady(status);
  return false;
}

// Single connect check reusing evidence so card and seed agree.
export function isConnectReady(
  status: OnboardingStatus | null | undefined,
): boolean {
  if (!status) return false;
  return isCalendarGranted(status) || isEmailReady(status) || isIndexReady(status);
}

export function calendarBadge(
  status: OnboardingStatus | null | undefined,
): OnboardingBadge {
  if (isCalendarGranted(status)) return "Ready";
  return "Needs permission";
}

export function emailBadge(
  status: OnboardingStatus | null | undefined,
): OnboardingBadge {
  // A successful fetch proves liveness; accounts alone stay Configured.
  if (isEmailReady(status)) return "Ready";
  // Present accounts without a fetch prove configuration, not liveness.
  if (
    status &&
    Array.isArray(status.emailAccounts) &&
    status.emailAccounts.length > 0
  )
    return "Configured";
  return "Not connected";
}

export function indexBadge(
  status: OnboardingStatus | null | undefined,
): OnboardingBadge {
  if (isIndexReady(status)) return "Ready";
  // Enabled without a watermark proves configuration, not readiness.
  if (status?.indexEnabled === true) return "Configured";
  return "Not connected";
}

// Selects the single verified seed; unverified capabilities never seed a turn.
// Optional goal prefers its capability when ready, else fixed priority.
export function selectSeedPrompt(
  status: OnboardingStatus | null | undefined,
  goal?: OnboardingGoal | null,
): string {
  if (goal === "inbox" && isGoalReady(status, goal)) return EMAIL_SEED_PROMPT;
  if (goal === "day" && isGoalReady(status, goal)) return CALENDAR_SEED_PROMPT;
  if (goal === "remember" && isGoalReady(status, goal)) return INDEX_SEED_PROMPT;
  if (isCalendarGranted(status)) return CALENDAR_SEED_PROMPT;
  if (isEmailReady(status)) return EMAIL_SEED_PROMPT;
  if (isIndexReady(status)) return INDEX_SEED_PROMPT;
  return GENERIC_SEED_PROMPT;
}

export interface FinishOnboardingWithVerifiedSeedOptions {
  status: unknown;
  goal?: OnboardingGoal | null;
  complete?: (prompt: string) => Promise<void>;
  swallowCompleteErrors?: boolean;
}

// Single finish flow: verified seed plus completion.
// Completion throws unless swallowed for nav.
export async function finishOnboardingWithVerifiedSeed(
  options: FinishOnboardingWithVerifiedSeedOptions,
): Promise<string> {
  const base = parseOnboardingStatus(options.status ?? null);
  const prompt = selectSeedPrompt(base, options.goal ?? null);
  try {
    if (options.complete) await options.complete(prompt);
    else await apiCompleteOnboarding(prompt);
  } catch (err) {
    if (!options.swallowCompleteErrors) throw err;
    // Swallowed so the checklist still lands in chat; next focus converges.
  }
  return prompt;
}
