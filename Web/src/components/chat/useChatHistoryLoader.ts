// Rune Weaver Dashboard — Session history hydration, turn adoption on reload, and background run log reconciliation.

import { useCallback, useEffect, useRef, type MutableRefObject } from "react";
import {
  ApiError,
  getLiveTurn,
  getSession,
  getSessionToolActions,
  groupToolActionsByRound,
  isActiveRunStatus,
  newSessionId,
  parseRunTimestamp,
  toNonNegativeInt,
  type ChatSegment,
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
  messagesUpToLastUser,
  normalizeCompletedAtMs,
  reconstructMessages,
  toolActionCompletedAtMap,
  toolActionMap,
} from "./chatTimeline";
import {
  PARKED_SETTLE_GRACE_MS,
  type InFlightTurn,
  type MessageItem,
  type ParkedFlight,
} from "./chatTypes";

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
          let messagesToMap = res.messages;
          if (isTurnPending) {
            messagesToMap = messagesUpToLastUser(res.messages);
          }
          const mapped = reconstructMessages(
            messagesToMap,
            structured ? toolActionMap(structured.actions) : undefined,
            structured
              ? toolActionCompletedAtMap(structured.actions)
              : undefined,
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
  }, [sessionIDRef, knownDraftIDRef, didRecoverSessionRef, pendingRef, turnSessionIDRef, messagesRef, setMessages, setSessionID]);

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
        const isLiveActive = live.active ?? live.isRunning ?? false;
        if (live && isLiveActive) {
          const current = inFlightTurnRef.current;
          const currentHasData =
            current &&
            (current.text.length > 0 ||
              current.toolActions.length > 0 ||
              current.segments.length > 0);
          let next: InFlightTurn | null = current;
          if (currentHasData && current) {
            if (
              live.reasoning &&
              live.reasoning.trim().length > 0 &&
              !current.segments.some((s) => s.kind === "thought")
            ) {
              next = {
                ...current,
                segments: [
                  { kind: "thought" as const, text: live.reasoning },
                  ...current.segments,
                ],
              };
            }
          } else {
            const newSegments: ChatSegment[] = [];
            if (live.reasoning && live.reasoning.trim().length > 0) {
              newSegments.push({
                kind: "thought",
                text: live.reasoning,
              });
            }
            if (live.toolActions && live.toolActions.length > 0) {
              const groups = groupToolActionsByRound(live.toolActions);
              for (const group of groups) {
                newSegments.push({ kind: "tools", actions: group });
              }
            }
            if (live.text && live.text.trim().length > 0) {
              newSegments.push({
                kind: "text",
                text: live.text,
              });
            }
            next = {
              toolActions: live.toolActions ?? [],
              text: live.text ?? "",
              held: "",
              segments: newSegments,
            };
          }
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

          let messagesToMap = res.messages;
          if (isTurnPending) {
            messagesToMap = messagesUpToLastUser(res.messages);
          }

          const mapped = reconstructMessages(
            messagesToMap,
            structured ? toolActionMap(structured.actions) : undefined,
            structured
              ? toolActionCompletedAtMap(structured.actions)
              : undefined,
          );
          setMessages(mapped);
          messagesRef.current = mapped;
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
  }, [sessionID, setSessionTokens, sessionBaseRef, setContextTokens, setLastTurnTokens, setSessionGoalId, inputHistoryRef, historyIndexRef, draftRef, knownDraftIDRef, setMessages, pendingRef, turnSessionIDRef, messagesRef, sessionIDRef, didRecoverSessionRef, setSessionID]);

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
