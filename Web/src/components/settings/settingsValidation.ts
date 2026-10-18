// Rune Weaver Dashboard — Validation rules and payload builders for settings sections.

import type {
  ContainersSettingsUpdate,
  DesktopSettingsUpdate,
  FanoutConfigData,
  FanoutSettingsUpdate,
  GoalsSettingsUpdate,
  IdeasSettingsUpdate,
  MediaConfigData,
  PersonaData,
  PersonaSettingsUpdate,
  ProactiveSettingsUpdate,
  SettingsResponse,
  WorkspaceSettingsUpdate,
} from "../../api";
import {
  CONTAINERS_MAX_CONCURRENT_MAX,
  CONTAINERS_MAX_CONCURRENT_MIN,
  CONTAINERS_MEMORY_MAX_MB,
  CONTAINERS_MEMORY_MIN_MB,
  CONTAINERS_TTL_MAX_MINUTES,
  CONTAINERS_TTL_MIN_MINUTES,
  DEFAULT_FANOUT_MAX_WORKERS,
  DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
  DEFAULT_MEDIA_TIMEOUT_SECONDS,
  GOALS_MAX_ACTIVE_MAX,
  GOALS_MAX_ACTIVE_MIN,
  GOALS_STEP_INTERVAL_MAX_MINUTES,
  GOALS_STEP_INTERVAL_MIN_MINUTES,
  isValidProactiveMode,
  MAX_PERSONA_ASSISTANT_NAME_LENGTH,
  MAX_PERSONA_STYLE_LENGTH,
  MAX_PERSONA_USER_NAME_LENGTH,
  normalizeProactiveMode,
  parseBlockedAppsText,
  PERSONA_AVATAR_COLORS,
  PERSONA_TONES,
  personaAssistantName,
  personaStyle,
  personaUserName,
  PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS,
  PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS,
  PROACTIVE_MODES,
  WORKSPACE_QUOTA_FILES_MAX,
  WORKSPACE_QUOTA_FILES_MIN,
  WORKSPACE_QUOTA_MB_MAX,
  WORKSPACE_QUOTA_MB_MIN,
  WORKSPACE_TMP_TTL_MAX_DAYS,
  WORKSPACE_TMP_TTL_MIN_DAYS,
} from "../../api";
import {
  canonicalPersonaAvatarColor,
  canonicalPersonaTone,
} from "./settingsHelpers";

// --- Goals & Ideas ---

export function buildGoalsPayload(
  enabled: boolean,
  stepIntervalMinutes: number | string,
  maxActiveGoals: number | string,
  maxStepsPerGoal: number | string,
  planTimeoutSeconds: number | string,
  maxTriggersPerGoal: number | string
): GoalsSettingsUpdate {
  return {
    enabled,
    stepIntervalMinutes: Number(stepIntervalMinutes),
    maxActiveGoals: Number(maxActiveGoals),
    maxStepsPerGoal: Number(maxStepsPerGoal),
    planTimeoutSeconds: Number(planTimeoutSeconds),
    maxTriggersPerGoal: Number(maxTriggersPerGoal),
  };
}

export function validateGoalsFields(
  stepIntervalMinutes: number | string,
  maxActiveGoals: number | string,
  maxStepsPerGoal: number | string,
  planTimeoutSeconds: number | string,
  maxTriggersPerGoal: number | string
): string | null {
  const intervalNum = Number(stepIntervalMinutes);
  if (
    !Number.isInteger(intervalNum) ||
    intervalNum < GOALS_STEP_INTERVAL_MIN_MINUTES ||
    intervalNum > GOALS_STEP_INTERVAL_MAX_MINUTES
  ) {
    return `Invalid goals cadence: step interval must be between ${GOALS_STEP_INTERVAL_MIN_MINUTES} and ${GOALS_STEP_INTERVAL_MAX_MINUTES} minutes.`;
  }
  const capNum = Number(maxActiveGoals);
  if (
    !Number.isInteger(capNum) ||
    capNum < GOALS_MAX_ACTIVE_MIN ||
    capNum > GOALS_MAX_ACTIVE_MAX
  ) {
    return `Invalid goals cap: max active goals must be between ${GOALS_MAX_ACTIVE_MIN} and ${GOALS_MAX_ACTIVE_MAX}.`;
  }
  const stepsNum = Number(maxStepsPerGoal);
  if (!Number.isInteger(stepsNum) || stepsNum < 1 || stepsNum > 24) {
    return "Invalid goals plan length: max steps per goal must be between 1 and 24.";
  }
  const planTimeoutNum = Number(planTimeoutSeconds);
  if (
    !Number.isInteger(planTimeoutNum) ||
    planTimeoutNum < 0 ||
    planTimeoutNum > 86400
  ) {
    return "Invalid goals planning timeout: plan timeout must be between 0 (unlimited) and 86400 seconds.";
  }
  const triggersNum = Number(maxTriggersPerGoal);
  if (
    !Number.isInteger(triggersNum) ||
    triggersNum < 0 ||
    triggersNum > 32
  ) {
    return "Invalid goals triggers budget: max triggers per goal must be between 0 and 32.";
  }
  return null;
}

