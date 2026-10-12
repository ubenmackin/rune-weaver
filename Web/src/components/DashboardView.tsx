// Rune Weaver Dashboard — Executive Control Center & Mission Overview.
//
// Transforms RuneWeaver from a passive chat bot into an autonomous executive
// assistant. Shows the operator:
// 1. What needs your action (approvals, blocked goals)?
// 2. What we should focus on today (proactive ideas radar)?
// 3. What is working right now (live task trees & tools in flight)?
// 4. Goals momentum & step progress with 1-click advance?
// 5. Upcoming schedule cadence and recent executive report cards?
//
// The greeting row also owns the sole identity surface (settings picker editor excluded):
// the Wisp renders at 112px beside the assistant name and a one-line state
// caption, right-aligned on the welcome headline. Profile and chat surfaces
// show text identity only, so this cluster is where colorway, resolved state,
// and caption meet.

import { useCallback, useEffect, useState } from "react";
import type { ReactNode } from "react";
import {
  goalNeedsInput,
  isActiveRunStatus,
  isGoalUnplanned,
  listApprovals,
  listGoals,
  personaAssistantName,
  personaAvatarColor,
  personaUserName,
  type Goal,
  type HealthResponse,
  type PermissionRequest,
  type RunLogEntry,
} from "../api";
import type { Tab } from "./TopNav";
import DashboardPromptBar from "./dashboard/DashboardPromptBar";
import MorningRecommendations from "./dashboard/MorningRecommendations";
import NeedsActionQueue from "./dashboard/NeedsActionQueue";
import WorkingNowStream from "./dashboard/WorkingNowStream";
import GoalsCockpit from "./dashboard/GoalsCockpit";
import UpcomingSchedules from "./dashboard/UpcomingSchedules";
import RecentReports from "./dashboard/RecentReports";
import SystemPulseCard from "./dashboard/SystemPulseCard";
import RunDetailModal from "./RunDetailModal";
import {
  MAX_TIMER_DELAY_MS,
  PersonaAvatar,
  resolveAvatarState,
  usePersonaSignals,
  useSleepWakeNow,
} from "./PersonaAvatar";
import {
  getSharedRecentRuns,
  getSharedRunTitle,
} from "./dashboard/sharedRuns";
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
}

function getGreeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

// Rendered avatar edge: large enough to read the sprite's eyes and state ring
// at a glance, without overwhelming the headline it shares a row with.
const GREETING_AVATAR_SIZE = 112;

// Caption budget for the in-flight title: one line beside the name, so a runaway
// scheduler message truncates instead of pushing the greeting row taller.
const WORKING_TITLE_LIMIT = 60;

// Live poll cadence while work is in flight, mirroring the Working Right Now
// stream so the caption title stays fresh without extra network. Clamped to
// the shared platform timer ceiling so the interval can never overflow it.
const GREETING_POLL_MS = Math.min(4000, MAX_TIMER_DELAY_MS);

// Shortens a run title to one caption line. Truncation keeps the raw message
// intact everywhere else (the Working Right Now card shows it whole); the
// ellipsis marks the cut so a clipped title never reads as the full one.
function truncateWorkingTitle(title: string): string {
  const trimmed = title.trim();
  if (trimmed.length <= WORKING_TITLE_LIMIT) return trimmed;
  return `${trimmed.slice(0, WORKING_TITLE_LIMIT).trimEnd()}…`;
}

// Run-title fallback lives once in `dashboard/sharedRuns` (`getSharedRunTitle`)
// with a single trim policy, so the caption and the Working Right Now stream
// never disagree on what the agent is doing — including leading/trailing
// whitespace.

