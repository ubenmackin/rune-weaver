// Rune Weaver Dashboard — Settings form panels.
import AccessPane from "../AccessPane";
import { IndexPolicyPanel } from "../IndexingPanel";
import { EmailTab } from "./EmailTab";
import { EngineTab } from "./EngineTab";
import { GoalsTab } from "./GoalsTab";
import { MemoryTab } from "./MemoryTab";
import { NetworkTab } from "./NetworkTab";
import { PersonaTab } from "./PersonaTab";
import { ProvidersTab } from "./ProvidersTab";
import { SecurityTab } from "./SecurityTab";
import { ToolsTab } from "./ToolsTab";
import { VoiceTab } from "./VoiceTab";
import { WebSearchTab } from "./WebSearchTab";
import type { SettingsTab } from "./settingsTypes";
import { isSettingsFormDirty } from "./useSettingsDirty";
import type { useSettingsFormState } from "./useSettingsFormState";
import type { useSettingsSave } from "./useSettingsSave";
import type { useSettingsServices } from "./useSettingsServices";

export interface SettingsFormPanelsProps {
  activeTab: SettingsTab;
  form: ReturnType<typeof useSettingsFormState>;
  services: ReturnType<typeof useSettingsServices>;
  save: ReturnType<typeof useSettingsSave>;
  pendingCount: number;
  tamperedCount: number;
  serverAllowedHostsCount: number;
  serverAllowedHostsError: string | null;
}

// Renders access/indexing branches plus the tabbed config form.
// Single owner for the tab-to-pane mapping so the shell stays lean.
export function SettingsFormPanels({
  activeTab,
  form,
  services,
  save,
  pendingCount,
  tamperedCount,
  serverAllowedHostsCount,
  serverAllowedHostsError,
}: SettingsFormPanelsProps) {
  if (activeTab === "access") return <AccessPane />;
  if (activeTab === "indexing") return <IndexPolicyPanel />;
  const dirty = isSettingsFormDirty(form);
  return (
    <form onSubmit={save.handleSave} className="settings-form" noValidate>
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
          validationError={save.error}
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
          validationError={save.error}
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
          validationError={save.error}
        />
      )}
      {activeTab === "engine" && (
        <EngineTab
          engineName={form.engineName}
          setEngineName={form.setEngineName}
          logLevel={form.logLevel}
          setLogLevel={form.setLogLevel}
          compactionThresholdPercent={form.compactionThresholdPercent}
          setCompactionThresholdPercent={form.setCompactionThresholdPercent}
          maxToolIterations={form.maxToolIterations}
          setMaxToolIterations={form.setMaxToolIterations}
          proactiveMode={form.proactiveMode}
          setProactiveMode={form.setProactiveMode}
          proactiveJudgeTimeoutSeconds={form.proactiveJudgeTimeoutSeconds}
          setProactiveJudgeTimeoutSeconds={form.setProactiveJudgeTimeoutSeconds}
          settings={form.settings}
          validationError={save.error}
        />
      )}
      {activeTab === "tools" && (
        <ToolsTab
          safeTools={services.allTools}
          pluginsList={services.pluginsList}
          rescanLoading={services.rescanLoading}
          handleRescanPlugins={() => void services.handleRescanPlugins()}
          onBrowseMarketplace={() => services.setMarketplaceOpen(true)}
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
          togglingToolNames={services.togglingToolNames}
          updatingPluginId={services.updatingPluginId}
          pluginsDir={form.pluginsDir}
          setPluginsDir={form.setPluginsDir}
          pluginsMarketplaceIndexURL={form.pluginsMarketplaceIndexURL}
          setPluginsMarketplaceIndexURL={form.setPluginsMarketplaceIndexURL}
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
          validationError={save.error}
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
          memoryRecallAutoLimit={form.memoryRecallAutoLimit}
          setMemoryRecallAutoLimit={form.setMemoryRecallAutoLimit}
          memoryRecallDocPoolMultiplier={form.memoryRecallDocPoolMultiplier}
          setMemoryRecallDocPoolMultiplier={form.setMemoryRecallDocPoolMultiplier}
          memoryRecallEpisodicWeight={form.memoryRecallEpisodicWeight}
          setMemoryRecallEpisodicWeight={form.setMemoryRecallEpisodicWeight}
          validationError={save.error}
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
          validationError={save.error}
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
          validationError={save.error}
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
          validationError={save.error}
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
          disabled={save.saving || !dirty}
          title={dirty ? undefined : "No unsaved changes"}
        >
          {save.saving ? "Saving…" : "Save"}
        </button>
      </div>
    </form>
  );
}
