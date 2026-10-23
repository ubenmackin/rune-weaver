// Rune Weaver Dashboard — Session history hydration, turn adoption on reload, and background run log reconciliation.

import { useCallback, useEffect, useRef, type MutableRefObject } from "react";
import {
  ApiError,
  compareToolActionsByRound,
  getLiveTurn,
  getSession,
  getSessionToolActions,
  groupToolActionsByRound,
  isActiveRunStatus,
  newSessionId,
  parseRunTimestamp,
  toNonNegativeInt,
  type ChatSegment,
  type ToolAction,
} from "../../api";
import { normalizeSessionID } from "../../approvalsSession";
import type { FrozenRunLogEntry } from "../../hooks/useRunningRuns";
import { settleParkedFlight } from "./chatHelpers";
import {
  loadContextTokens,
  loadInputHistory,
  loadSessionTokens,
  mergeHistoryEntries,
  persistInputHistory,
} from "./chatHistoryRecall";
import {
  deduplicateToolActionsByCallID,
  flatTextFromSegments,
  messagesUpToLastUser,
  normalizeCompletedAtMs,
  reconstructMessages,
  toolActionCompletedAtMap,
  toolActionMap,
} from "./chatTimeline";
import {
  PARKED_SETTLE_GRACE_MS,
  WAITING_PREFIX,
  type InFlightTurn,
  type MessageItem,
  type ParkedFlight,
} from "./chatTypes";

// Merges GET /sessions/:id/live-turn into inFlightTurn, preserving any earlier or already-streamed
// segments and prepending pre-refresh tool batches in round order.
export function mergeLiveSnapshotIntoInFlightTurn(
  current: InFlightTurn | null,
  live: {
    reasoning?: string;
    toolActions?: ToolAction[];
    text?: string;
  },
): InFlightTurn {
  const base: InFlightTurn = current ?? {
    toolActions: [],
    text: "",
    held: "",
    segments: [],
  };
  const currentHasData =
    base.text.length > 0 ||
    base.toolActions.length > 0 ||
    base.segments.length > 0;

  if (!currentHasData) {
    const newSegments: ChatSegment[] = [];
    if (live.reasoning && live.reasoning.trim().length > 0) {
      newSegments.push({ kind: "thought", text: live.reasoning });
    }
    if (live.toolActions && live.toolActions.length > 0) {
      const groups = groupToolActionsByRound(
        deduplicateToolActionsByCallID(live.toolActions),
      );
      for (const group of groups) {
        newSegments.push({ kind: "tools", actions: group });
      }
    }
    if (live.text && live.text.trim().length > 0) {
      newSegments.push({ kind: "text", text: live.text });
    }
    return {
      toolActions: deduplicateToolActionsByCallID(live.toolActions ?? []),
      text: live.text ?? "",
      held: base.held ?? "",
      segments: newSegments,
    };
  }

  let nextSegments = [...base.segments];
  let nextActions = [...base.toolActions];
  let nextText = base.text;

  if (
    live.reasoning &&
    live.reasoning.trim().length > 0 &&
    !nextSegments.some((s) => s.kind === "thought")
  ) {
    nextSegments = [
      { kind: "thought" as const, text: live.reasoning },
      ...nextSegments,
    ];
  }

  if (live.toolActions && live.toolActions.length > 0) {
    const liveDeduped = deduplicateToolActionsByCallID(live.toolActions);
    const liveByCallID = new Map<string, ToolAction>();
    for (const a of liveDeduped) {
      if (a.callID) liveByCallID.set(a.callID, a);
    }
    const existingIDs = new Set(nextActions.map((a) => a.callID));
    nextActions = nextActions.map((a) => {
      const match = a.callID ? liveByCallID.get(a.callID) : undefined;
      return match && a.result == null && match.result != null
        ? { ...a, ...match }
        : a;
    });
    nextSegments = nextSegments.map((seg) => {
      if (seg.kind !== "tools") return seg;
      return {
        kind: "tools" as const,
        actions: seg.actions.map((a) => {
          const match = a.callID ? liveByCallID.get(a.callID) : undefined;
          return match && a.result == null && match.result != null
            ? { ...a, ...match }
            : a;
        }),
      };
    });

    const missing = liveDeduped.filter(
      (a) => a.callID && !existingIDs.has(a.callID),
    );
    if (missing.length > 0) {
      nextActions = deduplicateToolActionsByCallID([
        ...missing,
        ...nextActions,
      ]).sort(compareToolActionsByRound);
      const groups = groupToolActionsByRound(
        [...missing].sort(compareToolActionsByRound),
      );
      const insertIdx = nextSegments[0]?.kind === "thought" ? 1 : 0;
      nextSegments.splice(
        insertIdx,
        0,
        ...groups.map((actions) => ({ kind: "tools" as const, actions })),
      );
    }
  }

  if (
    nextText.trim().length === 0 &&
    live.text &&
    live.text.trim().length > 0
  ) {
    nextText = live.text;
    if (!nextSegments.some((s) => s.kind === "text")) {
      nextSegments.push({ kind: "text", text: live.text });
    }
  }

  return {
    ...base,
    toolActions: nextActions,
    text: nextText,
    segments: nextSegments,
  };
}

