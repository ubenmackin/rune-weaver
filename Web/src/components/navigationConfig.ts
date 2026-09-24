// Rune Weaver Dashboard — Shared navigation contract for top tabs and mobile bottom bar.
//
// Single source of truth for dashboard section tabs: owns the ordered tab list,
// the mobile breakpoint, and badge formatting so the desktop top nav and the
// mobile bottom nav render identical labels and counts without drifting.

import type { ComponentType } from "react";
import {
  ApprovalsIcon,
  ChatIcon,
  MemoryIcon,
  RunsIcon,
  SchedulesIcon,
} from "./icons";

// Mobile layout breakpoint shared by styles and components. Layouts at or
// below this width use the slim top plus bottom bar; widths above use tabs.
export const MOBILE_BREAKPOINT_PX = 640;

// Bottom bar owns exactly five tabs in this fixed order. Settings stays in
// the profile menu only and never appears here.
export type BottomTabId = "chat" | "approvals" | "memory" | "runs" | "schedules";

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
