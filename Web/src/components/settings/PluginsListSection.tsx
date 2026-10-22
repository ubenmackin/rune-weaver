// Rune Weaver Dashboard — Installed Runes and external plugins list section.
import type { PluginSummary, ToolInfo } from "../../api";
import { TrashIcon, WrenchIcon } from "../icons";

export interface PluginsListSectionProps {
  pluginsList: PluginSummary[];
  updatingPluginId: string | null;
  handleToggleEnable: (plugin: PluginSummary) => void;
  setPendingUninstallPlugin: (val: { id: string; name: string } | null) => void;
  handlePermissionChange: (
    pluginId: string,
    toolName: string,
    level: string
  ) => void;
  handleToggleTool: (tool: ToolInfo) => Promise<void>;
  togglingToolNames: Set<string>;
}

export function PluginsListSection({
  pluginsList,
  updatingPluginId,
  handleToggleEnable,
  setPendingUninstallPlugin,
  handlePermissionChange,
  handleToggleTool,
  togglingToolNames,
}: PluginsListSectionProps) {
  return (
    <>
      <h4
        style={{
          margin: "20px 0 12px 0",
          display: "flex",
          alignItems: "center",
          gap: "8px",
        }}
      >
        <span>Installed Runes & Plugins</span>
      </h4>

      {pluginsList.length === 0 ? (
        <div
          className="empty-state-box"
          style={{ padding: "28px", textAlign: "center" }}
        >
          <WrenchIcon size={32} />
          <p>No external runes discovered in plugins directory.</p>
          <p className="muted text-sm" style={{ marginTop: "8px" }}>
            Add rune packages to the plugins directory below, then use Rescan
            Plugins to discover them.
          </p>
        </div>
      ) : (
        <div className="tool-categories-container">
          {pluginsList.map((plugin) => {
            const isPending = plugin.status === "discovered";
            const isTampered = plugin.status === "tampered";
            const enabledCount = plugin.tools.filter((t) => t.isEnabled).length;
            const allEnabled =
              plugin.tools.length > 0 &&
              enabledCount === plugin.tools.length;
            const anyEnabled = enabledCount > 0;
            return (
              <section key={plugin.id} className="tool-category-section">
                <div className="tool-category-header">
                  <div className="tool-category-title-group">
                    <WrenchIcon size={18} />
                    <h4 className="tool-category-title">{plugin.name}</h4>
                    <span className="tool-category-badge all-disabled">
                      v{plugin.version}
                    </span>
                    <span className="tool-category-badge all-disabled">
                      {plugin.runtime}
                    </span>
                    {plugin.isEnabled ? (
                      <span className="tool-category-badge all-enabled">
                        ENABLED
                      </span>
                    ) : isPending ? (
                      <span className="tool-category-badge partial">
                        PENDING REVIEW
                      </span>
                    ) : isTampered ? (
                      <span className="tool-category-badge partial">
                        TAMPERED
                      </span>
                    ) : (
                      <span className="tool-category-badge all-disabled">
                        DISABLED
                      </span>
                    )}
                    <span
                      className={`tool-category-badge ${
                        allEnabled
                          ? "all-enabled"
                          : anyEnabled
                            ? "partial"
                            : "all-disabled"
                      }`}
                    >
                      {enabledCount} of {plugin.tools.length} enabled
                    </span>
                  </div>
                  <div className="tool-category-actions">
                    <button
                      type="button"
                      className={
                        plugin.isEnabled
                          ? "ghost icon-text-btn"
                          : "primary icon-text-btn"
                      }
                      onClick={() => handleToggleEnable(plugin)}
                      disabled={updatingPluginId === plugin.id}
                    >
                      {updatingPluginId === plugin.id
                        ? "Updating..."
                        : plugin.isEnabled
                          ? "Disable"
                          : isPending
                            ? "Approve & Enable"
                            : isTampered
                              ? "Re-verify & Enable"
                              : "Enable"}
                    </button>
                    <button
                      type="button"
                      className="icon-button danger"
                      onClick={() =>
                        setPendingUninstallPlugin({
                          id: plugin.id,
                          name: plugin.name,
                        })
                      }
                      disabled={updatingPluginId === plugin.id}
                      title={`Uninstall ${plugin.name}`}
                      aria-label={`Uninstall ${plugin.name}`}
                    >
                      <TrashIcon size={14} />
                    </button>
                  </div>
                </div>

                <div style={{ marginBottom: "12px" }}>
                  <div
                    style={{
                      fontSize: "0.8rem",
                      color: "var(--text-secondary, #a0aec0)",
                    }}
                  >
                    <code>{plugin.id}</code>{" "}
                    {plugin.author ? `• by ${plugin.author}` : ""}
                  </div>
                  {plugin.description && (
                    <p
                      style={{
                        margin: "4px 0 8px 0",
                        fontSize: "0.88rem",
                        color: "var(--text-secondary, #cbd5e0)",
                      }}
                    >
                      {plugin.description}
                    </p>
                  )}
                  {isPending && (
                    <div
                      style={{
                        fontSize: "0.8rem",
                        color: "#ed8936",
                        marginBottom: "8px",
                      }}
                    >
                      Awaiting approval — disabled by default until approved.
                    </div>
                  )}
                  {isTampered && (
                    <div
                      style={{
                        fontSize: "0.8rem",
                        color: "#f56565",
                        marginBottom: "8px",
                      }}
                    >
                      Changed on disk since approval — quarantined and
                      disabled.
                    </div>
                  )}
                  {plugin.integrityHash && (
                    <div
                      style={{
                        fontSize: "0.75rem",
                        color: "var(--text-secondary, #a0aec0)",
                        display: "flex",
                        alignItems: "center",
                        gap: "6px",
                      }}
                    >
                      <span>SHA-256 Hash:</span>
                      <code style={{ fontSize: "0.72rem" }}>
                        {plugin.integrityHash.substring(0, 16)}...
                      </code>
                      {isTampered ? (
                        <span style={{ color: "#f56565" }}>
                          (MISMATCH DETECTED)
                        </span>
                      ) : (
                        <span style={{ color: "#48bb78" }}>✓ Verified</span>
                      )}
                    </div>
                  )}
                </div>

                <div className="builtin-tools-grid">
                  {plugin.tools.map((tool) => {
                    const override =
                      plugin.permissionOverrides[tool.name];
                    const effectiveLevel = override || tool.permissionLevel;
                    const isToggling = togglingToolNames.has(tool.name);
                    const pluginGated =
                      !plugin.isEnabled || isTampered || isPending;
                    return (
                      <article
                        key={tool.name}
                        className="builtin-tool-card"
                      >
                        <div className="builtin-tool-card-header">
                          <code
                            className="builtin-tool-name"
                            title={tool.name}
                          >
                            {tool.name}
                          </code>
                          <span className="builtin-tool-permission">
                            {effectiveLevel}
                          </span>
                        </div>
                        <p
                          className="builtin-tool-desc"
                          title={tool.description}
                        >
                          {tool.description}
                        </p>
                        {tool.description && (
                          <details className="builtin-tool-details">
                            <summary>Details</summary>
                            <p className="builtin-tool-details-body">
                              {tool.description}
                            </p>
                          </details>
                        )}
                        <div
                          style={{
                            display: "flex",
                            alignItems: "center",
                            gap: "6px",
                            marginTop: "8px",
                          }}
                        >
                          <span
                            style={{
                              fontSize: "0.75rem",
                              color: "var(--text-secondary, #a0aec0)",
                            }}
                          >
                            Permission:
                          </span>
                          <select
                            value={override || "default"}
                            onChange={(e) =>
                              handlePermissionChange(
                                plugin.id,
                                tool.name,
                                e.target.value
                              )
                            }
                            disabled={updatingPluginId === plugin.id}
                            className="input-field"
                          >
                            <option value="default">
                              Default ({tool.permissionLevel})
                            </option>
                            <option value="readOnly">readOnly</option>
                            <option value="requiresApproval">
                              requiresApproval
                            </option>
                          </select>
                        </div>
                        <div className="builtin-tool-footer">
                          <label
                            className="toggle-label tool-switch"
                            style={{
                              display: "flex",
                              alignItems: "center",
                              gap: "8px",
                              flexShrink: 0,
                              cursor: isToggling ? "wait" : "pointer",
                            }}
                          >
                            <input
                              type="checkbox"
                              role="switch"
                              className="tool-switch-input"
                              aria-label={`${tool.name} ${tool.isEnabled ? "Enabled" : "Disabled"}`}
                              aria-checked={tool.isEnabled}
                              checked={tool.isEnabled}
                              onChange={() => void handleToggleTool(tool)}
                              disabled={isToggling || pluginGated}
                              title={
                                pluginGated
                                  ? "Enable plugin first"
                                  : undefined
                              }
                            />
                            <span
                              className="tool-switch-track"
                              data-on={tool.isEnabled ? "true" : "false"}
                              aria-hidden="true"
                            >
                              <span className="tool-switch-thumb" />
                            </span>
                            <span className="tool-switch-state">
                              {isToggling
                                ? "Updating…"
                                : tool.isEnabled
                                  ? "Enabled"
                                  : "Disabled"}
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
    </>
  );
}
export default PluginsListSection;
