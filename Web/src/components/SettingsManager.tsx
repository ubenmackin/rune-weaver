// Rune Weaver Dashboard — Settings manager coordinator shell for config.toml configuration.
import { useEffect, useState } from "react";
import { reopenOnboarding } from "../api/onboarding";
import {
  clearWizardSnooze,
  isWizardSnoozed,
  resumeWizard,
  subscribeWizardSnooze,
} from "./onboarding/wizardSnooze";
import { useIsMobile } from "../hooks/useIsMobile";
import { useRunningRuns } from "../hooks/useRunningRuns";
import { useToastStack } from "../hooks/useToastStack";
import { MenuIcon, RefreshIcon } from "./icons";
import { SettingsModals } from "./settings/SettingsModals";
import SettingsSidenav from "./settings/SettingsSidenav";
import { SettingsFormPanels } from "./settings/SettingsFormPanels";
import { isToolsAdvancedError } from "./settings/ToolsTab";
import { isVoiceAdvancedError } from "./settings/VoiceTab";
import { isGoalsAdvancedError } from "./settings/GoalsTab";
import { isWebAdvancedError } from "./settings/WebSearchTab";
import { isEngineAdvancedError } from "./settings/EngineTab";
import {
  browserElapsedSeconds,
  BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT,
  BROWSER_PYTHON_STAGE_COPY,
  BROWSER_PYTHON_VENV_DISPLAY,
  BROWSER_START_CAP_MS,
  BROWSER_START_POLL_INTERVAL_MS,
  browserStageCopy,
  hasAccessSectionLink,
  isBrowserLongStage,
  isSettingsTab,
  resolveBrowserStage,
  resolveBrowserStartedAt,
  SECRET_STATUS_CHUNK_SIZE,
  SERVER_BIND_PRESETS,
  SERVER_BOOT_POLL_INTERVAL_MS,
  type SettingsManagerProps,
  type SettingsTab,
} from "./settings/settingsTypes";
import { getToolCategory } from "./settings/settingsHelpers";
import { ToolConfigModals } from "./settings/ToolConfigModals";
import { useSettingsFormState } from "./settings/useSettingsFormState";
import { useSettingsLifecycle } from "./settings/useSettingsLifecycle";
import { useSettingsSave } from "./settings/useSettingsSave";
import { useSettingsServices } from "./settings/useSettingsServices";
import { ToastStack } from "./Toast";

// Export the public API contract for backwards compatibility with test suites and callers.
export {
  isSettingsTab,
  getToolCategory,
  BROWSER_PYTHON_VENV_DISPLAY,
  BROWSER_START_POLL_INTERVAL_MS,
  BROWSER_START_CAP_MS,
  BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT,
  BROWSER_PYTHON_STAGE_COPY,
  SERVER_BIND_PRESETS,
  SERVER_BOOT_POLL_INTERVAL_MS,
  resolveBrowserStage,
  resolveBrowserStartedAt,
  browserStageCopy,
  isBrowserLongStage,
  browserElapsedSeconds,
  SECRET_STATUS_CHUNK_SIZE,
};
export type { SettingsManagerProps };

// Single owner for the global-banner suppression check: an advanced error
// prints once inside its disclosure, never twice behind the global banner.
export function isSettingsAdvancedError(message: string | null | undefined): boolean {
  return (
    isToolsAdvancedError(message) ||
    isVoiceAdvancedError(message) ||
    isGoalsAdvancedError(message) ||
    isWebAdvancedError(message) ||
    isEngineAdvancedError(message)
  );
}

export type SettingsManagerWithReopenProps = SettingsManagerProps & {
  onReopenOnboarding?: () => Promise<void> | void;
};