// Merges already-persisted current-turn rounds (loaded from GET /sessions/:id + tool-actions)
// into inFlightTurn so mid-turn page refreshes display completed rounds immediately.
export function mergePersistedMessagesIntoInFlightTurn(
  current: InFlightTurn | null,
  persistedMessages: MessageItem[],
): InFlightTurn {
  const persistedSegments: ChatSegment[] = [];
  const persistedActions: ToolAction[] = [];
  for (const m of persistedMessages) {
    if (m.role !== "assistant") continue;
    if (m.segments && m.segments.length > 0) {
      for (const seg of m.segments) {
        if (seg.kind === "text" && seg.text.trim().startsWith(WAITING_PREFIX)) {
          continue;
        }
        persistedSegments.push(seg);
      }
    } else if (
      m.text.trim().length > 0 &&
      !m.text.trim().startsWith(WAITING_PREFIX)
    ) {
      persistedSegments.push({ kind: "text", text: m.text });
    }
    if (m.toolActions) {
      persistedActions.push(...m.toolActions);
    }
  }
  const base: InFlightTurn = current ?? {
    toolActions: [],
    text: "",
    held: "",
    segments: [],
  };
  if (persistedSegments.length === 0 && persistedActions.length === 0) {
    return base;
  }
  const currentHasData =
    base.text.length > 0 ||
    base.toolActions.length > 0 ||
    base.segments.length > 0;
  if (!currentHasData) {
    const deduped = deduplicateToolActionsByCallID(persistedActions);
    return {
      toolActions: deduped,
      text: flatTextFromSegments(persistedSegments),
      held: base.held ?? "",
      segments: persistedSegments,
    };
  }
  return mergeLiveSnapshotIntoInFlightTurn(base, {
    toolActions: persistedActions,
    text: flatTextFromSegments(persistedSegments),
  });
}

