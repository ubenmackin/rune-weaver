// Rune Weaver Dashboard — Greeting identity cluster with live attention state.

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
  type Goal,
  type PermissionRequest,
  type RunLogEntry,
} from "../../api";
import {
  getSharedRecentRuns,
  getSharedRunTitle,
} from "./sharedRuns";
import {
  useSharedWebSocket,
  type WSIncomingFrame,
} from "../../hooks/useSharedWebSocket";
import {
  PersonaAvatar,
  resolveAvatarState,
  usePersonaSignals,
  useSleepWakeNow,
} from "../PersonaAvatar";
import {
  GREETING_AVATAR_SIZE,
  GREETING_POLL_MS,
  truncateWorkingTitle,
} from "./dashboardGreeting";
import type { Tab } from "../TopNav";

// Run-title fallback lives once in `dashboard/sharedRuns` (`getSharedRunTitle`) with a single trim
// policy, so the caption and the Working Right Now stream never disagree on what the agent is doing
// — including leading/trailing whitespace.

// Greeting-row identity cluster: avatar, assistant name, and one-line state caption.
export default function DashboardGreetingIdentity({
  onSelectTab,
}: {
  onSelectTab: (tab: Tab) => void;
}) {
  // Persona name, attention, working, and idle clock come from the shared store: Settings publishes
  // the persona, ChatView publishes activity and the working flag, TopNav mirrors attention from the
  // badges it already owns.
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

  // Live snapshot of the signals the sections below already fetch.
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

  // Shared sleep-wake clock owns the clamp/re-arm in one place, so idle→sleeping lands without
  // polling and without a second timer copy. Attention and working short-circuit sleeping, so no
  // timer arms while either is active.
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

  // One line per resolved state. Attention is a button because it routes; working names the first
  // active run truncated to the caption budget; sleeping rests until the next run and idle confirms
  // the queue is clear.
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
