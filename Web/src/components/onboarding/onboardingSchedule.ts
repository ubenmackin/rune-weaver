// Rune Weaver Dashboard — Onboarding email briefing schedule.
import { createJob, listJobs, updateJob, updateSettings } from "../../api";
import { fetchJson } from "../../api/http";
import {
  ONBOARDING_EMAIL_DIGEST_PROMPT,
  ONBOARDING_EMAIL_SCHEDULE_CRON,
  ONBOARDING_EMAIL_SCHEDULE_NAME,
  finishOnboardingWithVerifiedSeed,
  isIndexReady,
  parseOnboardingStatus,
  selectFinishDestination,
  type OnboardingFinishDestination,
  type OnboardingStatus,
} from "./seedPrompt";
import type { OnboardingGoal } from "./PersonaStep";
import { clearWizardState } from "./wizardStorage";

// Single-flight so concurrent finishes share one list-plus-create.
let ensureInFlight: Promise<string> | null = null;

// Exact name match reuses the canonical job; disabled or drifted rows repair.
export async function ensureOnboardingEmailSchedule(): Promise<string> {
  if (ensureInFlight) return ensureInFlight;
  ensureInFlight = (async () => {
    const listed = await listJobs();
    const jobs = Array.isArray(listed?.jobs) ? listed.jobs : [];
    const existing = jobs.find((job) => job.name === ONBOARDING_EMAIL_SCHEDULE_NAME);
    if (existing) {
      const drifted =
        existing.schedule !== ONBOARDING_EMAIL_SCHEDULE_CRON ||
        existing.prompt !== ONBOARDING_EMAIL_DIGEST_PROMPT;
      if (existing.enabled === true && !drifted) return existing.id;
      const repaired = await updateJob(existing.id, {
        schedule: ONBOARDING_EMAIL_SCHEDULE_CRON,
        prompt: ONBOARDING_EMAIL_DIGEST_PROMPT,
        enabled: true,
      });
      if (!repaired?.id) throw new Error("Failed to ensure onboarding email schedule");
      return repaired.id;
    }
    try {
      const created = await createJob({
        name: ONBOARDING_EMAIL_SCHEDULE_NAME,
        schedule: ONBOARDING_EMAIL_SCHEDULE_CRON,
        prompt: ONBOARDING_EMAIL_DIGEST_PROMPT,
        enabled: true,
      });
      if (!created?.id) throw new Error("Failed to ensure onboarding email schedule");
      return created.id;
    } catch (err) {
      // Concurrent finish won the race; re-list for the winner.
      const relisted = await listJobs();
      const rerun = Array.isArray(relisted?.jobs) ? relisted.jobs : [];
      const winner = rerun.find((job) => job.name === ONBOARDING_EMAIL_SCHEDULE_NAME);
      if (winner) {
        const drifted =
          winner.schedule !== ONBOARDING_EMAIL_SCHEDULE_CRON ||
          winner.prompt !== ONBOARDING_EMAIL_DIGEST_PROMPT;
        if (winner.enabled === true && !drifted) return winner.id;
        const repaired = await updateJob(winner.id, {
          schedule: ONBOARDING_EMAIL_SCHEDULE_CRON,
          prompt: ONBOARDING_EMAIL_DIGEST_PROMPT,
          enabled: true,
        });
        if (repaired?.id) return repaired.id;
      }
      throw err;
    }
  })();
  try {
    return await ensureInFlight;
  } finally {
    ensureInFlight = null;
  }
}

export interface FinishOnboardingFlowOptions {
  status: OnboardingStatus | null;
  goal?: OnboardingGoal | null;
  complete?: (prompt: string) => Promise<void>;
}

export interface FinishOnboardingFlowResult {
  destination: OnboardingFinishDestination;
  prompt: string;
}

// Single finish owner: destination plus artifacts plus verified completion.
// Artifact or completion failures throw so callers stay fail-closed.
export async function finishOnboardingFlow(
  options: FinishOnboardingFlowOptions,
): Promise<FinishOnboardingFlowResult> {
  const goal = options.goal ?? null;
  const destination = selectFinishDestination(options.status, goal);
  let effectiveDestination = destination;
  let finishStatus = options.status;
  if (destination.kind === "schedules") {
    await ensureOnboardingEmailSchedule();
  }
  if (goal === "remember" && !isIndexReady(options.status)) {
    await updateSettings({ index: { enabled: true } });
    try {
      const raw = await fetchJson<unknown>("/onboarding/status");
      finishStatus = parseOnboardingStatus(raw);
      effectiveDestination = selectFinishDestination(finishStatus, goal);
    } catch {
      // Enable won but the reread failed; hold indexing so a stale read never blocks finish.
      effectiveDestination = { kind: "indexing", highlightRun: true };
    }
  }
  const prompt = await finishOnboardingWithVerifiedSeed({
    status: finishStatus,
    goal,
    complete: options.complete,
  });
  clearWizardState();
  return { destination: effectiveDestination, prompt };
}
