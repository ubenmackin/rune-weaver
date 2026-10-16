// Rune Weaver Dashboard — Shared goal detail state and mutation helpers.

import { useCallback, useEffect, useState } from "react";
import {
  advanceGoal,
  ApiError,
  getGoal,
  listRuns,
  parseGoalUpdatedFrame,
  patchGoal,
  patchGoalStep,
  type Goal,
  type GoalDetailResponse,
  type GoalStep,
  type RunLogEntry,
} from "../api";
import {
  useSharedWebSocket,
  type WSIncomingFrame,
} from "./useSharedWebSocket";

// The engine's single-flight refusal is a contention signal, not a transient
// fault, so it earns honest copy instead of the raw transport message. Kept
// as one string builder so both goal surfaces phrase contention identically.
function goalAdvanceConflictMessage(goalTitle: string): string {
  return `"${goalTitle}" is already running — wait for the current run to finish.`;
}

// Active goals pause; every resting state (paused, needs input) resumes. The
// caller re-reads the authoritative row after the PATCH, so this only picks
// the intent, not the resulting stored state.
function goalToggleNextStatus(status: string): "active" | "paused" {
  return status === "active" ? "paused" : "active";
}

// Announcement after a successful pause/resume. One builder keeps the two
// surfaces reading the same verb for the same transition.
function goalToggleNotice(
  nextStatus: "active" | "paused",
  goalTitle: string,
): string {
  return nextStatus === "paused"
    ? `Paused "${goalTitle}".`
    : `Resumed "${goalTitle}".`;
}

// The plan checkbox expresses the two resting states only; blocked and skipped
// steps stay engine-owned and are surfaced without a manual toggle.
export function goalStepNextStatus(step: GoalStep): "done" | "pending" {
  return step.status === "done" ? "pending" : "done";
}

// Maps a failed REST call to owner-facing copy, preferring the engine's own
// message over a generic fallback so a rejected request still names its cause.
function goalFailureMessage(failure: unknown, fallback: string): string {
  return failure instanceof ApiError ? failure.message : fallback;
}

// Reads a goal, its plan, and its bounded linked runs in one pass so no
// surface renders a half-filled row. Run history is best-effort: a runs fetch
// failure leaves an empty list rather than failing the whole detail.
async function loadGoalDetail(
  goalId: string,
  runLimit: number,
): Promise<{ detail: GoalDetailResponse; runs: RunLogEntry[] }> {
  const [detail, runList] = await Promise.all([
    getGoal(goalId),
    listRuns(runLimit, undefined, undefined, goalId).catch(() => ({
      runs: [] as RunLogEntry[],
      count: 0,
    })),
  ]);
  return { detail, runs: runList.runs };
}

export interface UseGoalDetailOptions {
  // Bounds the linked-runs fetch; each surface shows its own slice.
  runLimit: number;
  // Owner-facing error sink. A mutation clears it (null) before running so
  // stale copy never lingers beside a fresh attempt.
  onError?: (message: string | null) => void;
  // Owner-facing notice sink, used for advance and pause/resume announcements.
  onNotice?: (notice: string | null) => void;
}

export interface GoalDetailController {
  detail: GoalDetailResponse | null;
  runs: RunLogEntry[];
  // Id of the goal whose detail read is in flight; null when idle.
  loadingDetailId: string | null;
  // Id of the goal whose mutation is in flight so a caller can lock one row
  // without disabling every other row.
  advancingGoalId: string | null;
  togglingGoalId: string | null;
  togglingStepId: string | null;
  advance: (goal: Goal) => Promise<void>;
  // Resolves to the refreshed detail on success so a list caller can sync its
  // row without a second read; null when the change failed.
  toggleStatus: (goal: Goal) => Promise<GoalDetailResponse | null>;
  // Resolves true when the step PATCH and the follow-up detail read both
  // landed, so a list caller knows to refresh its derived tallies.
  setStepStatus: (step: GoalStep, nextStatus: string) => Promise<boolean>;
}

