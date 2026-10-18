// Rune Weaver Dashboard — Multi-session background turn parking and restore management.

import { useCallback, useRef, useState } from "react";
import {
  isValidToolIDs,
  normalizeRoundIndex,
  toNonNegativeInt,
  type ToolResult,
} from "../../api";
import { sanitizeWarnings } from "../../warnings";
import type {
  WSIncomingFrame,
  WSToolEndFrame,
  WSToolStartFrame,
} from "../../hooks/useSharedWebSocket";
import { logWarn } from "../../logger";
import {
  mergeWarningLists,
  parkedFlightKey,
  pruneExpiredParkedFlights,
  storeParkedFlight,
} from "./chatHelpers";
import {
  contextTokensKey,
  loadSessionTokens,
  sessionTokensKey,
} from "./chatHistoryRecall";
import {
  appendDeltaToSegments,
  appendReasoningDeltaToSegments,
  appendToolStartToSegments,
  isToolResult,
  updateToolEndInSegments,
} from "./chatTimeline";
import type { InFlightTurn, MessageItem, ParkedFlight } from "./chatTypes";

export function useParkedFlights() {
  const parkedFlightsRef = useRef<Map<string, ParkedFlight>>(new Map());
  const [backgroundRunningIDs, setBackgroundRunningIDs] = useState<string[]>([]);
  const backgroundRunningRef = useRef<Set<string>>(new Set());
  const [trimmedLiveFlights, setTrimmedLiveFlights] = useState<string[]>([]);

  const markBackgroundRunning = useCallback((normalized: string, running: boolean) => {
    if (!normalized) return;
    const current = backgroundRunningRef.current;
    if (running) {
      if (current.has(normalized)) return;
      current.add(normalized);
    } else {
      if (!current.has(normalized)) return;
      current.delete(normalized);
    }
    setBackgroundRunningIDs([...current]);
  }, []);

  const reapExpiredFlightsAndSurface = useCallback(() => {
    const expired = pruneExpiredParkedFlights(parkedFlightsRef.current);
    for (const prunedKey of expired.prunedKeys) {
      markBackgroundRunning(prunedKey, false);
    }
    if (expired.prunedLiveKeys.length > 0) {
      setTrimmedLiveFlights((previous) => [
        ...previous,
        ...expired.prunedLiveKeys.filter((k) => !previous.includes(k)),
      ]);
    }
  }, [markBackgroundRunning]);

  const parkFlight = useCallback(
    (
      activeID: string | null | undefined,
      inFlightTurn: InFlightTurn | null,
      messages: MessageItem[],
      turnWarnings: string[],
      lastTurnTokens: number | null,
      sessionBase: number,
      cancelled: boolean,
    ) => {
      const key = parkedFlightKey(activeID);
      if (!key) {
        logWarn(
          "[ChatView] cannot park active turn without a session id; keeping live view",
        );
        return;
      }
      reapExpiredFlightsAndSurface();
      const snapshot = inFlightTurn;
      const outcome = storeParkedFlight(parkedFlightsRef.current, key, {
        turn: snapshot
          ? {
              toolActions: [...snapshot.toolActions],
              text: snapshot.text,
              held: snapshot.held ?? "",
              segments: snapshot.segments.map((segment) =>
                segment.kind === "tools"
                  ? { kind: "tools" as const, actions: [...segment.actions] }
                  : { ...segment },
              ),
            }
          : { toolActions: [], text: "", held: "", segments: [] },
        pending: true,
        messages: [...messages],
        completedMessage: null,
        warnings: [...turnWarnings],
        turnTokens: lastTurnTokens,
        base: sessionBase,
        cancelled,
        updatedAt: Date.now(),
      });
      if (outcome.evictedKey) {
        markBackgroundRunning(outcome.evictedKey, false);
      }
      if (outcome.evictedLive || outcome.refused) {
        const trimmedKey = outcome.evictedKey ?? key;
        setTrimmedLiveFlights((previous) =>
          previous.includes(trimmedKey) ? previous : [...previous, trimmedKey],
        );
      }
      markBackgroundRunning(key, true);
    },
    [markBackgroundRunning, reapExpiredFlightsAndSurface],
  );

  const updateParkedFlightFromFrame = useCallback(
    (frameSessionID: string, data: WSIncomingFrame) => {
      const key = parkedFlightKey(frameSessionID);
      if (!key) {
        logWarn(
          "[ChatView] dropping background frame for empty session key",
        );
        setTrimmedLiveFlights((previous) =>
          previous.includes("unknown") ? previous : [...previous, "unknown"],
        );
        return;
      }
      const frameType =
        typeof (data as unknown as Record<string, unknown>).type === "string"
          ? (data as unknown as Record<string, unknown>).type
          : undefined;
      const ensureFlight = (): ParkedFlight => {
        const existing = parkedFlightsRef.current.get(key);
        if (existing) {
          const refreshed: ParkedFlight = {
            ...existing,
            updatedAt: Date.now(),
          };
          parkedFlightsRef.current.delete(key);
          parkedFlightsRef.current.set(key, refreshed);
          return refreshed;
        }
        const base = loadSessionTokens(frameSessionID);
        const created: ParkedFlight = {
          turn: { toolActions: [], text: "", held: "", segments: [] },
          pending: true,
          warnings: [],
          turnTokens: null,
          base,
          cancelled: false,
          updatedAt: Date.now(),
        };
        reapExpiredFlightsAndSurface();
        const outcome = storeParkedFlight(parkedFlightsRef.current, key, created);
        if (outcome.evictedKey) {
          markBackgroundRunning(outcome.evictedKey, false);
        }
        if (outcome.evictedLive || outcome.refused) {
          const trimmedKey = outcome.evictedKey ?? key;
          setTrimmedLiveFlights((previous) =>
            previous.includes(trimmedKey) ? previous : [...previous, trimmedKey],
          );
        }
        markBackgroundRunning(key, true);
        return created;
      };
      if (
        frameType === "delta" ||
        frameType === "reasoning_delta" ||
        frameType === "tool_start" ||
        frameType === "tool_end" ||
        frameType === "warning" ||
        frameType === "turn_alive" ||
        frameType === "turn_tokens" ||
        frameType === "tool_progress"
      ) {
        const flight = ensureFlight();
        if (!flight.turn) {
          flight.turn = { toolActions: [], text: "", held: "", segments: [] };
        }
        if (frameType === "delta") {
          const rawDelta: unknown = (data as unknown as Record<string, unknown>).delta;
          const deltaText = typeof rawDelta === "string" ? rawDelta : "";
          if (deltaText) {
            flight.turn.text += deltaText;
            flight.turn.segments = appendDeltaToSegments(
              flight.turn.segments,
              deltaText,
            );
          }
        } else if (frameType === "reasoning_delta") {
          const rawDelta: unknown = (data as unknown as Record<string, unknown>).delta;
          const deltaText = typeof rawDelta === "string" ? rawDelta : "";
          if (deltaText) {
            flight.turn.segments = appendReasoningDeltaToSegments(
              flight.turn.segments,
              deltaText,
            );
          }
        } else if (frameType === "tool_start") {
          const rawCallID: unknown = (data as unknown as Record<string, unknown>).callID;
          const rawToolName: unknown = (data as unknown as Record<string, unknown>).toolName;
          const rawArgs: unknown = (data as unknown as Record<string, unknown>).argumentsJSON;
          if (!isValidToolIDs(rawToolName, rawCallID)) {
            return;
          }
          const callID = (rawCallID as string).trim();
          const toolName = (rawToolName as string).trim();
          const started = {
            callID,
            toolName,
            argumentsJSON: typeof rawArgs === "string" ? rawArgs : "{}",
            ...((data as WSToolStartFrame).roundIndex !== undefined
              ? {
                  roundIndex: normalizeRoundIndex(
                    (data as WSToolStartFrame).roundIndex,
                  ),
                }
              : {}),
          };
          flight.turn.toolActions.push(started);
          flight.turn.segments = appendToolStartToSegments(
            flight.turn.segments,
            started,
          );
        } else if (frameType === "tool_end") {
          const rawCallID: unknown = (data as unknown as Record<string, unknown>).callID;
          const rawToolName: unknown = (data as unknown as Record<string, unknown>).toolName;
          const rawResult: unknown = (data as unknown as Record<string, unknown>).result;
          if (!isValidToolIDs(rawToolName, rawCallID)) {
            return;
          }
          if (rawResult != null && !isToolResult(rawResult)) return;
          const result: ToolResult | null = isToolResult(rawResult) ? rawResult : null;
          const callID = (rawCallID as string).trim();
          const toolName = (rawToolName as string).trim();
          const round = normalizeRoundIndex(
            (data as WSToolEndFrame).roundIndex,
          );
          const hasMatch = flight.turn.toolActions.some(
            (action) => action.callID === callID,
          );
          if (hasMatch) {
            flight.turn.toolActions = flight.turn.toolActions.map((action) =>
              action.callID === callID
                ? {
                    ...action,
                    result,
                    ...(round !== undefined ? { roundIndex: round } : {}),
                  }
                : action,
            );
          } else {
            const fallbackIndex = flight.turn.toolActions.findIndex(
              (action) => !action.result && action.toolName === toolName,
            );
            if (fallbackIndex !== -1) {
              flight.turn.toolActions = flight.turn.toolActions.map(
                (action, index) =>
                  index === fallbackIndex
                    ? {
                        ...action,
                        result,
                        ...(round !== undefined ? { roundIndex: round } : {}),
                      }
                    : action,
              );
            }
          }
          flight.turn.segments = updateToolEndInSegments(
            flight.turn.segments,
            callID,
            toolName,
            result,
            round,
          );
        } else if (frameType === "warning") {
          const rawWarning: unknown = (data as unknown as Record<string, unknown>).message;
          if (typeof rawWarning !== "string" || !rawWarning.trim()) return;
          const trimmed = rawWarning.trim();
          if (!flight.warnings.includes(trimmed)) flight.warnings.push(trimmed);
        } else if (frameType === "turn_tokens") {
          const rawTotal: unknown = (data as unknown as Record<string, unknown>)
            .turnTotalTokens;
          const turnTotal = toNonNegativeInt(rawTotal);
          if (turnTotal != null) {
            flight.turnTokens = turnTotal;
          }
        }
        return;
      }
      if (
        frameType === "done" ||
        frameType === "cancelled" ||
        frameType === "error"
      ) {
        const flight = parkedFlightsRef.current.get(key);
        if (frameType === "done") {
          const terminalWarnings = sanitizeWarnings(
            (data as unknown as Record<string, unknown>).warnings,
          );
          if (terminalWarnings.length > 0 && flight) {
            flight.warnings = mergeWarningLists(
              flight.warnings,
              terminalWarnings,
            );
          }
          const rawSessionTokens: unknown = (data as unknown as Record<string, unknown>)
            .sessionTokens;
          const rawContextTokens: unknown = (data as unknown as Record<string, unknown>)
            .contextTokens;
          const rawTotal: unknown = (data as unknown as Record<string, unknown>).totalTokens;
          const authoritative = toNonNegativeInt(rawSessionTokens);
          const authContextTokens = toNonNegativeInt(rawContextTokens);
          const turnTotal = toNonNegativeInt(rawTotal);
          try {
            if (authoritative != null) {
              localStorage.setItem(
                sessionTokensKey(frameSessionID),
                String(authoritative),
              );
            } else if (flight && turnTotal != null) {
              localStorage.setItem(
                sessionTokensKey(frameSessionID),
                String(flight.base + turnTotal),
              );
            }
            if (authContextTokens != null) {
              localStorage.setItem(
                contextTokensKey(frameSessionID),
                String(authContextTokens),
              );
            }
          } catch {
            // Storage stays best-effort.
          }
        }
        if (flight) {
          flight.pending = false;
          flight.turn = null;
          flight.updatedAt = Date.now();
          parkedFlightsRef.current.delete(key);
          parkedFlightsRef.current.set(key, flight);
        } else {
          parkedFlightsRef.current.delete(key);
        }
        markBackgroundRunning(key, false);
      }
    },
    [markBackgroundRunning, reapExpiredFlightsAndSurface],
  );

  return {
    parkedFlightsRef,
    backgroundRunningIDs,
    backgroundRunningRef,
    trimmedLiveFlights,
    setTrimmedLiveFlights,
    markBackgroundRunning,
    reapExpiredFlightsAndSurface,
    parkFlight,
    updateParkedFlightFromFrame,
  };
}
