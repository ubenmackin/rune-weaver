// Rune Weaver Dashboard — shared hook supplying the Settings manager's tab state and service handlers.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  EmbeddingsStatusResponse,
  PluginSummary,
  SettingsResponse,
  ToolInfo,
  WorkspaceMachineResponse,
  WorkspaceUsageResponse,
} from "../../api";
import {
  ApiError,
  authHeaders,
  checkSecretStatus,
  clearAuthToken,
  ensureEmbeddings,
  ensureSearch,
  getEmbeddingsStatus,
  getPlugins,
  getSearchHealth,
  getTools,
  getWorkspaceMachine,
  getWorkspaceUsage,
  isSessionAuthenticated,
  pruneWorkspaceTmp,
  recycleWorkspaceMachine,
  removeSearch,
  rescanPlugins,
  resolveSearchDiagnostics,
  resolveSearchMessage,
  rotateToken,
  startElapsedSeconds,
  stopSearch,
  stopWorkspaceMachine,
  uninstallPlugin,
  updatePluginState,
  updateToolState,
} from "../../api";
import { useSearchStartProgress } from "../../hooks/useSearchStartProgress";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import { getEmailPasswordEnv, getToolCategory } from "./settingsHelpers";
import {
  BROWSER_PYTHON_VENV_DISPLAY,
  BROWSER_START_CAP_MS,
  BROWSER_START_POLL_INTERVAL_MS,
  isBrowserLongStage,
  resolveBrowserStage,
  resolveBrowserStartedAt,
  SECRET_STATUS_CHUNK_SIZE,
  trimBrowserText,
  type BrowserPythonHealthPayload,
  type EmailEntry,
  type ProviderEntry,
  type SettingsTab,
} from "./settingsTypes";

export interface UseSettingsServicesProps {
  activeTab: SettingsTab;
  settings: SettingsResponse | null;
  providersList: ProviderEntry[];
  emailAccountsList: EmailEntry[];
  sonarrApiKeyEnv: string;
  radarrApiKeyEnv: string;
  pushSuccessToast: (msg: string) => void;
  pushErrorToast: (msg: string) => void;
}

