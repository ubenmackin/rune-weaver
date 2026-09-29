// Rune Weaver Dashboard — Shared navigation contract for top tabs and mobile bottom bar.
//
// Single source of truth for dashboard navigation: owns the flat mobile tab
// list, the desktop group/dropdown composition, the mobile breakpoint, and
// badge formatting plus roll-up so the desktop top nav and the mobile bottom
// nav render identical labels and counts without drifting.

import type { ComponentType } from "react";
import {
  ApprovalsIcon,
  ChatIcon,
  MemoryIcon,
  RunsIcon,
  SchedulesIcon,
  TargetIcon,
  WorkIcon,
} from "./icons";

// Mobile layout breakpoint shared by styles and components. Layouts at or
// below this width use the slim top plus bottom bar; widths above use tabs.
export const MOBILE_BREAKPOINT_PX = 640;

// Bottom bar owns exactly five tabs in this fixed order. Settings stays in
// the profile menu only and never appears here.
export type BottomTabId = "chat" | "approvals" | "memory" | "runs" | "schedules";

// Desktop widened the tab set with goals, which the Work dropdown exposes while
// the mobile bottom bar intentionally stays at five tabs. Keeping this as a
// separate alias (rather than widening BottomTabId) is what lets the top nav
// badge the goals surface without forcing a sixth mobile tab.
export type NavTabId = BottomTabId | "goals";

export interface NavItem {
  // Stable tab identifier used for routing hashes and selection state.
  id: BottomTabId;
  // Human-readable label shared by the top nav and the bottom bar.
  label: string;
  // Icon component rendered at 16px on desktop and 22px on the bottom bar.
  icon: ComponentType<{ size?: number; className?: string }>;
}

// Canonical tab order: chat, approvals, memory, runs, schedules. Desktop top
// nav and mobile bottom bar both derive from this list so ordering and labels
// cannot drift between breakpoints.
export const NAV_ITEMS: NavItem[] = [
  { id: "chat", label: "Chat", icon: ChatIcon },
  { id: "approvals", label: "Approvals", icon: ApprovalsIcon },
  { id: "memory", label: "Memory", icon: MemoryIcon },
  { id: "runs", label: "Runs", icon: RunsIcon },
  { id: "schedules", label: "Schedules", icon: SchedulesIcon },
];

// Desktop top-level group identifiers. Chat, Approvals, and Memory stand alone
// while Work folds the goal, schedule, and run surfaces behind one dropdown so
// the bar stays short as operational views multiply.
export type NavGroupId = "chat" | "approvals" | "work" | "memory";

// Icon component shape shared by every navigation entry at both breakpoints.
type NavIcon = ComponentType<{ size?: number; className?: string }>;

// One selectable child inside a desktop dropdown group. Children select a tab
// and close the menu, so they carry no independent open state of their own.
export interface NavChild {
  // Stable tab id used for selection state and the routing hash.
  id: NavTabId;
  // Human-readable label shown inside the dropdown.
  label: string;
  // Icon rendered beside the label.
  icon: NavIcon;
}

// A top-level desktop entry: either a plain tab or a folder of related tabs.
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

// Canonical desktop ordering: Chat, Approvals, Work (goals/schedules/runs), and
// Memory. Approvals keeps its own badge on the tab itself because it never
// nests, while Work rolls its children's unread counts into one trigger badge.
export const NAV_GROUPS: NavGroupEntry[] = [
  { kind: "tab", id: "chat", label: "Chat", icon: ChatIcon },
  { kind: "tab", id: "approvals", label: "Approvals", icon: ApprovalsIcon },
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
  { kind: "tab", id: "memory", label: "Memory", icon: MemoryIcon },
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
