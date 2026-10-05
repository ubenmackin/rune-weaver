// Rune Weaver Dashboard — main application shell and section navigation.
// Keeps chat mounted across tabs so in-flight turns and session state survive navigation, with a full-width sticky nav keeping health and notification badges visible.
//
// The shell is also the client-side half of the owner-auth gate. The engine
// serves the dashboard bundle publicly (a browser cannot attach a bearer header
// to navigation or asset fetches), so this gate decides the posture: the
// authenticated dashboard only mounts once a health probe proves the session
// cleared the owner gate or the engine serves no auth, and it falls back to the
// in-bundle login view on logout or a uniform 401. Keeping the authenticated
// hooks inside a child component means no dashboard socket or API polling runs
// before the gate opens.
//
// Heavy tab-switched views load through React.lazy so each section ships as
// its own route-level chunk: statically bundling every surface into one entry
// pushed first-party code past the size ceiling Rollup warns on, while the
// small above-the-fold shell pieces (login gate, top nav, mobile bar) stay
// static so first paint never waits on a section chunk. The auth gate renders
// before any lazy boundary mounts, so an unauthenticated browser never fetches
// a dashboard chunk at all.

import { lazy, Suspense, useEffect, useState } from "react";
import {
  clearAuthToken,
  getHealth,
  isAuthenticatedHealth,
  subscribeAuthState,
  type HealthResponse,
} from "./api";
import LoginView from "./components/LoginView";
import MobileBottomNav from "./components/MobileBottomNav";
import TopNav, { type Tab } from "./components/TopNav";
import { useWebNotifications } from "./hooks/useWebNotifications";

// Route-level chunks for the tab-switched surfaces. Splitting happens at the
// import mechanism only: props, selection logic, and the shared WebSocket and
// settings stores live exactly where they did under static imports, and the
// panel mount/unmount pattern below is unchanged. Each lazy component is
// created once at module scope, so a section's chunk is fetched on its first
// render and reused for every later visit across tab switches.
const ApprovalsInbox = lazy(() => import("./components/ApprovalsInbox"));
const ChatView = lazy(() => import("./components/ChatView"));
const DashboardView = lazy(() => import("./components/DashboardView"));
const GoalsManager = lazy(() => import("./components/GoalsManager"));
const MemoryBrowser = lazy(() => import("./components/MemoryBrowser"));
const RunLogViewer = lazy(() => import("./components/RunLogViewer"));
const SchedulerManager = lazy(() => import("./components/SchedulerManager"));
const SettingsManager = lazy(() => import("./components/SettingsManager"));
const StagedChangesDrawer = lazy(() => import("./components/StagedChangesDrawer"));

const VALID_TABS: Tab[] = ["dashboard", "chat", "approvals", "goals", "memory", "indexing", "runs", "schedules", "settings"];

export function isStandaloneMode(): boolean {
  if (typeof window === "undefined") return false;
  const params = new URLSearchParams(window.location.search);
  if (params.get("standalone") === "true") return true;
  const hash = window.location.hash;
  if (hash.includes("standalone=true")) return true;
  return false;
}

