// Rune Weaver Dashboard — Top navigation bar for section switching and service status.

import { useState, useEffect, useRef, useCallback } from "react";
import type { HealthResponse } from "../api";
import {
  DEFAULT_SEARCH_SEARXNG_URL,
  ensureSearch,
  getSearchHealth,
  getSettings,
  personaUserName,
  stopSearch,
  resolveSearchMessage,
  resolveSearchURL,
  searchStageCopy,
} from "../api";
import { useSearchStartProgress } from "../hooks/useSearchStartProgress";
import { useToastStack } from "../hooks/useToastStack";
import { useSharedWebSocket, type WSIncomingFrame } from "../hooks/useSharedWebSocket";
import { ToastStack } from "./Toast";
import {
  peekPersonaSignals,
  publishAgentAttention,
  publishPersonaFromSettings,
  usePersonaSignals,
} from "./PersonaAvatar";
import {
  BellIcon,
  ChevronDownIcon,
  FileDiffIcon,
  RuneGlyph,
  SearchIcon,
  SettingsIcon,
  StopIcon,
  UserIcon,
} from "./icons";
import { NAV_GROUPS, formatBadgeCount, isGroupActive, normalizeBadgeCount, rolledUpBadge } from "./navigationConfig";
import type { NavGroupId, NavTabId } from "./navigationConfig";

// Dashboard sections reachable from the top nav and mobile navigation.
export type Tab =
  | "dashboard"
  | "chat"
  | "approvals"
  | "goals"
  | "memory"
  | "indexing"
  | "runs"
  | "schedules"
  | "settings";

interface TopNavProps {
  currentTab: Tab;
  onSelectTab: (tab: Tab) => void;
  health: HealthResponse | null;
  runsBadge?: number;
  approvalsBadge?: number;
  // Unread goal nudges rolled into the Work trigger alongside runs. The shell
  // owns the count so selecting goals can acknowledge it like runs/approvals.
  goalsBadge?: number;
  warningsBadge?: number;
  stagedFilesCount?: number;
  onOpenStagedDrawer?: () => void;
  onRequestNotifications?: () =>
    | void
    | Promise<NotificationPermission | "unsupported" | void>;
  onClearBadges?: () => void;
}

