// Rune Weaver Dashboard — Onboarding HTTP client and status contract.
import { ApiError, fetchJson } from "./http";
import { isRecord } from "../typeGuards";

export type OnboardingStepId = "brain" | "persona" | "connect" | "protect";

export const ONBOARDING_STEP_IDS: readonly OnboardingStepId[] = [
  "brain",
  "persona",
  "connect",
  "protect",
];

// Fail-closed membership check so only the four allowlisted ids reach the wire.
export function isOnboardingStepId(value: unknown): value is OnboardingStepId {
  return (
    typeof value === "string" &&
    (ONBOARDING_STEP_IDS as readonly string[]).includes(value)
  );
}

// Single web source for the seed-prompt bound so truncation and engine storage agree.
export const MAX_SEED_PROMPT_CHARS = 200;

// Truncates an overlong seed prompt with an ellipsis so the complete call never
// sends more than the bound while keeping the tail visibly shortened.
export function truncateSeedPromptUsed(value: unknown): string {
  if (typeof value !== "string") return "";
  const chars = Array.from(value);
  if (chars.length <= MAX_SEED_PROMPT_CHARS) return value;
  return `${chars.slice(0, MAX_SEED_PROMPT_CHARS - 1).join("")}…`;
}

export interface OnboardingItemState {
  id: OnboardingStepId;
  completed: boolean;
  skipped: boolean;
}

export interface OnboardingEmailAccount {
  address: string;
  fetchSucceeded: boolean;
}

// Single status shape for GET /onboarding/status; seeding and checklist reuse it.
export interface OnboardingStatus {
  completed?: boolean;
  completedAt: string | null;
  skippedSteps: OnboardingStepId[];
  checklistDismissed: boolean;
  seedPromptUsed: string | null;
  items?: OnboardingItemState[];
  brainReady?: boolean;
  personaSet: boolean;
  emailReady?: boolean;
  calendarReady?: boolean;
  indexReady?: boolean;
  policyAcked: boolean;
  calendarStatus: string | null;
  emailAccounts: OnboardingEmailAccount[];
  indexEnabled: boolean;
  indexWatermark: string | number | null;
  pendingPermission: boolean;
}

// Canonical never-started shape for an absent row: nothing done, nothing skipped.
export function neverStartedOnboardingStatus(): OnboardingStatus {
  return {
    completed: false,
    completedAt: null,
    skippedSteps: [],
    checklistDismissed: false,
    seedPromptUsed: null,
    items: ONBOARDING_STEP_IDS.map((id) => ({ id, completed: false, skipped: false })),
    brainReady: false,
    personaSet: false,
    emailReady: false,
    calendarReady: false,
    indexReady: false,
    policyAcked: false,
    calendarStatus: null,
    emailAccounts: [],
    indexEnabled: false,
    indexWatermark: null,
    pendingPermission: false,
  };
}

// Single source for skipped-step sanitizing: allowlist plus 4-entry cap.
export const MAX_SKIPPED_STEPS = 4;

// Normalizes the skipped-steps array fail-closed: unknown ids drop, capped at 4.
export function sanitizeSkippedSteps(value: unknown): OnboardingStepId[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<OnboardingStepId>();
  for (const entry of value) {
    if (isOnboardingStepId(entry) && !seen.has(entry)) {
      seen.add(entry);
    }
  }
  return ONBOARDING_STEP_IDS.filter((id) => seen.has(id)).slice(0, MAX_SKIPPED_STEPS);
}

// Internal parser stays single-sourced on the shared sanitizer.
function parseSkippedSteps(value: unknown): OnboardingStepId[] {
  return sanitizeSkippedSteps(value);
}

// Normalizes one per-step item: unknown ids reject so drifted steps never enter state.
function parseOnboardingItem(value: unknown, skipped: Set<string>): OnboardingItemState | null {
  if (!isRecord(value)) return null;
  const rawId = value.id ?? value.stepId ?? value.step_id;
  if (!isOnboardingStepId(rawId)) return null;
  const completedRaw = value.completed;
  const completed = typeof completedRaw === "boolean" ? completedRaw : false;
  const skippedRaw = value.skipped;
  const skippedFlag =
    typeof skippedRaw === "boolean" ? skippedRaw : skipped.has(rawId);
  return { id: rawId, completed, skipped: skippedFlag };
}