function getInitialTab(): Tab {
  if (typeof window === "undefined") return "dashboard";
  if (isStandaloneMode()) return "settings";
  const rawHash = window.location.hash.replace("#", "").toLowerCase();
  const hash = rawHash.split("/")[0].split("?")[0] as Tab;
  if (VALID_TABS.includes(hash)) return hash;
  const rawPath = window.location.pathname.replace(/^\//, "").toLowerCase();
  const path = rawPath.split("/")[0] as Tab;
  if (VALID_TABS.includes(path)) return path;
  return "dashboard";
}

// Gate state before the boot probe answers. "checking" renders a neutral loading
// frame so neither the dashboard nor the login form flashes before the engine
// reports which posture it is serving.
type AuthGate = "checking" | "authenticated" | "required";

// Suspense placeholder for a lazy section while its chunk is in flight. Reuses
// the shell's existing loading frame markup rather than inventing a second
// progress visual: it occupies the same content slot the section will render
// into, so the swap from placeholder to view adds no layout shift.
function SectionProgress() {
  return (
    <div className="section-loading">
      <div className="spinner" />
      <p>Loading section…</p>
    </div>
  );
}

export default function App() {
  const [authGate, setAuthGate] = useState<AuthGate>("checking");
  const [health, setHealth] = useState<HealthResponse | null>(null);

  // Boot probe decides the initial posture from the health shape: a full payload
  // means the request cleared the owner gate (or auth is off), while the minimal
  // liveness object means a login is required.
  useEffect(() => {
    let cancelled = false;
    getHealth()
      .then((response) => {
        if (cancelled) return;
        if (isAuthenticatedHealth(response)) {
          setHealth(response);
          setAuthGate("authenticated");
        } else {
          // Minimal liveness means no valid credential reached the route: drop
          // any stored token so the next login starts clean.
          clearAuthToken();
          setAuthGate("required");
        }
      })
      .catch(() => {
        // Fail closed on unreachable or errored engine: require login rather than
        // rendering an unauthenticated dashboard.
        if (!cancelled) {
          clearAuthToken();
          setAuthGate("required");
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Login, logout, rotation, and uniform 401 all move the gate through this one
  // subscription; a freshly opened gate refreshes health so the header shows the
  // authenticated session instead of the boot liveness shape.
  useEffect(() => {
    return subscribeAuthState((authenticated) => {
      if (!authenticated) {
        setHealth(null);
        // A cleared credential does not by itself mean a login form belongs on
        // screen: the loopback no-auth posture serves no gate at all, so its
        // public health probe keeps returning the full shape after logout. Re-
        // probe with the cleared credential and only require a login when the
        // engine answers with the minimal liveness shape; a deployment that
        // accepts any non-empty value must never ask for one.
        getHealth()
          .then((response) => {
            if (isAuthenticatedHealth(response)) {
              setHealth(response);
              setAuthGate("authenticated");
            } else {
              setAuthGate("required");
            }
          })
          .catch(() => {
            // The credential is already gone and the posture could not be
            // confirmed, so fail toward the login gate: keeping the dashboard
            // would leave a token-less session whose later 401s cannot flip the
            // gate back, stranding the tab on errors with no way to sign in.
            setAuthGate("required");
          });
        return;
      }
      setAuthGate("authenticated");
      getHealth()
        .then((response) => setHealth(response))
        .catch(() => {
          // Keep the previous health rather than blanking the header.
        });
    });
  }, []);

  if (authGate === "required") {
    return <LoginView onAuthenticated={() => setAuthGate("authenticated")} />;
  }

  if (authGate === "checking") {
    return (
      <div className="section-loading">
        <div className="spinner" />
        <p>Connecting to the engine…</p>
      </div>
    );
  }

  return <AuthenticatedApp health={health} />;
}

interface AuthenticatedAppProps {
  // Live engine health owned by the gate so a post-login probe reaches the
  // header without the child re-probing on every mount.
  health: HealthResponse | null;
}

function AuthenticatedApp({ health }: AuthenticatedAppProps) {
  const isStandalone = isStandaloneMode();
  const [tab, setTab] = useState<Tab>(() => (isStandalone ? "settings" : getInitialTab()));
  const [stagedDrawerOpen, setStagedDrawerOpen] = useState(false);
  const [stagedFilesCount, setStagedFilesCount] = useState(0);
  const [pendingChatPrompt, setPendingChatPrompt] = useState<string | null>(null);
  const [targetChatSessionId, setTargetChatSessionId] = useState<string | null>(null);

  function handleOpenChatWithPrompt(prompt: string) {
    setPendingChatPrompt(prompt);
    handleSelectTab("chat");
  }

  function handleOpenSession(sessionId: string) {
    setTargetChatSessionId(sessionId);
    if (typeof window !== "undefined") {
      window.location.hash = `chat/${sessionId}`;
    }
    handleSelectTab("chat");
  }

  const {
    notificationsEnabled,
    permission,
    requestPermission,
    runsBadge,
    clearRunsBadge,
    approvalsBadge,
    clearApprovalsBadge,
    warningsBadge,
    clearWarningsBadge,
    // Owner-attention goal nudges live with the notification hook so the Work
    // group's rolled-up badge has a single source of truth. The defaults keep a
    // partial test double from breaking the shell wiring.
    goalsAttention = 0,
    clearGoalsAttention = () => {},
  } = useWebNotifications();

  useEffect(() => {
    if (isStandalone) return;
    function handleHashChange() {
      const rawHash = window.location.hash.replace("#", "").toLowerCase();
      const current = rawHash.split("/")[0].split("?")[0] as Tab;
      if (VALID_TABS.includes(current)) {
        setTab((previous) => (previous === current ? previous : current));
      }
    }
    window.addEventListener("hashchange", handleHashChange);
    return () => window.removeEventListener("hashchange", handleHashChange);
  }, [isStandalone]);

  function handleSelectTab(selected: Tab) {
    if (isStandalone) return;
    setTab((previous) => (previous === selected ? previous : selected));
    // Writing the hash fires `hashchange`, which would set the same tab a
    // second time; guard the write so selecting the active tab (or an
    // already-synced hash) never triggers the redundant second update.
    if (
      typeof window !== "undefined" &&
      window.location.hash !== `#${selected}` &&
      !window.location.hash.startsWith(`#${selected}/`) &&
      !window.location.hash.startsWith(`#${selected}?`)
    ) {
      window.location.hash = selected;
    }
    if (selected === "runs") clearRunsBadge();
    if (selected === "approvals") clearApprovalsBadge();
    // Goals sits inside the Work group; selecting it acknowledges the same
    // way the flat runs tab does.
    if (selected === "goals") clearGoalsAttention();
    // Warnings surface in the chat banner, so viewing chat clears the bell badge.
    if (selected === "chat") clearWarningsBadge();
  }

  // Bell wiring owns badge clearing plus the permission prompt, while the bell
  // button itself owns the visible toast. Clearing happens only by showing chat:
  // the warnings banner already informs there, so navigating there is the single
  // acknowledgment. Denied and unsupported taps never clear and never re-prompt,
  // keeping the count until the operator actually views chat. The resolved
  // outcome is returned so the bell can toast granted versus guidance without
  // re-reading globals.
  async function handleRequestNotifications(): Promise<
    NotificationPermission | "unsupported"
  > {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return "unsupported";
    }
    // Prefer the hook-owned permission but fall back to the live global so
    // older test doubles without the new field still resolve honestly.
    const current =
      typeof permission === "string"
        ? (permission as NotificationPermission)
        : Notification.permission;
    // Fail-closed: a blocked choice stays blocked until site settings change;
    // never fire a silent re-prompt and never clear unseen warnings.
    if (current === "denied") {
      return "denied";
    }
    if (current === "granted") {
      if (warningsBadge > 0) {
        handleSelectTab("chat");
      }
      return "granted";
    }
    try {
      const outcome = (await requestPermission()) as
        | NotificationPermission
        | "unsupported"
        | void;
      const resolved =
        typeof outcome === "string" ? outcome : Notification.permission;
      if (resolved === "granted" && warningsBadge > 0) {
        handleSelectTab("chat");
      }
      return resolved as NotificationPermission | "unsupported";
    } catch {
      return Notification.permission;
    }
  }

  if (isStandalone) {
    return (
      <div className="app-root standalone-settings">
        <main className="app-main-content">
          <div className="app-container">
            <Suspense fallback={<SectionProgress />}>
              <SettingsManager />
            </Suspense>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="app-root">
      {/* 100% Full-width sticky Top Navigation */}
      <TopNav
        currentTab={tab}
        onSelectTab={handleSelectTab}
        health={health}
        runsBadge={runsBadge}
        approvalsBadge={approvalsBadge}
        goalsBadge={goalsAttention}
        warningsBadge={warningsBadge}
        stagedFilesCount={stagedFilesCount}
        onOpenStagedDrawer={() => setStagedDrawerOpen(true)}
        notificationsEnabled={notificationsEnabled}
        onRequestNotifications={handleRequestNotifications}
      />

      {/* The drawer is a page-level overlay that renders nothing while closed,
          so its in-flight chunk gets a null fallback: any visible placeholder
          here would be a new element the closed state never had, and count
          badge wiring simply begins the moment the chunk lands. */}
      <Suspense fallback={null}>
        <StagedChangesDrawer
          isOpen={stagedDrawerOpen}
          onClose={() => setStagedDrawerOpen(false)}
          onCountChange={setStagedFilesCount}
        />
      </Suspense>

      {/* Main Content Area */}
      <main className="app-main-content">
        <div className="app-container">
          {/* Chat tab is kept mounted so ongoing conversation and session state are preserved across navigation */}
          <div
            className="tab-panel-wrapper"
            style={{ display: tab === "chat" ? "block" : "none", height: tab === "chat" ? "100%" : undefined }}
            aria-hidden={tab !== "chat"}
          >
            {/* The boundary lives inside the display-toggled wrapper so the
                loading placeholder follows the panel's own visibility: while
                chat is not the active tab the chunk fetch is invisible, and
                once loaded the panel stays mounted exactly as before. */}
            <Suspense fallback={<SectionProgress />}>
              <ChatView
                health={health}
                onSelectTab={handleSelectTab}
                isActive={tab === "chat"}
                initialPrompt={pendingChatPrompt}
                onClearInitialPrompt={() => setPendingChatPrompt(null)}
                targetSessionId={targetChatSessionId}
                onClearTargetSessionId={() => setTargetChatSessionId(null)}
              />
            </Suspense>
          </div>

          {tab === "dashboard" ? (
            <Suspense fallback={<SectionProgress />}>
              <DashboardView
                health={health}
                stagedFilesCount={stagedFilesCount}
                onOpenStagedDrawer={() => setStagedDrawerOpen(true)}
                onSelectTab={handleSelectTab}
                onOpenChatWithPrompt={handleOpenChatWithPrompt}
                onOpenSession={handleOpenSession}
              />
            </Suspense>
          ) : null}

          {/* Each tab condition keeps its own boundary: mounting a section on
              first visit and unmounting it on tab switch is the pre-lazy
              behavior, and a per-tab fallback means a slow chunk for one
              section never blanks the content of another. */}
          {tab === "approvals" ? (
            <Suspense fallback={<SectionProgress />}>
              <ApprovalsInbox />
            </Suspense>
          ) : null}
          {tab === "goals" ? (
            <Suspense fallback={<SectionProgress />}>
              <GoalsManager attentionCount={goalsAttention} onOpenSettings={() => setTab("settings")} />
            </Suspense>
          ) : null}
          {tab === "memory" ? (
            <Suspense fallback={<SectionProgress />}>
              <MemoryBrowser view="memory" />
            </Suspense>
          ) : null}
          {tab === "indexing" ? (
            <Suspense fallback={<SectionProgress />}>
              <MemoryBrowser view="indexing" />
            </Suspense>
          ) : null}
          {tab === "runs" ? (
            <Suspense fallback={<SectionProgress />}>
              <RunLogViewer />
            </Suspense>
          ) : null}
          {tab === "schedules" ? (
            <Suspense fallback={<SectionProgress />}>
              <SchedulerManager />
            </Suspense>
          ) : null}
          {tab === "settings" ? (
            <Suspense fallback={<SectionProgress />}>
              <SettingsManager />
            </Suspense>
          ) : null}
        </div>
      </main>

      {/* Mobile bottom tab bar: five canonical groups with unread badges and drop-up menus. Both
          tab surfaces stay mounted on every viewport while the stylesheet
          owns visibility (max-width reveals the bar and hides the top links,
          min-width does the inverse), so a missing or fail-closed viewport
          probe can never leave a phone with zero tab surfaces. The bar keeps
          its distinct mobile landmark so the two surfaces stay uniquely
          named while both are in the DOM. */}
      <MobileBottomNav
        currentTab={tab}
        onSelectTab={(selected) => handleSelectTab(selected)}
        runsBadge={runsBadge}
        approvalsBadge={approvalsBadge}
        goalsBadge={goalsAttention}
      />
    </div>
  );
}
