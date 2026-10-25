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
        <div className="rune-marketplace-header-row">
          <WrenchIcon size={20} className="header-icon" />
          <h3>Community Rune Marketplace</h3>
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

      <div className="modal-body rune-marketplace-body">
        <p className="rune-marketplace-intro text-sm">
          Browse and install community runes to extend Rune Weaver's capabilities.
          All installed runes are quarantined in a <strong>disabled state by default</strong> until you review and enable them.
        </p>

        {installedNotice && (
          <div className="rune-marketplace-success text-sm">
            <CheckIcon size={16} />
            <span>{installedNotice}</span>
          </div>
        )}

        {error && (
          <div className="rune-marketplace-error text-sm">
            <AlertTriangleIcon size={16} />
            <span>{error}</span>
          </div>
        )}

        <div className="rune-marketplace-search-row">
          <div className="rune-marketplace-search-box">
            <SearchIcon size={16} className="rune-marketplace-search-icon" />
            <input
              type="text"
              placeholder="Search runes by name, description, tags, or tools..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="rune-marketplace-search-input text-sm"
            />
          </div>
          <button
            type="button"
            className="btn btn-secondary rune-marketplace-refresh-btn"
            onClick={loadMarketplace}
            disabled={loading}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>Refresh</span>
          </button>
        </div>

        {loading && items.length === 0 ? (
          <div className="rune-marketplace-empty text-sm">
            Loading community marketplace catalog...
          </div>
        ) : filteredItems.length === 0 ? (
          <div className="rune-marketplace-empty text-sm">
            No community runes found matching your search.
          </div>
        ) : (
          <div className="rune-marketplace-list">
            {filteredItems.map((item) => (
              <div key={item.id} className="rune-marketplace-card">
                <div className="rune-marketplace-card-top">
                  <div>
                    <div className="rune-marketplace-card-identity">
                      <span className="rune-marketplace-name">{item.name}</span>
                      <span className="rune-marketplace-version-badge text-xs">
                        v{item.version}
                      </span>
                      <span className="rune-marketplace-runtime-badge text-xs">
                        {item.runtime}
                      </span>
                    </div>
                    <div className="rune-marketplace-meta rune-marketplace-byline text-sm">
                      by {item.author} &bull; <code className="text-xs">{item.id}</code>
                    </div>
                  </div>

                  {item.isInstalled ? (
                    <button
                      type="button"
                      className="btn rune-marketplace-installed-btn"
                      disabled
                    >
                      <CheckIcon size={14} />
                      <span>Installed</span>
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="primary rune-marketplace-install-btn"
                      onClick={() => handleInstall(item)}
                      disabled={installingId === item.id}
                    >
                      {installingId === item.id ? "Installing..." : "Install"}
                    </button>
                  )}
                </div>

                <p className="rune-marketplace-description text-sm">{item.description}</p>

                <div className="rune-marketplace-tags-row">
                  <span className="rune-marketplace-tools-label text-xs">Tools:</span>
                  {item.declaredTools.map((tool) => (
                    <span key={tool} className="rune-marketplace-tool-chip text-xs">
                      {tool}
                    </span>
                  ))}
                  {item.tags.map((tag) => (
                    <span key={tag} className="rune-marketplace-tag-chip text-xs">
                      #{tag}
                    </span>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="modal-footer">
        <button type="button" className="btn btn-secondary" onClick={onClose}>
          Close
        </button>
      </div>
    </Modal>
  );
}
