// Rune Weaver Dashboard — Settings advanced counts helpers.
import {
  DEFAULT_GOALS_MAX_ACTIVE_GOALS,
  DEFAULT_GOALS_MAX_STEPS_PER_GOAL,
  DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL,
  DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS,
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
} from "../../api";
import type { EmailEntry, ProviderEntry } from "./settingsTypes";

export const DEFAULT_MEMORY_RECALL_AUTO_LIMIT = 5;
export const DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER = 4;
export const DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT = 0.25;

export const DEFAULT_MEMORY_EMBEDDING_BACKEND = "local";

// Counts non-default provider fields hidden behind Advanced.
export function countProvidersAdvancedChanged(
  providers: ProviderEntry[]
): number {
  let count = 0;
  for (const item of providers) {
    const cfg = item.config;
    if ((cfg.apiStyle || "").trim() !== "") count += 1;
    if (cfg.contextLength !== undefined && cfg.contextLength !== null) {
      const raw = cfg.contextLength as unknown;
      if (raw !== "" && !Number.isNaN(Number(raw))) count += 1;
    }
    if (cfg.slotCount !== undefined && cfg.slotCount !== null) {
      const raw = cfg.slotCount as unknown;
      if (raw !== "" && !Number.isNaN(Number(raw))) count += 1;
    }
    if (cfg.cachePrompt !== undefined && cfg.cachePrompt !== null) {
      const raw = cfg.cachePrompt as unknown;
      if (raw !== "") count += 1;
    }
    if (cfg.supportsVision !== undefined && cfg.supportsVision !== null) {
      const raw = cfg.supportsVision as unknown;
      if (raw !== "") count += 1;
    }
  }
  return count;
}

// Counts non-default persona fields hidden behind Advanced.
export function countPersonaAdvancedChanged(
  avatarDraft: string,
  styleDraft: string,
  defaultAvatar: string
): number {
  let count = 0;
  if ((avatarDraft || "") !== defaultAvatar) count += 1;
  if ((styleDraft || "") !== "") count += 1;
  return count;
}

// Counts non-default email fields hidden behind Advanced.
export function countEmailAdvancedChanged(accounts: EmailEntry[]): number {
  let count = 0;
  for (const item of accounts) {
    const acc = item.account;
    if (((acc.smtpHost ?? "") as string).trim() !== "") count += 1;
    const portRaw = acc.smtpPort as unknown;
    if (
      portRaw !== undefined &&
      portRaw !== null &&
      String(portRaw).trim() !== ""
    ) {
      count += 1;
    }
    const sec = String(acc.smtpSecurity ?? "").trim().toLowerCase();
    if (sec !== "" && sec !== "auto") count += 1;
  }
  return count;
}

// Counts non-default memory fields hidden behind Advanced.
// Only recall knobs live behind Advanced; the embedding backend
// select stays in Simple so it is excluded from the chip.
export function countMemoryAdvancedChanged(
  docPoolMultiplier: number | string,
  episodicWeight: number | string,
  autoLimit?: number | string
): number {
  let count = 0;
  const docNum = Number(docPoolMultiplier);
  if (!Number.isNaN(docNum) && docNum !== DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER)
    count += 1;
  const weightNum = Number(episodicWeight);
  if (
    !Number.isNaN(weightNum) &&
    weightNum !== DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT
  )
    count += 1;
  if (autoLimit !== undefined) {
    const autoNum = Number(autoLimit);
    if (!Number.isNaN(autoNum) && autoNum !== DEFAULT_MEMORY_RECALL_AUTO_LIMIT)
      count += 1;
  }
  return count;
}

// Counts only the editable compaction knob; scheduler and goal
// budgets render as read-only text so they never affect the chip.
export function countEngineAdvancedChanged(
  compactionThresholdPercent: number | string
): number {
  let count = 0;
  if (Number(compactionThresholdPercent) !== 80) count += 1;
  return count;
}

// Counts non-default goals fields hidden behind Advanced.
export function countGoalsAdvancedChanged(
  maxActiveGoals: number | string,
  maxStepsPerGoal: number | string,
  planTimeoutSeconds: number | string,
  maxTriggersPerGoal: number | string
): number {
  let count = 0;
  if (Number(maxActiveGoals) !== DEFAULT_GOALS_MAX_ACTIVE_GOALS) count += 1;
  if (Number(maxStepsPerGoal) !== DEFAULT_GOALS_MAX_STEPS_PER_GOAL) count += 1;
  if (Number(planTimeoutSeconds) !== DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS)
    count += 1;
  if (Number(maxTriggersPerGoal) !== DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL)
    count += 1;
  return count;
}

// Counts non-default tools fields hidden behind Advanced.
export function countToolsAdvancedChanged(
  pluginsDir: string,
  marketplaceIndexURL: string,
  autoRescan: boolean
): number {
  let count = 0;
  if ((pluginsDir || "").trim() !== "~/.runeweaver/plugins") count += 1;
  if (
    (marketplaceIndexURL || "").trim() !==
    "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"
  )
    count += 1;
  if (autoRescan !== true) count += 1;
  return count;
}

// Counts non-default web fields hidden behind Advanced.
export function countWebAdvancedChanged(
  searxngURL: string,
  timeoutSeconds: number | string
): number {
  let count = 0;
  if ((searxngURL || "").trim() !== DEFAULT_SEARCH_SEARXNG_URL) count += 1;
  if (Number(timeoutSeconds) !== DEFAULT_SEARCH_TIMEOUT_SECONDS) count += 1;
  return count;
}

// Default whisper model; Advanced holds this knob alone.
export const DEFAULT_VOICE_WHISPER_MODEL = "base";

// Counts only the whisper model hidden behind Advanced; STT/TTS
// providers stay in Simple so they never affect the chip.
export function countVoiceAdvancedChanged(whisperModel: string): number {
  return (whisperModel || "").trim() !== DEFAULT_VOICE_WHISPER_MODEL ? 1 : 0;
}
