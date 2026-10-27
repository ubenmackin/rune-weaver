// Rune Weaver Dashboard — Settings lifecycle, tab navigation, convergence checks, and network sync.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  authHeaders,
  canonicalRestartHost,
  DEFAULT_SERVER_HOSTNAME,
  DEFAULT_SERVER_PORT,
  getSettings,
  parseServerAllowedHostsText,
  validateServerAllowedHosts,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import { isSettingsFormDirty } from "./useSettingsDirty";
import { areServerAllowedHostsEqual } from "./settingsHelpers";
import {
  hasAccessSectionLink,
  isSettingsTab,
  SERVER_BOOT_POLL_INTERVAL_MS,
  type SettingsTab,
} from "./settingsTypes";
import type { useSettingsFormState } from "./useSettingsFormState";
import type { useSettingsSave } from "./useSettingsSave";
import type { useSettingsServices } from "./useSettingsServices";

export interface UseSettingsLifecycleProps {
  activeTab: SettingsTab;
  setActiveTab: (tab: SettingsTab) => void;
  form: ReturnType<typeof useSettingsFormState>;
  services: ReturnType<typeof useSettingsServices>;
  save: ReturnType<typeof useSettingsSave>;
  clearToasts: () => void;
  isMobile: boolean;
}

export function useSettingsLifecycle({
  activeTab,
  setActiveTab,
  form,
  services,
  save,
  clearToasts,
  isMobile,
}: UseSettingsLifecycleProps) {
  const formRef = useRef(form);
  formRef.current = form;
  const servicesRef = useRef(services);
  servicesRef.current = services;
  const saveRef = useRef(save);
  saveRef.current = save;

  const [loading, setLoading] = useState(false);
  const [settingsMenuOpen, setSettingsMenuOpen] = useState(false);
  const [settingsNavQuery, setSettingsNavQuery] = useState("");
  const [settingsStale, setSettingsStale] = useState(false);
  const menuButtonRef = useRef<HTMLButtonElement | null>(null);

  // Hash-based tab sync
  useEffect(() => {
    function syncTabFromHash() {
      if (typeof window === "undefined") return;
      if (hasAccessSectionLink()) {
        setActiveTab("access");
      } else {
        const match = window.location.hash.match(/#settings\/([a-z-]+)/);
        if (match && isSettingsTab(match[1])) {
          setActiveTab(match[1]);
        }
      }
    }
    window.addEventListener("hashchange", syncTabFromHash);
    return () => window.removeEventListener("hashchange", syncTabFromHash);
  }, [setActiveTab]);

  const returnFocusToMenuButton = useCallback(() => {
    menuButtonRef.current?.focus();
  }, []);

  const closeSettingsMenu = useCallback(() => {
    setSettingsMenuOpen(false);
  }, []);

  const handleSettingsBackdropClick = useCallback(() => {
    closeSettingsMenu();
    returnFocusToMenuButton();
  }, [closeSettingsMenu, returnFocusToMenuButton]);

  const selectSettingsTab = useCallback(
    (tab: SettingsTab) => {
      if (!isSettingsTab(tab)) return;
      clearToasts();
      setActiveTab(tab);
      if (isMobile && settingsMenuOpen) {
        closeSettingsMenu();
        returnFocusToMenuButton();
      }
    },
    [clearToasts, isMobile, settingsMenuOpen, closeSettingsMenu, returnFocusToMenuButton, setActiveTab]
  );

  useEffect(() => {
    if (!settingsMenuOpen) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      closeSettingsMenu();
      returnFocusToMenuButton();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [settingsMenuOpen, closeSettingsMenu, returnFocusToMenuButton]);

  useEffect(() => {
    clearToasts();
  }, [activeTab, clearToasts]);

  // Reconciles the boot snapshot from /health when the engine advertises its live bind
  const refreshBootBind = useCallback(async () => {
    try {
      const res = await fetch("/health", {
        headers: authHeaders(),
        credentials: "same-origin",
      });
      if (!res.ok) return;
      const payload = (await res.json()) as {
        serverHostname?: unknown;
        serverPort?: unknown;
        serverAllowedHosts?: unknown;
      };
      const bootHostname =
        typeof payload.serverHostname === "string" && payload.serverHostname.trim()
          ? payload.serverHostname
          : null;
      const bootPort =
        typeof payload.serverPort === "number" && Number.isInteger(payload.serverPort)
          ? (payload.serverPort as number)
          : null;
      const bootHosts = Array.isArray(payload.serverAllowedHosts)
        ? (payload.serverAllowedHosts as unknown[]).filter(
            (h): h is string => typeof h === "string"
          )
        : null;
      if (bootHostname !== null && bootPort !== null && bootHosts !== null) {
        formRef.current.setLiveServerBind({
          hostname: bootHostname,
          port: bootPort,
          allowedHosts: [...bootHosts],
        });
      }
    } catch {}
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    saveRef.current.setError(null);
    try {
      const data = await getSettings();
      formRef.current.populateForm(data);
      void refreshBootBind();
      void servicesRef.current.loadPluginsData();
      setSettingsStale(false);
    } catch (failure) {
      saveRef.current.setError(
        failure instanceof ApiError ? failure.message : "Failed to load settings"
      );
    } finally {
      setLoading(false);
    }
  }, [refreshBootBind]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const clearSettingsStale = useCallback(() => {
    setSettingsStale(false);
  }, []);

  // Dirty drafts are never clobbered: the frame marks stale when dirty,
  // while foreground and reconnect refetch only when clean.
  const handleSettingsChangedFrame = useCallback(
    (frame: WSIncomingFrame) => {
      if ((frame as { type?: string }).type !== "settings_changed") return;
      if (isSettingsFormDirty(formRef.current)) {
        setSettingsStale(true);
        return;
      }
      setSettingsStale(false);
      void refresh();
    },
    [refresh]
  );

  const handleReconnectRefresh = useCallback(() => {
    if (isSettingsFormDirty(formRef.current)) return;
    void refresh();
  }, [refresh]);

  useSharedWebSocket(
    handleSettingsChangedFrame,
    undefined,
    handleReconnectRefresh
  );

  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      handleReconnectRefresh();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [handleReconnectRefresh]);

  // A completed save reconciles drafts with stored settings, so a pending stale flag lapses.
  const prevSavingRef = useRef(save.saving);
  useEffect(() => {
    if (prevSavingRef.current && !save.saving && !save.error) {
      setSettingsStale(false);
    }
    prevSavingRef.current = save.saving;
  }, [save.saving, save.error]);

  // Tab lifecycle effects
  useEffect(() => {
    if (activeTab === "search") {
      void servicesRef.current.refreshSearchHealth();
      void servicesRef.current.refreshBrowserHealth();
    } else if (activeTab === "memory") {
      void servicesRef.current.refreshEmbeddingsStatus();
    } else if (activeTab === "network") {
      void refreshBootBind();
    } else if (activeTab === "tools") {
      void servicesRef.current.refreshWorkspaceUsage();
      void servicesRef.current.refreshWorkspaceMachine();
    }
  }, [activeTab, refreshBootBind]);

  // Convergence check for restart banner
  useEffect(() => {
    const { serverRestartRequired, settings, liveServerBind, setServerRestartRequired } =
      formRef.current;
    if (!serverRestartRequired || !settings || !liveServerBind) return;
    const fileHostname =
      typeof settings.serverHostname === "string" &&
      settings.serverHostname.trim()
        ? settings.serverHostname
        : DEFAULT_SERVER_HOSTNAME;
    const filePort =
      typeof settings.serverPort === "number" &&
      Number.isInteger(settings.serverPort)
        ? settings.serverPort
        : DEFAULT_SERVER_PORT;
    const fileHosts = Array.isArray(settings.serverAllowedHosts)
      ? (settings.serverAllowedHosts as string[])
      : [];
    const converged =
      canonicalRestartHost(fileHostname) ===
        canonicalRestartHost(liveServerBind.hostname) &&
      filePort === liveServerBind.port &&
      areServerAllowedHostsEqual(fileHosts, liveServerBind.allowedHosts);
    if (converged) {
      setServerRestartRequired(false);
    }
  }, [
    form.serverRestartRequired,
    form.settings,
    form.liveServerBind,
  ]);

  // Network poll during restart required
  useEffect(() => {
    if (activeTab !== "network") return;
    const { settings, liveServerBind, serverRestartRequired } = formRef.current;
    const fileHostname =
      typeof settings?.serverHostname === "string" &&
      settings.serverHostname.trim()
        ? settings.serverHostname
        : DEFAULT_SERVER_HOSTNAME;
    const filePort =
      typeof settings?.serverPort === "number" &&
      Number.isInteger(settings.serverPort)
        ? settings.serverPort
        : DEFAULT_SERVER_PORT;
    const fileHosts = Array.isArray(settings?.serverAllowedHosts)
      ? (settings.serverAllowedHosts as string[])
      : [];
    const bootHostname = liveServerBind?.hostname ?? fileHostname;
    const bootPort = liveServerBind?.port ?? filePort;
    const bootHosts = liveServerBind?.allowedHosts ?? fileHosts;
    const fileDiffersFromBoot =
      canonicalRestartHost(fileHostname) !==
        canonicalRestartHost(bootHostname) ||
      filePort !== bootPort ||
      !areServerAllowedHostsEqual(fileHosts, bootHosts);
    if (!serverRestartRequired && !fileDiffersFromBoot) return;
    const timer = setInterval(() => {
      void refreshBootBind();
    }, SERVER_BOOT_POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [
    activeTab,
    form.serverRestartRequired,
    form.settings,
    form.liveServerBind,
    refreshBootBind,
  ]);

  // Force Advanced open on browser provision error
  useEffect(() => {
    if (services.browserError && services.browserAdvancedRef.current) {
      services.browserAdvancedRef.current.open = true;
    }
  }, [services.browserError, services.browserAdvancedRef]);

  // Computed allowed hosts validation & count
  const serverAllowedHostsCount = parseServerAllowedHostsText(
    form.serverAllowedHostsText
  ).length;
  const serverAllowedHostsError = validateServerAllowedHosts(
    parseServerAllowedHostsText(form.serverAllowedHostsText)
  );

  // File vs boot badge calculation
  const serverFileHostnameForBadge =
    typeof form.settings?.serverHostname === "string" &&
    form.settings.serverHostname.trim()
      ? form.settings.serverHostname
      : DEFAULT_SERVER_HOSTNAME;
  const serverFilePortForBadge =
    typeof form.settings?.serverPort === "number" &&
    Number.isInteger(form.settings.serverPort)
      ? form.settings.serverPort
      : DEFAULT_SERVER_PORT;
  const serverFileHostsForBadge = Array.isArray(form.settings?.serverAllowedHosts)
    ? (form.settings.serverAllowedHosts as string[])
    : [];
  const serverBootHostnameForBadge =
    form.liveServerBind?.hostname ?? serverFileHostnameForBadge;
  const serverBootPortForBadge =
    form.liveServerBind?.port ?? serverFilePortForBadge;
  const serverBootHostsForBadge =
    form.liveServerBind?.allowedHosts ?? serverFileHostsForBadge;
  const serverFileDiffersFromBootForBadge =
    canonicalRestartHost(serverFileHostnameForBadge) !==
      canonicalRestartHost(serverBootHostnameForBadge) ||
    serverFilePortForBadge !== serverBootPortForBadge ||
    !areServerAllowedHostsEqual(
      serverFileHostsForBadge,
      serverBootHostsForBadge
    );
  const serverRestartVisible =
    form.serverRestartRequired || serverFileDiffersFromBootForBadge;

  const safePlugins = Array.isArray(services.pluginsList)
    ? services.pluginsList
    : [];
  const pendingCount = safePlugins.filter(
    (p) => p?.status === "discovered"
  ).length;
  const tamperedCount = safePlugins.filter(
    (p) => p?.status === "tampered"
  ).length;

  return {
    loading,
    refresh,
    settingsStale,
    clearSettingsStale,
    settingsMenuOpen,
    setSettingsMenuOpen,
    settingsNavQuery,
    setSettingsNavQuery,
    menuButtonRef,
    handleSettingsBackdropClick,
    selectSettingsTab,
    serverAllowedHostsCount,
    serverAllowedHostsError,
    serverRestartVisible,
    pendingCount,
    tamperedCount,
  };
}