export function buildIdeasPayload(
  enabled: boolean,
  maxPerCycle: number | string,
  timeoutSeconds: number | string
): IdeasSettingsUpdate {
  return {
    enabled,
    maxPerCycle: Number(maxPerCycle),
    timeoutSeconds: Number(timeoutSeconds),
  };
}

export function validateIdeasFields(
  maxPerCycle: number | string,
  timeoutSeconds: number | string
): string | null {
  const maxCycleNum = Number(maxPerCycle);
  if (!Number.isInteger(maxCycleNum) || maxCycleNum < 1 || maxCycleNum > 10) {
    return "Invalid ideas per cycle: must be between 1 and 10.";
  }
  const timeoutNum = Number(timeoutSeconds);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 1 || timeoutNum > 120) {
    return "Invalid ideas timeout: review timeout must be between 1 and 120 seconds.";
  }
  return null;
}

// --- Proactive & Interruption ---

export function buildProactivePayload(
  mode: string,
  judgeTimeoutSeconds: number | string
): ProactiveSettingsUpdate {
  return {
    mode: normalizeProactiveMode(mode),
    judgeTimeoutSeconds: Number(judgeTimeoutSeconds),
  };
}

export function validateProactiveFields(
  mode: string,
  judgeTimeoutSeconds: number | string
): string | null {
  const normalizedMode = normalizeProactiveMode(mode);
  if (!isValidProactiveMode(normalizedMode)) {
    return `Invalid proactive mode: must be one of ${(PROACTIVE_MODES as readonly string[]).join(", ")}.`;
  }
  const timeoutNum = Number(judgeTimeoutSeconds);
  if (
    !Number.isInteger(timeoutNum) ||
    timeoutNum < PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS ||
    timeoutNum > PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS
  ) {
    return `Invalid proactive judge timeout: timeout must be between ${PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS} and ${PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS} seconds.`;
  }
  return null;
}

// --- Persona ---

export function buildPersonaDelta(
  loaded: PersonaData,
  assistantNameDraft: string,
  toneDraft: string,
  styleDraft: string,
  userNameDraft: string,
  avatarDraft: string
): PersonaSettingsUpdate {
  const delta: PersonaSettingsUpdate = {};
  const loadedName = personaAssistantName(loaded) ?? "";
  const nextName = assistantNameDraft.trim();
  if (nextName !== loadedName) {
    delta.assistantName = nextName;
  }
  const loadedTone = canonicalPersonaTone(loaded.tone);
  if (toneDraft !== loadedTone) {
    delta.tone = toneDraft;
  }
  if (styleDraft !== personaStyle(loaded)) {
    delta.style = styleDraft;
  }
  const loadedUserName = personaUserName(loaded);
  const nextUserName = userNameDraft.trim();
  if (nextUserName !== loadedUserName) {
    delta.userName = nextUserName;
  }
  const loadedAvatar = canonicalPersonaAvatarColor(loaded.avatar);
  if (avatarDraft !== loadedAvatar) {
    delta.avatar = avatarDraft;
  }
  return delta;
}

