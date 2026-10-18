// Rune Weaver Dashboard — Save execution, active-run guard, and modal save handlers.

import type React from "react";
import { useRef, useState } from "react";
import type {
  EmailAccountData,
  ProviderConfigData,
} from "../../api";
import {
  ApiError,
  canonicalRestartHost,
  DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_TIMEOUT_SECONDS,
  DEFAULT_ENGINE_MAX_TOOL_ITERATIONS,
  DEFAULT_SERVER_HOSTNAME,
  DEFAULT_SERVER_PORT,
  hasActiveRuns,
  listRuns,
  normalizeServerAllowedHost,
  parseServerAllowedHostsText,
  RUN_LOG_POLL_LIMIT,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
  updateSettings,
  validateServerAllowedHosts,
  validateServerHostname,
} from "../../api";
import {
  areServerAllowedHostsEqual,
  validateBrowserFetchTimeoutSeconds,
  validateBrowserTimeoutSeconds,
  validateDesktopCaptureBounds,
  validateMediaTimeoutSeconds,
} from "./settingsHelpers";
import type { SettingsTab } from "./settingsTypes";
import {
  buildContainersPatch,
  buildDesktopPayload,
  buildFanoutPayload,
  buildGoalsPayload,
  buildIdeasPayload,
  buildMediaPayload,
  buildPersonaDelta,
  buildProactivePayload,
  buildWorkspacePayload,
  validateContainersFields,
  validateGoalsFields,
  validateIdeasFields,
  validatePersonaFields,
  validateProactiveFields,
  validateWorkspaceFields,
} from "./settingsValidation";
import type { useSettingsFormState } from "./useSettingsFormState";

export interface UseSettingsSaveProps {
  activeTab: SettingsTab;
  form: ReturnType<typeof useSettingsFormState>;
  sharedRuns: readonly ({ status?: unknown } | null | undefined)[];
  onSettingsSaved?: () => void;
  pushSuccessToast: (msg: string) => void;
}

