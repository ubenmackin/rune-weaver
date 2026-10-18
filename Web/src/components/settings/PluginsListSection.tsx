// Rune Weaver Dashboard — Installed Runes and external plugins list section.

import type { PluginSummary } from "../../api";
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
}

export function PluginsListSection({
  pluginsList,
  updatingPluginId,
  handleToggleEnable,
  setPendingUninstallPlugin,
  handlePermissionChange,
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
        <div style={{ display: "flex", flexDirection: "column", gap: "14px" }}>
          {pluginsList.map((plugin) => {
            const isPending = plugin.status === "discovered";
            const isTampered = plugin.status === "tampered";
            return (
              <div
                key={plugin.id}
                style={{
                  padding: "16px",
                  borderRadius: "8px",
                  backgroundColor: "var(--bg-card, #1e2533)",
                  border: isTampered
                    ? "1px solid rgba(245, 101, 101, 0.5)"
                    : isPending
                      ? "1px solid rgba(237, 137, 54, 0.5)"
                      : "1px solid var(--border-color, #2d3748)",
                }}
              >
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    alignItems: "flex-start",
                    marginBottom: "8px",
                    flexWrap: "wrap",
                    gap: "8px",
                  }}
                >
                  <div>
                    <div
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: "8px",
                        flexWrap: "wrap",
                      }}
                    >
                      <span style={{ fontWeight: 600, fontSize: "1.02rem" }}>
                        {plugin.name}
                      </span>
                      <span
                        style={{
                          fontSize: "0.75rem",
                          padding: "2px 6px",
                          borderRadius: "4px",
                          backgroundColor: "#2d3748",
                          color: "#a0aec0",
                        }}
                      >
                        v{plugin.version}
                      </span>
                      <span
                        style={{
                          fontSize: "0.75rem",
                          padding: "2px 6px",
                          borderRadius: "4px",
                          backgroundColor: "#2c3e50",
                          color: "#63b3ed",
                        }}
                      >
                        {plugin.runtime}
                      </span>

                      {plugin.isEnabled ? (
                        <span
                          style={{
                            fontSize: "0.75rem",
                            padding: "2px 8px",
                            borderRadius: "4px",
                            backgroundColor: "rgba(72, 187, 120, 0.2)",
                            color: "#48bb78",
                            fontWeight: 600,
                          }}
                        >
                          ENABLED
                        </span>
                      ) : isPending ? (
                        <span
                          style={{
                            fontSize: "0.75rem",
                            padding: "2px 8px",
                            borderRadius: "4px",
                            backgroundColor: "rgba(237, 137, 54, 0.2)",
                            color: "#ed8936",
                            fontWeight: 600,
                          }}
                        >
                          PENDING REVIEW
                        </span>
                      ) : isTampered ? (
                        <span
                          style={{
                            fontSize: "0.75rem",
                            padding: "2px 8px",
                            borderRadius: "4px",
                            backgroundColor: "rgba(245, 101, 101, 0.2)",
                            color: "#f56565",
                            fontWeight: 600,
                          }}
                        >
                          TAMPERED
                        </span>
                      ) : (
                        <span
                          style={{
                            fontSize: "0.75rem",
                            padding: "2px 8px",
                            borderRadius: "4px",
                            backgroundColor: "rgba(160, 174, 192, 0.2)",
                            color: "#a0aec0",
                          }}
                        >
                          DISABLED
                        </span>
                      )}
                    </div>
                    <div
                      style={{
                        fontSize: "0.8rem",
                        color: "var(--text-secondary, #a0aec0)",
                        marginTop: "3px",
                      }}
                    >
                      <code>{plugin.id}</code>{" "}
                      {plugin.author ? `• by ${plugin.author}` : ""}
                    </div>
                  </div>

                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: "8px",
                    }}
                  >
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

                {plugin.description && (
                  <p
                    style={{
                      margin: "4px 0 10px 0",
                      fontSize: "0.88rem",
                      color: "var(--text-secondary, #cbd5e0)",
                    }}
                  >
                    {plugin.description}
                  </p>
                )}

                {plugin.integrityHash && (
                  <div
                    style={{
                      fontSize: "0.75rem",
                      color: "var(--text-secondary, #a0aec0)",
                      marginBottom: "10px",
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

                <div
                  style={{
                    borderTop: "1px solid var(--border-color, #2d3748)",
                    paddingTop: "8px",
                  }}
                >
                  <div
                    style={{
                      fontSize: "0.75rem",
                      fontWeight: 600,
                      color: "var(--text-secondary, #a0aec0)",
                      marginBottom: "6px",
                      textTransform: "uppercase",
                    }}
                  >
                    Declared Tools ({plugin.tools.length})
                  </div>
                  <div
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: "6px",
                    }}
                  >
                    {plugin.tools.map((tool) => {
                      const override = plugin.permissionOverrides[tool.name];
                      return (
                        <div
                          key={tool.name}
                          style={{
                            display: "flex",
                            justifyContent: "space-between",
                            alignItems: "center",
                            padding: "6px 10px",
                            borderRadius: "6px",
                            backgroundColor: "var(--bg-secondary, #141822)",
                            fontSize: "0.85rem",
                            flexWrap: "wrap",
                            gap: "8px",
                          }}
                        >
                          <div>
                            <code
                              style={{ fontWeight: 600, color: "#63b3ed" }}
                            >
                              {tool.name}
                            </code>
                            {tool.description && (
                              <span
                                style={{
                                  fontSize: "0.75rem",
                                  color: "var(--text-secondary, #a0aec0)",
                                  marginLeft: "6px",
                                }}
                              >
                                ({tool.description})
                              </span>
                            )}
                          </div>

                          <div
                            style={{
                              display: "flex",
                              alignItems: "center",
                              gap: "6px",
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
                              style={{
                                fontSize: "0.78rem",
                                padding: "2px 6px",
                                borderRadius: "4px",
                                backgroundColor: "var(--bg-card, #1e2533)",
                                color: "inherit",
                                border: "1px solid var(--border-color, #2d3748)",
                              }}
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
                        </div>
                      );
                    })}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
export default PluginsListSection;