export function validatePersonaFields(
  assistantNameDraft: string,
  toneDraft: string,
  styleDraft: string,
  userNameDraft: string,
  avatarDraft: string
): string | null {
  if (assistantNameDraft.length > MAX_PERSONA_ASSISTANT_NAME_LENGTH) {
    return `Invalid assistant name: must be at most ${MAX_PERSONA_ASSISTANT_NAME_LENGTH} characters.`;
  }
  if (!(PERSONA_TONES as readonly string[]).includes(toneDraft)) {
    return `Invalid tone: must be one of ${(PERSONA_TONES as readonly string[]).join(", ")}.`;
  }
  if (styleDraft.length > MAX_PERSONA_STYLE_LENGTH) {
    return `Invalid style guidance: must be at most ${MAX_PERSONA_STYLE_LENGTH} characters.`;
  }
  if (userNameDraft.length > MAX_PERSONA_USER_NAME_LENGTH) {
    return `Invalid user name: must be at most ${MAX_PERSONA_USER_NAME_LENGTH} characters.`;
  }
  if (!(PERSONA_AVATAR_COLORS as readonly string[]).includes(avatarDraft)) {
    return `Invalid avatar accent: must be one of ${(PERSONA_AVATAR_COLORS as readonly string[]).join(", ")}.`;
  }
  return null;
}

// --- Workspace ---

export function buildWorkspacePayload(
  quotaMB: number | string,
  quotaFiles: number | string,
  tmpTTLDays: number | string
): WorkspaceSettingsUpdate {
  return {
    quotaMB: Number(quotaMB),
    quotaFiles: Number(quotaFiles),
    tmpTTLDays: Number(tmpTTLDays),
  };
}

export function validateWorkspaceFields(
  quotaMB: number | string,
  quotaFiles: number | string,
  tmpTTLDays: number | string
): string | null {
  const quotaMBNum = Number(quotaMB);
  if (
    !Number.isInteger(quotaMBNum) ||
    quotaMBNum < WORKSPACE_QUOTA_MB_MIN ||
    quotaMBNum > WORKSPACE_QUOTA_MB_MAX
  ) {
    return `Invalid workspace quota: quota must be between ${WORKSPACE_QUOTA_MB_MIN} and ${WORKSPACE_QUOTA_MB_MAX} MB.`;
  }
  const quotaFilesNum = Number(quotaFiles);
  if (
    !Number.isInteger(quotaFilesNum) ||
    quotaFilesNum < WORKSPACE_QUOTA_FILES_MIN ||
    quotaFilesNum > WORKSPACE_QUOTA_FILES_MAX
  ) {
    return `Invalid workspace file quota: max files must be between ${WORKSPACE_QUOTA_FILES_MIN} and ${WORKSPACE_QUOTA_FILES_MAX}.`;
  }
  const tmpTTLNum = Number(tmpTTLDays);
  if (
    !Number.isInteger(tmpTTLNum) ||
    tmpTTLNum < WORKSPACE_TMP_TTL_MIN_DAYS ||
    tmpTTLNum > WORKSPACE_TMP_TTL_MAX_DAYS
  ) {
    return `Invalid workspace tmp retention: tmp TTL must be between ${WORKSPACE_TMP_TTL_MIN_DAYS} and ${WORKSPACE_TMP_TTL_MAX_DAYS} days.`;
  }
  return null;
}

// --- Containers ---

export function buildContainersPatch(
  memoryMB: number | string,
  maxConcurrent: number | string,
  ttlMinutes: number | string
): ContainersSettingsUpdate {
  return {
    memoryMb: Number(memoryMB),
    maxConcurrent: Number(maxConcurrent),
    ttlMinutes: Number(ttlMinutes),
  };
}

export function validateContainersFields(
  memoryMB: number | string,
  maxConcurrent: number | string,
  ttlMinutes: number | string
): string | null {
  const memoryNum = Number(memoryMB);
  if (
    !Number.isInteger(memoryNum) ||
    memoryNum < CONTAINERS_MEMORY_MIN_MB ||
    memoryNum > CONTAINERS_MEMORY_MAX_MB
  ) {
    return `Invalid containers memory: memoryMb must be between ${CONTAINERS_MEMORY_MIN_MB} and ${CONTAINERS_MEMORY_MAX_MB} MB.`;
  }
  const maxConcurrentNum = Number(maxConcurrent);
  if (
    !Number.isInteger(maxConcurrentNum) ||
    maxConcurrentNum < CONTAINERS_MAX_CONCURRENT_MIN ||
    maxConcurrentNum > CONTAINERS_MAX_CONCURRENT_MAX
  ) {
    return `Invalid containers concurrency: max_concurrent must be between ${CONTAINERS_MAX_CONCURRENT_MIN} and ${CONTAINERS_MAX_CONCURRENT_MAX}.`;
  }
  const ttlNum = Number(ttlMinutes);
  if (
    !Number.isInteger(ttlNum) ||
    ttlNum < CONTAINERS_TTL_MIN_MINUTES ||
    ttlNum > CONTAINERS_TTL_MAX_MINUTES
  ) {
    return `Invalid containers TTL: ttl_minutes must be between ${CONTAINERS_TTL_MIN_MINUTES} and ${CONTAINERS_TTL_MAX_MINUTES} minutes.`;
  }
  return null;
}

