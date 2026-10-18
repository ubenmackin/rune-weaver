// Rune Weaver Dashboard — Form state and field mutations for Settings.

import { useCallback, useRef, useState } from "react";
import type {
  ContainersConfigData,
  DesktopConfigData,
  EmailAccountData,
  FanoutConfigData,
  GoalsConfigData,
  IdeasConfigData,
  MediaConfigData,
  PersonaData,
  ProactiveConfigData,
  ProviderConfigData,
  SettingsResponse,
  WorkspaceConfigData,
} from "../../api";
import {
  DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_TIMEOUT_SECONDS,
  DEFAULT_CONTAINERS_CONFIG,
  DEFAULT_DESKTOP_BLOCKED_APPS_TEXT,
  DEFAULT_DESKTOP_JPEG_QUALITY,
  DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION,
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
  DEFAULT_PERSONA_AVATAR,
  DEFAULT_PERSONA_TONE,
  DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS,
  DEFAULT_PROACTIVE_MODE,
  DEFAULT_SEARCH_MAX_RESULTS,
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
  DEFAULT_SERVER_HOSTNAME,
  DEFAULT_SERVER_PORT,
  DEFAULT_WORKSPACE_CONFIG,
  engineMaxToolIterations,
  formatBlockedAppsText,
  formatServerAllowedHostsText,
  normalizeProactiveMode,
  personaAssistantName,
  personaStyle,
  personaUserName,
} from "../../api";
import { publishPersonaFromSettings } from "../PersonaAvatar";
import {
  canonicalPersonaAvatarColor,
  canonicalPersonaTone,
  isServerBindPreset,
} from "./settingsHelpers";
import type {
  EmailEntry,
  LiveServerBind,
  ProviderEntry,
} from "./settingsTypes";