export function useSettingsServices({
  activeTab,
  settings,
  providersList,
  emailAccountsList,
  sonarrApiKeyEnv,
  radarrApiKeyEnv,
  pushSuccessToast,
  pushErrorToast,
}: UseSettingsServicesProps) {
  // Search state
  const [searchReachable, setSearchReachable] = useState<boolean | null>(null);
  const [searchHealthLoading, setSearchHealthLoading] = useState(false);
  const [searchAction, setSearchAction] = useState<"start" | "stop" | "remove" | null>(
    null
  );
  const [pendingRemoveSearch, setPendingRemoveSearch] = useState(false);
  const {
    searchStage,
    searchStartElapsed,
    beginSearchStartProgress,
    endSearchStartProgress,
  } = useSearchStartProgress();
  const [searchHealthError, setSearchHealthError] = useState<string | null>(null);
  const [searchDiagnostics, setSearchDiagnostics] = useState<string | null>(null);

  const searchActionBusy = searchAction !== null;
  const searchRunning = searchReachable === true;
  const searchRemoveEnabled = searchAction === null && !searchRunning;

  // Managed browser Python health
  const [browserReady, setBrowserReady] = useState<boolean | null>(null);
  const [browserPythonPath, setBrowserPythonPath] = useState<string>("");
  const [browserVenvPath, setBrowserVenvPath] = useState<string>(
    BROWSER_PYTHON_VENV_DISPLAY
  );
  const [browserHealthLoading, setBrowserHealthLoading] = useState(false);
  const [browserAction, setBrowserAction] = useState<"ensure" | null>(null);
  const browserActionRef = useRef<"ensure" | null>(null);
  const [browserStage, setBrowserStage] = useState<string | null>(null);
  const [browserElapsed, setBrowserElapsed] = useState(0);
  const browserTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const browserStageRef = useRef<string | null>(null);
  const browserStartMsRef = useRef(0);
  const browserAdvancedRef = useRef<HTMLDetailsElement | null>(null);
  const [browserError, setBrowserError] = useState<string | null>(null);
  const [browserDiagnostics, setBrowserDiagnostics] = useState<string | null>(null);
  const browserActionBusy = browserAction !== null;

  // Local embedding supervisor health
  const [embeddingsStatus, setEmbeddingsStatus] =
    useState<EmbeddingsStatusResponse | null>(null);
  const [embeddingsLoading, setEmbeddingsLoading] = useState(false);
  const [embeddingsActionBusy, setEmbeddingsActionBusy] = useState(false);

  // Workspace usage & machine
  const [workspaceUsage, setWorkspaceUsage] =
    useState<WorkspaceUsageResponse | null>(null);
  const [workspaceLoading, setWorkspaceLoading] = useState(false);
  const [workspaceError, setWorkspaceError] = useState<string | null>(null);
  const [workspaceMachine, setWorkspaceMachine] =
    useState<WorkspaceMachineResponse | null>(null);
  const [workspaceMachineLoading, setWorkspaceMachineLoading] = useState(false);
  const [workspaceMachineError, setWorkspaceMachineError] = useState<string | null>(
    null
  );
  const [workspaceMachineAction, setWorkspaceMachineAction] = useState<
    "stop" | "recycle" | null
  >(null);
  const [pruningWorkspace, setPruningWorkspace] = useState(false);
  const [pendingPruneWorkspace, setPendingPruneWorkspace] = useState(false);

  // Plugins & Tools state
  const [pluginsList, setPluginsList] = useState<PluginSummary[]>([]);
  const [allTools, setAllTools] = useState<ToolInfo[]>([]);
  const [rescanLoading, setRescanLoading] = useState(false);
  const [marketplaceOpen, setMarketplaceOpen] = useState(false);
  const [updatingPluginId, setUpdatingPluginId] = useState<string | null>(null);
  const [pendingUninstallPlugin, setPendingUninstallPlugin] = useState<{
    id: string;
    name: string;
  } | null>(null);
  const [togglingCategory, setTogglingCategory] = useState<string | null>(null);
  const [togglingToolNames, setTogglingToolNames] = useState<Set<string>>(
    () => new Set<string>()
  );
  const [toolSearchQuery, setToolSearchQuery] = useState("");
  const [selectedToolCategory, setSelectedToolCategory] = useState("all");

  // Keychain secrets state
  const [secretStatus, setSecretStatus] = useState<Record<string, boolean>>({});
  const [secretModal, setSecretModal] = useState<{
    isOpen: boolean;
    secretKey: string;
    title: string;
    isUpdate: boolean;
  } | null>(null);

  // Token rotation & auth
  const [rotateConfirmStep, setRotateConfirmStep] = useState<0 | 1 | 2>(0);
  const [rotating, setRotating] = useState(false);
  const [rotateError, setRotateError] = useState<string | null>(null);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [tokenSavedAck, setTokenSavedAck] = useState(false);
  const [tokenCopyState, setTokenCopyState] = useState<"idle" | "copied" | "failed">(
    "idle"
  );

  const hasOwnerSession = isSessionAuthenticated();

  // Load plugins and tools
  const loadPluginsData = useCallback(async () => {
    try {
      const [pluginsRes, toolsRes] = await Promise.all([
        getPlugins(),
        getTools(),
      ]);
      setPluginsList(Array.isArray(pluginsRes?.plugins) ? pluginsRes.plugins : []);
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
    } catch {
      setPluginsList([]);
      setAllTools([]);
    }
  }, []);

  // Search health
  const refreshSearchHealth = useCallback(async () => {
    setSearchHealthLoading(true);
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    try {
      const response = await getSearchHealth();
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchDiagnostics(resolveSearchDiagnostics(response));
      } else {
        setSearchReachable(null);
        setSearchHealthError(
          "Search health returned an unexpected response; status unknown."
        );
      }
    } catch (err) {
      setSearchReachable(null);
      setSearchDiagnostics(null);
      setSearchHealthError(
        err instanceof Error ? err.message : "Search health check failed."
      );
    } finally {
      setSearchHealthLoading(false);
    }
  }, []);

  const handleToggleSearch = async () => {
    if (searchAction !== null) return;
    const wasStarting = !searchReachable;
    setSearchAction(wasStarting ? "start" : "stop");
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    if (wasStarting) {
      beginSearchStartProgress(() => {
        void refreshSearchHealth();
      });
    }
    try {
      const response = wasStarting ? await ensureSearch() : await stopSearch();
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchDiagnostics(resolveSearchDiagnostics(response));
        if (wasStarting && !response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(detail ?? "Search start failed; status unchanged.");
        } else if (!wasStarting && response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(detail ?? "Search stop failed; still reachable.");
        }
      } else if (wasStarting) {
        setSearchHealthError(
          "Search start returned an unexpected response; status unchanged."
        );
      } else {
        setSearchHealthError(
          "Search stop returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setSearchHealthError(
        err instanceof Error
          ? err.message
          : wasStarting
            ? "Failed to start search."
            : "Failed to stop search."
      );
    } finally {
      endSearchStartProgress();
      setSearchAction(null);
    }
  };

  const handleConfirmRemoveSearch = async () => {
    if (searchAction !== null) return;
    setPendingRemoveSearch(false);
    setSearchAction("remove");
    setSearchHealthError(null);
    setSearchDiagnostics(null);
    try {
      const response = await removeSearch();
      if (typeof response?.reachable === "boolean") {
        setSearchReachable(response.reachable);
        setSearchDiagnostics(resolveSearchDiagnostics(response));
        if (response.reachable) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(
            detail ??
              "Search remove failed; still reachable. Stop the container first, then retry remove."
          );
        } else if (response.removed === false) {
          const detail = resolveSearchMessage(response);
          setSearchHealthError(
            detail ?? "Search remove failed; status unchanged."
          );
        }
      } else {
        setSearchHealthError(
          "Search remove returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setSearchHealthError(
        err instanceof Error ? err.message : "Failed to remove search container."
      );
    } finally {
      setSearchAction(null);
    }
  };

  // Browser Python health
  const clearBrowserPoll = useCallback(() => {
    if (browserTimerRef.current !== null) {
      clearInterval(browserTimerRef.current);
      browserTimerRef.current = null;
    }
  }, []);

  const refreshBrowserHealth = useCallback(async () => {
    setBrowserHealthLoading(true);
    try {
      const res = await fetch("/browser/health", {
        headers: authHeaders(),
        credentials: "same-origin",
      });
      if (!res.ok) {
        setBrowserReady(null);
        return;
      }
      const payload = (await res.json()) as BrowserPythonHealthPayload;
      if (typeof payload?.ready === "boolean") {
        setBrowserReady(payload.ready);
        if (typeof payload.pythonPath === "string" && payload.pythonPath.trim()) {
          setBrowserPythonPath(payload.pythonPath.trim());
        }
        if (typeof payload.venvPath === "string" && payload.venvPath.trim()) {
          setBrowserVenvPath(payload.venvPath.trim());
        }
      } else {
        setBrowserReady(null);
      }
    } catch {
      setBrowserReady(null);
    } finally {
      setBrowserHealthLoading(false);
    }
  }, []);

  const beginBrowserProgress = useCallback(() => {
    setBrowserStage(null);
    browserStageRef.current = null;
    setBrowserElapsed(0);
    const clientStartMs = Date.now();
    browserStartMsRef.current = clientStartMs;
    if (browserTimerRef.current !== null) {
      clearInterval(browserTimerRef.current);
      browserTimerRef.current = null;
    }
    browserTimerRef.current = setInterval(() => {
      if (
        Date.now() - clientStartMs > BROWSER_START_CAP_MS &&
        !isBrowserLongStage(browserStageRef.current)
      ) {
        if (browserTimerRef.current !== null) {
          clearInterval(browserTimerRef.current);
          browserTimerRef.current = null;
        }
        browserStageRef.current = null;
        setBrowserStage(null);
        void refreshBrowserHealth();
        return;
      }
      fetch("/browser/health", {
        headers: authHeaders(),
        credentials: "same-origin",
      })
        .then((res) => (res.ok ? res.json() : null))
        .then((payload) => {
          if (!payload || typeof payload !== "object") return;
          const typed = payload as BrowserPythonHealthPayload;
          const stage = resolveBrowserStage(typed);
          browserStageRef.current = stage;
          setBrowserStage(stage);
          setBrowserElapsed(
            startElapsedSeconds(
              resolveBrowserStartedAt(typed),
              browserStartMsRef.current
            )
          );
        })
        .catch(() => {});
    }, BROWSER_START_POLL_INTERVAL_MS);
  }, [refreshBrowserHealth]);

  const endBrowserProgress = useCallback(() => {
    clearBrowserPoll();
    browserStageRef.current = null;
    setBrowserStage(null);
  }, [clearBrowserPoll]);

  const handleEnsureBrowser = async () => {
    if (browserActionRef.current !== null) return;
    browserActionRef.current = "ensure";
    setBrowserAction("ensure");
    setBrowserError(null);
    setBrowserDiagnostics(null);
    beginBrowserProgress();
    try {
      const res = await fetch("/browser/ensure", {
        method: "POST",
        headers: authHeaders({ "Content-Type": "application/json" }),
        credentials: "same-origin",
        body: JSON.stringify({}),
      });
      if (!res.ok) {
        let detail = `Request failed: /browser/ensure (${res.status})`;
        try {
          const text = await res.text();
          if (text) {
            try {
              const parsed: unknown = JSON.parse(text);
              const record =
                typeof parsed === "object" && parsed !== null
                  ? (parsed as Record<string, unknown>)
                  : null;
              const reason =
                record != null
                  ? (record.reason ?? record.message ?? record.error)
                  : undefined;
              detail =
                typeof reason === "string" && reason.trim()
                  ? reason.trim().slice(0, 500)
                  : text.slice(0, 500);
            } catch {
              detail = text.slice(0, 500);
            }
          }
        } catch {}
        setBrowserReady(null);
        setBrowserError(detail);
        return;
      }
      const payload = (await res.json()) as BrowserPythonHealthPayload;
      if (typeof payload?.ready === "boolean") {
        setBrowserReady(payload.ready);
        if (typeof payload.pythonPath === "string" && payload.pythonPath.trim()) {
          setBrowserPythonPath(payload.pythonPath.trim());
        }
        if (typeof payload.venvPath === "string" && payload.venvPath.trim()) {
          setBrowserVenvPath(payload.venvPath.trim());
        }
        setBrowserDiagnostics(trimBrowserText(payload.diagnostics));
        if (!payload.ready) {
          const detail = trimBrowserText(payload.message);
          setBrowserError(
            detail ?? "Browser Python is not ready; status unchanged."
          );
        }
      } else {
        setBrowserError(
          "Browser ensure returned an unexpected response; status unchanged."
        );
      }
    } catch (err) {
      setBrowserError(
        err instanceof Error ? err.message : "Failed to ensure browser Python."
      );
    } finally {
      endBrowserProgress();
      browserActionRef.current = null;
      setBrowserAction(null);
    }
  };

  // Embeddings health
  const refreshEmbeddingsStatus = useCallback(async () => {
    setEmbeddingsLoading(true);
    try {
      const res = await getEmbeddingsStatus();
      setEmbeddingsStatus(res);
    } catch {
    } finally {
      setEmbeddingsLoading(false);
    }
  }, []);

  const handleEnsureEmbeddings = useCallback(async () => {
    setEmbeddingsActionBusy(true);
    try {
      const res = await ensureEmbeddings();
      setEmbeddingsStatus(res);
      pushSuccessToast("Initializing local embedding engine…");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      pushErrorToast(`Failed to initialize embedding engine: ${message}`);
    } finally {
      setEmbeddingsActionBusy(false);
    }
  }, [pushSuccessToast, pushErrorToast]);

  const handleEmbeddingsWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      if (frame.type === "embeddings_status" && activeTab === "memory") {
        void refreshEmbeddingsStatus();
      }
    },
    [activeTab, refreshEmbeddingsStatus]
  );
  useSharedWebSocket(handleEmbeddingsWSFrame);

  // Workspace usage & machine
  const refreshWorkspaceUsage = useCallback(async () => {
    setWorkspaceLoading(true);
    setWorkspaceError(null);
    try {
      const usage = await getWorkspaceUsage();
      if (
        typeof usage?.bytes !== "number" ||
        typeof usage?.files !== "number" ||
        typeof usage?.quotaMB !== "number" ||
        typeof usage?.quotaFiles !== "number"
      ) {
        setWorkspaceUsage(null);
        setWorkspaceError(
          "Workspace usage returned an unexpected response; quotas unknown."
        );
        return;
      }
      setWorkspaceUsage(usage);
    } catch (err) {
      setWorkspaceUsage(null);
      setWorkspaceError(
        err instanceof Error ? err.message : "Failed to load workspace usage."
      );
    } finally {
      setWorkspaceLoading(false);
    }
  }, []);

  const refreshWorkspaceMachine = useCallback(async () => {
    setWorkspaceMachineLoading(true);
    setWorkspaceMachineError(null);
    try {
      const state = await getWorkspaceMachine();
      if (
        typeof state?.exists !== "boolean" ||
        typeof state?.running !== "boolean" ||
        typeof state?.image !== "string"
      ) {
        setWorkspaceMachine(null);
        setWorkspaceMachineError(
          "Workspace machine returned an unexpected response; status unknown."
        );
        return;
      }
      setWorkspaceMachine(state);
    } catch (err) {
      setWorkspaceMachine(null);
      setWorkspaceMachineError(
        err instanceof Error
          ? err.message
          : "Failed to load workspace machine state."
      );
    } finally {
      setWorkspaceMachineLoading(false);
    }
  }, []);

  const handleStopWorkspaceMachine = async () => {
    if (workspaceMachineAction !== null) return;
    setWorkspaceMachineAction("stop");
    try {
      const res = await stopWorkspaceMachine();
      setWorkspaceMachine(res);
      pushSuccessToast("Workspace container stopped.");
    } catch (err) {
      pushErrorToast(
        err instanceof Error ? err.message : "Failed to stop workspace machine."
      );
    } finally {
      setWorkspaceMachineAction(null);
    }
  };

  const handleRecycleWorkspaceMachine = async () => {
    if (workspaceMachineAction !== null) return;
    setWorkspaceMachineAction("recycle");
    try {
      const res = await recycleWorkspaceMachine();
      setWorkspaceMachine(res);
      pushSuccessToast("Workspace container recycled.");
    } catch (err) {
      pushErrorToast(
        err instanceof Error
          ? err.message
          : "Failed to recycle workspace machine."
      );
    } finally {
      setWorkspaceMachineAction(null);
    }
  };

  const handleConfirmPruneWorkspace = async () => {
    if (pruningWorkspace) return;
    setPendingPruneWorkspace(false);
    setPruningWorkspace(true);
    try {
      const receipt = await pruneWorkspaceTmp();
      const removed = typeof receipt?.removed === "number" ? receipt.removed : 0;
      pushSuccessToast(
        removed === 1 ? "Pruned 1 tmp entry." : `Pruned ${removed} tmp entries.`
      );
      await refreshWorkspaceUsage();
    } catch (err) {
      pushErrorToast(
        err instanceof Error ? err.message : "Failed to prune workspace tmp."
      );
    } finally {
      setPruningWorkspace(false);
    }
  };

  // Plugins & Tools operations
  const handleRescanPlugins = async () => {
    setRescanLoading(true);
    try {
      const res = await rescanPlugins();
      setPluginsList(Array.isArray(res?.plugins) ? res.plugins : []);
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      pushSuccessToast(`Discovered ${res.plugins?.length ?? 0} external runes.`);
    } catch (err) {
      pushErrorToast(
        err instanceof Error ? err.message : "Failed to rescan plugins."
      );
    } finally {
      setRescanLoading(false);
    }
  };

  const handleToggleEnable = async (plugin: PluginSummary) => {
    const nextEnabled = !plugin.isEnabled;
    setUpdatingPluginId(plugin.id);
    try {
      await updatePluginState(plugin.id, {
        action: nextEnabled ? "enable" : "disable",
      });
      await loadPluginsData();
      pushSuccessToast(
        nextEnabled
          ? `Enabled rune '${plugin.name}'.`
          : `Disabled rune '${plugin.name}'.`
      );
    } catch (err) {
      pushErrorToast(
        err instanceof Error ? err.message : "Failed to update rune state."
      );
    } finally {
      setUpdatingPluginId(null);
    }
  };

  const handlePermissionChange = async (
    pluginId: string,
    toolName: string,
    level: string
  ) => {
    try {
      await updatePluginState(pluginId, {
        action:
          level === "default" ? "clear_override" : "override_permission",
        toolName,
        permissionLevel:
          level === "default"
            ? undefined
            : (level as "readOnly" | "requiresApproval"),
      });
      await loadPluginsData();
      pushSuccessToast(`Updated permission for '${toolName}'.`);
    } catch (err) {
      pushErrorToast(
        err instanceof Error
          ? err.message
          : "Failed to update permission override."
      );
    }
  };

  const confirmUninstallPlugin = async () => {
    if (!pendingUninstallPlugin) return;
    const { id, name } = pendingUninstallPlugin;
    setUpdatingPluginId(id);
    try {
      await uninstallPlugin(id);
      await loadPluginsData();
      pushSuccessToast(`Uninstalled rune '${name}'.`);
      setPendingUninstallPlugin(null);
    } catch (err) {
      pushErrorToast(
        err instanceof Error ? err.message : "Failed to uninstall rune."
      );
    } finally {
      setUpdatingPluginId(null);
    }
  };

  const cancelUninstallPlugin = () => {
    setPendingUninstallPlugin(null);
  };

  const handleToggleTool = async (tool: ToolInfo) => {
    const nextEnabled = !tool.isEnabled;
    setTogglingToolNames((prev) => new Set(prev).add(tool.name));
    try {
      await updateToolState(tool.name, nextEnabled);
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      // External cards read pluginsList while built-ins read safeTools;
      // refetch plugins for plugin tools so externals update live.
      if (tool.pluginID || !tool.isBuiltIn) {
        const pluginsRes = await getPlugins();
        setPluginsList(Array.isArray(pluginsRes?.plugins) ? pluginsRes.plugins : []);
      }
      pushSuccessToast(
        nextEnabled
          ? `Enabled tool '${tool.name}'.`
          : `Disabled tool '${tool.name}'.`
      );
    } catch (err) {
      pushErrorToast(
        err instanceof Error
          ? err.message
          : `Failed to update tool '${tool.name}'.`
      );
    } finally {
      setTogglingToolNames((prev) => {
        const next = new Set(prev);
        next.delete(tool.name);
        return next;
      });
    }
  };

  const handleToggleCategory = async (categoryId: string, enable: boolean) => {
    const categoryTools = (Array.isArray(allTools) ? allTools : []).filter(
      (t) => t.isBuiltIn && getToolCategory(t) === categoryId
    );
    const targets = categoryTools.filter((t) => t.isEnabled !== enable);
    if (targets.length === 0) return;
    setTogglingCategory(categoryId);
    try {
      for (const tool of targets) {
        await updateToolState(tool.name, enable);
      }
      const toolsRes = await getTools();
      setAllTools(Array.isArray(toolsRes?.tools) ? toolsRes.tools : []);
      pushSuccessToast(
        `${enable ? "Enabled" : "Disabled"} all tools in '${categoryId}'.`
      );
    } catch (err) {
      pushErrorToast(
        err instanceof Error ? err.message : `Failed to update ${categoryId} tools.`
      );
    } finally {
      setTogglingCategory(null);
    }
  };

  // Secret status & modals
  const handleOpenStoreSecretModal = (
    secretKey: string,
    label: string,
    isUpdate: boolean
  ) => {
    setSecretModal({
      isOpen: true,
      secretKey,
      title: isUpdate
        ? `Update ${label} in Keychain`
        : `Store ${label} to Keychain`,
      isUpdate,
    });
  };

  const handleSecretSaved = (key: string) => {
    setSecretStatus((prev) => ({ ...prev, [key]: true }));
    pushSuccessToast(`Stored secret for ${key} into macOS Keychain.`);
  };

  const relevantSecretKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const item of emailAccountsList) {
      const name = item.account.name?.trim();
      if (name) {
        keys.add(getEmailPasswordEnv(name));
      }
    }
    for (const item of providersList) {
      const keyEnv = (item.config.apiKeyEnv || "").trim();
      if (keyEnv) {
        keys.add(keyEnv);
      }
    }
    const sonarrEnv = sonarrApiKeyEnv.trim();
    if (sonarrEnv) {
      keys.add(sonarrEnv);
    }
    const radarrEnv = radarrApiKeyEnv.trim();
    if (radarrEnv) {
      keys.add(radarrEnv);
    }
    const storedSonarrEnv = (
      settings?.media?.sonarr?.apiKeyEnv || ""
    ).trim();
    if (storedSonarrEnv) {
      keys.add(storedSonarrEnv);
    }
    const storedRadarrEnv = (
      settings?.media?.radarr?.apiKeyEnv || ""
    ).trim();
    if (storedRadarrEnv) {
      keys.add(storedRadarrEnv);
    }
    return Array.from(keys);
  }, [
    emailAccountsList,
    providersList,
    sonarrApiKeyEnv,
    radarrApiKeyEnv,
    settings,
  ]);

  const refreshSecretStatus = useCallback(
    async (keysToQuery?: string[]) => {
      const keys = keysToQuery ?? relevantSecretKeys;
      if (keys.length === 0) return;
      try {
        const merged: Record<string, boolean> = {};
        for (let i = 0; i < keys.length; i += SECRET_STATUS_CHUNK_SIZE) {
          const chunk = keys.slice(i, i + SECRET_STATUS_CHUNK_SIZE);
          const res = await checkSecretStatus(chunk);
          if (res) {
            Object.assign(merged, res);
          }
        }
        setSecretStatus((prev) => ({ ...prev, ...merged }));
      } catch {}
    },
    [relevantSecretKeys]
  );

  useEffect(() => {
    if (relevantSecretKeys.length > 0) {
      void refreshSecretStatus();
    }
  }, [relevantSecretKeys, refreshSecretStatus]);

  // Token rotation
  const handleConfirmRotate = async () => {
    if (rotating) return;
    setRotateConfirmStep(0);
    setRotating(true);
    setRotateError(null);
    setTokenCopyState("idle");
    try {
      const token = await rotateToken();
      setNewToken(token);
      setTokenSavedAck(false);
    } catch (err) {
      setRotateError(
        err instanceof ApiError ? err.message : "Failed to rotate access token."
      );
    } finally {
      setRotating(false);
    }
  };

  const handleCopyNewToken = async () => {
    if (!newToken) return;
    try {
      await navigator.clipboard.writeText(newToken);
      setTokenCopyState("copied");
    } catch {
      setTokenCopyState("failed");
    }
  };

  const handleDismissNewToken = () => {
    setNewToken(null);
    setTokenSavedAck(false);
    setTokenCopyState("idle");
  };

  const handleLogout = () => {
    clearAuthToken();
  };

  return {
    searchReachable,
    searchHealthLoading,
    searchAction,
    searchActionBusy,
    searchRunning,
    searchRemoveEnabled,
    searchStage,
    pendingRemoveSearch,
    setPendingRemoveSearch,
    searchStartElapsed,
    searchHealthError,
    searchDiagnostics,
    refreshSearchHealth,
    handleToggleSearch,
    handleConfirmRemoveSearch,
    browserReady,
    browserPythonPath,
    browserVenvPath,
    browserHealthLoading,
    browserAction,
    browserActionBusy,
    browserStage,
    browserElapsed,
    browserError,
    browserDiagnostics,
    browserAdvancedRef,
    refreshBrowserHealth,
    handleEnsureBrowser,
    embeddingsStatus,
    embeddingsLoading,
    embeddingsActionBusy,
    refreshEmbeddingsStatus,
    handleEnsureEmbeddings,
    workspaceUsage,
    workspaceLoading,
    workspaceError,
    workspaceMachine,
    workspaceMachineLoading,
    workspaceMachineError,
    workspaceMachineAction,
    pruningWorkspace,
    pendingPruneWorkspace,
    setPendingPruneWorkspace,
    refreshWorkspaceUsage,
    refreshWorkspaceMachine,
    handleStopWorkspaceMachine,
    handleRecycleWorkspaceMachine,
    handleConfirmPruneWorkspace,
    pluginsList,
    allTools,
    rescanLoading,
    marketplaceOpen,
    setMarketplaceOpen,
    updatingPluginId,
    pendingUninstallPlugin,
    setPendingUninstallPlugin,
    togglingCategory,
    togglingToolNames,
    loadPluginsData,
    handleRescanPlugins,
    handleToggleEnable,
    confirmUninstallPlugin,
    cancelUninstallPlugin,
    toolSearchQuery,
    setToolSearchQuery,
    selectedToolCategory,
    setSelectedToolCategory,
    handlePermissionChange,
    handleToggleTool,
    handleToggleCategory,
    secretStatus,
    secretModal,
    setSecretModal,
    handleOpenStoreSecretModal,
    handleSecretSaved,
    refreshSecretStatus,
    relevantSecretKeys,
    rotateConfirmStep,
    setRotateConfirmStep,
    rotating,
    rotateError,
    setRotateError,
    newToken,
    tokenSavedAck,
    setTokenSavedAck,
    tokenCopyState,
    handleConfirmRotate,
    handleCopyNewToken,
    handleDismissNewToken,
    handleLogout,
    hasOwnerSession,
  };
}
