// Rune Weaver Dashboard — Top navigation bar for section switching and service status.
// Keeps primary tabs focused on operational views while the profile dropdown surfaces
// Settings plus live engine health, so configuration stays reachable without crowding chat.
import React, { useState, useEffect, useRef, useCallback } from "react";
import type { HealthResponse } from "../api";
import {
  ApprovalsIcon,
  BellIcon,
  ChatIcon,
  ChevronDownIcon,
  MemoryIcon,
  RuneGlyph,
  RunsIcon,
  SchedulesIcon,
  SettingsIcon,
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
  const closeTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const navItems: NavItemConfig[] = [
    { id: "chat", label: "Chat", icon: ChatIcon },
    { id: "approvals", label: "Approvals", icon: ApprovalsIcon, badge: approvalsBadge },
    { id: "memory", label: "Memory", icon: MemoryIcon },
    { id: "runs", label: "Runs", icon: RunsIcon, badge: runsBadge },
    { id: "schedules", label: "Schedules", icon: SchedulesIcon },
  ];

  useEffect(() => {
    return () => {
      if (closeTimeoutRef.current) {
        clearTimeout(closeTimeoutRef.current);
      }
    };
  }, []);

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (profileRef.current && !profileRef.current.contains(event.target as Node)) {
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

  const handleMouseEnter = useCallback(() => {
    if (closeTimeoutRef.current) {
      clearTimeout(closeTimeoutRef.current);
      closeTimeoutRef.current = null;
    }
    setProfileOpen(true);
  }, []);

  const handleMouseLeave = useCallback(() => {
    closeTimeoutRef.current = setTimeout(() => {
      setProfileOpen(false);
    }, 150);
  }, []);

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

        {/* Profile Dropdown */}
        <div
          ref={profileRef}
          className="profile-dropdown-container"
          onMouseEnter={handleMouseEnter}
          onMouseLeave={handleMouseLeave}
        >
          <button
            type="button"
            onClick={() => setProfileOpen((prev) => !prev)}
            className={`profile-dropdown-btn ${profileOpen ? "open" : ""} ${
              currentTab === "settings" ? "settings-active" : ""
            }`}
            aria-expanded={profileOpen}
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
            <div className="profile-dropdown-menu" role="menu">
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
                Rune Weaver v{health?.version || "1.0.0"}
              </div>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
