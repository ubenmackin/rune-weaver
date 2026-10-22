// Rune Weaver Dashboard — Executive Control Center & Mission Overview.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  listSessions,
  personaUserName,
  type HealthResponse,
  type RunLogEntry,
} from "../api";
import { fetchJson } from "../api/http";
import type { OnboardingStatus as ApiOnboardingStatus } from "../api/onboarding";
import type { Tab } from "./TopNav";
import DashboardPromptBar from "./dashboard/DashboardPromptBar";
import GettingStartedCard, {
  deriveChecklistItems,
  countCompletedItems,
  CHECKLIST_TOTAL,
  type ChecklistItemId,
} from "./dashboard/GettingStartedCard";
import {
  parseOnboardingStatus as parseSeedStatus,
  type OnboardingFinishDestination,
} from "./onboarding/seedPrompt";
import { finishOnboardingFlow } from "./onboarding/onboardingSchedule";
import MorningRecommendations from "./dashboard/MorningRecommendations";
import NeedsActionQueue from "./dashboard/NeedsActionQueue";
import WorkingNowStream from "./dashboard/WorkingNowStream";
import GoalsCockpit from "./dashboard/GoalsCockpit";
import UpcomingSchedules from "./dashboard/UpcomingSchedules";
import RecentReports from "./dashboard/RecentReports";
import SystemPulseCard from "./dashboard/SystemPulseCard";
import RunDetailModal from "./RunDetailModal";
import { usePersonaSignals } from "./PersonaAvatar";
import { getGreeting } from "./dashboard/dashboardGreeting";
import DashboardGreetingIdentity from "./dashboard/DashboardGreetingIdentity";
import {
  useSharedWebSocket,
  type WSIncomingFrame,
} from "../hooks/useSharedWebSocket";

export interface DashboardViewProps {
  health: HealthResponse | null;
  stagedFilesCount?: number;
  onOpenStagedDrawer?: () => void;
  onSelectTab: (tab: Tab) => void;
  onOpenChatWithPrompt?: (prompt: string) => void;
  onOpenSession?: (sessionId: string) => void;
  onboardingStatus?: ApiOnboardingStatus | null;
  onOnboardingRefresh?: () => Promise<void>;
  onOnboardingComplete?: (seedPromptUsed: string) => Promise<void>;
  onFinished?: (destination?: OnboardingFinishDestination) => void;
  initialPrompt?: string | null;
  onClearInitialPrompt?: () => void;
  promptAttention?: boolean;
}

