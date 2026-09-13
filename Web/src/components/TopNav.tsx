// Rune Weaver Dashboard — 100% full-width top navigation bar styled after Runic.
// Displays brand with Rune glyph, center navigation with active states/badges, and right status/notifications.

import React from "react";
import type { HealthResponse } from "../api";
import {
  ApprovalsIcon,
  BellIcon,
  ChatIcon,
  MemoryIcon,
  RuneGlyph,
  RunsIcon,
  SchedulesIcon,
} from "./icons";

export type Tab = "chat" | "approvals" | "memory" | "runs" | "schedules";

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
  const navItems: NavItemConfig[] = [
    { id: "chat", label: "Chat", icon: ChatIcon },
    { id: "approvals", label: "Approvals", icon: ApprovalsIcon, badge: approvalsBadge },
    { id: "memory", label: "Memory", icon: MemoryIcon },
    { id: "runs", label: "Runs", icon: RunsIcon, badge: runsBadge },
    { id: "schedules", label: "Schedules", icon: SchedulesIcon },
  ];

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

        <div className="top-nav-status-badge" title="Engine Status">
          <span className="status-dot" />
          <span className="status-text">
            {health
              ? `${health.model || health.engine} · v${health.version}`
              : "connecting…"}
          </span>
        </div>
      </div>
    </header>
  );
}