interface UseChatHistoryLoaderOptions {
  sessionID: string;
  sessionIDRef: MutableRefObject<string>;
  knownDraftIDRef: MutableRefObject<string | null>;
  didRecoverSessionRef: MutableRefObject<boolean>;
  turnSessionIDRef: MutableRefObject<string | null>;
  pendingRef: MutableRefObject<boolean>;
  cancelledRef: MutableRefObject<boolean>;
  activeTurnStartMsRef: MutableRefObject<number | null>;
  messagesRef: MutableRefObject<MessageItem[]>;
  sharedRunsRef: MutableRefObject<ReadonlyArray<FrozenRunLogEntry>>;
  sharedRunningIDsRef: MutableRefObject<string[]>;
  parkedFlightsRef: MutableRefObject<Map<string, ParkedFlight>>;
  backgroundRunningRef: MutableRefObject<Set<string>>;
  inputHistoryRef: MutableRefObject<string[]>;
  historyIndexRef: MutableRefObject<number>;
  draftRef: MutableRefObject<string>;
  sessionBaseRef: MutableRefObject<number>;
  inFlightTurnRef: MutableRefObject<InFlightTurn | null>;
  lastTurnTokensRef: MutableRefObject<number | null>;
  setSessionID: (id: string) => void;
  setMessages: (messages: MessageItem[] | ((prev: MessageItem[]) => MessageItem[])) => void;
  setInFlightTurn: (turn: InFlightTurn | null) => void;
  setPending: (pending: boolean) => void;
  setSessionTokens: (tokens: number) => void;
  setContextTokens: (tokens: number) => void;
  setLastTurnTokens: (tokens: number | null) => void;
  setSessionGoalId: (goalId: string | null) => void;
  armTurnTimeout: () => void;
  clearTurnTimeout: () => void;
  markBackgroundRunning: (normalized: string, running: boolean) => void;
  reapExpiredFlightsAndSurface: () => void;
  refreshApprovals: () => void;
  reconcileReconnecting: () => void;
  isOpen: () => boolean;
  sharedRuns: ReadonlyArray<FrozenRunLogEntry>;
  sharedRunningIDs: string[];
}