// Owns goal detail plus its mutations for one id at a time. A null id leaves the controller idle
// (no read, no push handling) so a collapsed panel keeps no stale row state.
export function useGoalDetail(
  goalId: string | null,
  options: UseGoalDetailOptions,
): GoalDetailController {
  const { runLimit, onError, onNotice } = options;
  // Detail and its linked runs are stored together with the goal they belong
  // to so switching goals never renders the previous goal's plan for a frame.
  const [loaded, setLoaded] = useState<{
    goalId: string;
    detail: GoalDetailResponse;
    runs: RunLogEntry[];
  } | null>(null);
  const [loadingDetailId, setLoadingDetailId] = useState<string | null>(null);
  const [advancingGoalId, setAdvancingGoalId] = useState<string | null>(null);
  const [togglingGoalId, setTogglingGoalId] = useState<string | null>(null);
  const [togglingStepId, setTogglingStepId] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!goalId) return;
    setLoadingDetailId(goalId);
    try {
      const result = await loadGoalDetail(goalId, runLimit);
      setLoaded({ goalId, detail: result.detail, runs: result.runs });
    } catch (failure) {
      onError?.(goalFailureMessage(failure, "Goal detail failed"));
    } finally {
      setLoadingDetailId(null);
    }
  }, [goalId, runLimit, onError]);

  useEffect(() => {
    // Drop the previous goal's payload on a switch so nothing stale lingers;
    // the active-goal guard on read already prevents a one-frame flash, and
    // this releases the retained rows as well.
    setLoaded(null);
    if (!goalId) return;
    void reload();
  }, [goalId, reload]);

  // The push is the refresh: only a snapshot naming this goal re-reads detail,
  // so an unrelated goal's progress never re-fetches this surface.
  const handleSocketFrame = useCallback(
    (frame: WSIncomingFrame) => {
      if (!goalId) return;
      const snapshot = parseGoalUpdatedFrame(
        frame as unknown as Record<string, unknown>,
      );
      if (snapshot && snapshot.id === goalId) {
        void reload();
      }
    },
    [goalId, reload],
  );
  useSharedWebSocket(handleSocketFrame);

  const advance = useCallback(
    async (goal: Goal) => {
      setAdvancingGoalId(goal.id);
      onError?.(null);
      onNotice?.(null);
      try {
        await advanceGoal(goal.id);
        onNotice?.(
          goal.status === "unplanned"
            ? `Drafting plan for "${goal.title}"…`
            : `Working on "${goal.title}"…`,
        );
        await reload();
      } catch (failure) {
        onError?.(
          failure instanceof ApiError && failure.status === 409
            ? goalAdvanceConflictMessage(goal.title)
            : goalFailureMessage(
                failure,
                goal.status === "unplanned"
                  ? `Planning "${goal.title}" failed`
                  : `Working on "${goal.title}" failed`,
              ),
        );
      } finally {
        setAdvancingGoalId(null);
      }
    },
    [reload, onError, onNotice],
  );

  const toggleStatus = useCallback(
    async (goal: Goal): Promise<GoalDetailResponse | null> => {
      setTogglingGoalId(goal.id);
      onError?.(null);
      const nextStatus = goalToggleNextStatus(goal.status);
      try {
        const updated = await patchGoal(goal.id, { status: nextStatus });
        onNotice?.(goalToggleNotice(nextStatus, goal.title));
        await reload();
        return updated;
      } catch (failure) {
        onError?.(goalFailureMessage(failure, "Status change failed"));
        return null;
      } finally {
        setTogglingGoalId(null);
      }
    },
    [reload, onError, onNotice],
  );

  const setStepStatus = useCallback(
    async (step: GoalStep, nextStatus: string): Promise<boolean> => {
      setTogglingStepId(step.id);
      onError?.(null);
      try {
        await patchGoalStep(step.goalId, step.id, { status: nextStatus });
        await reload();
        return true;
      } catch (failure) {
        onError?.(goalFailureMessage(failure, "Step update failed"));
        return false;
      } finally {
        setTogglingStepId(null);
      }
    },
    [reload, onError],
  );

  // Only expose payload that belongs to the current goal id; a switch hides
  // the previous goal's detail immediately even before its read lands.
  const active = loaded && loaded.goalId === goalId ? loaded : null;

  return {
    detail: active?.detail ?? null,
    runs: active?.runs ?? [],
    loadingDetailId,
    advancingGoalId,
    togglingGoalId,
    togglingStepId,
    advance,
    toggleStatus,
    setStepStatus,
  };
}