export function useSettingsSave({
  activeTab,
  form,
  sharedRuns,
  onSettingsSaved,
  pushSuccessToast,
}: UseSettingsSaveProps) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showActiveGuard, setShowActiveGuard] = useState(false);

  const [configuringToolName, setConfiguringToolName] = useState<string | null>(null);

  const [mediaSaveLoading, setMediaSaveLoading] = useState(false);
  const [mediaModalError, setMediaModalError] = useState<string | null>(null);
  const mediaSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [browserSaveLoading, setBrowserSaveLoading] = useState(false);
  const [browserModalError, setBrowserModalError] = useState<string | null>(null);
  const browserSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [desktopSaveLoading, setDesktopSaveLoading] = useState(false);
  const [desktopModalError, setDesktopModalError] = useState<string | null>(null);
  const desktopSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [fanoutSaveLoading, setFanoutSaveLoading] = useState(false);
  const [fanoutModalError, setFanoutModalError] = useState<string | null>(null);
  const fanoutSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const executeSave = async () => {
    setSaving(true);
    setError(null);

    if (activeTab === "persona") {
      const personaValidationError = validatePersonaFields(
        form.personaAssistantNameDraft,
        form.personaToneDraft,
        form.personaStyleDraft,
        form.personaUserNameDraft,
        form.personaAvatarDraft
      );
      if (personaValidationError) {
        setError(personaValidationError);
        setSaving(false);
        return;
      }
      const personaDelta = buildPersonaDelta(
        form.personaLoadedRef.current,
        form.personaAssistantNameDraft,
        form.personaToneDraft,
        form.personaStyleDraft,
        form.personaUserNameDraft,
        form.personaAvatarDraft
      );
      if (Object.keys(personaDelta).length === 0) {
        setSaving(false);
        return;
      }
      try {
        const updated = await updateSettings({ persona: personaDelta });
        form.populateForm(updated);
        onSettingsSaved?.();
        pushSuccessToast(
          "Persona saved. The agent adopts the new identity on engine reload."
        );
      } catch (failure) {
        setError(
          failure instanceof ApiError ? failure.message : "Failed to save persona"
        );
      } finally {
        setSaving(false);
      }
      return;
    }

    const seenNames = new Set<string>();
    for (const entry of form.providersList) {
      const trimmedName = entry.name.trim();
      if (!trimmedName) {
        setError("Provider names cannot be empty.");
        setSaving(false);
        return;
      }
      if (seenNames.has(trimmedName)) {
        setError(
          `Duplicate provider name: "${trimmedName}". Provider names must be unique.`
        );
        setSaving(false);
        return;
      }
      seenNames.add(trimmedName);
    }

    const providersMap: Record<string, ProviderConfigData> = {};
    for (const entry of form.providersList) {
      const trimmedName = entry.name.trim();
      if (!trimmedName) continue;
      const sUrl = entry.config.serverURL;
      const kEnv = entry.config.apiKeyEnv;
      const pType = entry.config.providerType;
      const aStyle = entry.config.apiStyle;

      const cLenRaw = entry.config.contextLength;
      if (
        cLenRaw !== undefined &&
        cLenRaw !== null &&
        (cLenRaw as unknown) !== ""
      ) {
        const cLenCheck = Number(cLenRaw);
        if (!Number.isInteger(cLenCheck) || cLenCheck <= 0) {
          const label = trimmedName || "(unnamed)";
          setError(
            `Invalid contextLength for provider "${label}": contextLength must be a positive integer.`
          );
          setSaving(false);
          return;
        }
      }
      const cLenNum =
        cLenRaw === undefined || cLenRaw === null || (cLenRaw as unknown) === ""
          ? undefined
          : Number(cLenRaw);
      const cLen =
        cLenNum === undefined || Number.isNaN(cLenNum) ? undefined : cLenNum;

      const slotRaw = entry.config.slotCount;
      if (
        slotRaw !== undefined &&
        slotRaw !== null &&
        (slotRaw as unknown) !== ""
      ) {
        const slotCheck = Number(slotRaw);
        if (!Number.isInteger(slotCheck) || slotCheck <= 0) {
          const label = trimmedName || "(unnamed)";
          setError(
            `Invalid slotCount for provider "${label}": slotCount must be a positive integer.`
          );
          setSaving(false);
          return;
        }
      }
      const slotNum =
        slotRaw === undefined || slotRaw === null || (slotRaw as unknown) === ""
          ? undefined
          : Number(slotRaw);
      const slot =
        slotNum === undefined || Number.isNaN(slotNum) ? undefined : slotNum;

      const cacheRaw = entry.config.cachePrompt;
      let cache: boolean | undefined;
      if (
        cacheRaw === undefined ||
        cacheRaw === null ||
        (cacheRaw as unknown) === ""
      ) {
        cache = undefined;
      } else if (cacheRaw === true || (cacheRaw as unknown) === "true") {
        cache = true;
      } else if (cacheRaw === false || (cacheRaw as unknown) === "false") {
        cache = false;
      } else {
        const label = trimmedName || "(unnamed)";
        setError(
          `Invalid cachePrompt for provider "${label}": cachePrompt must be true, false, or empty (unset).`
        );
        setSaving(false);
        return;
      }

      const visionRaw = entry.config.supportsVision;
      let vision: boolean | undefined;
      if (
        visionRaw === undefined ||
        visionRaw === null ||
        (visionRaw as unknown) === ""
      ) {
        vision = undefined;
      } else if (visionRaw === true || (visionRaw as unknown) === "true") {
        vision = true;
      } else if (visionRaw === false || (visionRaw as unknown) === "false") {
        vision = false;
      } else {
        const label = trimmedName || "(unnamed)";
        setError(
          `Invalid supportsVision for provider "${label}": supportsVision must be true, false, or empty (unset).`
        );
        setSaving(false);
        return;
      }

      providersMap[trimmedName] = {
        enabled: entry.config.enabled,
        model: entry.config.model?.trim() || undefined,
        serverURL: sUrl?.trim() || undefined,
        apiKeyEnv: kEnv?.trim() || undefined,
        providerType: pType?.trim() || undefined,
        apiStyle: aStyle?.trim() || undefined,
        contextLength: cLen != null ? Number(cLen) : undefined,
        slotCount: slot != null ? Number(slot) : undefined,
        cachePrompt: cache,
        supportsVision: vision,
      };
    }

    const workspaceValidationError = validateWorkspaceFields(
      form.workspaceQuotaMB,
      form.workspaceQuotaFiles,
      form.workspaceTmpTTLDays
    );
    if (workspaceValidationError) {
      setError(workspaceValidationError);
      setSaving(false);
      return;
    }

    const containersValidationError = validateContainersFields(
      form.containersMemoryMB,
      form.containersMaxConcurrent,
      form.containersTTLMinutes
    );
    if (containersValidationError) {
      setError(containersValidationError);
      setSaving(false);
      return;
    }

    const goalsValidationError = validateGoalsFields(
      form.goalsStepIntervalMinutes,
      form.goalsMaxActiveGoals,
      form.goalsMaxStepsPerGoal,
      form.goalsPlanTimeoutSeconds,
      form.goalsMaxTriggersPerGoal
    );
    if (goalsValidationError) {
      setError(goalsValidationError);
      setSaving(false);
      return;
    }

    const ideasValidationError = validateIdeasFields(
      form.ideasMaxPerCycle,
      form.ideasTimeoutSeconds
    );
    if (ideasValidationError) {
      setError(ideasValidationError);
      setSaving(false);
      return;
    }

    const proactiveValidationError = validateProactiveFields(
      form.proactiveMode,
      form.proactiveJudgeTimeoutSeconds
    );
    if (proactiveValidationError) {
      setError(proactiveValidationError);
      setSaving(false);
      return;
    }

    for (const entry of form.emailAccountsList) {
      const trimmedName = entry.account.name.trim();
      const trimmedHost = entry.account.host.trim();
      const trimmedUsername = entry.account.username.trim();
      if (!trimmedName || !trimmedHost || !trimmedUsername) {
        setError(
          "Email accounts require a name, host, and username. Complete or remove incomplete rows before saving."
        );
        setSaving(false);
        return;
      }
    }

    for (const entry of form.emailAccountsList) {
      const label = entry.account.name.trim() || "(unnamed)";
      const portNum = Number(entry.account.port);
      if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
        setError(
          `Invalid port for email account "${label}": port must be between 1 and 65535.`
        );
        setSaving(false);
        return;
      }
      const rawSmtpPort = entry.account.smtpPort;
      if (
        rawSmtpPort !== undefined &&
        rawSmtpPort !== null &&
        String(rawSmtpPort).trim() !== ""
      ) {
        const smtpNum = Number(rawSmtpPort);
        const allowedSmtpPorts = [25, 465, 587, 2525];
        if (!Number.isInteger(smtpNum) || !allowedSmtpPorts.includes(smtpNum)) {
          setError(
            `Invalid SMTP port for email account "${label}": smtpPort must be one of 25, 465, 587, 2525 (got ${String(rawSmtpPort).trim()}).`
          );
          setSaving(false);
          return;
        }
      }
    }

    const trimmedSearxngURL = form.searchSearxngURL.trim();
    if (!trimmedSearxngURL) {
      setError("Search SearXNG URL cannot be empty.");
      setSaving(false);
      return;
    }
    try {
      const parsedSearchURL = new URL(trimmedSearxngURL);
      if (
        parsedSearchURL.protocol !== "http:" &&
        parsedSearchURL.protocol !== "https:"
      ) {
        throw new Error("bad protocol");
      }
    } catch {
      setError(
        `Invalid SearXNG URL: "${trimmedSearxngURL}". Use an absolute http(s) URL.`
      );
      setSaving(false);
      return;
    }

    const timeoutNum = Number(form.searchTimeoutSeconds);
    if (!Number.isInteger(timeoutNum) || timeoutNum < 1 || timeoutNum > 120) {
      setError("Invalid search timeout: timeout must be between 1 and 120 seconds.");
      setSaving(false);
      return;
    }
    const maxResultsNum = Number(form.searchMaxResults);
    if (
      !Number.isInteger(maxResultsNum) ||
      maxResultsNum < 1 ||
      maxResultsNum > 50
    ) {
      setError("Invalid search max results: max results must be between 1 and 50.");
      setSaving(false);
      return;
    }

    const browserTimeoutError = validateBrowserTimeoutSeconds(
      form.browserTimeoutSeconds
    );
    if (browserTimeoutError) {
      setError(browserTimeoutError);
      setSaving(false);
      return;
    }
    const browserFetchTimeoutError = validateBrowserFetchTimeoutSeconds(
      form.browserFetchTimeoutSeconds
    );
    if (browserFetchTimeoutError) {
      setError(browserFetchTimeoutError);
      setSaving(false);
      return;
    }
    const mediaTimeoutError = validateMediaTimeoutSeconds(
      form.mediaTimeoutSeconds
    );
    if (mediaTimeoutError) {
      setError(mediaTimeoutError);
      setSaving(false);
      return;
    }

    const desktopBoundsError = validateDesktopCaptureBounds(
      form.desktopMaxImageDimension,
      form.desktopJpegQuality
    );
    if (desktopBoundsError) {
      setError(desktopBoundsError);
      setSaving(false);
      return;
    }

    const trimmedServerHostname = form.serverHostname.trim();
    if (!trimmedServerHostname) {
      setError("Server hostname cannot be empty.");
      setSaving(false);
      return;
    }
    const serverHostnameError = validateServerHostname(trimmedServerHostname);
    if (serverHostnameError) {
      setError(`Invalid server hostname: ${serverHostnameError}`);
      setSaving(false);
      return;
    }
    const serverPortNum = Number(form.serverPort);
    if (
      !Number.isInteger(serverPortNum) ||
      serverPortNum < 1 ||
      serverPortNum > 65535
    ) {
      setError("Invalid server port: port must be between 1 and 65535.");
      setSaving(false);
      return;
    }
    const trimmedServerHosts = parseServerAllowedHostsText(
      form.serverAllowedHostsText
    );
    const serverHostsError = validateServerAllowedHosts(trimmedServerHosts);
    if (serverHostsError) {
      setError(`Invalid allowed hosts: ${serverHostsError}`);
      setSaving(false);
      return;
    }

    const emailAccounts: EmailAccountData[] = form.emailAccountsList.map((entry) => {
      const rawHost = entry.account.smtpHost ?? "";
      const trimmedSmtpHost = String(rawHost).trim();
      const rawPort = entry.account.smtpPort;
      const portNum =
        rawPort === undefined || rawPort === null || (rawPort as unknown) === ""
          ? undefined
          : Number(rawPort);
      const rawSecurity = entry.account.smtpSecurity ?? "";
      const trimmedSecurity = String(rawSecurity).trim().toLowerCase();
      const security =
        trimmedSecurity === "ssl" || trimmedSecurity === "starttls"
          ? trimmedSecurity
          : undefined;
      const rebuilt: EmailAccountData = {
        name: entry.account.name.trim(),
        type: entry.account.type.trim() || "imap",
        host: entry.account.host.trim(),
        port: Number(entry.account.port),
        username: entry.account.username.trim(),
      };
      if (trimmedSmtpHost) {
        rebuilt.smtpHost = trimmedSmtpHost;
      }
      if (
        portNum !== undefined &&
        Number.isInteger(portNum) &&
        portNum >= 1 &&
        portNum <= 65535
      ) {
        rebuilt.smtpPort = portNum;
      }
      if (security) {
        rebuilt.smtpSecurity = security;
      }
      return rebuilt;
    });

    try {
      const preservedEmbeddingModel =
        form.memoryEmbeddingModel || form.settings?.memoryEmbeddingModel || "";
      const rawMaxToolIterations = String(form.maxToolIterations ?? "").trim();
      const maxToolIterationsValue =
        rawMaxToolIterations === ""
          ? DEFAULT_ENGINE_MAX_TOOL_ITERATIONS
          : Number(rawMaxToolIterations);
      const clampedMaxToolIterations = Number.isFinite(maxToolIterationsValue)
        ? Math.max(
            TOOL_ROUNDS_MIN,
            Math.min(TOOL_ROUNDS_MAX, Math.floor(maxToolIterationsValue))
          )
        : DEFAULT_ENGINE_MAX_TOOL_ITERATIONS;

      const loadedServerHostname =
        typeof form.settings?.serverHostname === "string" &&
        form.settings.serverHostname.trim()
          ? form.settings.serverHostname
          : DEFAULT_SERVER_HOSTNAME;
      const loadedServerPort =
        typeof form.settings?.serverPort === "number" &&
        Number.isInteger(form.settings.serverPort)
          ? form.settings.serverPort
          : DEFAULT_SERVER_PORT;
      const loadedServerHosts = Array.isArray(form.settings?.serverAllowedHosts)
        ? (form.settings.serverAllowedHosts as string[])
        : [];
      const serverDirty =
        canonicalRestartHost(trimmedServerHostname) !==
          canonicalRestartHost(loadedServerHostname) ||
        serverPortNum !== loadedServerPort ||
        !areServerAllowedHostsEqual(trimmedServerHosts, loadedServerHosts);

      const preSaveFileBind = {
        hostname: loadedServerHostname,
        port: loadedServerPort,
        allowedHosts: [...loadedServerHosts],
      };

      const updated = await updateSettings({
        engineName: form.engineName,
        logLevel: form.logLevel,
        compactionThresholdPercent: Number(form.compactionThresholdPercent),
        maxToolIterations: clampedMaxToolIterations,
        defaultProvider: form.defaultProvider,
        fallbackProvider: form.fallbackProvider,
        providers: providersMap,
        containers: buildContainersPatch(
          form.containersMemoryMB,
          form.containersMaxConcurrent,
          form.containersTTLMinutes
        ),
        memoryVectorDBPath: form.memoryVectorDBPath,
        memoryEpisodesDBPath: form.memoryEpisodesDBPath,
        memoryEmbeddingModel: preservedEmbeddingModel,
        memoryEmbeddingBackend: form.memoryEmbeddingBackend,
        voiceSTTProvider: form.voiceSTTProvider,
        voiceWhisperModel: form.voiceWhisperModel,
        voiceTTSProvider: form.voiceTTSProvider,
        browserSearxngURL: trimmedSearxngURL,
        browserSearchTimeoutSeconds: timeoutNum,
        browserTimeoutSeconds:
          Number(form.browserTimeoutSeconds) || DEFAULT_BROWSER_TIMEOUT_SECONDS,
        browserFetchTimeoutSeconds:
          Number(form.browserFetchTimeoutSeconds) ||
          DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
        browserMaxResults: maxResultsNum,
        searchSearxngURL: trimmedSearxngURL,
        searchTimeoutSeconds: timeoutNum,
        searchMaxResults: maxResultsNum,
        emailAccounts,
        pluginsDir: form.pluginsDir,
        pluginsMarketplaceIndexURL: form.pluginsMarketplaceIndexURL,
        pluginsAutoRescan: form.pluginsAutoRescan,
        media: buildMediaPayload(
          form.settings,
          form.mediaTimeoutSeconds,
          form.sonarrEnabled,
          form.sonarrUrl,
          form.sonarrApiKeyEnv,
          form.sonarrDefaultQuality,
          form.sonarrDefaultRoot,
          form.radarrEnabled,
          form.radarrUrl,
          form.radarrApiKeyEnv,
          form.radarrDefaultQuality,
          form.radarrDefaultRoot
        ),
        desktop: buildDesktopPayload(
          form.desktopMaxImageDimension,
          form.desktopJpegQuality,
          form.desktopBlockedAppsText
        ),
        workspace: buildWorkspacePayload(
          form.workspaceQuotaMB,
          form.workspaceQuotaFiles,
          form.workspaceTmpTTLDays
        ),
        goals: buildGoalsPayload(
          form.goalsEnabled,
          form.goalsStepIntervalMinutes,
          form.goalsMaxActiveGoals,
          form.goalsMaxStepsPerGoal,
          form.goalsPlanTimeoutSeconds,
          form.goalsMaxTriggersPerGoal
        ),
        proactive: buildProactivePayload(
          form.proactiveMode,
          form.proactiveJudgeTimeoutSeconds
        ),
        ideas: buildIdeasPayload(
          form.ideasEnabled,
          form.ideasMaxPerCycle,
          form.ideasTimeoutSeconds
        ),
        ...(serverDirty
          ? {
              serverHostname: trimmedServerHostname,
              serverPort: serverPortNum,
              serverAllowedHosts: trimmedServerHosts.map((h) =>
                normalizeServerAllowedHost(h)
              ),
            }
          : {}),
      });

      if (updated.requiresRestart) {
        form.setLiveServerBind((prev) => prev ?? preSaveFileBind);
      }
      form.populateForm(updated);
      onSettingsSaved?.();

      if (updated.requiresRestart) {
        if (serverDirty) {
          form.setServerRestartRequired(true);
          pushSuccessToast(
            "Settings saved. Restart required for network changes."
          );
        } else {
          pushSuccessToast("Settings saved. Restart required.");
        }
      } else {
        pushSuccessToast("Settings saved.");
      }
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Failed to save settings"
      );
    } finally {
      setSaving(false);
    }
  };

  const hasRunningWork = async (): Promise<boolean> => {
    try {
      const live = await listRuns(RUN_LOG_POLL_LIMIT);
      const raw = (live as unknown as { runs?: unknown })?.runs;
      const rows = Array.isArray(raw)
        ? (raw as Array<{ status?: unknown }>)
        : [];
      return hasActiveRuns(rows);
    } catch {
      if (Array.isArray(sharedRuns)) {
        return hasActiveRuns(sharedRuns);
      }
      return false;
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (saving) return;
    let active = false;
    try {
      active = await hasRunningWork();
    } catch {
      active = false;
    }
    if (active) {
      setShowActiveGuard(true);
      return;
    }
    await executeSave();
  };

  const handleConfirmGuardSave = async () => {
    setShowActiveGuard(false);
    await executeSave();
  };

  const handleCancelGuard = () => {
    setShowActiveGuard(false);
  };

  const handleSaveMediaConfig = async () => {
    const mediaTimeoutError = validateMediaTimeoutSeconds(
      form.mediaTimeoutSeconds
    );
    if (mediaTimeoutError) {
      setMediaModalError(mediaTimeoutError);
      return;
    }
    setMediaSaveLoading(true);
    setMediaModalError(null);
    try {
      const updated = await updateSettings({
        media: buildMediaPayload(
          form.settings,
          form.mediaTimeoutSeconds,
          form.sonarrEnabled,
          form.sonarrUrl,
          form.sonarrApiKeyEnv,
          form.sonarrDefaultQuality,
          form.sonarrDefaultRoot,
          form.radarrEnabled,
          form.radarrUrl,
          form.radarrApiKeyEnv,
          form.radarrDefaultQuality,
          form.radarrDefaultRoot
        ),
      });
      form.populateForm(updated);
      pushSuccessToast("Media settings saved!");
      if (mediaSaveTimerRef.current !== null) {
        clearTimeout(mediaSaveTimerRef.current);
        mediaSaveTimerRef.current = null;
      }
      mediaSaveTimerRef.current = setTimeout(() => {
        mediaSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setMediaModalError(
        err instanceof ApiError ? err.message : "Failed to save media settings"
      );
    } finally {
      setMediaSaveLoading(false);
    }
  };

  const handleSaveBrowserConfig = async () => {
    const browserTimeoutError = validateBrowserTimeoutSeconds(
      form.browserTimeoutSeconds
    );
    if (browserTimeoutError) {
      setBrowserModalError(browserTimeoutError);
      return;
    }
    const browserFetchTimeoutError = validateBrowserFetchTimeoutSeconds(
      form.browserFetchTimeoutSeconds
    );
    if (browserFetchTimeoutError) {
      setBrowserModalError(browserFetchTimeoutError);
      return;
    }
    setBrowserSaveLoading(true);
    setBrowserModalError(null);
    try {
      const bTimeout = Number(form.browserTimeoutSeconds);
      const fTimeout = Number(form.browserFetchTimeoutSeconds);
      const updated = await updateSettings({
        browserTimeoutSeconds:
          isNaN(bTimeout) || bTimeout <= 0
            ? DEFAULT_BROWSER_TIMEOUT_SECONDS
            : bTimeout,
        browserFetchTimeoutSeconds:
          isNaN(fTimeout) || fTimeout <= 0
            ? DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS
            : fTimeout,
      });
      if (updated.browserTimeoutSeconds !== undefined) {
        form.setBrowserTimeoutSeconds(updated.browserTimeoutSeconds);
      }
      if (updated.browserFetchTimeoutSeconds !== undefined) {
        form.setBrowserFetchTimeoutSeconds(updated.browserFetchTimeoutSeconds);
      }
      pushSuccessToast("Web, browser & API settings saved!");
      if (browserSaveTimerRef.current !== null) {
        clearTimeout(browserSaveTimerRef.current);
        browserSaveTimerRef.current = null;
      }
      browserSaveTimerRef.current = setTimeout(() => {
        browserSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setBrowserModalError(
        err instanceof ApiError ? err.message : "Failed to save browser settings"
      );
    } finally {
      setBrowserSaveLoading(false);
    }
  };

  const handleSaveDesktopConfig = async () => {
    const desktopBoundsError = validateDesktopCaptureBounds(
      form.desktopMaxImageDimension,
      form.desktopJpegQuality
    );
    if (desktopBoundsError) {
      setDesktopModalError(desktopBoundsError);
      return;
    }
    setDesktopSaveLoading(true);
    setDesktopModalError(null);
    try {
      const updated = await updateSettings({
        desktop: buildDesktopPayload(
          form.desktopMaxImageDimension,
          form.desktopJpegQuality,
          form.desktopBlockedAppsText
        ),
      });
      form.populateForm(updated);
      pushSuccessToast("Desktop settings saved!");
      if (desktopSaveTimerRef.current !== null) {
        clearTimeout(desktopSaveTimerRef.current);
        desktopSaveTimerRef.current = null;
      }
      desktopSaveTimerRef.current = setTimeout(() => {
        desktopSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setDesktopModalError(
        err instanceof ApiError ? err.message : "Failed to save desktop settings"
      );
    } finally {
      setDesktopSaveLoading(false);
    }
  };

  const handleSaveFanoutConfig = async () => {
    setFanoutSaveLoading(true);
    setFanoutModalError(null);
    try {
      const updated = await updateSettings({
        fanout: buildFanoutPayload(
          form.fanoutLoadedRef.current,
          form.fanoutMaxWorkers,
          form.fanoutWorkerTimeoutSeconds,
          form.fanoutFullTools
        ),
      });
      form.populateForm(updated);
      pushSuccessToast("Fan-out settings saved!");
      if (fanoutSaveTimerRef.current !== null) {
        clearTimeout(fanoutSaveTimerRef.current);
        fanoutSaveTimerRef.current = null;
      }
      fanoutSaveTimerRef.current = setTimeout(() => {
        fanoutSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setFanoutModalError(
        err instanceof ApiError ? err.message : "Failed to save fan-out settings"
      );
    } finally {
      setFanoutSaveLoading(false);
    }
  };

  return {
    saving,
    error,
    setError,
    showActiveGuard,
    configuringToolName,
    setConfiguringToolName,
    mediaSaveLoading,
    mediaModalError,
    browserSaveLoading,
    browserModalError,
    desktopSaveLoading,
    desktopModalError,
    fanoutSaveLoading,
    fanoutModalError,
    executeSave,
    handleSave,
    handleConfirmGuardSave,
    handleCancelGuard,
    handleSaveMediaConfig,
    handleSaveBrowserConfig,
    handleSaveDesktopConfig,
    handleSaveFanoutConfig,
  };
}
