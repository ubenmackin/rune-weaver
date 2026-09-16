// Rune Weaver Dashboard — Top navigation bar for section switching and service status.
// Keeps primary tabs focused on operational views while the profile dropdown surfaces
// Settings plus live engine health, so configuration stays reachable without crowding chat.
import React, { useState, useEffect, useRef, useCallback } from "react";
import type { HealthResponse } from "../api";
import {
  DEFAULT_SEARCH_SEARXNG_URL,
  ensureSearch,
  getSearchHealth,
  resolveSearchMessage,
  resolveSearchURL,
  stopSearch,
} from "../api";
import {
  ApprovalsIcon,
  BellIcon,
  ChatIcon,
  ChevronDownIcon,
  MemoryIcon,
  RuneGlyph,
  RunsIcon,
  SchedulesIcon,
  SearchIcon,
  SettingsIcon,
  StopIcon,
  UserIcon,
} from "./icons";

export type Tab = "chat" | "approvals" | "memory" | "runs" | "schedules" | "settings";

interface NavItemConfig {
  id: Tab;
  label: string;
  icon: React.ComponentType<{ size?: number; className?: string }>;
  badge?: number;
}

interface TopNavProps {
  currentTab: Tab;
  onSelectTab: (tab: Tab) => void;
  health: HealthResponse | null;
  runsBadge?: number;
  approvalsBadge?: number;
  notificationsEnabled: boolean;
  onRequestNotifications: () => void;
}

