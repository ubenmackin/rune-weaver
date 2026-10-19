// Rune Weaver Dashboard — Onboarding seed prompt selector.

import {
  completeOnboarding as apiCompleteOnboarding,
  isValidIndexWatermark,
  neverStartedOnboardingStatus,
  parseOnboardingStatus as parseApiOnboardingStatus,
  type OnboardingEmailAccount,
  type OnboardingStatus,
} from "../../api/onboarding";
import { createGoal as apiCreateGoal, listGoals as apiListGoals } from "../../api";
import {
  DEMO_GOAL_STATEMENT,
  DEMO_GOAL_TITLE,
} from "../dashboard/dashboardGreeting";

export type { OnboardingEmailAccount, OnboardingStatus };
export { neverStartedOnboardingStatus };

export type OnboardingBadge = "Ready" | "Not connected" | "Needs permission";

export const CALENDAR_SEED_PROMPT =
  "Show my schedule for today and flag any conflicts.";
export const EMAIL_SEED_PROMPT =
  "Summarize my unread email from today and flag anything urgent.";
export const INDEX_SEED_PROMPT =
  "Search my indexed notes for the quarterly plan and summarize it.";
export const GENERIC_SEED_PROMPT =
  "What can you help me with?\n\nTry: Give me a Morning briefing of my day.";

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
// or blank never counts while the server flag stays as legacy fallback.
export function isIndexReady(
  status: OnboardingStatus | null | undefined,
): boolean {
  if (!status) return false;
  if (status.indexReady === true) return true;
  if (status.indexEnabled !== true) return false;
  return isValidIndexWatermark(status.indexWatermark);
}

// Single connect check reusing flags plus evidence so card and seed agree.
export function isConnectReady(
  status: OnboardingStatus | null | undefined,
): boolean {
  if (!status) return false;
  if (status.calendarReady === true || status.emailReady === true)
    return true;
  return isCalendarGranted(status) || isEmailReady(status) || isIndexReady(status);
}

export function calendarBadge(
  status: OnboardingStatus | null | undefined,
): OnboardingBadge {
  if (isCalendarGranted(status) || status?.calendarReady === true)
    return "Ready";
  return "Needs permission";
}

export function emailBadge(
  status: OnboardingStatus | null | undefined,
): OnboardingBadge {
  if (isEmailReady(status) || status?.emailReady === true) return "Ready";
  return "Not connected";
}

export function indexBadge(
  status: OnboardingStatus | null | undefined,
): OnboardingBadge {
  if (isIndexReady(status)) return "Ready";
  return "Not connected";
}

// Selects the single verified seed; unverified capabilities never seed a turn.
export function selectSeedPrompt(
  status: OnboardingStatus | null | undefined,
): string {
  if (isCalendarGranted(status) || status?.calendarReady === true)
    return CALENDAR_SEED_PROMPT;
  if (isEmailReady(status) || status?.emailReady === true)
    return EMAIL_SEED_PROMPT;
  if (isIndexReady(status)) return INDEX_SEED_PROMPT;
  return GENERIC_SEED_PROMPT;
}

export interface FinishOnboardingWithVerifiedSeedOptions {
  status: unknown;
  complete?: (prompt: string) => Promise<void>;
  swallowCompleteErrors?: boolean;
}

// Single finish flow: verified seed plus demo goal plus completion.
// Demo failures never block; completion throws unless swallowed for nav.
export async function finishOnboardingWithVerifiedSeed(
  options: FinishOnboardingWithVerifiedSeedOptions,
): Promise<string> {
  const base = parseOnboardingStatus(options.status ?? null);
  const prompt = selectSeedPrompt(base);
  try {
    const res = await apiListGoals();
    const goals = Array.isArray((res as { goals?: unknown })?.goals)
      ? ((res as { goals: unknown[] }).goals ?? [])
      : [];
    if (goals.length === 0) {
      await apiCreateGoal({ title: DEMO_GOAL_TITLE, statement: DEMO_GOAL_STATEMENT });
    }
  } catch {
    // Demo creation never blocks landing in chat with the seed prompt.
  }
  try {
    if (options.complete) await options.complete(prompt);
    else await apiCompleteOnboarding(prompt);
  } catch (err) {
    if (!options.swallowCompleteErrors) throw err;
    // Swallowed so the checklist still lands in chat; next focus converges.
  }
  return prompt;
}