export function useSettingsFormState() {
  const [settings, setSettings] = useState<SettingsResponse | null>(null);

  // Engine state
  const [engineName, setEngineName] = useState("");
  const [logLevel, setLogLevel] = useState("info");
  const [compactionThresholdPercent, setCompactionThresholdPercent] = useState(80);
  const [maxToolIterations, setMaxToolIterations] = useState<number | string>(15);

  // Providers state
  const [defaultProvider, setDefaultProvider] = useState("");
  const [fallbackProvider, setFallbackProvider] = useState("");
  const [providersList, setProvidersList] = useState<ProviderEntry[]>([]);

  // Memory state
  const [memoryVectorDBPath, setMemoryVectorDBPath] = useState("");
  const [memoryEpisodesDBPath, setMemoryEpisodesDBPath] = useState("");
  const [memoryEmbeddingModel, setMemoryEmbeddingModel] = useState("");
  const [memoryEmbeddingBackend, setMemoryEmbeddingBackend] = useState("local");

  // Voice state
  const [voiceSTTProvider, setVoiceSTTProvider] = useState("");
  const [voiceWhisperModel, setVoiceWhisperModel] = useState("");
  const [voiceTTSProvider, setVoiceTTSProvider] = useState("");

  // Search state
  const [searchSearxngURL, setSearchSearxngURL] = useState(DEFAULT_SEARCH_SEARXNG_URL);
  const [searchTimeoutSeconds, setSearchTimeoutSeconds] = useState<number | string>(
    DEFAULT_SEARCH_TIMEOUT_SECONDS
  );
  const [searchMaxResults, setSearchMaxResults] = useState<number | string>(
    DEFAULT_SEARCH_MAX_RESULTS
  );
  const [browserTimeoutSeconds, setBrowserTimeoutSeconds] = useState<number | string>(
    DEFAULT_BROWSER_TIMEOUT_SECONDS
  );
  const [browserFetchTimeoutSeconds, setBrowserFetchTimeoutSeconds] = useState<
    number | string
  >(DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS);

  // Plugins state
  const [pluginsDir, setPluginsDir] = useState("~/.runeweaver/plugins");
  const [pluginsMarketplaceIndexURL, setPluginsMarketplaceIndexURL] = useState(
    "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"
  );
  const [pluginsAutoRescan, setPluginsAutoRescan] = useState(true);

  // Email accounts state
  const [emailAccountsList, setEmailAccountsList] = useState<EmailEntry[]>([]);

  // Media state (Sonarr & Radarr)
  const [sonarrEnabled, setSonarrEnabled] = useState(true);
  const [sonarrUrl, setSonarrUrl] = useState("");
  const [sonarrApiKeyEnv, setSonarrApiKeyEnv] = useState("SONARR_API_KEY");
  const [sonarrDefaultQuality, setSonarrDefaultQuality] = useState("");
  const [sonarrDefaultRoot, setSonarrDefaultRoot] = useState("");
  const [radarrEnabled, setRadarrEnabled] = useState(true);
  const [radarrUrl, setRadarrUrl] = useState("");
  const [radarrApiKeyEnv, setRadarrApiKeyEnv] = useState("RADARR_API_KEY");
  const [radarrDefaultQuality, setRadarrDefaultQuality] = useState("");
  const [radarrDefaultRoot, setRadarrDefaultRoot] = useState("");
  const [mediaTimeoutSeconds, setMediaTimeoutSeconds] = useState<number | string>(
    DEFAULT_MEDIA_TIMEOUT_SECONDS
  );

  // Desktop state
  const [desktopMaxImageDimension, setDesktopMaxImageDimension] = useState<
    number | string
  >(DEFAULT_DESKTOP_MAX_IMAGE_DIMENSION);
  const [desktopJpegQuality, setDesktopJpegQuality] = useState<number | string>(
    DEFAULT_DESKTOP_JPEG_QUALITY
  );
  const [desktopBlockedAppsText, setDesktopBlockedAppsText] = useState<string>(
    DEFAULT_DESKTOP_BLOCKED_APPS_TEXT
  );

  // Fanout state
  const [fanoutMaxWorkers, setFanoutMaxWorkers] = useState<number | string>(
    DEFAULT_FANOUT_MAX_WORKERS
  );
  const [fanoutWorkerTimeoutSeconds, setFanoutWorkerTimeoutSeconds] = useState<
    number | string
  >(DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS);
  const [fanoutFullTools, setFanoutFullTools] = useState<boolean>(
    DEFAULT_FANOUT_FULL_TOOLS
  );
  const fanoutLoadedRef = useRef<FanoutConfigData>({
    maxWorkers: DEFAULT_FANOUT_MAX_WORKERS,
    workerTimeoutSeconds: DEFAULT_FANOUT_WORKER_TIMEOUT_SECONDS,
    fullTools: DEFAULT_FANOUT_FULL_TOOLS,
  });

  // Goals state
  const [goalsEnabled, setGoalsEnabled] = useState<boolean>(DEFAULT_GOALS_ENABLED);
  const [goalsStepIntervalMinutes, setGoalsStepIntervalMinutes] = useState<
    number | string
  >(DEFAULT_GOALS_STEP_INTERVAL_MINUTES);
  const [goalsMaxActiveGoals, setGoalsMaxActiveGoals] = useState<number | string>(
    DEFAULT_GOALS_MAX_ACTIVE_GOALS
  );
  const [goalsMaxStepsPerGoal, setGoalsMaxStepsPerGoal] = useState<number | string>(
    DEFAULT_GOALS_MAX_STEPS_PER_GOAL
  );
  const [goalsPlanTimeoutSeconds, setGoalsPlanTimeoutSeconds] = useState<
    number | string
  >(DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS);
  const [goalsMaxTriggersPerGoal, setGoalsMaxTriggersPerGoal] = useState<
    number | string
  >(DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL);

  // Ideas state
  const [ideasEnabled, setIdeasEnabled] = useState<boolean>(DEFAULT_IDEAS_ENABLED);
  const [ideasMaxPerCycle, setIdeasMaxPerCycle] = useState<number | string>(
    DEFAULT_IDEAS_MAX_PER_CYCLE
  );
  const [ideasTimeoutSeconds, setIdeasTimeoutSeconds] = useState<number | string>(
    DEFAULT_IDEAS_TIMEOUT_SECONDS
  );

  // Proactive state
  const [proactiveMode, setProactiveMode] = useState<string>(DEFAULT_PROACTIVE_MODE);
  const [proactiveJudgeTimeoutSeconds, setProactiveJudgeTimeoutSeconds] =
    useState<number | string>(DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS);

  // Persona state
  const [personaAssistantNameDraft, setPersonaAssistantNameDraft] = useState("");
  const [personaToneDraft, setPersonaToneDraft] = useState<string>(DEFAULT_PERSONA_TONE);
  const [personaStyleDraft, setPersonaStyleDraft] = useState("");
  const [personaUserNameDraft, setPersonaUserNameDraft] = useState("");
  const [personaAvatarDraft, setPersonaAvatarDraft] = useState<string>(
    DEFAULT_PERSONA_AVATAR
  );
  const personaLoadedRef = useRef<PersonaData>({});

  // Containers state
  const [containersMemoryMB, setContainersMemoryMB] = useState<number | string>(
    DEFAULT_CONTAINERS_CONFIG.memoryMb
  );
  const [containersMaxConcurrent, setContainersMaxConcurrent] = useState<
    number | string
  >(DEFAULT_CONTAINERS_CONFIG.maxConcurrent);
  const [containersTTLMinutes, setContainersTTLMinutes] = useState<number | string>(
    DEFAULT_CONTAINERS_CONFIG.ttlMinutes
  );

  // Workspace state
  const [workspaceQuotaMB, setWorkspaceQuotaMB] = useState<number | string>(
    DEFAULT_WORKSPACE_CONFIG.quotaMB
  );
  const [workspaceQuotaFiles, setWorkspaceQuotaFiles] = useState<number | string>(
    DEFAULT_WORKSPACE_CONFIG.quotaFiles
  );
  const [workspaceTmpTTLDays, setWorkspaceTmpTTLDays] = useState<number | string>(
    DEFAULT_WORKSPACE_CONFIG.tmpTTLDays
  );

  // Network state
  const [serverHostname, setServerHostname] = useState<string>(DEFAULT_SERVER_HOSTNAME);
  const [serverHostnameCustom, setServerHostnameCustom] = useState(false);
  const [serverPort, setServerPort] = useState<number | string>(DEFAULT_SERVER_PORT);
  const [serverAllowedHostsText, setServerAllowedHostsText] = useState<string>("");
  const [serverRestartRequired, setServerRestartRequired] = useState(false);
  const [liveServerBind, setLiveServerBind] = useState<LiveServerBind | null>(null);

  // Section populate helpers
  const populateMediaSettings = useCallback(
    (media: MediaConfigData | undefined | null) => {
      if (media?.timeoutSeconds !== undefined) {
        setMediaTimeoutSeconds(
          media.timeoutSeconds ?? DEFAULT_MEDIA_TIMEOUT_SECONDS
        );
      }
      if (media?.sonarr) {
        setSonarrEnabled(media.sonarr.enabled ?? true);
        setSonarrUrl(media.sonarr.url ?? "");
        setSonarrApiKeyEnv(media.sonarr.apiKeyEnv || "SONARR_API_KEY");
        setSonarrDefaultQuality(media.sonarr.defaultQualityProfile || "");
        setSonarrDefaultRoot(media.sonarr.defaultRootFolder || "");
      }
      if (media?.radarr) {
        setRadarrEnabled(media.radarr.enabled ?? true);
        setRadarrUrl(media.radarr.url ?? "");
        setRadarrApiKeyEnv(media.radarr.apiKeyEnv || "RADARR_API_KEY");
        setRadarrDefaultQuality(media.radarr.defaultQualityProfile || "");
        setRadarrDefaultRoot(media.radarr.defaultRootFolder || "");
      }
    },
    []
  );

  const populateDesktopSettings = useCallback(
    (desktop: DesktopConfigData | undefined | null) => {
      if (!desktop) return;
      if (typeof desktop.maxImageDimension === "number") {
        setDesktopMaxImageDimension(desktop.maxImageDimension);
      }
      if (typeof desktop.jpegQuality === "number") {
        setDesktopJpegQuality(desktop.jpegQuality);
      }
      if (Array.isArray(desktop.blockedApps)) {
        setDesktopBlockedAppsText(formatBlockedAppsText(desktop.blockedApps));
      }
    },
    []
  );

  const populateFanoutSettings = useCallback(
    (fanout: FanoutConfigData | undefined | null) => {
      const next: FanoutConfigData = { ...fanoutLoadedRef.current };
      if (typeof fanout?.maxWorkers === "number") {
        setFanoutMaxWorkers(fanout.maxWorkers);
        next.maxWorkers = fanout.maxWorkers;
      }
      if (typeof fanout?.workerTimeoutSeconds === "number") {
        setFanoutWorkerTimeoutSeconds(fanout.workerTimeoutSeconds);
        next.workerTimeoutSeconds = fanout.workerTimeoutSeconds;
      }
      if (typeof fanout?.fullTools === "boolean") {
        setFanoutFullTools(fanout.fullTools);
        next.fullTools = fanout.fullTools;
      }
      fanoutLoadedRef.current = next;
    },
    []
  );

  const populateGoalsSettings = useCallback(
    (goals: GoalsConfigData | undefined | null) => {
      if (!goals) return;
      if (typeof goals.enabled === "boolean") {
        setGoalsEnabled(goals.enabled);
      }
      const stepInterval = goals.stepIntervalMinutes;
      if (typeof stepInterval === "number") {
        setGoalsStepIntervalMinutes(stepInterval);
      }
      const maxActive = goals.maxActiveGoals;
      if (typeof maxActive === "number") {
        setGoalsMaxActiveGoals(maxActive);
      }
      const maxSteps = goals.maxStepsPerGoal;
      if (typeof maxSteps === "number") {
        setGoalsMaxStepsPerGoal(maxSteps);
      }
      const planTimeout = goals.planTimeoutSeconds;
      if (typeof planTimeout === "number") {
        setGoalsPlanTimeoutSeconds(planTimeout);
      }
      const maxTriggers = goals.maxTriggersPerGoal;
      if (typeof maxTriggers === "number") {
        setGoalsMaxTriggersPerGoal(maxTriggers);
      }
    },
    []
  );

  const populateIdeasSettings = useCallback(
    (ideas: IdeasConfigData | undefined | null) => {
      if (!ideas) return;
      if (typeof ideas.enabled === "boolean") {
        setIdeasEnabled(ideas.enabled);
      }
      const maxCycle = ideas.maxPerCycle;
      if (typeof maxCycle === "number") {
        setIdeasMaxPerCycle(maxCycle);
      }
      const timeout = ideas.timeoutSeconds;
      if (typeof timeout === "number") {
        setIdeasTimeoutSeconds(timeout);
      }
    },
    []
  );

  const populateProactiveSettings = useCallback(
    (proactive: ProactiveConfigData | undefined | null) => {
      if (!proactive) return;
      if (typeof proactive.mode === "string" && proactive.mode.trim()) {
        const canonical = normalizeProactiveMode(proactive.mode);
        if (canonical) {
          setProactiveMode(canonical);
        }
      }
      if (typeof proactive.judgeTimeoutSeconds === "number") {
        setProactiveJudgeTimeoutSeconds(proactive.judgeTimeoutSeconds);
      }
    },
    []
  );

  const populatePersonaSettings = useCallback(
    (persona: PersonaData | undefined | null) => {
      const loaded = persona ?? {};
      personaLoadedRef.current = loaded;
      setPersonaAssistantNameDraft(personaAssistantName(loaded) ?? "");
      setPersonaToneDraft(canonicalPersonaTone(loaded.tone));
      setPersonaStyleDraft(personaStyle(loaded));
      setPersonaUserNameDraft(personaUserName(loaded));
      setPersonaAvatarDraft(canonicalPersonaAvatarColor(loaded.avatar));
    },
    []
  );

  const populateWorkspaceSettings = useCallback(
    (workspace: WorkspaceConfigData | undefined | null) => {
      if (!workspace) return;
      const quotaMB = typeof workspace.quotaMB === "number" ? workspace.quotaMB : null;
      if (quotaMB !== null) setWorkspaceQuotaMB(quotaMB);
      const quotaFiles =
        typeof workspace.quotaFiles === "number" ? workspace.quotaFiles : null;
      if (quotaFiles !== null) setWorkspaceQuotaFiles(quotaFiles);
      const tmpTTL =
        typeof workspace.tmpTTLDays === "number" ? workspace.tmpTTLDays : null;
      if (tmpTTL !== null) setWorkspaceTmpTTLDays(tmpTTL);
    },
    []
  );

  const populateContainersSettings = useCallback(
    (containers: ContainersConfigData | undefined | null) => {
      if (!containers) return;
      const memoryMB =
        typeof containers.memoryMb === "number" ? containers.memoryMb : null;
      if (memoryMB !== null) setContainersMemoryMB(memoryMB);
      const maxConcurrent =
        typeof containers.maxConcurrent === "number"
          ? containers.maxConcurrent
          : null;
      if (maxConcurrent !== null) setContainersMaxConcurrent(maxConcurrent);
      const ttlMinutes =
        typeof containers.ttlMinutes === "number" ? containers.ttlMinutes : null;
      if (ttlMinutes !== null) setContainersTTLMinutes(ttlMinutes);
    },
    []
  );

  const populateForm = useCallback(
    (data: SettingsResponse) => {
      setSettings(data);
      setEngineName(data.engineName);
      setLogLevel(data.logLevel);
      setCompactionThresholdPercent(data.compactionThresholdPercent ?? 80);
      setMaxToolIterations(engineMaxToolIterations(data));
      setDefaultProvider(data.defaultProvider);
      setFallbackProvider(data.fallbackProvider ?? "");

      const pList: ProviderEntry[] = Object.entries(data.providers || {})
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([name, cfg], idx) => ({
          id: `p-${idx}-${name}`,
          name,
          config: {
            enabled: cfg.enabled ?? true,
            model: cfg.model ?? "",
            serverURL: cfg.serverURL || "",
            apiKeyEnv: cfg.apiKeyEnv || "",
            providerType: cfg.providerType || "",
            apiStyle: cfg.apiStyle || "",
            contextLength: cfg.contextLength,
            slotCount: cfg.slotCount,
            cachePrompt: cfg.cachePrompt,
            supportsVision: cfg.supportsVision,
          },
        }));
      setProvidersList(pList);

      setMemoryVectorDBPath(data.memoryVectorDBPath);
      setMemoryEpisodesDBPath(data.memoryEpisodesDBPath);
      setMemoryEmbeddingModel(data.memoryEmbeddingModel);
      setMemoryEmbeddingBackend(data.memoryEmbeddingBackend ?? "local");
      setVoiceSTTProvider(data.voiceSTTProvider);
      setVoiceWhisperModel(data.voiceWhisperModel);
      setVoiceTTSProvider(data.voiceTTSProvider);

      setSearchSearxngURL(
        data.browserSearxngURL ??
          data.searchSearxngURL ??
          DEFAULT_SEARCH_SEARXNG_URL
      );
      setSearchTimeoutSeconds(
        data.browserSearchTimeoutSeconds ??
          data.searchTimeoutSeconds ??
          DEFAULT_SEARCH_TIMEOUT_SECONDS
      );
      setSearchMaxResults(
        data.browserMaxResults ??
          data.searchMaxResults ??
          DEFAULT_SEARCH_MAX_RESULTS
      );
      if (data.browserTimeoutSeconds !== undefined) {
        setBrowserTimeoutSeconds(data.browserTimeoutSeconds);
      }
      if (data.browserFetchTimeoutSeconds !== undefined) {
        setBrowserFetchTimeoutSeconds(data.browserFetchTimeoutSeconds);
      }
      setPluginsDir(data.pluginsDir ?? "~/.runeweaver/plugins");
      setPluginsMarketplaceIndexURL(
        data.pluginsMarketplaceIndexURL ??
          "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"
      );
      setPluginsAutoRescan(data.pluginsAutoRescan ?? true);

      const eList: EmailEntry[] = (data.emailAccounts || []).map((acc, idx) => ({
        id: `email-${idx}-${acc.name}`,
        account: { ...acc },
      }));
      setEmailAccountsList(eList);

      populateMediaSettings(data.media);
      populateDesktopSettings(data.desktop);
      populateGoalsSettings(data.goals);
      populateIdeasSettings(data.ideas);
      populateProactiveSettings(data.proactive);
      populatePersonaSettings(data.persona);
      publishPersonaFromSettings(data.persona);
      populateFanoutSettings(data.fanout);
      populateWorkspaceSettings(data.workspace);
      populateContainersSettings(data.containers);

      setServerHostname(
        typeof data.serverHostname === "string" && data.serverHostname.trim()
          ? data.serverHostname
          : DEFAULT_SERVER_HOSTNAME
      );
      setServerHostnameCustom(
        typeof data.serverHostname === "string" && data.serverHostname.trim()
          ? !isServerBindPreset(data.serverHostname)
          : false
      );
      setServerPort(
        typeof data.serverPort === "number" && Number.isInteger(data.serverPort)
          ? data.serverPort
          : DEFAULT_SERVER_PORT
      );
      setServerAllowedHostsText(
        formatServerAllowedHostsText(data.serverAllowedHosts)
      );

      const fileBindHostname =
        typeof data.serverHostname === "string" && data.serverHostname.trim()
          ? data.serverHostname
          : DEFAULT_SERVER_HOSTNAME;
      const fileBindPort =
        typeof data.serverPort === "number" && Number.isInteger(data.serverPort)
          ? data.serverPort
          : DEFAULT_SERVER_PORT;
      const fileBindHosts = Array.isArray(data.serverAllowedHosts)
        ? [...data.serverAllowedHosts]
        : [];
      setLiveServerBind((prev) =>
        prev ?? {
          hostname: fileBindHostname,
          port: fileBindPort,
          allowedHosts: fileBindHosts,
        }
      );
      setServerRestartRequired(Boolean(data.requiresRestart));
    },
    [
      populateMediaSettings,
      populateDesktopSettings,
      populateGoalsSettings,
      populateIdeasSettings,
      populateProactiveSettings,
      populatePersonaSettings,
      populateFanoutSettings,
      populateWorkspaceSettings,
      populateContainersSettings,
    ]
  );

  // Provider CRUD helpers
  const handleAddProvider = () => {
    const id = `new-p-${Date.now()}`;
    const name = `provider_${providersList.length + 1}`;
    setProvidersList((prev) => [
      ...prev,
      {
        id,
        name,
        config: {
          enabled: true,
          model: "",
          serverURL: "",
          apiKeyEnv: "",
          providerType: "",
          apiStyle: "",
          contextLength: undefined,
          slotCount: undefined,
          cachePrompt: undefined,
          supportsVision: undefined,
        },
      },
    ]);
  };

  const handleRemoveProvider = (id: string, name: string) => {
    const filtered = providersList.filter((p) => p.id !== id);
    setProvidersList(filtered);
    if (defaultProvider === name) {
      setDefaultProvider(filtered.length > 0 ? filtered[0].name : "");
    }
    if (fallbackProvider === name) {
      setFallbackProvider("");
    }
  };

  const handleProviderNameChange = (id: string, newName: string) => {
    const existing = providersList.find((item) => item.id === id);
    if (existing) {
      if (defaultProvider === existing.name) {
        setDefaultProvider(newName);
      }
      if (fallbackProvider === existing.name) {
        setFallbackProvider(newName);
      }
    }
    setProvidersList((prev) =>
      prev.map((item) => (item.id === id ? { ...item, name: newName } : item))
    );
  };

  const handleProviderFieldChange = (
    id: string,
    field: keyof ProviderConfigData,
    val: string | boolean | number | undefined,
    onError?: (msg: string) => void
  ) => {
    let visionNext: boolean | undefined = undefined;
    const isVisionField = field === "supportsVision";
    if (isVisionField) {
      if (val === "" || val === undefined) {
        visionNext = undefined;
      } else if (val === true || val === "true") {
        visionNext = true;
      } else if (val === false || val === "false") {
        visionNext = false;
      } else {
        const label =
          (providersList.find((item) => item.id === id)?.name ?? "").trim() ||
          "(unnamed)";
        onError?.(
          `Invalid supportsVision for provider "${label}": supportsVision must be true, false, or empty (unset).`
        );
        return;
      }
    }
    setProvidersList((prev) =>
      prev.map((item) => {
        if (item.id === id) {
          const updated = { ...item.config, [field]: val };
          if (field === "serverURL") updated.serverURL = val as string;
          if (field === "apiKeyEnv") updated.apiKeyEnv = val as string;
          if (field === "providerType") updated.providerType = val as string;
          if (field === "apiStyle") updated.apiStyle = val as string;
          if (field === "contextLength") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.contextLength = next as unknown as number | undefined;
          }
          if (field === "slotCount") {
            const next =
              val === "" || val === undefined ? undefined : Number(val);
            updated.slotCount = next as unknown as number | undefined;
          }
          if (field === "cachePrompt") {
            const next =
              val === "" || val === undefined
                ? undefined
                : val === true || val === "true"
                  ? true
                  : val === false || val === "false"
                    ? false
                    : (val as unknown as boolean | undefined);
            updated.cachePrompt = next;
          }
          if (field === "supportsVision") {
            updated.supportsVision = visionNext;
          }
          return { ...item, config: updated };
        }
        return item;
      })
    );
  };

  // Email Accounts CRUD helpers
  const handleAddEmailAccount = () => {
    const id = `new-email-${Date.now()}`;
    const name = `mail_${emailAccountsList.length + 1}`;
    setEmailAccountsList((prev) => [
      ...prev,
      {
        id,
        account: {
          name,
          type: "imap",
          host: "imap.example.com",
          port: 993,
          username: "",
        },
      },
    ]);
  };

  const handleRemoveEmailAccount = (id: string) => {
    setEmailAccountsList((prev) => prev.filter((item) => item.id !== id));
  };

  const handleEmailFieldChange = (
    id: string,
    field: keyof EmailAccountData,
    val: string | number
  ) => {
    setEmailAccountsList((prev) =>
      prev.map((item) => {
        if (item.id === id) {
          const next = { ...item.account };
          if (field === "port") {
            next.port = Number(val);
          } else if (field === "smtpPort") {
            const num = val === "" || val === undefined ? undefined : Number(val);
            next.smtpPort = num as unknown as number | undefined;
          } else if (field === "smtpHost") {
            next.smtpHost = val as string;
          } else if (field === "smtpSecurity") {
            next.smtpSecurity = val as string;
          } else {
            (next as Record<string, unknown>)[field] = val;
          }
          return {
            ...item,
            account: next as EmailAccountData,
          };
        }
        return item;
      })
    );
  };

  return {
    settings,
    setSettings,
    engineName,
    setEngineName,
    logLevel,
    setLogLevel,
    compactionThresholdPercent,
    setCompactionThresholdPercent,
    maxToolIterations,
    setMaxToolIterations,
    defaultProvider,
    setDefaultProvider,
    fallbackProvider,
    setFallbackProvider,
    providersList,
    setProvidersList,
    memoryVectorDBPath,
    setMemoryVectorDBPath,
    memoryEpisodesDBPath,
    setMemoryEpisodesDBPath,
    memoryEmbeddingModel,
    setMemoryEmbeddingModel,
    memoryEmbeddingBackend,
    setMemoryEmbeddingBackend,
    voiceSTTProvider,
    setVoiceSTTProvider,
    voiceWhisperModel,
    setVoiceWhisperModel,
    voiceTTSProvider,
    setVoiceTTSProvider,
    searchSearxngURL,
    setSearchSearxngURL,
    searchTimeoutSeconds,
    setSearchTimeoutSeconds,
    searchMaxResults,
    setSearchMaxResults,
    browserTimeoutSeconds,
    setBrowserTimeoutSeconds,
    browserFetchTimeoutSeconds,
    setBrowserFetchTimeoutSeconds,
    pluginsDir,
    setPluginsDir,
    pluginsMarketplaceIndexURL,
    setPluginsMarketplaceIndexURL,
    pluginsAutoRescan,
    setPluginsAutoRescan,
    emailAccountsList,
    setEmailAccountsList,
    sonarrEnabled,
    setSonarrEnabled,
    sonarrUrl,
    setSonarrUrl,
    sonarrApiKeyEnv,
    setSonarrApiKeyEnv,
    sonarrDefaultQuality,
    setSonarrDefaultQuality,
    sonarrDefaultRoot,
    setSonarrDefaultRoot,
    radarrEnabled,
    setRadarrEnabled,
    radarrUrl,
    setRadarrUrl,
    radarrApiKeyEnv,
    setRadarrApiKeyEnv,
    radarrDefaultQuality,
    setRadarrDefaultQuality,
    radarrDefaultRoot,
    setRadarrDefaultRoot,
    mediaTimeoutSeconds,
    setMediaTimeoutSeconds,
    desktopMaxImageDimension,
    setDesktopMaxImageDimension,
    desktopJpegQuality,
    setDesktopJpegQuality,
    desktopBlockedAppsText,
    setDesktopBlockedAppsText,
    fanoutMaxWorkers,
    setFanoutMaxWorkers,
    fanoutWorkerTimeoutSeconds,
    setFanoutWorkerTimeoutSeconds,
    fanoutFullTools,
    setFanoutFullTools,
    fanoutLoadedRef,
    goalsEnabled,
    setGoalsEnabled,
    goalsStepIntervalMinutes,
    setGoalsStepIntervalMinutes,
    goalsMaxActiveGoals,
    setGoalsMaxActiveGoals,
    goalsMaxStepsPerGoal,
    setGoalsMaxStepsPerGoal,
    goalsPlanTimeoutSeconds,
    setGoalsPlanTimeoutSeconds,
    goalsMaxTriggersPerGoal,
    setGoalsMaxTriggersPerGoal,
    ideasEnabled,
    setIdeasEnabled,
    ideasMaxPerCycle,
    setIdeasMaxPerCycle,
    ideasTimeoutSeconds,
    setIdeasTimeoutSeconds,
    proactiveMode,
    setProactiveMode,
    proactiveJudgeTimeoutSeconds,
    setProactiveJudgeTimeoutSeconds,
    personaAssistantNameDraft,
    setPersonaAssistantNameDraft,
    personaToneDraft,
    setPersonaToneDraft,
    personaStyleDraft,
    setPersonaStyleDraft,
    personaUserNameDraft,
    setPersonaUserNameDraft,
    personaAvatarDraft,
    setPersonaAvatarDraft,
    personaLoadedRef,
    containersMemoryMB,
    setContainersMemoryMB,
    containersMaxConcurrent,
    setContainersMaxConcurrent,
    containersTTLMinutes,
    setContainersTTLMinutes,
    workspaceQuotaMB,
    setWorkspaceQuotaMB,
    workspaceQuotaFiles,
    setWorkspaceQuotaFiles,
    workspaceTmpTTLDays,
    setWorkspaceTmpTTLDays,
    serverHostname,
    setServerHostname,
    serverHostnameCustom,
    setServerHostnameCustom,
    serverPort,
    setServerPort,
    serverAllowedHostsText,
    setServerAllowedHostsText,
    serverRestartRequired,
    setServerRestartRequired,
    liveServerBind,
    setLiveServerBind,
    populateForm,
    handleAddProvider,
    handleRemoveProvider,
    handleProviderNameChange,
    handleProviderFieldChange,
    handleAddEmailAccount,
    handleRemoveEmailAccount,
    handleEmailFieldChange,
  };
}
