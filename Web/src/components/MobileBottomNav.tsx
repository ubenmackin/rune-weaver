// Rune Weaver Dashboard — Mobile bottom navigation bar for narrow viewports.
//
// Bottom-layout owner for handheld widths: renders the five canonical tabs in
// fixed order with touch-sized targets and unread badges. Hidden on desktop
// via stylesheet breakpoints; selection and routing stay with the app shell.

import { NAV_ITEMS, formatBadgeCount, normalizeBadgeCount, type BottomTabId } from "./navigationConfig";

export interface MobileBottomNavProps {
  // Currently selected tab id (may include profile-only ids such as
  // settings). Unknown ids fail closed: no tab renders active.
  currentTab: string;
  // Tab selection callback owned by the app shell (updates state plus hash).
  onSelectTab: (tab: BottomTabId) => void;
  // Unread count for the runs tab; zero or absent hides the badge.
  runsBadge?: number;
  // Unread count for the approvals tab; zero or absent hides the badge.
  approvalsBadge?: number;
  // Optional per-tab badge map that takes precedence over the named props so
  // presentational tests and future tabs can inject counts without new props.
  badges?: Partial<Record<BottomTabId, number>>;
}

// Resolves the display count for one tab: the explicit per-tab map wins when
// present, otherwise the named approvals/runs props apply. Tabs without a
// badge source resolve to zero so the badge stays hidden. Normalization is
// single-sourced in the navigation contract so desktop and mobile never drift.
function badgeForTab(
  id: BottomTabId,
  props: Pick<MobileBottomNavProps, "runsBadge" | "approvalsBadge" | "badges">
): number {
  const mapped = props.badges?.[id];
  if (typeof mapped === "number") return normalizeBadgeCount(mapped);
  if (id === "approvals") return normalizeBadgeCount(props.approvalsBadge);
  if (id === "runs") return normalizeBadgeCount(props.runsBadge);
  return 0;
}

export default function MobileBottomNav({
  currentTab,
  onSelectTab,
  runsBadge = 0,
  approvalsBadge = 0,
  badges,
}: MobileBottomNavProps) {
  return (
    // Distinct mobile landmark keeps the desktop and handheld tab surfaces
    // uniquely named when both mount; the shell keeps this mounted on every
    // viewport while the stylesheet owns visibility, so a missing or
    // fail-closed viewport probe can never leave a phone with zero tab
    // surfaces.
    <nav className="mobile-bottom-nav" aria-label="Dashboard sections — mobile">
      {NAV_ITEMS.map((item) => {
        const Icon = item.icon;
        // Fail-closed active state: only an exact id match highlights, so an
        // unknown currentTab leaves every tab inactive instead of guessing.
        const isActive = currentTab === item.id;
        const badgeCount = badgeForTab(item.id, {
          runsBadge,
          approvalsBadge,
          badges,
        });
        // The badge count lives in the owning button's accessible name because
        // a bare aria-label on the generic badge span is ignored without an
        // exposed role and would never be announced. The visual pill is
        // presentational, so it stays hidden from assistive tech.
        const accessibleLabel =
          badgeCount > 0 ? `${item.label}, ${badgeCount} unread` : item.label;
        return (
          <button
            key={item.id}
            type="button"
            className={`mobile-bottom-tab${isActive ? " active" : ""}`}
            onClick={() => onSelectTab(item.id)}
            aria-label={accessibleLabel}
            aria-current={isActive ? "page" : undefined}
          >
            <span className="mobile-bottom-tab-icon-wrap">
              <Icon size={22} className="mobile-bottom-tab-icon" />
              {badgeCount > 0 ? (
                <span className="mobile-bottom-tab-badge" aria-hidden="true">
                  {formatBadgeCount(badgeCount)}
                </span>
              ) : null}
            </span>
            <span className="mobile-bottom-tab-label">{item.label}</span>
          </button>
        );
      })}
    </nav>
  );
}