export function useChatHistoryLoader({
  sessionID,
  sessionIDRef,
  knownDraftIDRef,
  didRecoverSessionRef,
  turnSessionIDRef,
  pendingRef,
  cancelledRef,
  activeTurnStartMsRef,
  messagesRef,
  sharedRunsRef,
  sharedRunningIDsRef,
  parkedFlightsRef,
  backgroundRunningRef,
  inputHistoryRef,
  historyIndexRef,
  draftRef,
  sessionBaseRef,
  inFlightTurnRef,
  lastTurnTokensRef,
  setSessionID,
  setMessages,
  setInFlightTurn,
  setPending,
  setSessionTokens,
  setContextTokens,
  setLastTurnTokens,
  setSessionGoalId,
  armTurnTimeout,
  clearTurnTimeout,
  markBackgroundRunning,
  reapExpiredFlightsAndSurface,
  refreshApprovals,
  reconcileReconnecting,
  isOpen,
  sharedRuns,
  sharedRunningIDs,
}: UseChatHistoryLoaderOptions) {
  // Reloads persisted history for one session after its terminal frame was missed.
  const reloadActiveHistory = useCallback((activeID: string) => {
    if (!activeID) return;
    if (knownDraftIDRef.current === activeID) return;
    const snapshotID = activeID;
    Promise.all([
      getSession(snapshotID),
      getSessionToolActions(snapshotID).catch(() => null),
    ])
      .then(([res, structured]) => {
        if (
          normalizeSessionID(sessionIDRef.current) !==
          normalizeSessionID(snapshotID)
        ) {
          return;
        }
        if (res && Array.isArray(res.messages)) {
          const isTurnPending =
            pendingRef.current &&
            normalizeSessionID(turnSessionIDRef.current) ===
              normalizeSessionID(snapshotID);
          const actionMap = structured
            ? toolActionMap(structured.actions)
            : undefined;
          const completedAtMap = structured
            ? toolActionCompletedAtMap(structured.actions)
            : undefined;
          let messagesToMap = res.messages;
          if (isTurnPending) {
            messagesToMap = messagesUpToLastUser(res.messages);
          }
          const mapped = reconstructMessages(
            messagesToMap,
            actionMap,
            completedAtMap,
          );
          const prevList = messagesRef.current;
          const lastPrev = prevList[prevList.length - 1];
          const lastMapped = mapped[mapped.length - 1];
          const keep =
            mapped.length < prevList.length &&
            !!lastPrev &&
            lastPrev.role === "assistant" &&
            !lastPrev.isError &&
            (!lastMapped || lastMapped.role !== "assistant");
          const finalMessages = keep ? prevList : mapped;
          setMessages(finalMessages);
          messagesRef.current = finalMessages;
          if (isTurnPending) {
            const fullMapped = reconstructMessages(
              res.messages,
              actionMap,
              completedAtMap,
            );
            const inFlightMessages = fullMapped.slice(mapped.length);
            if (inFlightMessages.length > 0) {
              const merged = mergePersistedMessagesIntoInFlightTurn(
                inFlightTurnRef.current,
                inFlightMessages,
              );
              inFlightTurnRef.current = merged;
              setInFlightTurn(merged);
            }
          }
        }
      })
      .catch((failure) => {
        if (
          normalizeSessionID(sessionIDRef.current) !==
          normalizeSessionID(snapshotID)
        ) {
          return;
        }
        if (
          failure instanceof ApiError &&
          failure.status === 404 &&
          !didRecoverSessionRef.current
        ) {
          didRecoverSessionRef.current = true;
          const next = newSessionId();
          knownDraftIDRef.current = next;
          localStorage.setItem("rw_active_session_id", next);
          setSessionID(next);
        }
      });
  }, [sessionIDRef, knownDraftIDRef, didRecoverSessionRef, pendingRef, turnSessionIDRef, messagesRef, inFlightTurnRef, setInFlightTurn, setMessages, setSessionID]);

  // Reattaches a reloaded tab to a turn the server still owns.
  const tryAdoptReloadedTurn = useCallback(() => {
    if (pendingRef.current) return false;
    if (cancelledRef.current) return false;
    const activeID = sessionIDRef.current;
    if (!activeID) return false;
    const activeNorm = normalizeSessionID(activeID);
    if (!activeNorm) return false;
    if (knownDraftIDRef.current === activeID) return false;
    if (!sharedRunningIDsRef.current.includes(activeNorm)) return false;
    const parked = parkedFlightsRef.current.get(activeNorm);
    if (parked?.pending) return false;
    let startedAt: number | null = null;
    for (const run of sharedRunsRef.current) {
      const raw = (run as { sessionID?: unknown }).sessionID;
      if (typeof raw !== "string" || !raw.trim()) continue;
      if (raw.trim().toLowerCase() !== activeNorm) continue;
      const status = (run as { status?: unknown }).status;
      if (
        !isActiveRunStatus(typeof status === "string" ? status : undefined)
      ) {
        continue;
      }
      const ts = parseRunTimestamp(
        (run as { timestamp?: unknown }).timestamp as string | number,
      ).getTime();
      if (Number.isFinite(ts) && ts > 0) {
        startedAt = ts;
        break;
      }
    }
    const shell: InFlightTurn = { toolActions: [], text: "", held: "", segments: [] };
    inFlightTurnRef.current = shell;
    setInFlightTurn(shell);
    setPending(true);
    pendingRef.current = true;
    turnSessionIDRef.current = activeID;
    activeTurnStartMsRef.current = startedAt ?? Date.now();
    armTurnTimeout();

    getLiveTurn(activeID)
      .then((live) => {
        if (
          normalizeSessionID(sessionIDRef.current) !== activeNorm ||
          !pendingRef.current
        ) {
          return;
        }
        const isLiveActive = live.active ?? false;
        if (live && isLiveActive) {
          const current = inFlightTurnRef.current;
          const next = mergeLiveSnapshotIntoInFlightTurn(current, live);
          if (next !== current) {
            setInFlightTurn(next);
            inFlightTurnRef.current = next;
          }
          const liveTotal = toNonNegativeInt(live.totalTokens);
          if (typeof liveTotal === "number") {
            setLastTurnTokens(liveTotal);
            lastTurnTokensRef.current = liveTotal;
          }
        }
      })
      .catch(() => {});

    return true;
  }, [pendingRef, cancelledRef, sessionIDRef, knownDraftIDRef, sharedRunningIDsRef, parkedFlightsRef, sharedRunsRef, inFlightTurnRef, setInFlightTurn, setPending, turnSessionIDRef, activeTurnStartMsRef, armTurnTimeout, setLastTurnTokens, lastTurnTokensRef]);

  // Load active session messages on initial mount / session change if existing
  useEffect(() => {
    let cancelled = false;
    const activeID = sessionID;
    const hydrated = loadSessionTokens(activeID);
    setSessionTokens(hydrated);
    sessionBaseRef.current = hydrated;
    const hydratedContext = loadContextTokens(activeID);
    setContextTokens(hydratedContext);
    setLastTurnTokens(null);
    setSessionGoalId(null);

    inputHistoryRef.current = loadInputHistory(activeID);
    historyIndexRef.current = -1;
    draftRef.current = "";

    if (knownDraftIDRef.current === activeID) {
      setMessages([]);
      return;
    }

    Promise.all([
      getSession(activeID),
      getSessionToolActions(activeID).catch(() => null),
    ])
      .then(([res, structured]) => {
        if (!cancelled && res && Array.isArray(res.messages)) {
          const isTurnPending =
            pendingRef.current &&
            normalizeSessionID(turnSessionIDRef.current) ===
              normalizeSessionID(activeID);

          const actionMap = structured
            ? toolActionMap(structured.actions)
            : undefined;
          const completedAtMap = structured
            ? toolActionCompletedAtMap(structured.actions)
            : undefined;

          let messagesToMap = res.messages;
          if (isTurnPending) {
            messagesToMap = messagesUpToLastUser(res.messages);
          }

          const mapped = reconstructMessages(
            messagesToMap,
            actionMap,
            completedAtMap,
          );
          setMessages(mapped);
          messagesRef.current = mapped;
          if (isTurnPending) {
            const fullMapped = reconstructMessages(
              res.messages,
              actionMap,
              completedAtMap,
            );
            const inFlightMessages = fullMapped.slice(mapped.length);
            if (inFlightMessages.length > 0) {
              const merged = mergePersistedMessagesIntoInFlightTurn(
                inFlightTurnRef.current,
                inFlightMessages,
              );
              inFlightTurnRef.current = merged;
              setInFlightTurn(merged);
            }
          }
          setSessionGoalId(
            typeof res.goalId === "string" && res.goalId.trim().length > 0
              ? res.goalId
              : null,
          );
          if (
            normalizeSessionID(sessionIDRef.current) !==
            normalizeSessionID(activeID)
          ) {
            return;
          }
          const ordered = [...res.messages].sort((a, b) => {
            const aMs = normalizeCompletedAtMs(a.createdAt) ?? -1;
            const bMs = normalizeCompletedAtMs(b.createdAt) ?? -1;
            return aMs - bMs;
          });
          const backfillTexts: string[] = [];
          for (const m of ordered) {
            if (m.role !== "user") continue;
            const textValue =
              typeof m.content === "string" ? m.content.trim() : "";
            if (!textValue) continue;
            backfillTexts.push(textValue);
          }
          const capped = mergeHistoryEntries(
            inputHistoryRef.current,
            backfillTexts,
          );
          inputHistoryRef.current = capped;
          historyIndexRef.current = -1;
          persistInputHistory(activeID, capped);
        }
      })
      .catch((failure) => {
        if (!cancelled) {
          if (
            failure instanceof ApiError &&
            failure.status === 404 &&
            !didRecoverSessionRef.current
          ) {
            didRecoverSessionRef.current = true;
            const next = newSessionId();
            knownDraftIDRef.current = next;
            localStorage.setItem("rw_active_session_id", next);
            setSessionID(next);
          }
          setSessionGoalId(null);
          setMessages([]);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [sessionID, setSessionTokens, sessionBaseRef, setContextTokens, setLastTurnTokens, setSessionGoalId, inputHistoryRef, historyIndexRef, draftRef, knownDraftIDRef, setMessages, pendingRef, turnSessionIDRef, messagesRef, inFlightTurnRef, setInFlightTurn, sessionIDRef, didRecoverSessionRef, setSessionID]);

  const isOpenRef = useRef(isOpen);
  isOpenRef.current = isOpen;
  const reconcileReconnectingRef = useRef(reconcileReconnecting);
  reconcileReconnectingRef.current = reconcileReconnecting;

  // Reconciles background badges with the authoritative run log.
  useEffect(() => {
    sharedRunsRef.current = sharedRuns;
    sharedRunningIDsRef.current = sharedRunningIDs;
    reconcileReconnectingRef.current();
    reapExpiredFlightsAndSurface();
    const running = sharedRunningIDs;
    const activeNorm = normalizeSessionID(sessionIDRef.current);
    for (const norm of running) {
      if (norm && norm !== activeNorm) {
        markBackgroundRunning(norm, true);
      }
    }
    if (!pendingRef.current && !cancelledRef.current && activeNorm) {
      if (running.includes(activeNorm) && isOpenRef.current()) {
        tryAdoptReloadedTurn();
      }
    }
    const settled = new Set<string>();
    for (const run of sharedRuns) {
      const raw = (run as { sessionID?: unknown }).sessionID;
      if (typeof raw !== "string" || !raw.trim()) continue;
      const norm = raw.trim().toLowerCase();
      if (!norm || running.includes(norm)) continue;
      settled.add(norm);
    }
    const nowMs = Date.now();
    for (const [key, flight] of [...parkedFlightsRef.current]) {
      if (!flight.pending || key === activeNorm) continue;
      if (running.includes(key)) continue;
      if (!settled.has(key)) continue;
      if (nowMs - flight.updatedAt < PARKED_SETTLE_GRACE_MS) continue;
      settleParkedFlight(parkedFlightsRef.current, key);
      markBackgroundRunning(key, false);
    }
    for (const norm of [...backgroundRunningRef.current]) {
      if (!norm || norm === activeNorm) continue;
      const stillPolled = running.includes(norm);
      const stillParked = parkedFlightsRef.current.get(norm)?.pending;
      if (!stillPolled && !stillParked) {
        markBackgroundRunning(norm, false);
      }
    }
    if (pendingRef.current && !cancelledRef.current && activeNorm && !isOpenRef.current()) {
      const liveTurnSID = turnSessionIDRef.current;
      const ownsActive =
        liveTurnSID == null ||
        normalizeSessionID(liveTurnSID) === activeNorm;
      if (ownsActive && !running.includes(activeNorm)) {
        const startedAt = activeTurnStartMsRef.current;
        if (
          startedAt != null &&
          Date.now() - startedAt >= PARKED_SETTLE_GRACE_MS
        ) {
          let hasSettledEvidence = false;
          let stillRunning = false;
          for (const run of sharedRuns) {
            const raw = (run as { sessionID?: unknown }).sessionID;
            if (typeof raw !== "string" || !raw.trim()) continue;
            if (raw.trim().toLowerCase() !== activeNorm) continue;
            const status = (run as { status?: unknown }).status;
            if (
              isActiveRunStatus(
                typeof status === "string" ? status : undefined,
              )
            ) {
              stillRunning = true;
              break;
            }
            const ts = parseRunTimestamp(
              (run as { timestamp?: unknown }).timestamp as
                | string
                | number,
            ).getTime();
            if (!Number.isFinite(ts) || ts <= 0) {
              continue;
            }
            if (ts >= startedAt - 5000) {
              hasSettledEvidence = true;
              break;
            }
          }
          if (!stillRunning && hasSettledEvidence) {
            clearTurnTimeout();
            turnSessionIDRef.current = null;
            activeTurnStartMsRef.current = null;
            pendingRef.current = false;
            setInFlightTurn(null);
            inFlightTurnRef.current = null;
            setPending(false);
            markBackgroundRunning(activeNorm, false);
            reloadActiveHistory(sessionIDRef.current);
            refreshApprovals();
          }
        }
      }
    }
  }, [sharedRuns, sharedRunningIDs, markBackgroundRunning, clearTurnTimeout, reloadActiveHistory, refreshApprovals, reapExpiredFlightsAndSurface, tryAdoptReloadedTurn, activeTurnStartMsRef, backgroundRunningRef, cancelledRef, inFlightTurnRef, parkedFlightsRef, pendingRef, sessionIDRef, setInFlightTurn, setPending, sharedRunningIDsRef, sharedRunsRef, turnSessionIDRef]);

  return {
    reloadActiveHistory,
    tryAdoptReloadedTurn,
  };
}
