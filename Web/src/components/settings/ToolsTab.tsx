// Rune Weaver Dashboard — Settings tools tab: tool toggles, plugin management, and workspace storage controls.
import { useState } from "react";
import { DEFAULT_WORKSPACE_CONFIG, type PluginSummary, type ToolInfo } from "../../api";
import { AlertTriangleIcon, RefreshIcon, SearchIcon, SettingsIcon, WrenchIcon } from "../icons";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import {
  countToolsAdvancedChanged,
  DEFAULT_TOOLS_AUTO_RESCAN,
  DEFAULT_TOOLS_MARKETPLACE_INDEX_URL,
  DEFAULT_TOOLS_PLUGINS_DIR,
} from "./settingsAdvancedCounts";
import PluginsListSection from "./PluginsListSection";
import {
  getCategoryConfigKey,
  getToolCategory,
  TOOL_CATEGORIES,
} from "./settingsHelpers";
import WorkspaceStorageSection from "./WorkspaceStorageSection";

// Advanced Tools validation messages the disclosure can focus; the shell reuses
// it so one message never prints twice. Quota plus tmp route workspace validation;
// machine usage plus status errors stay global.
export const TOOLS_ADVANCED_ERROR_KEYWORDS = [
  "plugins directory",
  "marketplace",
  "rescan",
  "quota",
  "tmp",
] as const;

export function isToolsAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return TOOLS_ADVANCED_ERROR_KEYWORDS.some((keyword) =>
    lowered.includes(keyword)
  );
}

export interface ToolsTabProps {
  handleRescanPlugins: () => void;
  rescanLoading: boolean;
  safeTools: ToolInfo[];
  pluginsList: PluginSummary[];
  pendingCount: number;
  tamperedCount: number;
  workspaceLoading: boolean;
  pruningWorkspace: boolean;
  workspaceError: string | null;
  workspaceUsage: Parameters<typeof WorkspaceStorageSection>[0]["workspaceUsage"];
  refreshWorkspaceUsage: () => Promise<void>;
  setPendingPruneWorkspace: (val: boolean) => void;
  workspaceMachineLoading: boolean;
  workspaceMachine: Parameters<typeof WorkspaceStorageSection>[0]["workspaceMachine"];
  workspaceMachineError: string | null;
  workspaceMachineAction: "stop" | "recycle" | null;
  handleStopWorkspaceMachine: () => Promise<void>;
  handleRecycleWorkspaceMachine: () => Promise<void>;
  workspaceQuotaMB: number | string;
  setWorkspaceQuotaMB: (val: number | string) => void;
  workspaceQuotaFiles: number | string;
  setWorkspaceQuotaFiles: (val: number | string) => void;
  workspaceTmpTTLDays: number | string;
  setWorkspaceTmpTTLDays: (val: number | string) => void;
  handleToggleEnable: (plugin: PluginSummary) => void;
  updatingPluginId: string | null;
  setPendingUninstallPlugin: (val: { id: string; name: string } | null) => void;
  handlePermissionChange: (pluginId: string, toolName: string, level: string) => void;
  toolSearchQuery: string;
  setToolSearchQuery: (val: string) => void;
  selectedToolCategory: string;
  setSelectedToolCategory: (val: string) => void;
  togglingCategory: string | null;
  handleToggleCategory: (catId: string, enable: boolean) => Promise<void>;
  togglingToolName: string | null;
  handleToggleTool: (tool: ToolInfo) => Promise<void>;
  onConfigureTool: (key: string) => void;
  pluginsDir: string;
  setPluginsDir: (val: string) => void;
  pluginsMarketplaceIndexURL: string;
  setPluginsMarketplaceIndexURL: (val: string) => void;
  pluginsAutoRescan: boolean;
  setPluginsAutoRescan: (val: boolean) => void;
  validationError?: string | null;
}