// Greeting-row identity cluster: avatar, assistant name, and one-line state
// caption. State resolves through the untouched priority helper fed by the
// REST snapshot the sections below already read (pending approvals, goals
// needing input, active runs) combined with the shared store liveness
// ChatView and TopNav publish (working/activity plus the attention mirror) —
// no new transport, no parallel navigation. Runs ride the shared single-flight
// fetcher so this mount never issues a second `GET /runs` outside the collapse
// window, and the snapshot refreshes on the same lifecycle frames the stream
// and queue already watch. Caption navigation reuses the dashboard's existing
// onSelectTab, so the attention button routes through the shell's single tab
// switcher.
function DashboardGreetingIdentity({
  onSelectTab,
}: {
  onSelectTab: (tab: Tab) => void;
}) {
  // Persona name, attention, working, and idle clock come from the shared
  // store: Settings publishes the persona, ChatView publishes activity and the
  // working flag, TopNav mirrors attention from the badges it already owns.
  // REST counts/titles below combine with those store mirrors (OR) so the
  // resolved state never ignores a publisher. This cluster only reads; it
  // never invents an identity.
  const {
    persona,
    attention: storeAttention,
    working: storeWorking,
    lastActivityAtMs,
  } = usePersonaSignals();
  const [approvals, setApprovals] = useState<PermissionRequest[]>([]);
  const [blockedGoals, setBlockedGoals] = useState<Goal[]>([]);
  const [allGoalsCount, setAllGoalsCount] = useState(0);
  const [activeRuns, setActiveRuns] = useState<RunLogEntry[]>([]);
  const [allRunsCount, setAllRunsCount] = useState(0);
  // False until the first snapshot settles: an absent caption while loading
  // reads as "still looking" rather than a confident idle claim.
  const [loaded, setLoaded] = useState(false);

  // Live snapshot of the signals the sections below already fetch. Failures
  // degrade to empty lists (the same posture as the Needs Action queue) so a
  // down endpoint yields no caption instead of a stale one; the empty-data
  // branch below then owns the render. Runs collapse through the shared
  // single-flight fetcher; lifecycle frames force past its freshness window so
  // a newly started or settled run appears now instead of at the next tick.
  const fetchGreetingSnapshot = useCallback(
    async (forceRefresh = false): Promise<void> => {
      try {
        const [approvalsRes, goalsRes, runRows] = await Promise.all([
          listApprovals(20).catch(() => ({ approvals: [], count: 0 })),
          listGoals().catch(() => ({ goals: [], count: 0 })),
          getSharedRecentRuns(30, { forceRefresh }).catch(
            () => [] as RunLogEntry[],
          ),
        ]);
        const approvalRows = Array.isArray(approvalsRes.approvals)
          ? approvalsRes.approvals
          : [];
        const goalRows = Array.isArray(goalsRes.goals) ? goalsRes.goals : [];
        const runs = Array.isArray(runRows) ? runRows : [];
        setApprovals(approvalRows);
        // Single blocked-goal predicate shared with the Needs Action queue so
        // both surfaces agree on which statuses count as needing input:
        // goals parked awaiting owner input OR unplanned goals not yet planning.
        setBlockedGoals(
          goalRows.filter(
            (goal) =>
              goalNeedsInput(goal.status) ||
              (isGoalUnplanned(goal.status) && !goal.isPlanning),
          ),
        );
        setAllGoalsCount(goalRows.length);
        setActiveRuns(runs.filter((run) => isActiveRunStatus(run.status)));
        setAllRunsCount(runs.length);
      } finally {
        setLoaded(true);
      }
    },
    [],
  );

  useEffect(() => {
    void fetchGreetingSnapshot();
  }, [fetchGreetingSnapshot]);

  // Lifecycle refresh keeps the caption/avatar from sticking to a mount-time
  // snapshot while the stream moves on: approvals and goal updates refresh the
  // queue signals, run frames force the shared runs cache past its window.
  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (
        frameType === "approval" ||
        frameType === "approval_decided" ||
        frameType === "goal_updated" ||
        frameType === "run_started" ||
        frameType === "run_completed"
      ) {
        void fetchGreetingSnapshot(
          frameType === "run_started" || frameType === "run_completed",
        );
      }
    },
    [fetchGreetingSnapshot],
  );

  const handleSocketOpen = useCallback(() => {
    void fetchGreetingSnapshot(true);
  }, [fetchGreetingSnapshot]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        void fetchGreetingSnapshot(true);
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () =>
      document.removeEventListener("visibilitychange", handleVisibility);
  }, [fetchGreetingSnapshot]);

  const approvalsCount = approvals.length;
  const blockedCount = blockedGoals.length;
  const totalAttention = approvalsCount + blockedCount;
  // Single-sourced liveness: the REST snapshot OR the store mirrors. Either
  // publisher lights the state so the greeting never disagrees with the nav
  // badges or the chat working flag it already mirrors.
  const hasAttention = storeAttention || totalAttention > 0;
  const isWorking = storeWorking || activeRuns.length > 0;

  // Shared sleep-wake clock owns the clamp/re-arm in one place, so
  // idle→sleeping lands without polling and without a second timer copy.
  // Attention and working short-circuit sleeping, so no timer arms while
  // either is active.
  const nowMs = useSleepWakeNow(hasAttention, isWorking, lastActivityAtMs);

  const resolvedState = resolveAvatarState({
    hasAttention,
    isWorking,
    lastActivityAtMs,
    nowMs,
  });

  // Polls while work is in flight so the caption title tracks the stream
  // without waiting for the next lifecycle frame. Rides the shared freshness
  // window like the stream, so concurrent polls still collapse to one fetch.
  useEffect(() => {
    if (!isWorking) return;
    const interval = setInterval(() => {
      void fetchGreetingSnapshot();
    }, GREETING_POLL_MS);
    return () => clearInterval(interval);
  }, [isWorking, fetchGreetingSnapshot]);

  // Stock fallback keeps the cluster word-for-word intact when no persona is
  // saved; the colorway helper degrades to violet inside the avatar.
  const personaName = personaAssistantName(persona) ?? "Rune Weaver Agent";
  const personaColor = personaAvatarColor(persona);

  // One line per resolved state. Attention is a button because it routes;
  // working names the first active run truncated to the caption budget;
  // sleeping rests until the next run and idle confirms the queue is clear.
  // Empty data (nothing fetched, no clock, no history) renders no caption
  // rather than inventing a mood. Titles reuse the shared run fallback, so
  // the caption derives from the same signals the stream already names with
  // no invented ownership.
  let caption: ReactNode = null;
  if (loaded) {
    if (hasAttention) {
      // REST counts own the label; the store mirror only lights the state.
      // When the store fires before the snapshot catches up, a count-less
      // fallback keeps the button honest instead of claiming zero.
      const label =
        totalAttention === 1
          ? "1 waiting on you"
          : totalAttention > 1
            ? `${totalAttention} waiting on you`
            : "Waiting on you";
      const destination = approvalsCount > 0 ? "approvals" : "goals";
      caption = (
        <button
          type="button"
          className="dashboard-greeting-caption-button"
          data-testid="dashboard-persona-caption"
          onClick={() => onSelectTab(destination)}
          aria-label={`${label} — open ${destination}`}
        >
          {label}
        </button>
      );
    } else if (isWorking) {
      // The shared fallback names the run exactly as the stream does; when
      // the store working flag fires before the runs snapshot catches up,
      // the bare working copy holds the state without inventing a title.
      const workingTitle =
        activeRuns.length > 0
          ? `Working on ${truncateWorkingTitle(getSharedRunTitle(activeRuns[0]))}`
          : "Working…";
      caption = (
        <span
          className="dashboard-greeting-caption"
          data-testid="dashboard-persona-caption"
        >
          {workingTitle}
        </span>
      );
    } else if (resolvedState === "sleeping") {
      caption = (
        <span
          className="dashboard-greeting-caption"
          data-testid="dashboard-persona-caption"
        >
          Resting — back on next run
        </span>
      );
    } else if (
      lastActivityAtMs > 0 ||
      allGoalsCount > 0 ||
      allRunsCount > 0
    ) {
      caption = (
        <span
          className="dashboard-greeting-caption"
          data-testid="dashboard-persona-caption"
        >
          All caught up
        </span>
      );
    } else {
      caption = null;
    }
  }

  return (
    <div
      className="dashboard-greeting-identity"
      data-testid="dashboard-greeting-identity"
    >
      <PersonaAvatar
        color={personaColor}
        state={resolvedState}
        size={GREETING_AVATAR_SIZE}
        label=""
        dataTestId="dashboard-persona-avatar"
      />
      <div className="dashboard-greeting-identity-text">
        <span
          className="dashboard-greeting-assistant"
          data-testid="dashboard-persona-name"
        >
          {personaName}
        </span>
        {caption}
      </div>
    </div>
  );
}