// Reads a strict true-or-1 flag so drifted values fail closed to incomplete.
function pickReadyFlag(record: Record<string, unknown>, camel: string, snake: string): boolean {
  const primary = record[camel];
  const fallback = record[snake];
  return primary === true || primary === 1 || fallback === true || fallback === 1;
}

// Picks the first present trimmed string across camel and snake spellings.
function pickStatusString(record: Record<string, unknown>, camel: string, snake: string): string | null {
  for (const key of [camel, snake]) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

// Reads one email account row, treating any truthy fetch flag as success.
function parseEvidenceEmailAccount(value: unknown): OnboardingEmailAccount | null {
  if (!isRecord(value)) return null;
  const rawAddress = value.address ?? value.email ?? value.account;
  const address = typeof rawAddress === "string" ? rawAddress.trim() : "";
  const flag =
    value.fetchSucceeded ??
    value.fetch_succeeded ??
    value.lastFetchSucceeded ??
    value.last_fetch_succeeded ??
    value.succeeded ??
    value.ok;
  return { address, fetchSucceeded: flag === true };
}

// Collects email accounts across both casing shapes, skipping drifted rows.
function pickEvidenceEmailAccounts(record: Record<string, unknown>): OnboardingEmailAccount[] {
  const raw =
    (Array.isArray(record.emailAccounts) ? record.emailAccounts : null) ??
    (Array.isArray(record.email_accounts) ? record.email_accounts : null);
  if (!raw) return [];
  const accounts: OnboardingEmailAccount[] = [];
  for (const entry of raw) {
    const parsed = parseEvidenceEmailAccount(entry);
    if (parsed) accounts.push(parsed);
  }
  return accounts;
}

// A watermark counts only when it names a post-epoch instant.
export function isValidIndexWatermark(value: unknown): boolean {
  if (typeof value === "number") return Number.isFinite(value) && value > 0;
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (!trimmed) return false;
  if (/^[+-]?\d+(\.\d+)?$/.test(trimmed)) return Number(trimmed) > 0;
  const millis = Date.parse(trimmed);
  return Number.isFinite(millis) && millis > 0;
}

// A watermark counts only when it names a real instant, never blank or epoch.
function pickEvidenceWatermark(record: Record<string, unknown>): string | number | null {
  const candidates = [
    record.indexWatermark,
    record.index_watermark,
    record.indexAsOf,
    record.index_as_of,
  ];
  for (const candidate of candidates) {
    if (typeof candidate === "string") {
      if (isValidIndexWatermark(candidate)) return candidate.trim();
      continue;
    }
    if (typeof candidate === "number" && Number.isFinite(candidate) && candidate > 0) {
      return candidate;
    }
  }
  return null;
}

// Validates the status shape before it enters view state. Returns null on drift
// so callers fail closed instead of rendering a partial checklist.
export function parseOnboardingStatus(value: unknown): OnboardingStatus | null {
  if (value === null || value === undefined) return neverStartedOnboardingStatus();
  if (!isRecord(value)) return null;
  const completedAtRaw = value.completedAt ?? value.completed_at ?? null;
  let completedAt: string | null = null;
  if (typeof completedAtRaw === "string" && completedAtRaw.trim()) {
    completedAt = completedAtRaw.trim();
  } else if (
    typeof completedAtRaw === "number" &&
    Number.isFinite(completedAtRaw) &&
    completedAtRaw > 0
  ) {
    // Numeric instants count as completed with ISO normalization.
    try {
      completedAt = new Date(completedAtRaw).toISOString();
    } catch {
      completedAt = String(completedAtRaw);
    }
  }
  // Single source: completion rides on completedAt alone; a drifted flag never overrides it.
  const completed = completedAt !== null;
  const skippedSteps = parseSkippedSteps(
    value.skippedSteps ?? value.skipped_steps ?? [],
  );
  const skippedSet = new Set<string>(skippedSteps);
  const dismissedRaw = value.checklistDismissed ?? value.checklist_dismissed ?? false;
  const checklistDismissed =
    dismissedRaw === true || dismissedRaw === 1
      ? true
      : dismissedRaw === false || dismissedRaw === 0
        ? false
        : false;
  const seedRaw = value.seedPromptUsed ?? value.seed_prompt_used ?? null;
  const seedPromptUsed =
    typeof seedRaw === "string" && seedRaw.length > 0 ? seedRaw : null;
  const itemsRaw = value.items;
  let items: OnboardingItemState[];
  if (Array.isArray(itemsRaw)) {
    const seen = new Map<OnboardingStepId, OnboardingItemState>();
    for (const entry of itemsRaw) {
      const parsed = parseOnboardingItem(entry, skippedSet);
      if (parsed && !seen.has(parsed.id)) seen.set(parsed.id, parsed);
    }
    // Fill any absent allowlisted step so view state always carries four rows.
    items = ONBOARDING_STEP_IDS.map(
      (id) =>
        seen.get(id) ?? {
          id,
          completed,
          skipped: skippedSet.has(id),
        }
    );
  } else {
    items = ONBOARDING_STEP_IDS.map((id) => ({
      id,
      completed,
      skipped: skippedSet.has(id),
    }));
  }
  return {
    completed,
    completedAt,
    skippedSteps,
    checklistDismissed,
    seedPromptUsed,
    items,
    brainReady: pickReadyFlag(value, "brainReady", "brain_ready"),
    personaSet: pickReadyFlag(value, "personaSet", "persona_set"),
    emailReady: pickReadyFlag(value, "emailReady", "email_ready"),
    calendarReady: pickReadyFlag(value, "calendarReady", "calendar_ready"),
    indexReady: pickReadyFlag(value, "indexReady", "index_ready"),
    policyAcked: pickReadyFlag(value, "policyAcked", "policy_acked"),
    calendarStatus: pickStatusString(value, "calendarStatus", "calendar_status"),
    emailAccounts: pickEvidenceEmailAccounts(value),
    indexEnabled: pickReadyFlag(value, "indexEnabled", "index_enabled"),
    indexWatermark: pickEvidenceWatermark(value),
    pendingPermission: pickReadyFlag(value, "pendingPermission", "pending_permission"),
  };
}

// Single source: completedAt alone decides; the derived flag mirrors it.
export function isOnboardingCompleted(status: OnboardingStatus | null | undefined): boolean {
  return status?.completedAt != null;
}

// Reads the single onboarding row plus live-derived item states.
export async function getOnboardingStatus(): Promise<OnboardingStatus> {
  const raw = await fetchJson<unknown>("/onboarding/status");
  const parsed = parseOnboardingStatus(raw);
  if (!parsed) {
    throw new ApiError("Invalid onboarding status response", 0);
  }
  return parsed;
}

// Marks onboarding complete, truncating the stored prompt to the client bound.
export function completeOnboarding(seedPromptUsed: string): Promise<void> {
  return fetchJson<void>("/onboarding/complete", {
    method: "POST",
    body: JSON.stringify({ seedPromptUsed: truncateSeedPromptUsed(seedPromptUsed) }),
  });
}

// Skips one allowlisted step; anything else rejects before touching the wire.
export async function skipOnboardingStep(stepId: OnboardingStepId): Promise<void> {
  if (!isOnboardingStepId(stepId)) {
    throw new ApiError(`unknown_step: ${String(stepId)}`, 400);
  }
  return fetchJson<void>("/onboarding/skip", {
    method: "POST",
    body: JSON.stringify({ step: stepId }),
  });
}

// Hides the post-complete checklist without marking onboarding incomplete.
export function dismissChecklist(): Promise<void> {
  return fetchJson<void>("/onboarding/dismiss", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Reopens onboarding after completion so the checklist renders again.
export function reopenOnboarding(): Promise<void> {
  return fetchJson<void>("/onboarding/reopen", {
    method: "POST",
    body: JSON.stringify({}),
  });
}
