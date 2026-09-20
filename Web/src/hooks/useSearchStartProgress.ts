// Shared staged Start progress for the SearXNG container lifecycle.
// Centralizes the 1s health poll, minutes-budget client cap, elapsed math, and unmount cleanup
// so the profile menu and the Settings Web pane stay in lockstep instead of duplicating the
// timer, cap, and stage-resolution logic. The hook owns only the stage line (live step plus
// ticking elapsed); busy/disabled ownership stays with callers so the cap path can clear the
// stage line and re-probe the dot without unlocking the toggle before the terminal result lands.
import { useCallback, useEffect, useRef, useState } from "react";
import {
  SEARCH_START_CAP_MS,
  SEARCH_START_POLL_INTERVAL_MS,
  getSearchHealth,
  isSearchStartPullingStage,
  resolveStartStage,
  resolveStartStartedAt,
  startElapsedSeconds,
} from "../api";

export function useSearchStartProgress() {
  // Live Start step plus ticking elapsed count feeding the amber Starting line. Null stage means
  // no step to show; callers render the pill additively beside the persistent status text.
  const [searchStage, setSearchStage] = useState<string | null>(null);
  const [searchStartElapsed, setSearchStartElapsed] = useState(0);
  const searchStartTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  // Latest stage mirror for the cap guard: state reads stale inside the interval closure, so the
  // ref lets the cap suspend while the step reports pulling without waiting for a re-render.
  const stageRef = useRef<string | null>(null);
  // Per-start cap reprobe (dot refresh) stored in a ref so the interval always calls the start
  // that armed it even if the caller re-renders mid-flight.
  const capReprobeRef = useRef<(() => void) | null>(null);

  // Stops the Start poll without touching terminal state; safe to call twice so the cap path and
  // the settle path can share it.
  const clearSearchStartPoll = useCallback(() => {
    if (searchStartTimerRef.current !== null) {
      clearInterval(searchStartTimerRef.current);
      searchStartTimerRef.current = null;
    }
  }, []);

  // Unmount must never leave a 1s poll running behind a closed menu or pane.
  useEffect(() => {
    const timerRef = searchStartTimerRef;
    return () => {
      if (timerRef.current !== null) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }
    };
  }, []);

  // Arms a fresh Start poll: resets the stage line, records the client-side Start instant, and
  // polls health about 1s for the live step plus elapsed. The cap fires only past the
  // minutes-budget window while not pulling; it clears the stage line and re-probes the dot via
  // the caller callback while keeping the toggle locked until the terminal ensure result lands.
  const beginSearchStartProgress = useCallback(
    (onCapReprobe?: () => void) => {
      setSearchStage(null);
      stageRef.current = null;
      setSearchStartElapsed(0);
      const clientStartMs = Date.now();
      capReprobeRef.current = onCapReprobe ?? null;
      clearSearchStartPoll();
      searchStartTimerRef.current = setInterval(() => {
        if (
          Date.now() - clientStartMs > SEARCH_START_CAP_MS &&
          !isSearchStartPullingStage(stageRef.current)
        ) {
          clearSearchStartPoll();
          stageRef.current = null;
          setSearchStage(null);
          capReprobeRef.current?.();
          return;
        }
        getSearchHealth()
          .then((probe) => {
            const stage = resolveStartStage(probe);
            stageRef.current = stage;
            setSearchStage(stage);
            setSearchStartElapsed(
              startElapsedSeconds(resolveStartStartedAt(probe), clientStartMs),
            );
          })
          .catch(() => {
            // Poll failures only skip one tick; the next poll retries while the dot stays put.
          });
      }, SEARCH_START_POLL_INTERVAL_MS);
    },
    [clearSearchStartPoll],
  );

  // Terminal settle stops the Starting line on every path (success, failure, cancellation) so no
  // settle leaves the poll or the pill behind. Busy ownership stays with the caller.
  const endSearchStartProgress = useCallback(() => {
    clearSearchStartPoll();
    stageRef.current = null;
    setSearchStage(null);
  }, [clearSearchStartPoll]);

  return {
    searchStage,
    searchStartElapsed,
    beginSearchStartProgress,
    endSearchStartProgress,
    clearSearchStartPoll,
  };
}