export default function TopNav({
  currentTab,
  onSelectTab,
  health,
  runsBadge = 0,
  approvalsBadge = 0,
  goalsBadge = 0,
  warningsBadge = 0,
  stagedFilesCount = 0,
  onOpenStagedDrawer,
  onRequestNotifications,
  onClearBadges,
}: TopNavProps) {
  const [profileOpen, setProfileOpen] = useState(false);
  const profileRef = useRef<HTMLDivElement>(null);
  const profileButtonRef = useRef<HTMLButtonElement>(null);
  // Desktop group dropdowns (currently Work) mirror the profile menu exactly: click/keyboard
  // toggled with no hover path.
  const [openGroup, setOpenGroup] = useState<NavGroupId | null>(null);
  const groupRefs = useRef<Partial<Record<NavGroupId, HTMLDivElement | null>>>({});
  const groupButtonRefs = useRef<Partial<Record<NavGroupId, HTMLButtonElement | null>>>({});
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
  // Shared staged Start progress (1s poll, minutes-budget cap, elapsed, cleanup) feeding the
  // amber Starting line; busy ownership stays here so the cap path keeps the toggle locked.
  const {
    searchStage,
    searchStartElapsed,
    beginSearchStartProgress,
    endSearchStartProgress,
  } = useSearchStartProgress();

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

  // Desktop groups derive labels, icons, and membership from the shared navigation contract so the
  // top bar cannot drift from the tab model.
  const badgeByTab: Partial<Record<NavTabId, number>> = {
    approvals: approvalsBadge,
    runs: runsBadge,
    goals: goalsBadge,
  };
  // Shared normalization keeps the bell badge floored through the single navigation-contract helper
  // so desktop and mobile never drift; the normalized count feeds both the display string and the
  // owning button's accessible name so fractional inputs announce what they render.
  const normalizedWarnings = normalizeBadgeCount(warningsBadge);
  const warningsDisplay = formatBadgeCount(normalizedWarnings);

  // Staged drawer trigger stays always visible (including zero, fetch failure, and reload) so
  // review never waits on the tool path.
  const normalizedStagedCount = normalizeBadgeCount(stagedFilesCount);

  // Operator name for the profile block. The shared persona store owns the data flow: Settings
  // publishes on every load and save, so a rename lands here live.
  const { persona, personaLoaded } = usePersonaSignals();
  useEffect(() => {
    if (personaLoaded) return;
    let cancelled = false;
    getSettings()
      .then((settings) => {
        if (cancelled) return;
        // Discard the probe once any other reader has loaded settings first: the store already
        // carries an equal-or-fresher persona, and a late response from a stale request must never
        // clobber it.
        if (peekPersonaSignals().personaLoaded) return;
        publishPersonaFromSettings(settings?.persona);
      })
      .catch(() => {
        // Unknown persona is the stock persona: an unread settings surface
        // must never strand the profile block on a half-loaded identity.
      });
    return () => {
      cancelled = true;
    };
  }, [personaLoaded]);

  // The avatar's attention signal is the same two global counts the nav already surfaces — pending
  // approvals and unread goal nudges (the goal-needs-input badge) — published once here for the
  // greeting cluster, which combines this store flag with its REST snapshot to resolve one avatar.
  useEffect(() => {
    publishAgentAttention(approvalsBadge > 0 || goalsBadge > 0);
  }, [approvalsBadge, goalsBadge]);

  // Operator identity with the same blank normalization as the greeting row plus the chat header: a
  // stored owner name that trims to empty is indistinguishable from an absent persona, so both fall
  // back to "Operator" instead of rendering an empty string.
  const operatorNameRaw = personaUserName(persona).trim();
  const operatorDisplayName =
    operatorNameRaw.length > 0 ? operatorNameRaw : "Operator";

  // Local transient feedback for the bell: the shared stack owns timers plus the dismiss surface,
  // so this nav never invents a second toast system and badge counting stays untouched upstream.
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast } =
    useToastStack();

  // Listen for embedding engine status updates and surface transient toasts
  const lastEmbeddingStatusRef = useRef<string | null>(null);
  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      if (frame.type === "embeddings_status") {
        const { status, message, error } = frame;
        if (lastEmbeddingStatusRef.current === status) return;
        lastEmbeddingStatusRef.current = status;

        if (status === "downloading_binary" || status === "downloading_model") {
          pushSuccessToast(
            message ?? "Setting up local embedding engine (EmbeddingGemma 2)…",
            8000,
          );
        } else if (status === "ready") {
          pushSuccessToast("Local embeddings ready (Metal GPU accelerated).", 4000);
        } else if (status === "idle") {
          pushSuccessToast(
            message ?? "Local embedding engine entered standby to save power.",
            4000,
          );
        } else if (status === "error") {
          pushErrorToast(
            error ?? "Failed to initialize embedding engine.",
            8000,
          );
        }
      }
    },
    [pushSuccessToast, pushErrorToast],
  );
  useSharedWebSocket(handleWSFrame);

  // Every tap acknowledges in-app unread badges and warnings without prompting for
  // browser OS notifications (desktop alerts live in the macOS Menu Bar app).
  const handleBellClick = useCallback(async () => {
    const warningsCopy = (count: number) =>
      `${count} ${count === 1 ? "warning" : "warnings"} shown in chat.`;
    const count = normalizeBadgeCount(warningsBadge);
    const otherUnread =
      normalizeBadgeCount(runsBadge) +
      normalizeBadgeCount(approvalsBadge) +
      normalizeBadgeCount(goalsBadge);

    try {
      await onRequestNotifications?.();
    } catch {
      // Upstream callback failures never block local acknowledgment feedback.
    }
    onClearBadges?.();

    if (count > 0) {
      onSelectTab("chat");
      pushSuccessToast(warningsCopy(count));
    } else if (otherUnread > 0) {
      pushSuccessToast("Unread badges cleared.");
    } else {
      pushSuccessToast("Zero unread warnings.");
    }
  }, [
    warningsBadge,
    runsBadge,
    approvalsBadge,
    goalsBadge,
    onRequestNotifications,
    onClearBadges,
    onSelectTab,
    pushSuccessToast,
  ]);

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

  // Outside-click closes the open group menu.
  useEffect(() => {
    if (openGroup === null) return;
    const handleClickOutside = (event: MouseEvent) => {
      const target = event.target;
      const container = groupRefs.current[openGroup];
      if (target instanceof Node && container && !container.contains(target)) {
        setOpenGroup(null);
      }
    };
    document.addEventListener("mousedown", handleClickOutside);
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, [openGroup]);

  // Escape closes the open group menu and returns focus to its trigger so keyboard users never lose
  // place.
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

  // Toggling one group closes any other so two dropdowns are never open at
  // once; re-clicking the open trigger closes it.
  const handleGroupToggle = useCallback((groupId: NavGroupId) => {
    setOpenGroup((prev) => (prev === groupId ? null : groupId));
  }, []);

  // Choosing a child switches the section and closes the menu; focus stays with
  // the selected tab's content rather than trapping inside a collapsed menu.
  const handleChildSelect = useCallback(
    (tabId: NavTabId) => {
      onSelectTab(tabId);
      setOpenGroup(null);
    },
    [onSelectTab],
  );

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
        // Settings Web pane surfaces the same failure with detail.
        if (!cancelled) setSearchError(null);
      });
    return () => {
      cancelled = true;
    };
  }, [profileOpen, health?.searchReachable, health?.searchURL, searchHealth]);

  // Toggles the SearXNG container through the engine service.
  const handleToggleSearch = useCallback(async () => {
    if (searchBusyAction !== null) return;
    // Capture whether this action is a start so the error slot can tell a
    // failed start (unreachable) apart from a clean stop (unreachable by design),
    // and so the busy label names the in-flight action instead of always claiming Start.
    const wasStarting = !searchRunning;
    setSearchBusyAction(wasStarting ? "start" : "stop");
    setSearchError(null);
    // A Start fans out to a minutes-budget cascade (notably the first-run image pull), so poll
    // health about 1s for the live step while it runs.
    if (wasStarting) {
      beginSearchStartProgress(() => {
        getSearchHealth()
          .then((probe) => {
            if (typeof probe?.reachable === "boolean") {
              setSearchHealth({
                reachable: probe.reachable,
                url: resolveSearchURL(probe, searchURL),
              });
            }
          })
          .catch(() => {
            // Probe failure keeps the previous dot; the Starting line is already cleared.
          });
      });
    }
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
      // Terminal result stops the Starting line on every path (success, failure, cancellation),
      // so no settle leaves the poll or the pill behind.
      endSearchStartProgress();
      setSearchBusyAction(null);
    }
  }, [searchBusyAction, searchRunning, searchURL, beginSearchStartProgress, endSearchStartProgress]);

  return (
    <>
      <header className="top-nav" aria-label="Main navigation">
      <div className="top-nav-brand">
        <RuneGlyph size={24} className="rune-glyph-icon" />
        <span className="app-brand-title">RUNE WEAVER</span>
        <span className="top-nav-divider">|</span>
        <span className="top-nav-subtitle">Personal AI Agent</span>
      </div>

      <nav className="top-nav-links" aria-label="Dashboard sections">
        {NAV_GROUPS.map((group) => {
          // Leaf entries (Chat, Approvals, Memory) render as plain tabs, so the
          // approvals badge keeps its existing top-level placement and markup.
          if (group.kind === "tab") {
            const Icon = group.icon;
            const isActive = currentTab === group.id;
            // Normalized display keeps top and bottom bars identical through the shared contract
            // helper: the floored non-negative count feeds both the capped display string and the
            // owning button's accessible name so fractional inputs announce honestly.
            const normalizedBadge = normalizeBadgeCount(badgeByTab[group.id] ?? 0);
            const badgeDisplay = formatBadgeCount(normalizedBadge);
            const tabAccessibleLabel =
              normalizedBadge > 0
                ? `${group.label}, ${normalizedBadge} unread`
                : group.label;
            return (
              <button
                key={group.id}
                type="button"
                className={`top-nav-item ${isActive ? "active" : ""}`}
                onClick={() => onSelectTab(group.id)}
                aria-selected={isActive}
                aria-label={tabAccessibleLabel}
              >
                <Icon size={16} className="nav-item-icon" />
                <span>{group.label}</span>
                {badgeDisplay ? (
                  <span className="nav-badge" aria-hidden="true">
                    {badgeDisplay}
                  </span>
                ) : null}
              </button>
            );
          }

          const Icon = group.icon;
          // Parent active is membership, not equality: selecting any child tabs
          // lights the trigger so the owner keeps their bearings inside Work.
          const isActive = isGroupActive(group.id, currentTab);
          const isOpen = openGroup === group.id;
          // One rolled-up count tells the owner pending work exists across the
          // whole group without forcing the menu open.
          const normalizedRolled = normalizeBadgeCount(
            rolledUpBadge(group.id, badgeByTab),
          );
          const badgeDisplay = formatBadgeCount(normalizedRolled);
          const triggerAccessibleLabel =
            normalizedRolled > 0
              ? `${group.label}, ${normalizedRolled} unread`
              : group.label;
          return (
            <div
              key={group.id}
              ref={(el) => {
                groupRefs.current[group.id] = el;
              }}
              className="nav-dropdown-container"
            >
              <button
                type="button"
                ref={(el) => {
                  groupButtonRefs.current[group.id] = el;
                }}
                className={`top-nav-item nav-group-trigger ${
                  isActive ? "active" : ""
                } ${isOpen ? "open" : ""}`}
                onClick={() => handleGroupToggle(group.id)}
                aria-haspopup="menu"
                aria-expanded={isOpen}
                aria-controls={`nav-group-menu-${group.id}`}
                aria-label={triggerAccessibleLabel}
              >
                <Icon size={16} className="nav-item-icon" />
                <span>{group.label}</span>
                <ChevronDownIcon
                  size={13}
                  className={`dropdown-chevron ${isOpen ? "rotate-180" : ""}`}
                />
                {badgeDisplay ? (
                  <span className="nav-badge" aria-hidden="true">
                    {badgeDisplay}
                  </span>
                ) : null}
              </button>

              {isOpen && (
                <div
                  id={`nav-group-menu-${group.id}`}
                  className="nav-dropdown-menu"
                  role="menu"
                  aria-label={`${group.label} sections`}
                >
                  {group.children.map((child) => {
                    const ChildIcon = child.icon;
                    const childActive = currentTab === child.id;
                    // Each open-menu row names its own unread share so the rolled-up trigger total
                    // stays auditable without opening another surface; the pill renders the capped
                    // display string while the accessible name keeps the honest count.
                    const childCount = normalizeBadgeCount(badgeByTab[child.id] ?? 0);
                    const childDisplay = formatBadgeCount(childCount);
                    const childAccessibleLabel = childCount > 0 ? `${child.label}, ${childCount} unread` : child.label;
                    return (
                      <button
                        key={child.id}
                        type="button"
                        role="menuitem"
                        className={`nav-dropdown-item ${
                          childActive ? "active" : ""
                        }`}
                        onClick={() => handleChildSelect(child.id)}
                        aria-label={childAccessibleLabel}
                      >
                        <ChildIcon size={16} />
                        <span>{child.label}</span>
                        {childDisplay ? (
                          <span className="nav-dropdown-item-badge" aria-hidden="true">
                            {childDisplay}
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

      <div className="top-nav-right">
        {/* Bell surfaces unread degraded-tool warnings in amber and acknowledges
            unread in-app badges when tapped without requesting browser OS permissions. */}
        <button
          type="button"
          className={`icon-button ${normalizedWarnings > 0 ? "active" : ""}`}
          style={{ position: "relative" }}
          title={
            normalizedWarnings > 0
              ? `${normalizedWarnings} unread ${normalizedWarnings === 1 ? "warning" : "warnings"}`
              : "Alerts"
          }
          onClick={() => void handleBellClick()}
          aria-label={
            normalizedWarnings > 0
              ? `Alerts, ${normalizedWarnings} unread warnings`
              : "Alerts"
          }
        >
          <BellIcon size={16} />
          {warningsDisplay ? (
            <span
              className="nav-badge"
              aria-hidden="true"
              style={{
                position: "absolute",
                top: "-8px",
                right: "-8px",
                background: "#f59e0b",
              }}
            >
              {warningsDisplay}
            </span>
          ) : null}
        </button>

        {/* Staged Changes Drawer Trigger — always visible in every state
            (including zero, fetch failure, and reload) so the review path
            never waits on the tool path. Clicking always delegates to the
            upstream drawer wiring; at zero the drawer shows its existing
            `No staged changes` empty state. Never auto-opens on tool_end. */}
        <button
          type="button"
          className="top-nav-staged-btn"
          data-testid="top-nav-staged-btn"
          onClick={onOpenStagedDrawer}
          title={`${normalizedStagedCount} staged file change${normalizedStagedCount === 1 ? "" : "s"} waiting for review`}
          aria-label={`Open staged changes drawer (${normalizedStagedCount} files)`}
        >
          <FileDiffIcon size={16} />
          <span>Files</span>
          <span
            className="top-nav-staged-badge"
            style={
              normalizedStagedCount === 0
                ? { background: "rgba(148, 163, 184, 0.25)", color: "#94a3b8" }
                : undefined
            }
          >
            {normalizedStagedCount}
          </span>
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
            {/* Static trigger label: the operator space never shows the assistant
                name, which lives in the greeting row plus the chat header plus
                settings. The stock glyph names the menu alongside the fixed label,
                while the Wisp image itself renders in the sole identity surface (settings picker editor excluded). */}
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
                    {/* Operator identity only in the menu header as well: the name below
                        carries the stored owner name (or "Operator" when absent or blank)
                        while the glyph stays stock, keeping the sole identity surface (settings picker editor excluded).
                        The assistant name never renders here; it lives in the greeting
                        row plus the chat header plus settings only. */}
                    <UserIcon size={16} />
                  </div>
                  <div className="profile-header-details">
                    <span className="profile-name">{operatorDisplayName}</span>
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
                {/* SearXNG health sits beside Model and Provider so web search status is
                    visible without opening Settings. */}
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
                    {/* Status text stays mounted during Start so consumers keep a stable id;
                        the Starting pill plus stage and elapsed render additively beside it. */}
                    <span data-testid="searxng-status-text">
                      {!searchKnown ? "Unknown" : searchRunning ? "Reachable" : "Stopped"}
                    </span>
                    {searchBusyAction === "start" ? (
                      <span
                        style={{
                          display: "inline-flex",
                          alignItems: "center",
                          gap: "6px",
                        }}
                      >
                        <span
                          data-testid="searxng-starting-pill"
                          className="status-pill running"
                        >
                          Starting
                        </span>
                        <span
                          data-testid="searxng-start-stage"
                          style={{ fontSize: "11px", opacity: 0.85 }}
                        >
                          {searchStageCopy(searchStage)}
                        </span>
                        <span
                          data-testid="searxng-start-elapsed"
                          style={{ fontSize: "11px", opacity: 0.65 }}
                        >
                          {searchStartElapsed}s
                        </span>
                      </span>
                    ) : null}
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
      {/* Shared transient stack anchors top-right with independent timers; the
          existing dismiss surface keeps the minimum touch target so the 375px
          handheld tap always lands an acknowledged, dismissible notice. */}
      <ToastStack toasts={toasts} onDismiss={dismissToast} />
    </>
  );
}
