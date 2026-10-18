// Rune Weaver Dashboard — Settings navigation drawer and vertical category tabs list.

import {
  ApprovalsIcon,
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
import {
  matchesSettingsTab,
  SETTINGS_TABS,
  type SettingsTab,
} from "./settingsTypes";

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
  const settingsNavFilter = settingsNavQuery.trim().toLowerCase();
  const navTabVisible = (tab: SettingsTab) =>
    activeTab === tab || matchesSettingsTab(tab, settingsNavFilter);

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
            aria-label="Search settings sections"
            placeholder="Search settings sections…"
            value={settingsNavQuery}
            onChange={(e) => onSearchChange(e.target.value)}
          />
        </div>
        <nav
          className="settings-sidenav"
          aria-label="Settings categories"
          role="tablist"
        >
          {navTabVisible("access") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "access"}
              className={`settings-tab-btn ${activeTab === "access" ? "active" : ""}`}
              onClick={() => onSelectTab("access")}
            >
              <KeyIcon size={16} />
              <span>Access</span>
            </button>
          ) : null}

          {navTabVisible("providers") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "providers"}
              className={`settings-tab-btn ${activeTab === "providers" ? "active" : ""}`}
              onClick={() => onSelectTab("providers")}
            >
              <ChatIcon size={16} />
              <span>LLM Providers</span>
            </button>
          ) : null}

          {navTabVisible("persona") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "persona"}
              className={`settings-tab-btn ${activeTab === "persona" ? "active" : ""}`}
              onClick={() => onSelectTab("persona")}
            >
              <UserIcon size={16} />
              <span>Persona</span>
            </button>
          ) : null}

          {navTabVisible("voice") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "voice"}
              className={`settings-tab-btn ${activeTab === "voice" ? "active" : ""}`}
              onClick={() => onSelectTab("voice")}
            >
              <MicIcon size={16} />
              <span>Voice</span>
            </button>
          ) : null}

          {navTabVisible("memory") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "memory"}
              className={`settings-tab-btn ${activeTab === "memory" ? "active" : ""}`}
              onClick={() => onSelectTab("memory")}
            >
              <MemoryIcon size={16} />
              <span>Memory and Storage</span>
            </button>
          ) : null}

          {navTabVisible("goals") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "goals"}
              className={`settings-tab-btn ${activeTab === "goals" ? "active" : ""}`}
              onClick={() => onSelectTab("goals")}
            >
              <TargetIcon size={16} />
              <span>Goals</span>
            </button>
          ) : null}

          {navTabVisible("tools") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "tools"}
              className={`settings-tab-btn ${activeTab === "tools" ? "active" : ""}`}
              onClick={() => onSelectTab("tools")}
            >
              <WrenchIcon size={16} />
              <span>Tools and Runes</span>
              {pendingCount > 0 && (
                <span
                  className="settings-tab-badge"
                  style={{ backgroundColor: "#ed8936", color: "#ffffff" }}
                  title={`${pendingCount} runes pending human review`}
                >
                  {pendingCount}
                </span>
              )}
              {tamperedCount > 0 && (
                <span
                  className="settings-tab-badge"
                  style={{ backgroundColor: "#f56565", color: "#ffffff" }}
                  title={`${tamperedCount} runes modified since approval`}
                >
                  {tamperedCount}
                </span>
              )}
            </button>
          ) : null}

          {navTabVisible("indexing") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "indexing"}
              className={`settings-tab-btn ${activeTab === "indexing" ? "active" : ""}`}
              onClick={() => onSelectTab("indexing")}
            >
              <MemoryIcon size={16} />
              <span>Indexing</span>
            </button>
          ) : null}

          {navTabVisible("search") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "search"}
              className={`settings-tab-btn ${activeTab === "search" ? "active" : ""}`}
              onClick={() => onSelectTab("search")}
            >
              <SearchIcon size={16} />
              <span>Web</span>
            </button>
          ) : null}

          {navTabVisible("email") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "email"}
              className={`settings-tab-btn ${activeTab === "email" ? "active" : ""}`}
              onClick={() => onSelectTab("email")}
            >
              <MailIcon size={16} />
              <span>Email Accounts</span>
            </button>
          ) : null}

          {navTabVisible("security") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "security"}
              className={`settings-tab-btn ${activeTab === "security" ? "active" : ""}`}
              onClick={() => onSelectTab("security")}
            >
              <ApprovalsIcon size={16} />
              <span>Security</span>
            </button>
          ) : null}

          {navTabVisible("network") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "network"}
              className={`settings-tab-btn ${activeTab === "network" ? "active" : ""}`}
              onClick={() => onSelectTab("network")}
            >
              <SettingsIcon size={16} />
              <span>Network</span>
              {serverRestartVisible ? (
                <span
                  className="settings-tab-badge"
                  style={{ backgroundColor: "#ed8936", color: "#ffffff" }}
                  title="Network changes need a restart"
                >
                  !
                </span>
              ) : null}
            </button>
          ) : null}

          {navTabVisible("engine") ? (
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === "engine"}
              className={`settings-tab-btn ${activeTab === "engine" ? "active" : ""}`}
              onClick={() => onSelectTab("engine")}
            >
              <SettingsIcon size={16} />
              <span>Engine and Logs</span>
            </button>
          ) : null}

          {settingsNavFilter &&
          SETTINGS_TABS.every((tab) => !matchesSettingsTab(tab, settingsNavFilter)) ? (
            <p className="muted text-sm" data-testid="settings-nav-empty" style={{ padding: "8px 6px", margin: 0 }}>
              No settings sections match.
            </p>
          ) : null}
        </nav>
      </div>
    </>
  );
}
