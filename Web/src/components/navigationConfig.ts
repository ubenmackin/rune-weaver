// Rune Weaver Dashboard — Shared navigation contract for top tabs and mobile bottom bar.
//
// Single source of truth for dashboard navigation: owns the grouped
// navigation structure, the mobile breakpoint, and badge formatting plus
// roll-up so the desktop top nav and the mobile bottom nav render identical
// labels and counts without drifting.

import type { ComponentType } from "react";
import {
  ApprovalsIcon,
  ChatIcon,
  DashboardIcon,
  IndexDiscoverIcon,
  MemoryIcon,
  RunsIcon,
  SchedulesIcon,
  SearchIcon,
  TargetIcon,
  WorkIcon,
} from "./icons";

// Mobile layout breakpoint shared by styles and components. Layouts at or
// below this width use the slim top plus bottom bar; widths above use tabs.
export const MOBILE_BREAKPOINT_PX = 640;

// All selectable leaf tab identifiers across both breakpoints.
export type NavTabId =
  | "dashboard"
  | "chat"
  | "approvals"
  | "goals"
  | "schedules"
  | "runs"
  | "memory"
  | "indexing";

// Desktop and mobile top-level group identifiers: Dashboard, Chat, and Approvals stand alone
// as direct views while Work folds Goals, Schedules, and Runs, and Memory folds
// Search and Memory plus Index Status behind cohesive dropdowns.
export type NavGroupId = "dashboard" | "chat" | "approvals" | "work" | "memory";

// Icon component shape shared by every navigation entry at both breakpoints.
type NavIcon = ComponentType<{ size?: number; className?: string }>;

// One selectable child inside a dropdown group. Children select a tab
// and close the menu, so they carry no independent open state of their own.
export interface NavChild {
  // Stable tab id used for selection state and the routing hash.
  id: NavTabId;
  // Human-readable label shown inside the dropdown.
  label: string;
  // Icon rendered beside the label.
  icon: NavIcon;
}

// A top-level entry: either a plain tab or a folder of related tabs.
// The discriminated `kind` lets renderers branch exhaustively instead of
// inferring intent from the presence of `children`.
export interface NavTabEntry {
  kind: "tab";
  id: NavTabId;
  label: string;
  icon: NavIcon;
}

export interface NavChildGroup {
  kind: "group";
  id: NavGroupId;
  label: string;
  icon: NavIcon;
  children: NavChild[];
}

export type NavGroupEntry = NavTabEntry | NavChildGroup;

// Canonical navigation structure shared by desktop TopNav and handheld
// MobileBottomNav: Dashboard, Chat, and Approvals are direct tabs, while Work and Memory
// fold their respective sub-surfaces into dropdown/drop-up menus.
export const NAV_GROUPS: NavGroupEntry[] = [
  { kind: "tab", id: "dashboard", label: "Dashboard", icon: DashboardIcon },
  { kind: "tab", id: "chat", label: "Chat", icon: ChatIcon },
  { kind: "tab", id: "approvals", label: "Inbox", icon: ApprovalsIcon },
  {
    kind: "group",
    id: "work",
    label: "Work",
    icon: WorkIcon,
    children: [
      { id: "goals", label: "Goals", icon: TargetIcon },
      { id: "schedules", label: "Schedules", icon: SchedulesIcon },
      { id: "runs", label: "Runs", icon: RunsIcon },
    ],
  },
  {
    kind: "group",
    id: "memory",
    label: "Memory",
    icon: MemoryIcon,
    children: [
      { id: "memory", label: "Search and Memory", icon: SearchIcon },
      { id: "indexing", label: "Index Status", icon: IndexDiscoverIcon },
    ],
  },
];

// Normalizes any badge input to a non-negative integer with no upper bound.
// Non-finite, negative, and fractional values fail closed to zero (hidden)
// rather than rendering a misleading count. Display caps at 99+ through the
// shared formatter while accessible labels keep the honest unclamped count
// so a large backlog never announces a clamped value. Single owner for badge
// normalization so desktop and mobile cannot drift.
export function normalizeBadgeCount(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  const floored = Math.floor(value);
  if (floored <= 0) return 0;
  return floored;
}

// Formats a raw unread count for badge display. Zero (and any non-positive or
// non-finite input) returns an empty string so callers can hide the badge;
// 1-99 render verbatim and larger counts cap at 99+. Callers keep the raw
// count for the accessible `{n} unread` label while rendering this string.
export function formatBadgeCount(count: number): string {
  // Display-only cap over the shared normalization so flooring and
  // fail-closed edges stay single-sourced instead of duplicated per caller.
  const normalized = normalizeBadgeCount(count);
  if (normalized <= 0) return "";
  if (normalized <= 99) return String(normalized);
  return "99+";
}

// Reports whether a desktop group should read as active for the selected tab.
// Membership, not equality, is the rule: a group lights up when any of its
// children is selected. This is the tab-state analogue of a parent-route map,
// which the app does not need because it has no router. Unknown group ids fail
// closed to inactive so a stale caller never highlights the wrong entry.
export function isGroupActive(groupId: NavGroupId, currentTab: string): boolean {
  const entry = NAV_GROUPS.find((group) => group.id === groupId);
  if (!entry) return false;
  if (entry.kind === "group") {
    return entry.children.some((child) => child.id === currentTab);
  }
  return entry.id === currentTab;
}

// Sums the normalized unread counts across a group's children so one trigger
// badge communicates total pending work without the owner opening the menu.
// Leaf entries report their own badge (approvals stays top-level). Every child
// count routes through the shared normalizer so negative, fractional, and
// non-finite inputs collapse to zero instead of skewing the roll-up.
export function rolledUpBadge(
  groupId: NavGroupId,
  badges: Partial<Record<NavTabId, number>>,
): number {
  const entry = NAV_GROUPS.find((group) => group.id === groupId);
  if (!entry) return 0;
  if (entry.kind === "group") {
    return entry.children.reduce(
      (total, child) => total + normalizeBadgeCount(badges[child.id]),
      0,
    );
  }
  return normalizeBadgeCount(badges[entry.id]);
}
