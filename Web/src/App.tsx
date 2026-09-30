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

import { useEffect, useState } from "react";
import {
  clearAuthToken,
  getHealth,
  isAuthenticatedHealth,
  subscribeAuthState,
  type HealthResponse,
} from "./api";
import ApprovalsInbox from "./components/ApprovalsInbox";
import ChatView from "./components/ChatView";
import GoalsManager from "./components/GoalsManager";
import LoginView from "./components/LoginView";
import MemoryBrowser from "./components/MemoryBrowser";
import MobileBottomNav from "./components/MobileBottomNav";
import RunLogViewer from "./components/RunLogViewer";
import SchedulerManager from "./components/SchedulerManager";
import SettingsManager from "./components/SettingsManager";
import StagedChangesDrawer from "./components/StagedChangesDrawer";
import TopNav, { type Tab } from "./components/TopNav";
import { useWebNotifications } from "./hooks/useWebNotifications";

const VALID_TABS: Tab[] = ["chat", "approvals", "goals", "memory", "indexing", "runs", "schedules", "settings"];

export function isStandaloneMode(): boolean {
  if (typeof window === "undefined") return false;
  const params = new URLSearchParams(window.location.search);
  if (params.get("standalone") === "true") return true;
  const hash = window.location.hash;
  if (hash.includes("standalone=true")) return true;
  return false;
}

function getInitialTab(): Tab {
  if (typeof window === "undefined") return "chat";
  if (isStandaloneMode()) return "settings";
  const rawHash = window.location.hash.replace("#", "").toLowerCase();
  const hash = rawHash.split("/")[0].split("?")[0] as Tab;
  if (VALID_TABS.includes(hash)) return hash;
  const rawPath = window.location.pathname.replace(/^\//, "").toLowerCase();
  const path = rawPath.split("/")[0] as Tab;
  if (VALID_TABS.includes(path)) return path;
  return "chat";
}

// Gate state before the boot probe answers. "checking" renders a neutral loading
// frame so neither the dashboard nor the login form flashes before the engine
// reports which posture it is serving.
type AuthGate = "checking" | "authenticated" | "required";

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
    if (typeof window !== "undefined" && window.location.hash !== `#${selected}`) {
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
            <SettingsManager />
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

      <StagedChangesDrawer
        isOpen={stagedDrawerOpen}
        onClose={() => setStagedDrawerOpen(false)}
        onCountChange={setStagedFilesCount}
      />

      {/* Main Content Area */}
      <main className="app-main-content">
        <div className="app-container">
          {/* Chat tab is kept mounted so ongoing conversation and session state are preserved across navigation */}
          <div
            className="tab-panel-wrapper"
            style={{ display: tab === "chat" ? "block" : "none", height: tab === "chat" ? "100%" : undefined }}
            aria-hidden={tab !== "chat"}
          >
            <ChatView health={health} onSelectTab={handleSelectTab} />
          </div>

          {tab === "approvals" ? <ApprovalsInbox /> : null}
          {tab === "goals" ? <GoalsManager attentionCount={goalsAttention} /> : null}
          {tab === "memory" ? <MemoryBrowser view="memory" /> : null}
          {tab === "indexing" ? <MemoryBrowser view="indexing" /> : null}
          {tab === "runs" ? <RunLogViewer /> : null}
          {tab === "schedules" ? <SchedulerManager /> : null}
          {tab === "settings" ? <SettingsManager /> : null}
        </div>
      </main>

      {/* Mobile bottom tab bar: four canonical groups with unread badges and drop-up menus. Both
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
