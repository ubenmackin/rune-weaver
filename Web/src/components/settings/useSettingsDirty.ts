// Rune Weaver Dashboard — Dirty tracking for the main Settings form.

import type { EmailAccountData, ProviderConfigData } from "../../api";
import {
  DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_TIMEOUT_SECONDS,
  DEFAULT_CONTAINERS_CONFIG,
  DEFAULT_DESKTOP_BLOCKED_APPS,
  DEFAULT_DESKTOP_JPEG_QUALITY,
  DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION,
  DEFAULT_ENGINE_MAX_TOOL_ITERATIONS,
  DEFAULT_FANOUT_FULL_TOOLS,
  DEFAULT_FANOUT_MAX_WORKERS,
  DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
  DEFAULT_GOALS_ENABLED,
  DEFAULT_GOALS_MAX_ACTIVE_GOALS,
  DEFAULT_GOALS_MAX_STEPS_PER_GOAL,
  DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL,
  DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS,
  DEFAULT_GOALS_STEP_INTERVAL_MINUTES,
  DEFAULT_IDEAS_ENABLED,
  DEFAULT_IDEAS_MAX_PER_CYCLE,
  DEFAULT_IDEAS_TIMEOUT_SECONDS,
  DEFAULT_MEDIA_TIMEOUT_SECONDS,
  DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS,
  DEFAULT_PROACTIVE_MODE,
  DEFAULT_SEARCH_MAX_RESULTS,
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
  DEFAULT_SERVER_HOSTNAME,
  DEFAULT_SERVER_PORT,
  DEFAULT_WORKSPACE_CONFIG,
  canonicalRestartHost,
  engineMaxToolIterations,
  normalizeProactiveMode,
  parseBlockedAppsText,
  parseServerAllowedHostsText,
  personaAssistantName,
  personaStyle,
  personaUserName,
  resolveNotificationsConfig,
} from "../../api";
import {
  DEFAULT_MEMORY_RECALL_AUTO_LIMIT,
  DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER,
  DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT,
  DEFAULT_TOOLS_AUTO_RESCAN,
  DEFAULT_TOOLS_MARKETPLACE_INDEX_URL,
  DEFAULT_TOOLS_PLUGINS_DIR,
} from "./settingsAdvancedCounts";
import {
  areServerAllowedHostsEqual,
  canonicalPersonaAvatarColor,
  canonicalPersonaTone,
} from "./settingsHelpers";
import type { useSettingsFormState } from "./useSettingsFormState";

type SettingsForm = ReturnType<typeof useSettingsFormState>;

