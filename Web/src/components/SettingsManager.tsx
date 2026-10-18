// Rune Weaver Dashboard — Settings manager coordinator shell for config.toml configuration.

import { useState } from "react";
import { useIsMobile } from "../hooks/useIsMobile";
import { useRunningRuns } from "../hooks/useRunningRuns";
import { useToastStack } from "../hooks/useToastStack";
import AccessPane from "./AccessPane";
import { MenuIcon, RefreshIcon } from "./icons";
import { IndexPolicyPanel } from "./IndexingPanel";
import { EmailTab } from "./settings/EmailTab";
import { EngineTab } from "./settings/EngineTab";
import { GoalsTab } from "./settings/GoalsTab";
import { MemoryTab } from "./settings/MemoryTab";
import { NetworkTab } from "./settings/NetworkTab";
import { PersonaTab } from "./settings/PersonaTab";
import { ProvidersTab } from "./settings/ProvidersTab";
import { SecurityTab } from "./settings/SecurityTab";
import { getToolCategory } from "./settings/settingsHelpers";
import { SettingsModals } from "./settings/SettingsModals";
import SettingsSidenav from "./settings/SettingsSidenav";
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
import { ToolConfigModals } from "./settings/ToolConfigModals";
import { ToolsTab } from "./settings/ToolsTab";
import { useSettingsFormState } from "./settings/useSettingsFormState";
import { useSettingsLifecycle } from "./settings/useSettingsLifecycle";
import { useSettingsSave } from "./settings/useSettingsSave";
import { useSettingsServices } from "./settings/useSettingsServices";
import { VoiceTab } from "./settings/VoiceTab";
import { WebSearchTab } from "./settings/WebSearchTab";
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

