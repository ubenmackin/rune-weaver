// Rune Weaver Dashboard — Settings navigation drawer with Mac-like find-and-highlight.

import {
  ApprovalsIcon,
  BellIcon,
  ChatIcon,
  KeyIcon,
  MailIcon,
  MemoryIcon,
  MicIcon,
  SearchIcon,
  SettingsIcon,
  TargetIcon,
  UserIcon,
  WrenchIcon,
} from "../icons";
import type { SettingsTab } from "./settingsTypes";
import {
  highlightSettingTargetWhenReady,
  searchSettingsItems,
  type SettingsSearchItem,
} from "./settingsSearchIndex";

interface SettingsSidenavProps {
  settingsMenuOpen: boolean;
  activeTab: SettingsTab;
  settingsNavQuery: string;
  onSearchChange: (query: string) => void;
  onSelectTab: (tab: SettingsTab) => void;
  onBackdropClick: () => void;
  pendingCount: number;
  tamperedCount: number;
  serverRestartVisible: boolean;
}

// Single source for tab labels shared by the rail buttons and the item
// result rows below, so a rename lands in both without a second copy.
const SETTINGS_TAB_LABELS: Record<SettingsTab, string> = {
  access: "Access",
  providers: "LLM Providers",
  persona: "Persona",
  voice: "Voice",
  memory: "Memory and Storage",
  goals: "Goals",
  tools: "Tools and Runes",
  indexing: "Indexing",
  search: "Web",
  email: "Email Accounts",
  security: "Security",
  network: "Network",
  engine: "Engine and Logs",
  notifications: "Notifications",
};

export default function SettingsSidenav({
  settingsMenuOpen,
  activeTab,
  settingsNavQuery,
  onSearchChange,
  onSelectTab,
  onBackdropClick,
  pendingCount,
  tamperedCount,
  serverRestartVisible,
}: SettingsSidenavProps) {
  const isSearching = settingsNavQuery.trim().length > 0;
  const searchResults = isSearching
    ? searchSettingsItems(settingsNavQuery)
    : [];
  const showEmpty = isSearching && searchResults.length === 0;

  const handleSearchResultSelect = (item: SettingsSearchItem) => {
    onSelectTab(item.tab);
    onSearchChange("");
    // The newly selected pane commits asynchronously; the bounded poll
    // highlights once it mounts instead of racing the commit.
    highlightSettingTargetWhenReady(item.targetId);
  };

  return (
    <>
      {settingsMenuOpen ? (
        <button
          type="button"
          className="settings-backdrop"
          data-testid="settings-backdrop"
          aria-label="Close settings menu"
          onClick={onBackdropClick}
        />
      ) : null}
      <div className={`settings-nav-column${settingsMenuOpen ? " open" : ""}`}>
        <div className="settings-nav-search-wrapper">
          <SearchIcon size={14} className="settings-nav-search-icon" />
          <input
            type="search"
            className="settings-nav-search-input"
            data-testid="settings-nav-search"
            aria-label="Search settings"
            placeholder="Search settings…"
            value={settingsNavQuery}
            onChange={(e) => onSearchChange(e.target.value)}
          />
        </div>
        {isSearching ? (
          <div
            className="settings-sidenav settings-search-results"
            role="listbox"
            aria-label="Matching settings"
            data-testid="settings-search-results"
          >
            {searchResults.map((item) => (
              <button
                key={item.id}
                type="button"
                role="option"
                aria-selected={false}
                className="settings-tab-btn settings-search-result"
                data-testid={`settings-search-result-${item.id}`}
                onClick={() => handleSearchResultSelect(item)}
              >
                <span>{item.label}</span>
                <span className="settings-search-result-tab">
                  {SETTINGS_TAB_LABELS[item.tab]}
                </span>
              </button>
            ))}
            {showEmpty ? (
              <p
                className="muted text-sm settings-nav-empty"
                data-testid="settings-nav-empty"
              >
                No settings match.
              </p>
            ) : null}
          </div>
        ) : (
          <nav
            className="settings-sidenav"
            aria-label="Settings categories"
            role="tablist"
          >
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "access"}
              className={`settings-tab-btn ${activeTab === "access" ? "active" : ""}`}
              onClick={() => onSelectTab("access")}
            >
              <KeyIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.access}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "providers"}
              className={`settings-tab-btn ${activeTab === "providers" ? "active" : ""}`}
              onClick={() => onSelectTab("providers")}
            >
              <ChatIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.providers}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "persona"}
              className={`settings-tab-btn ${activeTab === "persona" ? "active" : ""}`}
              onClick={() => onSelectTab("persona")}
            >
              <UserIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.persona}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "voice"}
              className={`settings-tab-btn ${activeTab === "voice" ? "active" : ""}`}
              onClick={() => onSelectTab("voice")}
            >
              <MicIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.voice}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "memory"}
              className={`settings-tab-btn ${activeTab === "memory" ? "active" : ""}`}
              onClick={() => onSelectTab("memory")}
            >
              <MemoryIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.memory}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "goals"}
              className={`settings-tab-btn ${activeTab === "goals" ? "active" : ""}`}
              onClick={() => onSelectTab("goals")}
            >
              <TargetIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.goals}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "tools"}
              className={`settings-tab-btn ${activeTab === "tools" ? "active" : ""}`}
              onClick={() => onSelectTab("tools")}
            >
              <WrenchIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.tools}</span>
              {pendingCount > 0 && (
                <span
                  className="settings-tab-badge settings-tab-badge--amber"
                  title={`${pendingCount} runes pending human review`}
                >
                  {pendingCount}
                </span>
              )}
              {tamperedCount > 0 && (
                <span
                  className="settings-tab-badge settings-tab-badge--red"
                  title={`${tamperedCount} runes modified since approval`}
                >
                  {tamperedCount}
                </span>
              )}
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "indexing"}
              className={`settings-tab-btn ${activeTab === "indexing" ? "active" : ""}`}
              onClick={() => onSelectTab("indexing")}
            >
              <MemoryIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.indexing}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "search"}
              className={`settings-tab-btn ${activeTab === "search" ? "active" : ""}`}
              onClick={() => onSelectTab("search")}
            >
              <SearchIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.search}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "email"}
              className={`settings-tab-btn ${activeTab === "email" ? "active" : ""}`}
              onClick={() => onSelectTab("email")}
            >
              <MailIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.email}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "security"}
              className={`settings-tab-btn ${activeTab === "security" ? "active" : ""}`}
              onClick={() => onSelectTab("security")}
            >
              <ApprovalsIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.security}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "network"}
              className={`settings-tab-btn ${activeTab === "network" ? "active" : ""}`}
              onClick={() => onSelectTab("network")}
            >
              <SettingsIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.network}</span>
              {serverRestartVisible ? (
                <span
                  className="settings-tab-badge settings-tab-badge--amber"
                  title="Network changes need a restart"
                >
                  !
                </span>
              ) : null}
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "engine"}
              className={`settings-tab-btn ${activeTab === "engine" ? "active" : ""}`}
              onClick={() => onSelectTab("engine")}
            >
              <SettingsIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.engine}</span>
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "notifications"}
              className={`settings-tab-btn ${activeTab === "notifications" ? "active" : ""}`}
              onClick={() => onSelectTab("notifications")}
            >
              <BellIcon size={16} />
              <span>{SETTINGS_TAB_LABELS.notifications}</span>
            </button>
          </nav>
        )}
      </div>
    </>
  );
}