function trimmed(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function fanoutNumber(value: number | string, fallback: number): number {
  if (typeof value === "string" && value.trim() === "") return fallback;
  return Number(value);
}

function draftMaxToolIterations(value: number | string): number {
  if (String(value ?? "").trim() === "") return DEFAULT_ENGINE_MAX_TOOL_ITERATIONS;
  return Number(value);
}

function trimOrUndefined(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const next = value.trim();
  return next === "" ? undefined : next;
}

function numberOrUndefined(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string" && value.trim() === "") return undefined;
  return Number(value);
}

function optBool(value: unknown): boolean | undefined | unknown {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string" && value.trim() === "") return undefined;
  if (value === true || value === "true") return true;
  if (value === false || value === "false") return false;
  return value;
}

function canonicalProvider(value: ProviderConfigData) {
  return {
    enabled: value.enabled ?? true,
    model: trimOrUndefined(value.model),
    serverURL: trimOrUndefined(value.serverURL),
    apiKeyEnv: trimOrUndefined(value.apiKeyEnv),
    providerType: trimOrUndefined(value.providerType),
    apiStyle: trimOrUndefined(value.apiStyle),
    contextLength: numberOrUndefined(value.contextLength),
    slotCount: numberOrUndefined(value.slotCount),
    cachePrompt: optBool(value.cachePrompt),
    supportsVision: optBool(value.supportsVision),
  };
}

function providersDiffer(
  draft: SettingsForm["providersList"],
  stored: Record<string, ProviderConfigData>,
): boolean {
  const draftByName = new Map<string, ReturnType<typeof canonicalProvider>>();
  for (const entry of draft) {
    const name = entry.name.trim();
    if (!name) return true;
    if (draftByName.has(name)) return true;
    draftByName.set(name, canonicalProvider(entry.config));
  }
  const storedEntries = Object.entries(stored ?? {});
  if (draftByName.size !== storedEntries.length) return true;
  for (const [rawName, rawConfig] of storedEntries) {
    const name = String(rawName).trim();
    const draftConfig = draftByName.get(name);
    if (!draftConfig) return true;
    const storedConfig = canonicalProvider(rawConfig);
    if (draftConfig.enabled !== storedConfig.enabled) return true;
    if (draftConfig.model !== storedConfig.model) return true;
    if (draftConfig.serverURL !== storedConfig.serverURL) return true;
    if (draftConfig.apiKeyEnv !== storedConfig.apiKeyEnv) return true;
    if (draftConfig.providerType !== storedConfig.providerType) return true;
    if (draftConfig.apiStyle !== storedConfig.apiStyle) return true;
    if (!numbersEqual(draftConfig.contextLength, storedConfig.contextLength))
      return true;
    if (!numbersEqual(draftConfig.slotCount, storedConfig.slotCount))
      return true;
    if (draftConfig.cachePrompt !== storedConfig.cachePrompt) return true;
    if (draftConfig.supportsVision !== storedConfig.supportsVision) return true;
  }
  return false;
}

function numbersEqual(a: number | undefined, b: number | undefined): boolean {
  if (a === undefined && b === undefined) return true;
  if (typeof a === "number" && typeof b === "number") {
    if (Number.isNaN(a) && Number.isNaN(b)) return true;
    return a === b;
  }
  return a === b;
}

function canonicalEmail(account: EmailAccountData) {
  const smtpPortRaw = account.smtpPort;
  const smtpPort =
    smtpPortRaw === undefined ||
    smtpPortRaw === null ||
    String(smtpPortRaw).trim() === ""
      ? undefined
      : Number(smtpPortRaw);
  const securityRaw =
    typeof account.smtpSecurity === "string"
      ? account.smtpSecurity.trim().toLowerCase()
      : "";
  const smtpSecurity =
    securityRaw === "ssl" || securityRaw === "starttls"
      ? securityRaw
      : securityRaw === ""
        ? undefined
        : account.smtpSecurity;
  const smtpHost =
    typeof account.smtpHost === "string" && account.smtpHost.trim() !== ""
      ? account.smtpHost.trim()
      : undefined;
  return {
    name: trimmed(account.name),
    type: trimmed(account.type) || "imap",
    host: trimmed(account.host),
    port: Number(account.port),
    username: trimmed(account.username),
    smtpHost,
    smtpPort,
    smtpSecurity,
  };
}

function emailsDiffer(form: SettingsForm): boolean {
  const stored = form.settings?.emailAccounts ?? [];
  const draft = form.emailAccountsList;
  if (draft.length !== stored.length) return true;
  for (let i = 0; i < draft.length; i += 1) {
    const draftAccount = draft[i]?.account;
    const storedAccount = stored[i];
    if (!draftAccount || !storedAccount) return true;
    const a = canonicalEmail(draftAccount);
    const b = canonicalEmail(storedAccount);
    if (a.name !== b.name) return true;
    if (a.type !== b.type) return true;
    if (a.host !== b.host) return true;
    if (!numbersEqual(a.port, b.port)) return true;
    if (a.username !== b.username) return true;
    if ((a.smtpHost ?? undefined) !== (b.smtpHost ?? undefined)) return true;
    if (!numbersEqual(a.smtpPort, b.smtpPort)) return true;
    if ((a.smtpSecurity ?? undefined) !== (b.smtpSecurity ?? undefined))
      return true;
  }
  return false;
}

export function isSettingsFormDirty(form: SettingsForm): boolean {
  const settings = form.settings;
  if (!settings) return false;

  if (trimmed(form.engineName) !== trimmed(settings.engineName)) return true;
  if (trimmed(form.logLevel) !== trimmed(settings.logLevel)) return true;
  if (
    Number(form.compactionThresholdPercent) !==
    Number(settings.compactionThresholdPercent ?? 80)
  )
    return true;
  if (draftMaxToolIterations(form.maxToolIterations) !== engineMaxToolIterations(settings))
    return true;

  if (trimmed(form.defaultProvider) !== trimmed(settings.defaultProvider ?? ""))
    return true;
  if (trimmed(form.fallbackProvider) !== trimmed(settings.fallbackProvider ?? ""))
    return true;
  if (providersDiffer(form.providersList, settings.providers ?? {})) return true;

  if (trimmed(form.memoryVectorDBPath) !== trimmed(settings.memoryVectorDBPath ?? ""))
    return true;
  if (trimmed(form.memoryEpisodesDBPath) !== trimmed(settings.memoryEpisodesDBPath ?? ""))
    return true;
  if (
    trimmed(form.memoryEmbeddingBackend) !==
    trimmed(settings.memoryEmbeddingBackend ?? "local")
  )
    return true;
  const rawMemory = settings as unknown as Record<string, unknown>;
  const storedAuto =
    typeof rawMemory["memoryRecallAutoLimit"] === "number" &&
    Number.isFinite(rawMemory["memoryRecallAutoLimit"])
      ? (rawMemory["memoryRecallAutoLimit"] as number)
      : DEFAULT_MEMORY_RECALL_AUTO_LIMIT;
  if (Number(form.memoryRecallAutoLimit) !== storedAuto) return true;
  const storedPool =
    typeof rawMemory["memoryRecallDocPoolMultiplier"] === "number" &&
    Number.isFinite(rawMemory["memoryRecallDocPoolMultiplier"])
      ? (rawMemory["memoryRecallDocPoolMultiplier"] as number)
      : DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER;
  if (Number(form.memoryRecallDocPoolMultiplier) !== storedPool) return true;
  const storedWeight =
    typeof rawMemory["memoryRecallEpisodicWeight"] === "number" &&
    Number.isFinite(rawMemory["memoryRecallEpisodicWeight"])
      ? (rawMemory["memoryRecallEpisodicWeight"] as number)
      : DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT;
  if (Number(form.memoryRecallEpisodicWeight) !== storedWeight) return true;

  if (trimmed(form.voiceSTTProvider) !== trimmed(settings.voiceSTTProvider ?? ""))
    return true;
  if (trimmed(form.voiceWhisperModel) !== trimmed(settings.voiceWhisperModel ?? ""))
    return true;
  if (trimmed(form.voiceTTSProvider) !== trimmed(settings.voiceTTSProvider ?? ""))
    return true;

  const storedSearchURL =
    settings.browserSearxngURL ?? settings.searchSearxngURL ?? DEFAULT_SEARCH_SEARXNG_URL;
  if (trimmed(form.searchSearxngURL) !== trimmed(storedSearchURL)) return true;
  const storedSearchTimeout =
    settings.browserSearchTimeoutSeconds ??
    settings.searchTimeoutSeconds ??
    DEFAULT_SEARCH_TIMEOUT_SECONDS;
  if (Number(form.searchTimeoutSeconds) !== Number(storedSearchTimeout)) return true;
  const storedMaxResults =
    settings.browserMaxResults ?? settings.searchMaxResults ?? DEFAULT_SEARCH_MAX_RESULTS;
  if (Number(form.searchMaxResults) !== Number(storedMaxResults)) return true;
  if (
    Number(form.browserTimeoutSeconds) !==
    Number(settings.browserTimeoutSeconds ?? DEFAULT_BROWSER_TIMEOUT_SECONDS)
  )
    return true;
  if (
    Number(form.browserFetchTimeoutSeconds) !==
    Number(settings.browserFetchTimeoutSeconds ?? DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS)
  )
    return true;

  if (trimmed(form.pluginsDir) !== trimmed(settings.pluginsDir ?? DEFAULT_TOOLS_PLUGINS_DIR))
    return true;
  if (
    trimmed(form.pluginsMarketplaceIndexURL) !==
    trimmed(settings.pluginsMarketplaceIndexURL ?? DEFAULT_TOOLS_MARKETPLACE_INDEX_URL)
  )
    return true;
  if (
    form.pluginsAutoRescan !== (settings.pluginsAutoRescan ?? DEFAULT_TOOLS_AUTO_RESCAN)
  )
    return true;

  if (emailsDiffer(form)) return true;

  const storedMediaTimeout =
    typeof settings.media?.timeoutSeconds === "number"
      ? settings.media.timeoutSeconds
      : DEFAULT_MEDIA_TIMEOUT_SECONDS;
  const draftMediaTimeout =
    typeof form.mediaTimeoutSeconds === "string"
      ? parseInt(form.mediaTimeoutSeconds, 10)
      : Number(form.mediaTimeoutSeconds);
  const canonicalDraftMediaTimeout =
    Number.isNaN(draftMediaTimeout) || draftMediaTimeout <= 0
      ? DEFAULT_MEDIA_TIMEOUT_SECONDS
      : draftMediaTimeout;
  if (canonicalDraftMediaTimeout !== storedMediaTimeout) return true;
  if (form.sonarrEnabled !== (settings.media?.sonarr?.enabled ?? true)) return true;
  if (trimmed(form.sonarrUrl) !== trimmed(settings.media?.sonarr?.url ?? "")) return true;
  if (
    trimmed(form.sonarrApiKeyEnv || "SONARR_API_KEY") !==
    trimmed(settings.media?.sonarr?.apiKeyEnv || "SONARR_API_KEY")
  )
    return true;
  if (
    trimmed(form.sonarrDefaultQuality) !==
    trimmed(settings.media?.sonarr?.defaultQualityProfile ?? "")
  )
    return true;
  if (
    trimmed(form.sonarrDefaultRoot) !==
    trimmed(settings.media?.sonarr?.defaultRootFolder ?? "")
  )
    return true;
  if (form.radarrEnabled !== (settings.media?.radarr?.enabled ?? true)) return true;
  if (trimmed(form.radarrUrl) !== trimmed(settings.media?.radarr?.url ?? "")) return true;
  if (
    trimmed(form.radarrApiKeyEnv || "RADARR_API_KEY") !==
    trimmed(settings.media?.radarr?.apiKeyEnv || "RADARR_API_KEY")
  )
    return true;
  if (
    trimmed(form.radarrDefaultQuality) !==
    trimmed(settings.media?.radarr?.defaultQualityProfile ?? "")
  )
    return true;
  if (
    trimmed(form.radarrDefaultRoot) !==
    trimmed(settings.media?.radarr?.defaultRootFolder ?? "")
  )
    return true;

  const storedDesktopDimension =
    typeof settings.desktop?.maxImageDimension === "number"
      ? settings.desktop.maxImageDimension
      : DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION;
  if (Number(form.desktopMaxImageDimension) !== storedDesktopDimension) return true;
  const storedDesktopQuality =
    typeof settings.desktop?.jpegQuality === "number"
      ? settings.desktop.jpegQuality
      : DEFAULT_DESKTOP_JPEG_QUALITY;
  if (Number(form.desktopJpegQuality) !== storedDesktopQuality) return true;
  const storedBlockedApps = Array.isArray(settings.desktop?.blockedApps)
    ? settings.desktop.blockedApps.map((entry) => String(entry).trim()).filter(Boolean)
    : [...DEFAULT_DESKTOP_BLOCKED_APPS];
  const draftBlockedApps = parseBlockedAppsText(form.desktopBlockedAppsText);
  if (draftBlockedApps.length !== storedBlockedApps.length) return true;
  for (let i = 0; i < draftBlockedApps.length; i += 1) {
    if (draftBlockedApps[i] !== storedBlockedApps[i]) return true;
  }

  const fanoutLoaded = form.fanoutLoadedRef.current;
  if (
    fanoutNumber(form.fanoutMaxWorkers, DEFAULT_FANOUT_MAX_WORKERS) !==
    fanoutLoaded.maxWorkers
  )
    return true;
  if (
    fanoutNumber(form.fanoutWorkerTimeoutSeconds, DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS) !==
    fanoutLoaded.workerTimeoutSeconds
  )
    return true;
  if (form.fanoutFullTools !== (fanoutLoaded.fullTools ?? DEFAULT_FANOUT_FULL_TOOLS))
    return true;

  const storedGoalsEnabled = settings.goals?.enabled ?? DEFAULT_GOALS_ENABLED;
  if (form.goalsEnabled !== storedGoalsEnabled) return true;
  const storedStep =
    typeof settings.goals?.stepIntervalMinutes === "number"
      ? settings.goals.stepIntervalMinutes
      : DEFAULT_GOALS_STEP_INTERVAL_MINUTES;
  if (Number(form.goalsStepIntervalMinutes) !== storedStep) return true;
  const storedCap =
    typeof settings.goals?.maxActiveGoals === "number"
      ? settings.goals.maxActiveGoals
      : DEFAULT_GOALS_MAX_ACTIVE_GOALS;
  if (Number(form.goalsMaxActiveGoals) !== storedCap) return true;
  const storedSteps =
    typeof settings.goals?.maxStepsPerGoal === "number"
      ? settings.goals.maxStepsPerGoal
      : DEFAULT_GOALS_MAX_STEPS_PER_GOAL;
  if (Number(form.goalsMaxStepsPerGoal) !== storedSteps) return true;
  const storedPlanTimeout =
    typeof settings.goals?.planTimeoutSeconds === "number"
      ? settings.goals.planTimeoutSeconds
      : DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS;
  if (Number(form.goalsPlanTimeoutSeconds) !== storedPlanTimeout) return true;
  const storedTriggers =
    typeof settings.goals?.maxTriggersPerGoal === "number"
      ? settings.goals.maxTriggersPerGoal
      : DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL;
  if (Number(form.goalsMaxTriggersPerGoal) !== storedTriggers) return true;

  const storedIdeasEnabled = settings.ideas?.enabled ?? DEFAULT_IDEAS_ENABLED;
  if (form.ideasEnabled !== storedIdeasEnabled) return true;
  const storedIdeasCycle =
    typeof settings.ideas?.maxPerCycle === "number"
      ? settings.ideas.maxPerCycle
      : DEFAULT_IDEAS_MAX_PER_CYCLE;
  if (Number(form.ideasMaxPerCycle) !== storedIdeasCycle) return true;
  const storedIdeasTimeout =
    typeof settings.ideas?.timeoutSeconds === "number"
      ? settings.ideas.timeoutSeconds
      : DEFAULT_IDEAS_TIMEOUT_SECONDS;
  if (Number(form.ideasTimeoutSeconds) !== storedIdeasTimeout) return true;

  if (
    normalizeProactiveMode(form.proactiveMode) !==
    normalizeProactiveMode(settings.proactive?.mode ?? DEFAULT_PROACTIVE_MODE)
  )
    return true;
  const storedJudgeTimeout =
    typeof settings.proactive?.judgeTimeoutSeconds === "number"
      ? settings.proactive.judgeTimeoutSeconds
      : DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS;
  if (Number(form.proactiveJudgeTimeoutSeconds) !== storedJudgeTimeout) return true;

  // Each notification switch tracks independently against the resolved
  // snapshot so a single toggle marks the shared footer dirty; absent keys
  // resolve to enabled on both sides.
  const storedNotifications = resolveNotificationsConfig(
    settings.notifications ?? undefined,
  );
  if (form.notificationsApprovalRequested !== storedNotifications.approvalRequested)
    return true;
  if (form.notificationsSchedulerRun !== storedNotifications.schedulerRun)
    return true;
  if (form.notificationsGoalAdvance !== storedNotifications.goalAdvance)
    return true;
  if (form.notificationsIdeaProposed !== storedNotifications.ideaProposed)
    return true;
  if (form.notificationsIndexFailed !== storedNotifications.indexFailed)
    return true;
  if (form.notificationsChatFailed !== storedNotifications.chatFailed) return true;

  const personaLoaded = form.personaLoadedRef.current ?? {};
  if (trimmed(form.personaAssistantNameDraft) !== (personaAssistantName(personaLoaded) ?? ""))
    return true;
  if (canonicalPersonaTone(form.personaToneDraft) !== canonicalPersonaTone(personaLoaded.tone))
    return true;
  if (trimmed(form.personaStyleDraft) !== trimmed(personaStyle(personaLoaded)))
    return true;
  if (trimmed(form.personaUserNameDraft) !== trimmed(personaUserName(personaLoaded)))
    return true;
  if (
    canonicalPersonaAvatarColor(form.personaAvatarDraft) !==
    canonicalPersonaAvatarColor(personaLoaded.avatar)
  )
    return true;

  const storedMemoryMB =
    typeof settings.containers?.memoryMb === "number"
      ? settings.containers.memoryMb
      : DEFAULT_CONTAINERS_CONFIG.memoryMb;
  if (Number(form.containersMemoryMB) !== storedMemoryMB) return true;
  const storedConcurrent =
    typeof settings.containers?.maxConcurrent === "number"
      ? settings.containers.maxConcurrent
      : DEFAULT_CONTAINERS_CONFIG.maxConcurrent;
  if (Number(form.containersMaxConcurrent) !== storedConcurrent) return true;
  const storedTTL =
    typeof settings.containers?.ttlMinutes === "number"
      ? settings.containers.ttlMinutes
      : DEFAULT_CONTAINERS_CONFIG.ttlMinutes;
  if (Number(form.containersTTLMinutes) !== storedTTL) return true;

  const storedQuotaMB =
    typeof settings.workspace?.quotaMB === "number"
      ? settings.workspace.quotaMB
      : DEFAULT_WORKSPACE_CONFIG.quotaMB;
  if (Number(form.workspaceQuotaMB) !== storedQuotaMB) return true;
  const storedQuotaFiles =
    typeof settings.workspace?.quotaFiles === "number"
      ? settings.workspace.quotaFiles
      : DEFAULT_WORKSPACE_CONFIG.quotaFiles;
  if (Number(form.workspaceQuotaFiles) !== storedQuotaFiles) return true;
  const storedTmpTTL =
    typeof settings.workspace?.tmpTTLDays === "number"
      ? settings.workspace.tmpTTLDays
      : DEFAULT_WORKSPACE_CONFIG.tmpTTLDays;
  if (Number(form.workspaceTmpTTLDays) !== storedTmpTTL) return true;

  const rawHostname =
    typeof settings.serverHostname === "string" && settings.serverHostname.trim() !== ""
      ? settings.serverHostname
      : DEFAULT_SERVER_HOSTNAME;
  if (canonicalRestartHost(form.serverHostname) !== canonicalRestartHost(rawHostname))
    return true;
  const storedPort =
    typeof settings.serverPort === "number" && Number.isInteger(settings.serverPort)
      ? settings.serverPort
      : DEFAULT_SERVER_PORT;
  if (Number(form.serverPort) !== storedPort) return true;
  const storedHosts = Array.isArray(settings.serverAllowedHosts)
    ? settings.serverAllowedHosts
    : [];
  if (
    !areServerAllowedHostsEqual(parseServerAllowedHostsText(form.serverAllowedHostsText), storedHosts)
  )
    return true;

  return false;
}