export default function SettingsManager({
  onSettingsSaved,
}: SettingsManagerProps = {}) {
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

      {save.error && <div className="error-banner">{save.error}</div>}
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
          {activeTab === "access" ? <AccessPane /> : null}
          {activeTab === "indexing" ? <IndexPolicyPanel /> : null}
          {activeTab !== "access" && activeTab !== "indexing" ? (
            <form onSubmit={save.handleSave} className="settings-form">
              {activeTab === "providers" && (
                <ProvidersTab
                  providersList={form.providersList}
                  defaultProvider={form.defaultProvider}
                  setDefaultProvider={form.setDefaultProvider}
                  fallbackProvider={form.fallbackProvider}
                  setFallbackProvider={form.setFallbackProvider}
                  providerNames={form.providersList.map((p) => p.name)}
                  handleAddProvider={form.handleAddProvider}
                  handleRemoveProvider={form.handleRemoveProvider}
                  handleProviderNameChange={form.handleProviderNameChange}
                  handleProviderFieldChange={(id, field, val) =>
                    form.handleProviderFieldChange(
                      id,
                      field,
                      val as string | boolean | number | undefined,
                      save.setError
                    )
                  }
                  secretStatus={services.secretStatus}
                  onOpenStoreSecretModal={services.handleOpenStoreSecretModal}
                  setError={save.setError}
                />
              )}
              {activeTab === "persona" && (
                <PersonaTab
                  personaAssistantNameDraft={form.personaAssistantNameDraft}
                  setPersonaAssistantNameDraft={form.setPersonaAssistantNameDraft}
                  personaToneDraft={form.personaToneDraft}
                  setPersonaToneDraft={form.setPersonaToneDraft}
                  personaStyleDraft={form.personaStyleDraft}
                  setPersonaStyleDraft={form.setPersonaStyleDraft}
                  personaUserNameDraft={form.personaUserNameDraft}
                  setPersonaUserNameDraft={form.setPersonaUserNameDraft}
                  personaAvatarDraft={form.personaAvatarDraft}
                  setPersonaAvatarDraft={form.setPersonaAvatarDraft}
                />
              )}
              {activeTab === "goals" && (
                <GoalsTab
                  goalsEnabled={form.goalsEnabled}
                  setGoalsEnabled={form.setGoalsEnabled}
                  goalsStepIntervalMinutes={form.goalsStepIntervalMinutes}
                  setGoalsStepIntervalMinutes={form.setGoalsStepIntervalMinutes}
                  goalsMaxActiveGoals={form.goalsMaxActiveGoals}
                  setGoalsMaxActiveGoals={form.setGoalsMaxActiveGoals}
                  goalsMaxStepsPerGoal={form.goalsMaxStepsPerGoal}
                  setGoalsMaxStepsPerGoal={form.setGoalsMaxStepsPerGoal}
                  goalsPlanTimeoutSeconds={form.goalsPlanTimeoutSeconds}
                  setGoalsPlanTimeoutSeconds={form.setGoalsPlanTimeoutSeconds}
                  goalsMaxTriggersPerGoal={form.goalsMaxTriggersPerGoal}
                  setGoalsMaxTriggersPerGoal={form.setGoalsMaxTriggersPerGoal}
                  ideasEnabled={form.ideasEnabled}
                  setIdeasEnabled={form.setIdeasEnabled}
                  ideasMaxPerCycle={form.ideasMaxPerCycle}
                  setIdeasMaxPerCycle={form.setIdeasMaxPerCycle}
                  ideasTimeoutSeconds={form.ideasTimeoutSeconds}
                  setIdeasTimeoutSeconds={form.setIdeasTimeoutSeconds}
                  goalsConfig={form.settings?.goals}
                />
              )}
              {activeTab === "engine" && (
                <EngineTab
                  engineName={form.engineName}
                  setEngineName={form.setEngineName}
                  logLevel={form.logLevel}
                  setLogLevel={form.setLogLevel}
                  compactionThresholdPercent={form.compactionThresholdPercent}
                  setCompactionThresholdPercent={
                    form.setCompactionThresholdPercent
                  }
                  maxToolIterations={form.maxToolIterations}
                  setMaxToolIterations={form.setMaxToolIterations}
                  proactiveMode={form.proactiveMode}
                  setProactiveMode={form.setProactiveMode}
                  proactiveJudgeTimeoutSeconds={
                    form.proactiveJudgeTimeoutSeconds
                  }
                  setProactiveJudgeTimeoutSeconds={
                    form.setProactiveJudgeTimeoutSeconds
                  }
                  settings={form.settings}
                />
              )}
              {activeTab === "tools" && (
                <ToolsTab
                  safeTools={services.allTools}
                  pluginsList={services.pluginsList}
                  rescanLoading={services.rescanLoading}
                  handleRescanPlugins={() => void services.handleRescanPlugins()}
                  handleToggleEnable={services.handleToggleEnable}
                  setPendingUninstallPlugin={services.setPendingUninstallPlugin}
                  handleToggleTool={services.handleToggleTool}
                  handleToggleCategory={services.handleToggleCategory}
                  onConfigureTool={(name) => save.setConfiguringToolName(name)}
                  handlePermissionChange={services.handlePermissionChange}
                  toolSearchQuery={services.toolSearchQuery}
                  setToolSearchQuery={services.setToolSearchQuery}
                  selectedToolCategory={services.selectedToolCategory}
                  setSelectedToolCategory={services.setSelectedToolCategory}
                  togglingCategory={services.togglingCategory}
                  togglingToolName={services.togglingToolName}
                  updatingPluginId={services.updatingPluginId}
                  pluginsDir={form.pluginsDir}
                  setPluginsDir={form.setPluginsDir}
                  pluginsMarketplaceIndexURL={
                    form.pluginsMarketplaceIndexURL
                  }
                  setPluginsMarketplaceIndexURL={
                    form.setPluginsMarketplaceIndexURL
                  }
                  pluginsAutoRescan={form.pluginsAutoRescan}
                  setPluginsAutoRescan={form.setPluginsAutoRescan}
                  workspaceLoading={services.workspaceLoading}
                  pruningWorkspace={services.pruningWorkspace}
                  workspaceUsage={services.workspaceUsage}
                  refreshWorkspaceUsage={services.refreshWorkspaceUsage}
                  setPendingPruneWorkspace={services.setPendingPruneWorkspace}
                  workspaceError={services.workspaceError}
                  workspaceMachine={services.workspaceMachine}
                  workspaceMachineLoading={services.workspaceMachineLoading}
                  workspaceMachineError={services.workspaceMachineError}
                  workspaceMachineAction={services.workspaceMachineAction}
                  handleStopWorkspaceMachine={services.handleStopWorkspaceMachine}
                  handleRecycleWorkspaceMachine={services.handleRecycleWorkspaceMachine}
                  workspaceQuotaMB={form.workspaceQuotaMB}
                  setWorkspaceQuotaMB={form.setWorkspaceQuotaMB}
                  workspaceQuotaFiles={form.workspaceQuotaFiles}
                  setWorkspaceQuotaFiles={form.setWorkspaceQuotaFiles}
                  workspaceTmpTTLDays={form.workspaceTmpTTLDays}
                  setWorkspaceTmpTTLDays={form.setWorkspaceTmpTTLDays}
                  pendingCount={pendingCount}
                  tamperedCount={tamperedCount}
                />
              )}
              {activeTab === "security" && (
                <SecurityTab
                  containersMemoryMB={form.containersMemoryMB}
                  setContainersMemoryMB={form.setContainersMemoryMB}
                  containersMaxConcurrent={form.containersMaxConcurrent}
                  setContainersMaxConcurrent={form.setContainersMaxConcurrent}
                  containersTTLMinutes={form.containersTTLMinutes}
                  setContainersTTLMinutes={form.setContainersTTLMinutes}
                  rotateError={services.rotateError}
                  rotating={services.rotating}
                  onPromptRotate={() => {
                    services.setRotateError(null);
                    services.setRotateConfirmStep(1);
                  }}
                  handleLogout={services.handleLogout}
                  hasOwnerSession={services.hasOwnerSession}
                />
              )}
              {activeTab === "memory" && (
                <MemoryTab
                  memoryEmbeddingBackend={form.memoryEmbeddingBackend}
                  setMemoryEmbeddingBackend={form.setMemoryEmbeddingBackend}
                  embeddingsStatus={services.embeddingsStatus}
                  refreshEmbeddingsStatus={services.refreshEmbeddingsStatus}
                  embeddingsLoading={services.embeddingsLoading}
                  handleEnsureEmbeddings={services.handleEnsureEmbeddings}
                  embeddingsActionBusy={services.embeddingsActionBusy}
                  memoryEpisodesDBPath={form.memoryEpisodesDBPath}
                  setMemoryEpisodesDBPath={form.setMemoryEpisodesDBPath}
                  memoryVectorDBPath={form.memoryVectorDBPath}
                  setMemoryVectorDBPath={form.setMemoryVectorDBPath}
                />
              )}
              {activeTab === "voice" && (
                <VoiceTab
                  voiceSTTProvider={form.voiceSTTProvider}
                  setVoiceSTTProvider={form.setVoiceSTTProvider}
                  voiceTTSProvider={form.voiceTTSProvider}
                  setVoiceTTSProvider={form.setVoiceTTSProvider}
                  voiceWhisperModel={form.voiceWhisperModel}
                  setVoiceWhisperModel={form.setVoiceWhisperModel}
                />
              )}
              {activeTab === "search" && (
                <WebSearchTab
                  searchActionBusy={services.searchActionBusy}
                  searchRunning={services.searchRunning}
                  handleToggleSearch={services.handleToggleSearch}
                  searchAction={services.searchAction}
                  setPendingRemoveSearch={services.setPendingRemoveSearch}
                  searchRemoveEnabled={services.searchRemoveEnabled}
                  searchSearxngURL={form.searchSearxngURL}
                  setSearchSearxngURL={form.setSearchSearxngURL}
                  searchTimeoutSeconds={form.searchTimeoutSeconds}
                  setSearchTimeoutSeconds={form.setSearchTimeoutSeconds}
                  searchMaxResults={form.searchMaxResults}
                  setSearchMaxResults={form.setSearchMaxResults}
                  searchStage={services.searchStage}
                  searchStartElapsed={services.searchStartElapsed}
                  searchHealthLoading={services.searchHealthLoading}
                  searchReachable={services.searchReachable}
                  searchHealthError={services.searchHealthError}
                  searchDiagnostics={services.searchDiagnostics}
                  browserActionBusy={services.browserActionBusy}
                  browserStage={services.browserStage}
                  browserElapsed={services.browserElapsed}
                  browserReady={services.browserReady}
                  refreshBrowserHealth={services.refreshBrowserHealth}
                  browserHealthLoading={services.browserHealthLoading}
                  handleEnsureBrowser={services.handleEnsureBrowser}
                  browserAction={services.browserAction}
                  browserError={services.browserError}
                  browserDiagnostics={services.browserDiagnostics}
                  browserAdvancedRef={services.browserAdvancedRef}
                  browserVenvPath={services.browserVenvPath}
                  browserPythonPath={services.browserPythonPath}
                  pendingRemoveSearch={services.pendingRemoveSearch}
                  handleConfirmRemoveSearch={services.handleConfirmRemoveSearch}
                />
              )}
              {activeTab === "email" && (
                <EmailTab
                  emailAccountsList={form.emailAccountsList}
                  handleAddEmailAccount={form.handleAddEmailAccount}
                  handleRemoveEmailAccount={form.handleRemoveEmailAccount}
                  handleEmailFieldChange={form.handleEmailFieldChange}
                  secretStatus={services.secretStatus}
                  onOpenStoreSecretModal={services.handleOpenStoreSecretModal}
                />
              )}
              {activeTab === "network" && (
                <NetworkTab
                  settings={form.settings}
                  serverHostname={form.serverHostname}
                  setServerHostname={form.setServerHostname}
                  serverHostnameCustom={form.serverHostnameCustom}
                  setServerHostnameCustom={form.setServerHostnameCustom}
                  serverPort={form.serverPort}
                  setServerPort={form.setServerPort}
                  serverAllowedHostsText={form.serverAllowedHostsText}
                  setServerAllowedHostsText={form.setServerAllowedHostsText}
                  serverAllowedHostsError={serverAllowedHostsError}
                  serverAllowedHostsCount={serverAllowedHostsCount}
                  liveServerBind={form.liveServerBind}
                  serverRestartRequired={form.serverRestartRequired}
                  hasOwnerSession={services.hasOwnerSession}
                />
              )}
              <div className="settings-footer">
                <button
                  type="submit"
                  className="primary-button save-button"
                  disabled={save.saving}
                >
                  {save.saving ? "Saving…" : "Save"}
                </button>
              </div>
            </form>
          ) : null}
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
