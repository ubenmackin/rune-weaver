// Rune Weaver Dashboard — Mobile bottom navigation bar for narrow viewports.

import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronDownIcon } from "./icons";
import {
  NAV_GROUPS,
  formatBadgeCount,
  isGroupActive,
  normalizeBadgeCount,
  rolledUpBadge,
  type NavGroupId,
  type NavTabId,
} from "./navigationConfig";

export interface MobileBottomNavProps {
  // Currently selected tab id (may include profile-only ids such as
  // settings). Unknown ids fail closed: no tab renders active.
  currentTab: string;
  // Tab selection callback owned by the app shell (updates state plus hash).
  onSelectTab: (tab: NavTabId) => void;
  // Unread count for the runs tab; zero or absent hides the badge.
  runsBadge?: number;
  // Unread count for the approvals tab; zero or absent hides the badge.
  approvalsBadge?: number;
  // Unread count for goals; zero or absent hides the badge.
  goalsBadge?: number;
  // Optional per-tab badge map that takes precedence over the named props so
  // presentational tests and future tabs can inject counts without new props.
  badges?: Partial<Record<NavTabId, number>>;
}

// Resolves the display count for one tab: the explicit per-tab map wins when present, otherwise the
// named approvals/runs/goals props apply. Tabs without a badge source resolve to zero so the badge
// stays hidden.
function badgeForTab(
  id: NavTabId,
  props: Pick<MobileBottomNavProps, "runsBadge" | "approvalsBadge" | "goalsBadge" | "badges">,
): number {
  const mapped = props.badges?.[id];
  if (typeof mapped === "number") return normalizeBadgeCount(mapped);
  if (id === "approvals") return normalizeBadgeCount(props.approvalsBadge);
  if (id === "runs") return normalizeBadgeCount(props.runsBadge);
  if (id === "goals") return normalizeBadgeCount(props.goalsBadge);
  return 0;
}

