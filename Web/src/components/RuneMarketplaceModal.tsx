// Rune Weaver Dashboard — Community Rune Marketplace Modal.

import { useEffect, useState } from "react";
import {
  getMarketplacePlugins,
  installMarketplacePlugin,
  type MarketplacePluginItem,
} from "../api";
import Modal from "./Modal";
import { AlertTriangleIcon, CheckIcon, CloseIcon, RefreshIcon, SearchIcon, WrenchIcon } from "./icons";

interface RuneMarketplaceModalProps {
  isOpen: boolean;
  onClose: () => void;
  onPluginInstalled: () => void;
}

export default function RuneMarketplaceModal({
  isOpen,
  onClose,
  onPluginInstalled,
}: RuneMarketplaceModalProps) {
  const [items, setItems] = useState<MarketplacePluginItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [installingId, setInstallingId] = useState<string | null>(null);
  const [installedNotice, setInstalledNotice] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen) {
      loadMarketplace();
    }
  }, [isOpen]);

  async function loadMarketplace() {
    setLoading(true);
    setError(null);
    try {
      const response = await getMarketplacePlugins();
      setItems(response.items);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load marketplace index.");
    } finally {
      setLoading(false);
    }
  }

  async function handleInstall(item: MarketplacePluginItem) {
    setInstallingId(item.id);
    setError(null);
    try {
      // The catalog URL travels as display provenance only: the service validates its https shape
      // and scaffolds a disabled-by-default stub from the curated catalog without fetching remote
      // content, so every 1-click install lands quarantined for human review before enablement.
      await installMarketplacePlugin({
        id: item.id,
        downloadURL: item.downloadURL,
      });
      setInstalledNotice(
        `Installed '${item.name}'! In accordance with security policy, it has been placed in the disabled holding pen. Review and enable it in Tools & Runes.`
      );
      // Update local state
      setItems((prev) =>
        prev.map((it) => (it.id === item.id ? { ...it, isInstalled: true } : it))
      );
      onPluginInstalled();
    } catch (err) {
      setError(err instanceof Error ? err.message : `Failed to install '${item.name}'.`);
    } finally {
      setInstallingId(null);
    }
  }

  if (!isOpen) return null;

  const filteredItems = items.filter((item) => {
    if (!searchQuery.trim()) return true;
    const query = searchQuery.toLowerCase();
    return (
      item.name.toLowerCase().includes(query) ||
      item.description.toLowerCase().includes(query) ||
      item.tags.some((t) => t.toLowerCase().includes(query)) ||
      item.declaredTools.some((t) => t.toLowerCase().includes(query))
    );
  });

  return (
    <Modal label="Rune Marketplace" onClose={onClose} containerClassName="modal-container marketplace-modal">
      <div className="modal-header">
        <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
          <WrenchIcon size={20} className="header-icon" />
          <h3 style={{ margin: 0 }}>Community Rune Marketplace</h3>
        </div>
        <button
          type="button"
          className="btn-icon"
          onClick={onClose}
          aria-label="Close marketplace"
        >
          <CloseIcon size={16} />
        </button>
      </div>

      <div className="modal-body" style={{ maxHeight: "70vh", overflowY: "auto" }}>
        <p style={{ margin: "0 0 12px 0", color: "var(--text-secondary, #a0aec0)", fontSize: "0.9rem" }}>
          Browse and install community runes to extend Rune Weaver's capabilities.
          All installed runes are quarantined in a <strong>disabled state by default</strong> until you review and enable them.
        </p>

        {installedNotice && (
          <div
            style={{
              padding: "10px 14px",
              backgroundColor: "rgba(72, 187, 120, 0.15)",
              border: "1px solid rgba(72, 187, 120, 0.4)",
              borderRadius: "6px",
              color: "#48bb78",
              marginBottom: "14px",
              fontSize: "0.88rem",
              display: "flex",
              alignItems: "center",
              gap: "8px",
            }}
          >
            <CheckIcon size={16} />
            <span>{installedNotice}</span>
          </div>
        )}

        {error && (
          <div
            style={{
              padding: "10px 14px",
              backgroundColor: "rgba(245, 101, 101, 0.15)",
              border: "1px solid rgba(245, 101, 101, 0.4)",
              borderRadius: "6px",
              color: "#f56565",
              marginBottom: "14px",
              fontSize: "0.88rem",
              display: "flex",
              alignItems: "center",
              gap: "8px",
            }}
          >
            <AlertTriangleIcon size={16} />
            <span>{error}</span>
          </div>
        )}

        <div style={{ display: "flex", gap: "10px", marginBottom: "16px" }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              flex: 1,
              backgroundColor: "var(--bg-secondary, #1a202c)",
              border: "1px solid var(--border-color, #2d3748)",
              borderRadius: "6px",
              padding: "6px 10px",
            }}
          >
            <SearchIcon size={16} style={{ color: "var(--text-secondary, #a0aec0)", marginRight: "8px" }} />
            <input
              type="text"
              placeholder="Search runes by name, description, tags, or tools..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              style={{
                background: "transparent",
                border: "none",
                outline: "none",
                color: "inherit",
                width: "100%",
                fontSize: "0.9rem",
              }}
            />
          </div>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={loadMarketplace}
            disabled={loading}
            style={{ display: "flex", alignItems: "center", gap: "6px" }}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>Refresh</span>
          </button>
        </div>

        {loading && items.length === 0 ? (
          <div style={{ textAlign: "center", padding: "30px", color: "var(--text-secondary, #a0aec0)" }}>
            Loading community marketplace catalog...
          </div>
        ) : filteredItems.length === 0 ? (
          <div style={{ textAlign: "center", padding: "30px", color: "var(--text-secondary, #a0aec0)" }}>
            No community runes found matching your search.
          </div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: "12px" }}>
            {filteredItems.map((item) => (
              <div
                key={item.id}
                style={{
                  padding: "14px 16px",
                  borderRadius: "8px",
                  backgroundColor: "var(--bg-card, #202634)",
                  border: "1px solid var(--border-color, #2d3748)",
                  display: "flex",
                  flexDirection: "column",
                  gap: "8px",
                }}
              >
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
                  <div>
                    <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                      <span style={{ fontWeight: 600, fontSize: "1rem" }}>{item.name}</span>
                      <span style={{ fontSize: "0.75rem", padding: "2px 6px", borderRadius: "4px", backgroundColor: "#2d3748", color: "#a0aec0" }}>
                        v{item.version}
                      </span>
                      <span style={{ fontSize: "0.75rem", padding: "2px 6px", borderRadius: "4px", backgroundColor: "#2c3e50", color: "#63b3ed" }}>
                        {item.runtime}
                      </span>
                    </div>
                    <div style={{ fontSize: "0.8rem", color: "var(--text-secondary, #a0aec0)", marginTop: "2px" }}>
                      by {item.author} &bull; <code style={{ fontSize: "0.75rem" }}>{item.id}</code>
                    </div>
                  </div>

                  {item.isInstalled ? (
                    <button
                      type="button"
                      className="btn"
                      disabled
                      style={{
                        backgroundColor: "rgba(72, 187, 120, 0.15)",
                        color: "#48bb78",
                        border: "1px solid rgba(72, 187, 120, 0.3)",
                        display: "flex",
                        alignItems: "center",
                        gap: "6px",
                        padding: "6px 12px",
                      }}
                    >
                      <CheckIcon size={14} />
                      <span>Installed</span>
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="primary"
                      onClick={() => handleInstall(item)}
                      disabled={installingId === item.id}
                      style={{ padding: "6px 14px" }}
                    >
                      {installingId === item.id ? "Installing..." : "Install"}
                    </button>
                  )}
                </div>

                <p style={{ margin: "4px 0 0 0", fontSize: "0.88rem", color: "var(--text-primary, #e2e8f0)", lineHeight: "1.4" }}>
                  {item.description}
                </p>

                <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: "6px", marginTop: "4px" }}>
                  <span style={{ fontSize: "0.75rem", color: "var(--text-secondary, #a0aec0)" }}>Tools:</span>
                  {item.declaredTools.map((tool) => (
                    <span
                      key={tool}
                      style={{
                        fontSize: "0.75rem",
                        padding: "1px 6px",
                        borderRadius: "4px",
                        backgroundColor: "rgba(237, 137, 54, 0.15)",
                        color: "#ed8936",
                        border: "1px solid rgba(237, 137, 54, 0.3)",
                      }}
                    >
                      {tool}
                    </span>
                  ))}
                  {item.tags.map((tag) => (
                    <span
                      key={tag}
                      style={{
                        fontSize: "0.75rem",
                        padding: "1px 6px",
                        borderRadius: "4px",
                        backgroundColor: "var(--bg-secondary, #1a202c)",
                        color: "#a0aec0",
                      }}
                    >
                      #{tag}
                    </span>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="modal-footer" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn btn-secondary" onClick={onClose}>
          Close
        </button>
      </div>
    </Modal>
  );
}