// Checklist above the queue; Finish lands via destination prefill without send.
function DashboardGettingStarted({
  onSelectTab,
  onboardingStatus,
  onOnboardingRefresh,
  onOnboardingComplete,
  onFinished,
}: {
  onSelectTab: (tab: Tab) => void;
  onboardingStatus?: ApiOnboardingStatus | null;
  onOnboardingRefresh?: () => Promise<void>;
  onOnboardingComplete?: (seedPromptUsed: string) => Promise<void>;
  onFinished?: (destination?: OnboardingFinishDestination) => void;
}) {
  // App-owned status is the single live source when injected; local fetch stays
  // as the isolated fallback so the card still renders without the shell.
  const hasExternal = onboardingStatus !== undefined;
  const [raw, setRaw] = useState<Record<string, unknown> | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [hasChat, setHasChat] = useState(false);
  const [finishing, setFinishing] = useState(false);
  const [finishError, setFinishError] = useState<string | null>(null);
  const refreshInFlightRef = useRef(false);
  const refreshPendingRef = useRef(false);
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const refreshAll = useCallback(async () => {
    // Coalesce overlapping lifecycle frames so concurrent polls collapse to one fetch.
    if (refreshInFlightRef.current) {
      refreshPendingRef.current = true;
      return;
    }
    refreshInFlightRef.current = true;
    try {
      if (hasExternal) {
        // Live truth rides the App-owned hook; no second status GET here.
        if (onOnboardingRefresh) {
          try {
            await onOnboardingRefresh();
          } catch {
            // Stale snapshot still renders; next focus converges.
          }
        }
      } else {
        try {
          setRaw((await fetchJson<Record<string, unknown>>("/onboarding/status")) ?? null);
        } catch {
          setRaw(null);
        } finally {
          setLoaded(true);
        }
      }
      try {
        const sessions = await listSessions();
        setHasChat(Array.isArray(sessions.sessions) && sessions.sessions.length > 0);
      } catch {
        setHasChat(false);
      }
    } finally {
      refreshInFlightRef.current = false;
      if (refreshPendingRef.current) {
        refreshPendingRef.current = false;
        void refreshAll();
      }
    }
  }, [hasExternal, onOnboardingRefresh]);

  useEffect(() => {
    void refreshAll();
  }, [refreshAll]);

  useEffect(() => {
    return () => {
      if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    };
  }, []);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (frameType === "goal_updated" || frameType === "run_started" || frameType === "run_completed") {
        // Trailing debounce keeps run-frame bursts to one refresh per window.
        if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
        refreshTimerRef.current = setTimeout(() => {
          void refreshAll();
        }, 300);
      }
    },
    [refreshAll],
  );
  useSharedWebSocket(handleWSFrame);

  function handleStart(itemId: ChecklistItemId): void {
    if (itemId === "chat") {
      onSelectTab("chat");
      return;
    }
    onSelectTab("settings");
    if (itemId === "policy" && typeof window !== "undefined") {
      window.location.hash = "#settings/access";
    }
  }

  async function handleFinish(): Promise<void> {
    if (finishing) return;
    setFinishing(true);
    setFinishError(null);
    try {
      let seedRaw: Record<string, unknown> | null;
      if (hasExternal) {
        // Single source: prompt derives from the App-owned snapshot.
        seedRaw = (onboardingStatus ?? null) as unknown as Record<string, unknown> | null;
      } else {
        seedRaw = raw;
        try {
          seedRaw = await fetchJson<Record<string, unknown>>("/onboarding/status");
          setRaw(seedRaw ?? null);
          setLoaded(true);
        } catch {
          // Stale snapshot still seeds fail-closed to the generic prompt.
        }
      }
      const parsed = parseSeedStatus(seedRaw);
      const { destination } = await finishOnboardingFlow({
        status: parsed,
        goal: null,
        complete: onOnboardingComplete,
      });
      // Completion closes the App gate; refresh keeps live truth before nav.
      if (!onOnboardingComplete) await refreshAll().catch(() => {});
      if (hasExternal) await refreshAll();
      // Destination prefill never auto-sends; the owner taps Ask to send.
      if (onFinished) onFinished(destination);
      else onSelectTab("dashboard");
    } catch (err) {
      setFinishError(err instanceof Error ? err.message : "Failed to finish onboarding");
    } finally {
      setFinishing(false);
    }
  }

  const effectiveRaw: Record<string, unknown> | null = hasExternal
    ? ((onboardingStatus as unknown as Record<string, unknown> | null) ?? null)
    : raw;
  const effectiveLoaded = hasExternal ? true : loaded;
  if (!effectiveLoaded || effectiveRaw === null) return null;
  const completed = effectiveRaw.completedAt ?? effectiveRaw.completed_at;
  if (typeof completed === "string" && completed.trim()) return null;
  const checklistInput = { ...(effectiveRaw as Record<string, unknown>), firstChatSent: hasChat, hasChat };
  const items = deriveChecklistItems(checklistInput);
  if (countCompletedItems(items) >= CHECKLIST_TOTAL) return null;
  const dismissedValue = effectiveRaw.checklistDismissed ?? effectiveRaw.checklist_dismissed;
  const dismissed = dismissedValue === true || dismissedValue === 1;

  return (
    <>
      {finishError ? (
        <div
          className="notice-banner error"
          role="alert"
          data-testid="getting-started-finish-error"
        >
          {finishError}
        </div>
      ) : null}
      <GettingStartedCard
        status={checklistInput}
        dismissed={dismissed}
        finishing={finishing}
        onDismiss={() => void refreshAll()}
        onExpand={() => void refreshAll()}
        onStart={handleStart}
        onSelectTab={onSelectTab}
        onFinish={() => void handleFinish()}
      />
    </>
  );
}

