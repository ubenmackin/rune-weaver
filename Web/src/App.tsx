// Rune Weaver Dashboard — main application shell and section navigation.

import { lazy, Suspense, useCallback, useEffect, useState } from "react";
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
import GettingStartedWizard from "./components/onboarding/GettingStartedWizard";
import { isWizardSnoozed, subscribeWizardSnooze } from "./components/onboarding/wizardSnooze";
import { useOnboardingStatus } from "./hooks/useOnboardingStatus";
import { useWebNotifications } from "./hooks/useWebNotifications";

// Route-level chunks for the tab-switched surfaces.
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

// Suspense placeholder for a lazy section while its chunk is in flight.
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
        // A cleared credential does not by itself mean a login form belongs on screen: the loopback
        // no-auth posture serves no gate at all, so its public health probe keeps returning the full
        // shape after logout.
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
            // The credential is already gone and the posture could not be confirmed, so fail toward
            // the login gate: keeping the dashboard would leave a token-less session whose later
            // 401s cannot flip the gate back, stranding the tab on errors with no way to sign in.
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

  const refreshHealth = useCallback(() => {
    getHealth()
      .then((response) => {
        if (isAuthenticatedHealth(response)) {
          setHealth(response);
        }
      })
      .catch(() => {});
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

  return <AuthenticatedApp health={health} onRefreshHealth={refreshHealth} />;
}

interface AuthenticatedAppProps {
  // Live engine health owned by the gate so a post-login probe reaches the
  // header without the child re-probing on every mount.
  health: HealthResponse | null;
  onRefreshHealth?: () => void;
}

function AuthenticatedApp({ health, onRefreshHealth }: AuthenticatedAppProps) {
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

  // Wizard gate stays behind authentication: this shell only mounts after the
  // owner gate reports authenticated, and standalone never fetches or shows.
  // Snoozed Settings trips hide the wizard until resume or completion.
  const onboarding = useOnboardingStatus({ disabled: isStandalone });
  const [snoozed, setSnoozed] = useState(() => isWizardSnoozed());

  useEffect(() => subscribeWizardSnooze(setSnoozed), []);

  // A present status keeps the wizard mounted across refetch: focus and
  // Check Again re-reads flip isLoading while the cached row stays, so the
  // gate must not unmount on loading alone once a row exists.
  const showWizard =
    !isStandalone &&
    !snoozed &&
    (!onboarding.isLoading || onboarding.status != null) &&
    onboarding.error == null &&
    onboarding.status != null &&
    !onboarding.isCompleted;
  // A failed status fetch never hides silently; the error renders its own gate.
  const showWizardError =
    !isStandalone && !onboarding.isLoading && onboarding.error != null;

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
    if (selected === "chat") {
      clearWarningsBadge();
      onRefreshHealth?.();
    }
  }

  // Bell wiring owns badge clearing plus the permission prompt, while the bell button itself owns
  // the visible toast.
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
              <SettingsManager onSettingsSaved={onRefreshHealth} />
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
                onboardingStatus={onboarding.status}
                onOnboardingRefresh={onboarding.refresh}
                onOnboardingComplete={onboarding.complete}
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
              <MemoryBrowser />
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
              <SettingsManager onSettingsSaved={onRefreshHealth} onOnboardingRefresh={onboarding.refresh} />
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
      {showWizard && onboarding.status ? (
        <GettingStartedWizard
          initialSkippedSteps={onboarding.status.skippedSteps}
          onboardingStatus={onboarding.status}
          onOnboardingRefresh={onboarding.refresh}
          onOnboardingComplete={onboarding.complete}
          onOnboardingSkip={onboarding.skip}
          onFinished={() => {
            void onboarding.refresh().finally(() => handleSelectTab("chat"));
          }}
        />
      ) : null}
      {showWizardError ? (
        <div
          className="modal-backdrop"
          role="dialog"
          aria-modal="true"
          aria-label="Getting started"
        >
          <div
            className="modal-container wizard-modal"
            data-testid="getting-started-error"
          >
            <div className="modal-header">
              <div>
                <h3>Getting started</h3>
              </div>
            </div>
            <div className="modal-body wizard-body">
              <div className="error-banner" role="alert">
                {onboarding.error}
              </div>
            </div>
            <div className="modal-footer wizard-footer">
              <div className="wizard-footer-right">
                <button
                  type="button"
                  className="primary"
                  onClick={() => void onboarding.refresh()}
                >
                  Retry
                </button>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