export function ToolsTab({
  handleRescanPlugins,
  rescanLoading,
  safeTools,
  pluginsList,
  pendingCount,
  tamperedCount,
  workspaceLoading,
  pruningWorkspace,
  workspaceError,
  workspaceUsage,
  refreshWorkspaceUsage,
  setPendingPruneWorkspace,
  workspaceMachineLoading,
  workspaceMachine,
  workspaceMachineError,
  workspaceMachineAction,
  handleStopWorkspaceMachine,
  handleRecycleWorkspaceMachine,
  workspaceQuotaMB,
  setWorkspaceQuotaMB,
  workspaceQuotaFiles,
  setWorkspaceQuotaFiles,
  workspaceTmpTTLDays,
  setWorkspaceTmpTTLDays,
  handleToggleEnable,
  updatingPluginId,
  setPendingUninstallPlugin,
  handlePermissionChange,
  toolSearchQuery,
  setToolSearchQuery,
  selectedToolCategory,
  setSelectedToolCategory,
  togglingCategory,
  handleToggleCategory,
  togglingToolName,
  handleToggleTool,
  onConfigureTool,
  pluginsDir,
  setPluginsDir,
  pluginsMarketplaceIndexURL,
  setPluginsMarketplaceIndexURL,
  pluginsAutoRescan,
  setPluginsAutoRescan,
  validationError = null,
}: ToolsTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const advancedChangedCount = countToolsAdvancedChanged(
    pluginsDir,
    pluginsMarketplaceIndexURL,
    pluginsAutoRescan,
    workspaceQuotaMB,
    workspaceQuotaFiles,
    workspaceTmpTTLDays
  );

  // Reset restores stock plugin location, catalog URL, scan behavior,
  // plus workspace quotas and tmp retention.
  const resetToolsAdvanced = () => {
    setPluginsDir(DEFAULT_TOOLS_PLUGINS_DIR);
    setPluginsMarketplaceIndexURL(DEFAULT_TOOLS_MARKETPLACE_INDEX_URL);
    setPluginsAutoRescan(DEFAULT_TOOLS_AUTO_RESCAN);
    setWorkspaceQuotaMB(DEFAULT_WORKSPACE_CONFIG.quotaMB);
    setWorkspaceQuotaFiles(DEFAULT_WORKSPACE_CONFIG.quotaFiles);
    setWorkspaceTmpTTLDays(DEFAULT_WORKSPACE_CONFIG.tmpTTLDays);
  };
  const builtIns = safeTools.filter((t) => t.isBuiltIn);
  const q = toolSearchQuery.trim().toLowerCase();
  const filteredTools = builtIns.filter((tool) => {
    if (q && !tool.name.toLowerCase().includes(q) && !(tool.description?.toLowerCase().includes(q))) {
      return false;
    }
    if (selectedToolCategory !== "all" && getToolCategory(tool) !== selectedToolCategory) {
      return false;
    }
    return true;
  });

  const visibleCategories = TOOL_CATEGORIES.map((cat) => ({
    ...cat,
    tools: filteredTools.filter((t) => getToolCategory(t) === cat.id),
  })).filter((cat) => cat.tools.length > 0);

  return (
    <div className="settings-section card">
      <div className="settings-section-header">
        <div className="settings-section-title-group">
          <h3>Tools & Runes</h3>
          <p className="settings-section-hint">
            Manage internal and external tools. Discovered and newly installed runes remain disabled by default until reviewed and approved.
          </p>
        </div>
        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={handleRescanPlugins}
            disabled={rescanLoading}
          >
            <RefreshIcon size={14} className={rescanLoading ? "spin" : ""} />
            <span>{rescanLoading ? "Scanning..." : "Rescan Plugins"}</span>
          </button>
        </div>
      </div>

      {/* Metrics cards */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(130px, 1fr))", gap: "12px", margin: "16px 0" }}>
        <div style={{ padding: "12px", background: "var(--bg-secondary, #141822)", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)" }}>
          <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", textTransform: "uppercase", fontWeight: 600 }}>Active Tools</div>
          <div style={{ fontSize: "1.4rem", fontWeight: 700, color: "#48bb78", marginTop: "4px" }}>
            {safeTools.filter((t) => t.isEnabled).length}
          </div>
        </div>
        <div style={{ padding: "12px", background: "var(--bg-secondary, #141822)", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)" }}>
          <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", textTransform: "uppercase", fontWeight: 600 }}>External Runes</div>
          <div style={{ fontSize: "1.4rem", fontWeight: 700, marginTop: "4px" }}>
            {pluginsList.length}
          </div>
        </div>
        <div style={{ padding: "12px", background: "var(--bg-secondary, #141822)", borderRadius: "8px", border: "1px solid var(--border-color, #2d3748)" }}>
          <div style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)", textTransform: "uppercase", fontWeight: 600 }}>Pending Review</div>
          <div style={{ fontSize: "1.4rem", fontWeight: 700, color: pendingCount > 0 ? "#ed8936" : "inherit", marginTop: "4px" }}>
            {pendingCount}
          </div>
        </div>
        {tamperedCount > 0 && (
          <div style={{ padding: "12px", background: "rgba(245, 101, 101, 0.1)", borderRadius: "8px", border: "1px solid rgba(245, 101, 101, 0.3)" }}>
            <div style={{ fontSize: "0.75rem", color: "#f56565", textTransform: "uppercase", fontWeight: 600 }}>Tampered</div>
            <div style={{ fontSize: "1.4rem", fontWeight: 700, color: "#f56565", marginTop: "4px" }}>
              {tamperedCount}
            </div>
          </div>
        )}
      </div>

      {/* Warning banners */}
      {pendingCount > 0 && (
        <div
          style={{
            padding: "12px 16px",
            borderRadius: "8px",
            backgroundColor: "rgba(237, 137, 54, 0.15)",
            border: "1px solid rgba(237, 137, 54, 0.4)",
            marginBottom: "16px",
            display: "flex",
            alignItems: "flex-start",
            gap: "12px",
            color: "#ed8936",
          }}
        >
          <AlertTriangleIcon size={20} style={{ flexShrink: 0, marginTop: "2px" }} />
          <div style={{ fontSize: "0.88rem", lineHeight: "1.4" }}>
            <strong>{pendingCount} newly discovered rune(s) awaiting review.</strong>
            <div style={{ marginTop: "2px", color: "var(--text-primary, #e2e8f0)" }}>
              In accordance with security policy, new tools start disabled by default. Review their code and permissions below before enabling.
            </div>
          </div>
        </div>
      )}

      {tamperedCount > 0 && (
        <div
          style={{
            padding: "12px 16px",
            borderRadius: "8px",
            backgroundColor: "rgba(245, 101, 101, 0.15)",
            border: "1px solid rgba(245, 101, 101, 0.4)",
            marginBottom: "16px",
            display: "flex",
            alignItems: "flex-start",
            gap: "12px",
            color: "#f56565",
          }}
        >
          <AlertTriangleIcon size={20} style={{ flexShrink: 0, marginTop: "2px" }} />
          <div style={{ fontSize: "0.88rem", lineHeight: "1.4" }}>
            <strong>Security Alert: {tamperedCount} plugin(s) have been modified on disk since approval!</strong>
            <div style={{ marginTop: "2px", color: "var(--text-primary, #e2e8f0)" }}>
              Cryptographic tree hash does not match the approved signature. They have been quarantined and disabled.
            </div>
          </div>
        </div>
      )}

      {/* External Runes List */}
      <PluginsListSection
        pluginsList={pluginsList}
        updatingPluginId={updatingPluginId}
        handleToggleEnable={handleToggleEnable}
        setPendingUninstallPlugin={setPendingUninstallPlugin}
        handlePermissionChange={handlePermissionChange}
      />

      {/* Built-in Core Tools Section */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", margin: "28px 0 8px 0", flexWrap: "wrap", gap: "10px" }}>
        <h4 style={{ margin: 0, display: "flex", alignItems: "center", gap: "8px" }}>
          <span>Built-in Engine Tools</span>
        </h4>
        <span className="muted text-sm">
          {safeTools.filter((t) => t.isBuiltIn && t.isEnabled).length} of {safeTools.filter((t) => t.isBuiltIn).length} enabled
        </span>
      </div>

      {/* Search and Category Filter Bar */}
      <div className="tools-filter-bar">
        <div className="tools-search-wrapper">
          <SearchIcon size={16} className="tools-search-icon" />
          <input
            type="search"
            className="tools-search-input"
            placeholder="Search tools by name or description..."
            value={toolSearchQuery}
            onChange={(e) => setToolSearchQuery(e.target.value)}
          />
        </div>

        {/* Category Pills */}
        <div className="tools-category-pills">
          <button
            type="button"
            className={`tools-category-pill ${selectedToolCategory === "all" ? "active" : ""}`}
            onClick={() => setSelectedToolCategory("all")}
          >
            <span>All</span>
            <span className="tools-category-pill-count">
              {safeTools.filter((t) => t.isBuiltIn).length}
            </span>
          </button>
          {TOOL_CATEGORIES.map((cat) => {
            const catToolCount = safeTools.filter((t) => t.isBuiltIn && getToolCategory(t) === cat.id).length;
            if (catToolCount === 0) return null;
            const Icon = cat.icon;
            return (
              <button
                key={cat.id}
                type="button"
                className={`tools-category-pill ${selectedToolCategory === cat.id ? "active" : ""}`}
                onClick={() => setSelectedToolCategory(cat.id)}
              >
                <Icon size={13} />
                <span>{cat.name.replace(/,/g, "").split(" ")[0]}</span>
                <span className="tools-category-pill-count">{catToolCount}</span>
              </button>
            );
          })}
        </div>
      </div>

      {builtIns.length === 0 ? (
        <div className="empty-state-box">
          <WrenchIcon size={32} />
          <p>No built-in tools available.</p>
        </div>
      ) : filteredTools.length === 0 ? (
        <div className="empty-state-box" style={{ padding: "32px 16px" }}>
          <SearchIcon size={28} />
          <p style={{ margin: "8px 0 4px 0" }}>No tools match your filter criteria.</p>
          <button
            type="button"
            className="accent-ghost"
            onClick={() => {
              setToolSearchQuery("");
              setSelectedToolCategory("all");
            }}
            style={{ marginTop: "8px", fontSize: "0.82rem" }}
          >
            Reset filters
          </button>
        </div>
      ) : (
        <div className="tool-categories-container">
          {visibleCategories.map((cat) => {
            const enabledCount = cat.tools.filter((t) => t.isEnabled).length;
            const allEnabled = enabledCount === cat.tools.length;
            const anyEnabled = enabledCount > 0;
            const isTogglingCat = togglingCategory === cat.id;
            const Icon = cat.icon;
            const categoryConfigKey = getCategoryConfigKey(cat.id);
            const categoryHasConfig = cat.tools.some((t) => t.hasConfig);
            const categoryConfigTitle =
              categoryConfigKey === "desktop"
                ? "Configure Desktop Integration"
                : categoryConfigKey === "media.arr"
                  ? "Configure Sonarr & Radarr"
                  : categoryConfigKey === "fanout.run"
                    ? "Configure Parallel Fan-Out"
                    : "Configure Browser & Web Automation";

            return (
              <section key={cat.id} className="tool-category-section">
                <div className="tool-category-header">
                  <div className="tool-category-title-group">
                    <Icon size={18} />
                    <h4 className="tool-category-title">{cat.name}</h4>
                    <span
                      className={`tool-category-badge ${
                        allEnabled ? "all-enabled" : anyEnabled ? "partial" : "all-disabled"
                      }`}
                    >
                      {enabledCount} of {cat.tools.length} enabled
                    </span>
                  </div>
                  <div className="tool-category-actions">
                    <button
                      type="button"
                      className="tool-category-action-btn"
                      onClick={() => void handleToggleCategory(cat.id, !allEnabled)}
                      disabled={isTogglingCat}
                    >
                      {isTogglingCat ? "Updating…" : allEnabled ? "Disable All" : "Enable All"}
                    </button>
                    {categoryConfigKey !== null && categoryHasConfig ? (
                      <button
                        type="button"
                        className="tool-category-action-btn configure accent-ghost icon-text-btn"
                        title={categoryConfigTitle}
                        onClick={() => onConfigureTool(categoryConfigKey)}
                        style={{ padding: "4px 8px", fontSize: "0.78rem" }}
                      >
                        <SettingsIcon size={12} />
                        <span>Configure</span>
                      </button>
                    ) : null}
                  </div>
                </div>

                <div className="builtin-tools-grid">
                  {cat.tools.map((tool) => {
                    const isToggling = togglingToolName === tool.name;
                    return (
                      <article key={tool.name} className="builtin-tool-card">
                        <div className="builtin-tool-card-header">
                          <code className="builtin-tool-name" title={tool.name}>
                            {tool.name}
                          </code>
                          <span className="builtin-tool-permission">{tool.permissionLevel}</span>
                        </div>
                        <p className="builtin-tool-desc" title={tool.description}>
                          {tool.description}
                        </p>
                        {tool.description && (
                          <details className="builtin-tool-details">
                            <summary>Details</summary>
                            <p className="builtin-tool-details-body">{tool.description}</p>
                          </details>
                        )}
                        <div className="builtin-tool-footer">
                          <label
                            className="toggle-label tool-switch"
                            style={{ display: "flex", alignItems: "center", gap: "8px", flexShrink: 0, cursor: isToggling ? "wait" : "pointer" }}
                          >
                            <input
                              type="checkbox"
                              role="switch"
                              className="tool-switch-input"
                              aria-label={`${tool.name} ${tool.isEnabled ? "Enabled" : "Disabled"}`}
                              aria-checked={tool.isEnabled}
                              checked={tool.isEnabled}
                              onChange={() => void handleToggleTool(tool)}
                              disabled={isToggling}
                            />
                            <span
                              className="tool-switch-track"
                              data-on={tool.isEnabled ? "true" : "false"}
                              aria-hidden="true"
                            >
                              <span className="tool-switch-thumb" />
                            </span>
                            <span className="tool-switch-state">
                              {isToggling ? "Updating…" : tool.isEnabled ? "Enabled" : "Disabled"}
                            </span>
                          </label>
                        </div>
                      </article>
                    );
                  })}
                </div>
              </section>
            );
          })}
        </div>
      )}

      <AdvancedDisclosure
        tabName="Tools"
        changedCount={advancedChangedCount}
        summary={
          advancedChangedCount > 0
            ? `${advancedChangedCount} advanced tools ${advancedChangedCount === 1 ? "setting" : "settings"} changed`
            : undefined
        }
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        testId="advanced-tools"
        validationError={validationError}
        errorKeywords={[...TOOLS_ADVANCED_ERROR_KEYWORDS]}
        onReset={resetToolsAdvanced}
      >
        <div className="settings-section-title-group">
          <h4 style={{ margin: "0 0 4px 0" }}>Plugin Configuration</h4>
          <p className="settings-section-hint">
            Configure directory location, remote marketplace index, and startup scanning behavior.
          </p>
        </div>
        <div className="form-row">
          <div className="form-group flex-2">
            <label htmlFor="plugins-dir">Plugins Directory</label>
            <input
              id="plugins-dir"
              type="text"
              className="input-field"
              value={pluginsDir}
              onChange={(e) => setPluginsDir(e.target.value)}
              required
            />
            <span className="form-group-hint">
              Directory scanned for external rune packages (defaults to ~/.runeweaver/plugins).
            </span>
          </div>
          <div className="form-group flex-2">
            <label htmlFor="marketplace-url">Marketplace Index URL</label>
            <input
              id="marketplace-url"
              type="url"
              className="input-field"
              value={pluginsMarketplaceIndexURL}
              onChange={(e) => setPluginsMarketplaceIndexURL(e.target.value)}
              required
            />
            <span className="form-group-hint">
              Remote catalog URL for community runes. Endpoint override for the rune marketplace.
            </span>
          </div>
        </div>
        <div className="form-row" style={{ marginTop: "12px" }}>
          <div className="form-group checkbox-group">
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                id="plugins-autorescan"
                type="checkbox"
                checked={pluginsAutoRescan}
                onChange={(e) => setPluginsAutoRescan(e.target.checked)}
              />
              <span>Automatically scan plugins directory on startup</span>
            </label>
          </div>
        </div>
        <WorkspaceStorageSection
          workspaceLoading={workspaceLoading}
          pruningWorkspace={pruningWorkspace}
          workspaceError={workspaceError}
          workspaceUsage={workspaceUsage}
          refreshWorkspaceUsage={refreshWorkspaceUsage}
          setPendingPruneWorkspace={setPendingPruneWorkspace}
          workspaceMachineLoading={workspaceMachineLoading}
          workspaceMachine={workspaceMachine}
          workspaceMachineError={workspaceMachineError}
          workspaceMachineAction={workspaceMachineAction}
          handleStopWorkspaceMachine={handleStopWorkspaceMachine}
          handleRecycleWorkspaceMachine={handleRecycleWorkspaceMachine}
          workspaceQuotaMB={workspaceQuotaMB}
          setWorkspaceQuotaMB={setWorkspaceQuotaMB}
          workspaceQuotaFiles={workspaceQuotaFiles}
          setWorkspaceQuotaFiles={setWorkspaceQuotaFiles}
          workspaceTmpTTLDays={workspaceTmpTTLDays}
          setWorkspaceTmpTTLDays={setWorkspaceTmpTTLDays}
        />
      </AdvancedDisclosure>
    </div>
  );
}

export default ToolsTab;