export default function DashboardView({
  health,
  stagedFilesCount = 0,
  onOpenStagedDrawer,
  onSelectTab,
  onOpenChatWithPrompt,
  onOpenSession,
  onboardingStatus,
  onOnboardingRefresh,
  onOnboardingComplete,
  onFinished,
  initialPrompt,
  onClearInitialPrompt,
  promptAttention = false,
}: DashboardViewProps) {
  const [inspectedRun, setInspectedRun] = useState<RunLogEntry | null>(null);
  const [goalsRefreshTrigger, setGoalsRefreshTrigger] = useState(0);
  const greeting = getGreeting();
  // Greeting identity follows the same blank rule as the chat header: a stored owner name that
  // trims to empty is indistinguishable from an absent persona, so both surfaces fall back to the
  // stock address instead of greeting an empty string.
  const { persona: greetingPersona } = usePersonaSignals();
  const greetingName = personaUserName(greetingPersona).trim();
  const operatorName = greetingName.length > 0 ? greetingName : "Operator";

  function handlePromptSubmit(prompt: string) {
    if (onOpenChatWithPrompt) {
      // Prefill clears on send so a second landing can prefill again.
      onClearInitialPrompt?.();
      onOpenChatWithPrompt(prompt);
    } else {
      // No chat handler keeps the text in the bar instead of discarding input.
      onSelectTab("chat");
    }
  }

  function handleOpenSession(sessionId: string) {
    if (onOpenSession) {
      onOpenSession(sessionId);
    } else {
      localStorage.setItem("rw_active_session_id", sessionId);
      onSelectTab("chat");
    }
  }

  return (
    <div className="dashboard-root" role="region" aria-label="Executive Operations Dashboard">
      {/* Executive Welcome & Command Bar */}
      <header className="dashboard-hero-header">
        <div className="dashboard-greeting-row">
          <div className="dashboard-greeting-text">
            <h1 className="dashboard-greeting-title">{greeting}, {operatorName}</h1>
            <p className="dashboard-greeting-subtitle">
              Here is your daily operations overview, proactive radar, and autonomous work progress.
            </p>
          </div>
          <DashboardGreetingIdentity onSelectTab={onSelectTab} />
        </div>

        <DashboardPromptBar onSubmitPrompt={handlePromptSubmit} initialPrompt={initialPrompt} attention={promptAttention} />
      </header>

      {/* Proactive Radar (Morning Recommendations Banner) */}
      <MorningRecommendations
        onOpenChatWithIdea={(prompt) => handlePromptSubmit(prompt)}
        onIdeaAccepted={() => setGoalsRefreshTrigger((k) => k + 1)}
      />

      {/* Responsive Workstream & Cockpit Grid */}
      <div className="dashboard-main-grid">
        {/* Left Column: Primary Workstream (Approvals, Working Now, Recent Reports) */}
        <div className="dashboard-stream-column">
          <DashboardGettingStarted
            onSelectTab={onSelectTab}
            onboardingStatus={onboardingStatus}
            onOnboardingRefresh={onOnboardingRefresh}
            onOnboardingComplete={onOnboardingComplete}
            onFinished={onFinished}
          />
          <NeedsActionQueue
            onOpenSession={handleOpenSession}
            onOpenGoals={() => onSelectTab("goals")}
            onOpenSchedules={() => onSelectTab("schedules")}
          />

          <WorkingNowStream
            onOpenSession={handleOpenSession}
          />

          <RecentReports
            onOpenRuns={() => onSelectTab("runs")}
            onInspectRun={(run) => setInspectedRun(run)}
            onOpenSession={handleOpenSession}
          />
        </div>

        {/* Right Column: Side Cockpit (Telemetry, Goals Momentum, Upcoming Schedules) */}
        <div className="dashboard-cockpit-column">
          <SystemPulseCard
            health={health}
            stagedFilesCount={stagedFilesCount}
            onOpenStagedDrawer={onOpenStagedDrawer}
            onOpenSettings={() => onSelectTab("settings")}
            onOpenInbox={() => onSelectTab("approvals")}
            onOpenPolicy={() => {
              // Deep link lands on Access through the settings hash sync
              // with no reload; the shell keeps the settings tab selected.
              onSelectTab("settings");
              if (typeof window !== "undefined") {
                window.location.hash = "#settings/access";
              }
            }}
          />

          <GoalsCockpit
            refreshTrigger={goalsRefreshTrigger}
            onOpenGoals={() => onSelectTab("goals")}
            onOpenGoalDetail={() => onSelectTab("goals")}
          />

          <UpcomingSchedules
            onOpenSchedules={() => onSelectTab("schedules")}
          />
        </div>
      </div>

      {/* Run Inspection Modal */}
      {inspectedRun && (
        <RunDetailModal
          run={inspectedRun}
          onClose={() => setInspectedRun(null)}
        />
      )}
    </div>
  );
}