export default function MobileBottomNav({
  currentTab,
  onSelectTab,
  runsBadge = 0,
  approvalsBadge = 0,
  goalsBadge = 0,
  badges,
}: MobileBottomNavProps) {
  const [openGroup, setOpenGroup] = useState<NavGroupId | null>(null);
  const groupRefs = useRef<Partial<Record<NavGroupId, HTMLDivElement | null>>>({});
  // Trigger buttons keyed by group id so Escape and backdrop close can return
  // focus to the owning trigger, matching the desktop dropdown contract.
  const groupButtonRefs = useRef<Partial<Record<NavGroupId, HTMLButtonElement | null>>>({});

  const badgeMap: Partial<Record<NavTabId, number>> = {
    approvals: approvalsBadge,
    runs: runsBadge,
    goals: goalsBadge,
    ...badges,
  };

  const handleGroupToggle = useCallback((groupId: NavGroupId) => {
    setOpenGroup((prev) => (prev === groupId ? null : groupId));
  }, []);

  const handleChildSelect = useCallback(
    (tabId: NavTabId) => {
      onSelectTab(tabId);
      setOpenGroup(null);
    },
    [onSelectTab],
  );

  // Close drop-up menu on outside mousedown or touch
  useEffect(() => {
    if (openGroup === null) return;
    const handleClickOutside = (event: MouseEvent | TouchEvent) => {
      const target = event.target;
      const container = groupRefs.current[openGroup];
      if (target instanceof Node && container && !container.contains(target)) {
        setOpenGroup(null);
      }
    };
    document.addEventListener("mousedown", handleClickOutside);
    document.addEventListener("touchstart", handleClickOutside);
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("touchstart", handleClickOutside);
    };
  }, [openGroup]);

  // Escape closes any open menu and returns focus to its trigger so
  // keyboard users never lose place after dismissing the drop-up.
  useEffect(() => {
    if (openGroup === null) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        const trigger = groupButtonRefs.current[openGroup];
        setOpenGroup(null);
        trigger?.focus();
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [openGroup]);

  return (
    <>
      {openGroup !== null && (
        <div
          className="mobile-dropup-backdrop"
          onClick={() => {
            const trigger = groupButtonRefs.current[openGroup];
            setOpenGroup(null);
            trigger?.focus();
          }}
          aria-hidden="true"
        />
      )}
      <nav className="mobile-bottom-nav" aria-label="Dashboard sections — mobile">
        {NAV_GROUPS.map((entry) => {
          const Icon = entry.icon;

          if (entry.kind === "tab") {
            const isActive = currentTab === entry.id;
            const badgeCount = badgeForTab(entry.id, {
              runsBadge,
              approvalsBadge,
              goalsBadge,
              badges,
            });
            const accessibleLabel =
              badgeCount > 0 ? `${entry.label}, ${badgeCount} unread` : entry.label;

            return (
              <button
                key={entry.id}
                type="button"
                className={`mobile-bottom-tab${isActive ? " active" : ""}`}
                onClick={() => {
                  setOpenGroup(null);
                  onSelectTab(entry.id);
                }}
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
                <span className="mobile-bottom-tab-label">{entry.label}</span>
              </button>
            );
          }

          // Group entry (Work, Memory) with drop-up menu
          const isActive = isGroupActive(entry.id, currentTab);
          const isOpen = openGroup === entry.id;
          const rolledCount = normalizeBadgeCount(rolledUpBadge(entry.id, badgeMap));
          const accessibleLabel =
            rolledCount > 0 ? `${entry.label}, ${rolledCount} unread` : entry.label;

          return (
            <div
              key={entry.id}
              ref={(el) => {
                groupRefs.current[entry.id] = el;
              }}
              className="mobile-bottom-group-wrap"
            >
              <button
                type="button"
                ref={(el) => {
                  groupButtonRefs.current[entry.id] = el;
                }}
                className={`mobile-bottom-tab${isActive ? " active" : ""}${
                  isOpen ? " open" : ""
                }`}
                onClick={() => handleGroupToggle(entry.id)}
                aria-haspopup="menu"
                aria-expanded={isOpen}
                aria-controls={`mobile-group-menu-${entry.id}`}
                aria-label={accessibleLabel}
                aria-current={isActive ? "page" : undefined}
              >
                <span className="mobile-bottom-tab-icon-wrap">
                  <Icon size={22} className="mobile-bottom-tab-icon" />
                  {rolledCount > 0 ? (
                    <span className="mobile-bottom-tab-badge" aria-hidden="true">
                      {formatBadgeCount(rolledCount)}
                    </span>
                  ) : null}
                </span>
                <span className="mobile-bottom-tab-label-wrap">
                  <span className="mobile-bottom-tab-label">{entry.label}</span>
                  <ChevronDownIcon
                    size={10}
                    className={`mobile-bottom-tab-chevron ${isOpen ? "rotate-180" : ""}`}
                  />
                </span>
              </button>

              {isOpen && (
                <div
                  id={`mobile-group-menu-${entry.id}`}
                  className={`mobile-dropup-menu mobile-dropup-${entry.id}`}
                  role="menu"
                  aria-label={`${entry.label} sections`}
                >
                  {entry.children.map((child) => {
                    const ChildIcon = child.icon;
                    const childActive = currentTab === child.id;
                    const childBadge = badgeForTab(child.id, {
                      runsBadge,
                      approvalsBadge,
                      goalsBadge,
                      badges,
                    });
                    const childAccessibleLabel =
                      childBadge > 0
                        ? `${child.label}, ${childBadge} unread`
                        : child.label;

                    return (
                      <button
                        key={child.id}
                        type="button"
                        role="menuitem"
                        className={`mobile-dropup-item${childActive ? " active" : ""}`}
                        onClick={() => handleChildSelect(child.id)}
                        aria-label={childAccessibleLabel}
                        aria-current={childActive ? "page" : undefined}
                      >
                        <ChildIcon size={18} className="mobile-dropup-item-icon" />
                        <span className="mobile-dropup-item-label">{child.label}</span>
                        {childBadge > 0 ? (
                          <span
                            className="mobile-dropup-item-badge"
                            aria-hidden="true"
                          >
                            {formatBadgeCount(childBadge)}
                          </span>
                        ) : null}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}
      </nav>
    </>
  );
}