export default function TopNav({
  currentTab,
  onSelectTab,
  health,
  runsBadge = 0,
  approvalsBadge = 0,
  notificationsEnabled,
  onRequestNotifications,
}: TopNavProps) {
  const [profileOpen, setProfileOpen] = useState(false);
  const profileRef = useRef<HTMLDivElement>(null);
  const profileButtonRef = useRef<HTMLButtonElement>(null);
  // Live SearXNG state from explicit Start/Stop actions or a fallback probe. The /health payload
  // carries search fields on newer engines, so this local copy only overrides when the user acts or
  // when the engine predates those fields and a direct probe succeeds.
  const [searchHealth, setSearchHealth] = useState<{
    reachable: boolean;
    url: string;
  } | null>(null);
  // One in-flight slot names the running side so Start and Stop stay mutually
  // exclusive while the toggle label stays honest (Starting… vs Stopping…).
  const [searchBusyAction, setSearchBusyAction] = useState<"start" | "stop" | null>(
    null
  );
  const [searchError, setSearchError] = useState<string | null>(null);

  // Tri-state reachability: an explicit Start/Stop result wins, then the /health payload, otherwise
  // unknown. Unknown renders as a gray Unknown row (never red Stopped) so older engines without
  // search fields stay honest instead of claiming the container is down.
  const searchReachable: boolean | null =
    searchHealth?.reachable ?? health?.searchReachable ?? null;
  const searchKnown = searchReachable !== null;
  const searchRunning = searchReachable === true;
  const searchURL =
    resolveSearchURL(searchHealth, "") ||
    health?.searchURL ||
    DEFAULT_SEARCH_SEARXNG_URL;

  const navItems: NavItemConfig[] = [
    { id: "chat", label: "Chat", icon: ChatIcon },
    { id: "approvals", label: "Approvals", icon: ApprovalsIcon, badge: approvalsBadge },
    { id: "memory", label: "Memory", icon: MemoryIcon },
    { id: "runs", label: "Runs", icon: RunsIcon, badge: runsBadge },
    { id: "schedules", label: "Schedules", icon: SchedulesIcon },
  ];

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      // `event.target` can be null (or a non-Node in synthetic flows), so
      // guard with `instanceof Node` before probing containment instead of
      // an unchecked cast.
      const target = event.target;
      if (
        target instanceof Node &&
        profileRef.current &&
        !profileRef.current.contains(target)
      ) {
        setProfileOpen(false);
      }
    };
    if (profileOpen) {
      document.addEventListener("mousedown", handleClickOutside);
    }
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, [profileOpen]);

  // Escape closes the profile menu and returns focus to the trigger so
  // keyboard users never lose place. The menu is click/keyboard driven with
  // no hover-open path, removing the hover-plus-click toggle race.
  useEffect(() => {
    if (!profileOpen) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        setProfileOpen(false);
        profileButtonRef.current?.focus();
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [profileOpen]);

  // Click toggles the profile menu directly. Keyboard (Enter/Space) activates
  // the same toggle through the native button behavior.
  const handleProfileClick = useCallback(() => {
    setProfileOpen((prev) => !prev);
  }, []);

  // One-shot fallback probe for engines that predate search fields on /health. Runs only when the
  // menu opens with no health search data and no local override, so newer engines and explicit
  // Start/Stop results are never clobbered by a background fetch.
  useEffect(() => {
    if (!profileOpen) return;
    if (health?.searchReachable !== undefined) return;
    if (health?.searchURL !== undefined) return;
    if (searchHealth !== null) return;
    let cancelled = false;
    getSearchHealth()
      .then((response) => {
        if (cancelled) return;
        // Empty or shape-drifted payloads (e.g. {}) carry no reachable flag:
        // keep unknown gray instead of coercing missing to false red Stopped.
        if (typeof response?.reachable !== "boolean") return;
        setSearchHealth({
          reachable: response.reachable,
          url: resolveSearchURL(response, DEFAULT_SEARCH_SEARXNG_URL),
        });
        setSearchError(null);
      })
      .catch(() => {
        // Unknown stays unknown (gray) on probe failure, including 404 from
        // engines without search routes; the menu stays usable and the
        // Settings search pane surfaces the same failure with detail.
        if (!cancelled) setSearchError(null);
      });
    return () => {
      cancelled = true;
    };
  }, [profileOpen, health?.searchReachable, health?.searchURL, searchHealth]);

  // Toggles the SearXNG container through the engine service. The result becomes the local override
  // only on an honest boolean reachable flag; shape-drifted payloads keep the previous dot and
  // surface an inline error instead of optimistically flipping. A failed start (reachable false
  // after ensure) renders the cascade message in the existing error slot instead of flipping
  // silently to red; a failed stop (still reachable) does the same. Failures keep the menu open.
  const handleToggleSearch = useCallback(async () => {
    if (searchBusyAction !== null) return;
    // Capture whether this action is a start so the error slot can tell a
    // failed start (unreachable) apart from a clean stop (unreachable by design),
    // and so the busy label names the in-flight action instead of always claiming Start.
    const wasStarting = !searchRunning;
    setSearchBusyAction(wasStarting ? "start" : "stop");
    setSearchError(null);
    try {
      const response = searchRunning
        ? await stopSearch()
        : await ensureSearch();
      // Honest tri-state: only a boolean reachable flag may move the dot, matching the
      // fallback probe guard above; anything else keeps previous state.
      if (typeof response?.reachable === "boolean") {
        setSearchHealth({
          reachable: response.reachable,
          url: resolveSearchURL(response, searchURL),
        });
        const detail = resolveSearchMessage(response);
        if (wasStarting && !response.reachable) {
          // Failed start: surface the cascade detail (stage, exit, tail, timeout).
          setSearchError(detail ?? "Search start failed; status unchanged.");
        } else if (!wasStarting && response.reachable) {
          // Failed stop: the engine still answers, so the message explains why.
          setSearchError(detail ?? "Search stop failed; still reachable.");
        }
      } else {
        setSearchError("Search toggle returned an unexpected response; status unchanged.");
      }
    } catch (error) {
      setSearchError(
        error instanceof Error ? error.message : "Search toggle failed"
      );
    } finally {
      setSearchBusyAction(null);
    }
  }, [searchBusyAction, searchRunning, searchURL]);

  return (
    <header className="top-nav" aria-label="Main navigation">
      <div className="top-nav-brand">
        <RuneGlyph size={24} className="rune-glyph-icon" />
        <span className="app-brand-title">RUNE WEAVER</span>
        <span className="top-nav-divider">|</span>
        <span className="top-nav-subtitle">Personal AI Agent</span>
      </div>

      <nav className="top-nav-links" aria-label="Dashboard sections">
        {navItems.map((item) => {
          const Icon = item.icon;
          const isActive = currentTab === item.id;
          return (
            <button
              key={item.id}
              type="button"
              className={`top-nav-item ${isActive ? "active" : ""}`}
              onClick={() => onSelectTab(item.id)}
              aria-selected={isActive}
            >
              <Icon size={16} className="nav-item-icon" />
              <span>{item.label}</span>
              {item.badge && item.badge > 0 ? (
                <span className="nav-badge" aria-label={`${item.badge} unread`}>
                  {item.badge > 99 ? "99+" : item.badge}
                </span>
              ) : null}
            </button>
          );
        })}
      </nav>

      <div className="top-nav-right">
        <button
          type="button"
          className={`icon-button ${notificationsEnabled ? "active" : ""}`}
          title={
            notificationsEnabled
              ? "Web notifications enabled"
              : "Enable browser notifications"
          }
          onClick={onRequestNotifications}
          aria-label="Browser notifications"
        >
          <BellIcon size={16} />
        </button>

        {/* Profile Dropdown: click/keyboard driven with Escape to close and
            focus return. No hover-open path so pointer and keyboard orderings
            toggle deterministically. */}
        <div
          ref={profileRef}
          className="profile-dropdown-container"
        >
          <button
            type="button"
            ref={profileButtonRef}
            onClick={handleProfileClick}
            className={`profile-dropdown-btn ${profileOpen ? "open" : ""} ${
              currentTab === "settings" ? "settings-active" : ""
            }`}
            aria-expanded={profileOpen}
            aria-haspopup="menu"
            aria-controls="profile-menu"
            aria-label="Profile and Settings menu"
          >
            <UserIcon size={16} className="profile-user-icon" />
            <span className="status-dot" />
            <span className="profile-btn-label">Profile</span>
            <ChevronDownIcon
              size={13}
              className={`dropdown-chevron ${profileOpen ? "rotate-180" : ""}`}
            />
          </button>

          {profileOpen && (
            <div
              id="profile-menu"
              className="profile-dropdown-menu"
              role="menu"
              aria-label="Profile and Settings"
            >
              <div className="profile-menu-header">
                <div className="profile-header-user">
                  <div className="profile-avatar">
                    <UserIcon size={16} />
                  </div>
                  <div className="profile-header-details">
                    <span className="profile-name">Rune Weaver Agent</span>
                    <span className="profile-status-text">
                      <span className="status-dot-sm" /> Connected
                    </span>
                  </div>
                </div>
              </div>

              <div className="profile-menu-section">
                <div className="profile-info-row">
                  <span className="info-label">Model</span>
                  <span className="info-value" title={health?.model ?? "None"}>
                    {health?.model || "None configured"}
                  </span>
                </div>
                <div className="profile-info-row">
                  <span className="info-label">Provider</span>
                  <span className="info-value" title={health?.provider ?? "None"}>
                    {health?.provider || "Default"}
                  </span>
                </div>
                {/* SearXNG health sits beside Model and Provider so search status is visible
                    without opening Settings. */}
                <div
                  className="profile-info-row"
                  title={`SearXNG at ${searchURL} (${searchKnown ? (searchRunning ? "reachable" : "stopped") : "unknown"})`}
                >
                  <span className="info-label">SearXNG</span>
                  <span
                    className="info-value"
                    style={{
                      display: "inline-flex",
                      alignItems: "center",
                      gap: "6px",
                    }}
                  >
                    <span
                      data-testid="searxng-status-dot"
                      aria-label={
                        !searchKnown
                          ? "SearXNG status unknown"
                          : searchRunning
                            ? "SearXNG reachable"
                            : "SearXNG stopped"
                      }
                      title={`SearXNG at ${searchURL}`}
                      className="status-dot-sm"
                      style={{
                        backgroundColor: !searchKnown
                          ? "#a0aec0"
                          : searchRunning
                            ? "#34d399"
                            : "#f56565",
                        boxShadow: !searchKnown
                          ? "0 0 5px rgba(160, 174, 192, 0.6)"
                          : searchRunning
                            ? "0 0 5px rgba(52, 211, 153, 0.6)"
                            : "0 0 5px rgba(245, 101, 101, 0.6)",
                      }}
                    />
                    <span data-testid="searxng-status-text">
                      {!searchKnown ? "Unknown" : searchRunning ? "Running" : "Stopped"}
                    </span>
                    <button
                      type="button"
                      data-testid="searxng-toggle"
                      className="ghost icon-text-btn"
                      style={{ padding: "2px 8px", fontSize: "11px" }}
                      title={
                        searchRunning
                          ? `Stop SearXNG at ${searchURL}`
                          : `Start SearXNG at ${searchURL}`
                      }
                      aria-label={
                        searchRunning ? "Stop SearXNG" : "Start SearXNG"
                      }
                      onClick={(event) => {
                        event.stopPropagation();
                        void handleToggleSearch();
                      }}
                      disabled={searchBusyAction !== null}
                    >
                      {searchBusyAction === "start" ? (
                        <>
                          <SearchIcon size={14} />
                          <span>Starting…</span>
                        </>
                      ) : searchBusyAction === "stop" ? (
                        <>
                          <StopIcon size={14} />
                          <span>Stopping…</span>
                        </>
                      ) : searchRunning ? (
                        <>
                          <StopIcon size={14} />
                          <span>Stop</span>
                        </>
                      ) : (
                        <>
                          <SearchIcon size={14} />
                          <span>Start</span>
                        </>
                      )}
                    </button>
                  </span>
                </div>
                {searchError ? (
                  <div
                    className="error-banner"
                    data-testid="searxng-error"
                  >
                    {searchError}
                  </div>
                ) : null}
              </div>

              <div className="profile-menu-divider" />

              <button
                type="button"
                className={`profile-menu-item ${currentTab === "settings" ? "active" : ""}`}
                onClick={() => {
                  onSelectTab("settings");
                  setProfileOpen(false);
                }}
                role="menuitem"
              >
                <SettingsIcon size={16} />
                <span>Settings</span>
              </button>

              <div className="profile-menu-divider" />

              <div className="profile-menu-footer">
                Rune Weaver v{health?.version || "unknown"}
              </div>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