// --- Media (Sonarr & Radarr) ---

export function buildMediaPayload(
  settings: SettingsResponse | null,
  mediaTimeoutSeconds: number | string,
  sonarrEnabled: boolean,
  sonarrUrl: string,
  sonarrApiKeyEnv: string,
  sonarrDefaultQuality: string,
  sonarrDefaultRoot: string,
  radarrEnabled: boolean,
  radarrUrl: string,
  radarrApiKeyEnv: string,
  radarrDefaultQuality: string,
  radarrDefaultRoot: string
): MediaConfigData {
  const storedSonarrEnv =
    settings?.media?.sonarr?.apiKeyEnv?.trim() || "";
  const storedRadarrEnv =
    settings?.media?.radarr?.apiKeyEnv?.trim() || "";
  const timeoutSec =
    typeof mediaTimeoutSeconds === "string"
      ? parseInt(mediaTimeoutSeconds, 10)
      : mediaTimeoutSeconds;
  return {
    timeoutSeconds:
      isNaN(timeoutSec) || timeoutSec <= 0
        ? DEFAULT_MEDIA_TIMEOUT_SECONDS
        : timeoutSec,
    sonarr: {
      enabled: sonarrEnabled,
      url: sonarrUrl.trim(),
      apiKeyEnv: sonarrApiKeyEnv.trim() || storedSonarrEnv || "SONARR_API_KEY",
      defaultQualityProfile: sonarrDefaultQuality.trim(),
      defaultRootFolder: sonarrDefaultRoot.trim(),
    },
    radarr: {
      enabled: radarrEnabled,
      url: radarrUrl.trim(),
      apiKeyEnv: radarrApiKeyEnv.trim() || storedRadarrEnv || "RADARR_API_KEY",
      defaultQualityProfile: radarrDefaultQuality.trim(),
      defaultRootFolder: radarrDefaultRoot.trim(),
    },
  };
}

// --- Desktop ---

export function buildDesktopPayload(
  maxImageDimension: number | string,
  jpegQuality: number | string,
  blockedAppsText: string
): DesktopSettingsUpdate {
  return {
    maxImageDimension: Number(maxImageDimension),
    jpegQuality: Number(jpegQuality),
    blockedApps: parseBlockedAppsText(blockedAppsText),
  };
}

// --- Fanout ---

export function buildFanoutPayload(
  loaded: FanoutConfigData,
  maxWorkers: number | string,
  workerTimeoutSeconds: number | string,
  fullTools: boolean
): FanoutSettingsUpdate {
  const patch: FanoutSettingsUpdate = {};
  const maxRaw =
    typeof maxWorkers === "string" ? maxWorkers.trim() : maxWorkers;
  if (maxRaw === "") {
    if (loaded.maxWorkers !== DEFAULT_FANOUT_MAX_WORKERS) {
      patch.maxWorkers = DEFAULT_FANOUT_MAX_WORKERS;
    }
  } else {
    const maxNum = Number(maxRaw);
    if (maxNum !== loaded.maxWorkers) {
      patch.maxWorkers = maxNum;
    }
  }
  const timeoutRaw =
    typeof workerTimeoutSeconds === "string"
      ? workerTimeoutSeconds.trim()
      : workerTimeoutSeconds;
  if (timeoutRaw === "") {
    if (loaded.workerTimeoutSeconds !== DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS) {
      patch.workerTimeoutSeconds = DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS;
    }
  } else {
    const timeoutNum = Number(timeoutRaw);
    if (timeoutNum !== loaded.workerTimeoutSeconds) {
      patch.workerTimeoutSeconds = timeoutNum;
    }
  }
  if (fullTools !== loaded.fullTools) {
    patch.fullTools = fullTools;
  }
  return patch;
}