export default function DashboardView({
  health,
  stagedFilesCount = 0,
  onOpenStagedDrawer,
  onSelectTab,
  onOpenChatWithPrompt,
  onOpenSession,
}: DashboardViewProps) {
  const [inspectedRun, setInspectedRun] = useState<RunLogEntry | null>(null);
  const [goalsRefreshTrigger, setGoalsRefreshTrigger] = useState(0);
  const greeting = getGreeting();
  // Greeting identity follows the same blank rule as the chat header: a stored
  // owner name that trims to empty is indistinguishable from an absent persona,
  // so both surfaces fall back to the stock address instead of greeting an
  // empty string. Reading the shared store keeps the headline live when
  // Settings publishes a rename without a reload.
  const { persona: greetingPersona } = usePersonaSignals();
  const greetingName = personaUserName(greetingPersona).trim();
  const operatorName = greetingName.length > 0 ? greetingName : "Operator";

  function handlePromptSubmit(prompt: string) {
    if (onOpenChatWithPrompt) {
      onOpenChatWithPrompt(prompt);
    } else {
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

        <DashboardPromptBar onSubmitPrompt={handlePromptSubmit} />
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
          <NeedsActionQueue
            onOpenSession={handleOpenSession}
            onOpenGoals={() => onSelectTab("goals")}
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
            onOpenPolicy={() => onSelectTab("settings")}
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