export default function SettingsManager({
  onSettingsSaved,
  onReopenOnboarding,
}: SettingsManagerWithReopenProps = {}) {
  const [activeTab, setActiveTab] = useState<SettingsTab>(() => {
    if (typeof window !== "undefined") {
      if (hasAccessSectionLink()) return "access";
      const match = window.location.hash.match(/#settings\/([a-z-]+)/);
      if (match && isSettingsTab(match[1])) return match[1];
    }
    return "providers";
  });

  const {
    toasts,
    pushSuccessToast,
    pushErrorToast,
    dismissToast,
    clearToasts,
  } = useToastStack();
  const { runs: sharedRuns } = useRunningRuns();
  const isMobile = useIsMobile();
  const [wizardSnoozed, setWizardSnoozed] = useState(() => isWizardSnoozed());

  useEffect(() => subscribeWizardSnooze(setWizardSnoozed), []);

  // Form state hook
  const form = useSettingsFormState();

  // Services & lifecycle hook
  const services = useSettingsServices({
    activeTab,
    settings: form.settings,
    providersList: form.providersList,
    emailAccountsList: form.emailAccountsList,
    sonarrApiKeyEnv: form.sonarrApiKeyEnv,
    radarrApiKeyEnv: form.radarrApiKeyEnv,
    pushSuccessToast,
    pushErrorToast,
  });

  // Save logic hook
  const save = useSettingsSave({
    activeTab,
    form,
    sharedRuns,
    onSettingsSaved,
    pushSuccessToast,
  });

  const {
    loading,
    refresh,
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
  } = useSettingsLifecycle({
    activeTab,
    setActiveTab,
    form,
    services,
    save,
    clearToasts,
    isMobile,
  });

  if (loading && !form.settings) {
    return (
      <div className="section-loading">
        <div className="spinner" />
        <p>Loading configuration...</p>
      </div>
    );
  }

  return (
    <section
      className="panel settings-panel"
      aria-label="Settings and configuration"
    >
      <div className="panel-header-row">
        <button
          type="button"
          ref={menuButtonRef}
          className="settings-menu-btn"
          aria-label="Open settings menu"
          aria-expanded={settingsMenuOpen}
          onClick={() => setSettingsMenuOpen((previous) => !previous)}
        >
          <MenuIcon size={20} />
        </button>
        <div>
          <h2>Settings & Configuration</h2>
          <p className="muted text-sm">
            Manage LLM model routing, engine parameters, container policy, web
            search, and email accounts.
          </p>
        </div>

        <div className="row">
          {wizardSnoozed ? (
            <button
              type="button"
              className="ghost icon-text-btn"
              data-testid="resume-setup"
              onClick={() => {
                resumeWizard();
                if (typeof window !== "undefined") {
                  window.location.hash = "dashboard";
                }
              }}
              title="Resume setup wizard"
              aria-label="Resume setup"
            >
              <span>Resume setup</span>
            </button>
          ) : null}
          <button
            type="button"
            className="ghost icon-text-btn"
            data-testid="replay-setup"
            onClick={() => {
              void (async () => {
                try {
                  // Unsnooze first so the gate can mount, then reopen at the persisted step.
                  clearWizardSnooze();
                  // Single App-owned status stays live; direct reopen is fallback.
                  if (onReopenOnboarding) await onReopenOnboarding();
                  else await reopenOnboarding();
                  resumeWizard();
                  if (typeof window !== "undefined") {
                    window.location.hash = "dashboard";
                  }
                } catch (err) {
                  pushErrorToast(err instanceof Error ? err.message : "Failed to reopen setup");
                }
              })();
            }}
            title="Reopen setup wizard"
            aria-label="Replay setup"
          >
            <span>Replay setup</span>
          </button>
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void refresh()}
            disabled={loading || save.saving}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
        </div>
      </div>

      {form.settings && (
        <div className="settings-config-badge">
          <span>Config file:</span>
          <code>{form.settings.configPath}</code>
        </div>
      )}

      {save.error &&
        !(
          (activeTab === "tools" && isToolsAdvancedError(save.error)) ||
          (activeTab === "voice" && isVoiceAdvancedError(save.error)) ||
          (activeTab === "goals" && isGoalsAdvancedError(save.error)) ||
          (activeTab === "search" && isWebAdvancedError(save.error)) ||
          (activeTab === "engine" && isEngineAdvancedError(save.error))
        ) && (
          <div className="error-banner">{save.error}</div>
        )}
      <ToastStack toasts={toasts} onDismiss={dismissToast} />

      <div className="settings-layout">
        <SettingsSidenav
          settingsMenuOpen={settingsMenuOpen}
          activeTab={activeTab}
          settingsNavQuery={settingsNavQuery}
          onSearchChange={setSettingsNavQuery}
          onSelectTab={selectSettingsTab}
          onBackdropClick={handleSettingsBackdropClick}
          pendingCount={pendingCount}
          tamperedCount={tamperedCount}
          serverRestartVisible={serverRestartVisible}
        />

        <div className="settings-content">
          <SettingsFormPanels
            activeTab={activeTab}
            form={form}
            services={services}
            save={save}
            pendingCount={pendingCount}
            tamperedCount={tamperedCount}
            serverAllowedHostsCount={serverAllowedHostsCount}
            serverAllowedHostsError={serverAllowedHostsError}
          />
        </div>
      </div>

      <SettingsModals
        marketplaceOpen={services.marketplaceOpen}
        setMarketplaceOpen={services.setMarketplaceOpen}
        loadPluginsData={services.loadPluginsData}
        pendingPruneWorkspace={services.pendingPruneWorkspace}
        pruningWorkspace={services.pruningWorkspace}
        setPendingPruneWorkspace={services.setPendingPruneWorkspace}
        handleConfirmPruneWorkspace={services.handleConfirmPruneWorkspace}
        pendingUninstallPlugin={services.pendingUninstallPlugin}
        updatingPluginId={services.updatingPluginId}
        cancelUninstallPlugin={services.cancelUninstallPlugin}
        confirmUninstallPlugin={services.confirmUninstallPlugin}
        rotateConfirmStep={services.rotateConfirmStep}
        setRotateConfirmStep={services.setRotateConfirmStep}
        rotating={services.rotating}
        handleConfirmRotate={services.handleConfirmRotate}
        newToken={services.newToken}
        tokenSavedAck={services.tokenSavedAck}
        setTokenSavedAck={services.setTokenSavedAck}
        tokenCopyState={services.tokenCopyState}
        handleCopyNewToken={services.handleCopyNewToken}
        handleDismissNewToken={services.handleDismissNewToken}
        showActiveGuard={save.showActiveGuard}
        saving={save.saving}
        handleCancelGuard={save.handleCancelGuard}
        handleConfirmGuardSave={save.handleConfirmGuardSave}
        secretModal={services.secretModal}
        setSecretModal={services.setSecretModal}
        handleSecretSaved={services.handleSecretSaved}
      />

      <ToolConfigModals
        configuringToolName={save.configuringToolName}
        setConfiguringToolName={save.setConfiguringToolName}
        setActiveTab={setActiveTab}
        browserSaveLoading={save.browserSaveLoading}
        browserModalError={save.browserModalError}
        browserTimeoutSeconds={form.browserTimeoutSeconds}
        setBrowserTimeoutSeconds={form.setBrowserTimeoutSeconds}
        browserFetchTimeoutSeconds={form.browserFetchTimeoutSeconds}
        setBrowserFetchTimeoutSeconds={form.setBrowserFetchTimeoutSeconds}
        handleSaveBrowserConfig={save.handleSaveBrowserConfig}
        mediaSaveLoading={save.mediaSaveLoading}
        mediaModalError={save.mediaModalError}
        sonarrEnabled={form.sonarrEnabled}
        setSonarrEnabled={form.setSonarrEnabled}
        sonarrUrl={form.sonarrUrl}
        setSonarrUrl={form.setSonarrUrl}
        sonarrApiKeyEnv={form.sonarrApiKeyEnv}
        setSonarrApiKeyEnv={form.setSonarrApiKeyEnv}
        sonarrDefaultQuality={form.sonarrDefaultQuality}
        setSonarrDefaultQuality={form.setSonarrDefaultQuality}
        sonarrDefaultRoot={form.sonarrDefaultRoot}
        setSonarrDefaultRoot={form.setSonarrDefaultRoot}
        radarrEnabled={form.radarrEnabled}
        setRadarrEnabled={form.setRadarrEnabled}
        radarrUrl={form.radarrUrl}
        setRadarrUrl={form.setRadarrUrl}
        radarrApiKeyEnv={form.radarrApiKeyEnv}
        setRadarrApiKeyEnv={form.setRadarrApiKeyEnv}
        radarrDefaultQuality={form.radarrDefaultQuality}
        setRadarrDefaultQuality={form.setRadarrDefaultQuality}
        radarrDefaultRoot={form.radarrDefaultRoot}
        setRadarrDefaultRoot={form.setRadarrDefaultRoot}
        mediaTimeoutSeconds={form.mediaTimeoutSeconds}
        setMediaTimeoutSeconds={form.setMediaTimeoutSeconds}
        handleSaveMediaConfig={save.handleSaveMediaConfig}
        secretStatus={services.secretStatus}
        handleOpenStoreSecretModal={services.handleOpenStoreSecretModal}
        desktopSaveLoading={save.desktopSaveLoading}
        desktopModalError={save.desktopModalError}
        desktopMaxImageDimension={form.desktopMaxImageDimension}
        setDesktopMaxImageDimension={form.setDesktopMaxImageDimension}
        desktopJpegQuality={form.desktopJpegQuality}
        setDesktopJpegQuality={form.setDesktopJpegQuality}
        desktopBlockedAppsText={form.desktopBlockedAppsText}
        setDesktopBlockedAppsText={form.setDesktopBlockedAppsText}
        handleSaveDesktopConfig={save.handleSaveDesktopConfig}
        fanoutSaveLoading={save.fanoutSaveLoading}
        fanoutModalError={save.fanoutModalError}
        fanoutMaxWorkers={form.fanoutMaxWorkers}
        setFanoutMaxWorkers={form.setFanoutMaxWorkers}
        fanoutWorkerTimeoutSeconds={form.fanoutWorkerTimeoutSeconds}
        setFanoutWorkerTimeoutSeconds={form.setFanoutWorkerTimeoutSeconds}
        fanoutFullTools={form.fanoutFullTools}
        setFanoutFullTools={form.setFanoutFullTools}
        handleSaveFanoutConfig={save.handleSaveFanoutConfig}
      />
    </section>
  );
}
