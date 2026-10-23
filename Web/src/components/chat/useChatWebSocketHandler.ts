// Rune Weaver Dashboard — WebSocket incoming frame dispatcher handling streaming events, turn completions, errors, and approvals.

import { useCallback, type MutableRefObject } from "react";
import {
  compareToolActionsByRound,
  getGoal,
  isActiveRunStatus,
  isValidToolIDs,
  newSessionId,
  normalizeRoundIndex,
  parseGoalUpdatedFrame,
  parseRecallDiagnostics,
  parseToolProgress,
  textContainsPlaceholderForCall,
  toNonNegativeInt,
  type Goal,
  type PermissionRequest,
  type ToolProgress,
  type ToolResult,
} from "../../api";
import { sanitizeWarnings } from "../../warnings";
import type {
  WSIncomingFrame,
  WSToolEndFrame,
  WSToolStartFrame,
} from "../../hooks/useSharedWebSocket";
import {
  isRecord,
  mergeApprovalFrame,
  normalizeSessionID,
  runSessionID,
} from "../../approvalsSession";
import { publishAgentActivity } from "../PersonaAvatar";
import { appendLiveDelta } from "../liveTextBuffer";
import {
  isSteerMissFrame,
  isTooLongFrame,
  mergeWarningLists,
  storeParkedFlight,
} from "./chatHelpers";
import {
  carryHistoryForward,
  contextTokensKey,
  loadSessionTokens,
  sessionTokensKey,
} from "./chatHistoryRecall";
import {
  appendDeltaToSegments,
  appendReasoningDeltaToSegments,
  appendToolStartToSegments,
  buildDoneSegments,
  deduplicateToolActionsByCallID,
  flatActionsFromSegments,
  flatTextFromSegments,
  isToolAction,
  isToolResult,
  normalizeCompletedAtMs,
  removeResumedCallFromMessages,
  updateToolEndInSegments,
} from "./chatTimeline";
import {
  MAX_MESSAGES,
  WAITING_PREFIX,
  type InFlightTurn,
  type MessageItem,
  type ParkedFlight,
} from "./chatTypes";

interface UseChatWebSocketHandlerOptions {
  sessionIDRef: MutableRefObject<string>;
  turnSessionIDRef: MutableRefObject<string | null>;
  pendingRef: MutableRefObject<boolean>;
  cancelledRef: MutableRefObject<boolean>;
  activeTurnStartMsRef: MutableRefObject<number | null>;
  inFlightTurnRef: MutableRefObject<InFlightTurn | null>;
  sessionGoalIdRef: MutableRefObject<string | null>;
  sessionTokensRef: MutableRefObject<number>;
  sessionBaseRef: MutableRefObject<number>;
  pendingSteerRef: MutableRefObject<Array<{ id: string; text: string }>>;
  pendingNormalRef: MutableRefObject<{ id: string; text: string } | null>;
  inputHistoryRef: MutableRefObject<string[]>;
  latestPromptRef: MutableRefObject<string>;
  parkedFlightsRef: MutableRefObject<Map<string, ParkedFlight>>;

  setSessionID: (id: string) => void;
  setInFlightTurn: (
    turn:
      | InFlightTurn
      | null
      | ((prev: InFlightTurn | null) => InFlightTurn | null),
  ) => void;
  setPending: (pending: boolean) => void;
  setMessages: (updater: (prev: MessageItem[]) => MessageItem[]) => void;
  setInput: (value: string | ((prev: string) => string)) => void;
  setError: (err: string | null) => void;
  setTurnWarnings: (updater: string[] | ((prev: string[]) => string[])) => void;
  setPendingApprovals: (
    updater:
      | PermissionRequest[]
      | ((prev: PermissionRequest[]) => PermissionRequest[]),
  ) => void;
  setToolProgressByCallID: (
    updater:
      | Map<string, ToolProgress>
      | ((prev: Map<string, ToolProgress>) => Map<string, ToolProgress>),
  ) => void;
  setSessionGoal: (goal: Goal | null) => void;
  setActiveModel: (model: string) => void;
  setContextLimit: (limit: number) => void;
  setLastTurnTokens: (tokens: number | null) => void;
  setSessionTokens: (tokens: number) => void;
  setContextTokens: (tokens: number) => void;

  armTurnTimeout: () => void;
  clearTurnTimeout: () => void;
  clearAllToolProgress: () => void;
  forgetToolCall: (callID: string) => void;
  forgetToolCancelMark: (callID: string) => void;
  refreshApprovals: () => void;
  updateParkedFlightFromFrame: (frameSessionID: string, data: WSIncomingFrame) => void;
  markBackgroundRunning: (key: string, running: boolean) => void;
  preNameSessionIfFirst: (sessionId: string, promptText: string) => void;
}

export function useChatWebSocketHandler({
  sessionIDRef,
  turnSessionIDRef,
  pendingRef,
  cancelledRef,
  activeTurnStartMsRef,
  inFlightTurnRef,
  sessionGoalIdRef,
  sessionTokensRef,
  sessionBaseRef,
  pendingSteerRef,
  pendingNormalRef,
  inputHistoryRef,
  latestPromptRef,
  parkedFlightsRef,

  setSessionID,
  setInFlightTurn,
  setPending,
  setMessages,
  setInput,
  setError,
  setTurnWarnings,
  setPendingApprovals,
  setToolProgressByCallID,
  setSessionGoal,
  setActiveModel,
  setContextLimit,
  setLastTurnTokens,
  setSessionTokens,
  setContextTokens,

  armTurnTimeout,
  clearTurnTimeout,
  clearAllToolProgress,
  forgetToolCall,
  forgetToolCancelMark,
  refreshApprovals,
  updateParkedFlightFromFrame,
  markBackgroundRunning,
  preNameSessionIfFirst,
}: UseChatWebSocketHandlerOptions) {
  const handleWSMessage = useCallback(
    (data: WSIncomingFrame) => {
      if (!isRecord(data)) return;
      const frameSessionID =
        typeof data.sessionID === "string" ? data.sessionID : undefined;
      const frameType = typeof data.type === "string" ? data.type : undefined;

      if (
        frameType === "done" ||
        frameType === "cancelled" ||
        frameType === "error" ||
        frameType === "run_started" ||
        frameType === "run_completed"
      ) {
        publishAgentActivity(Date.now());
      }


      if (
        frameSessionID &&
        normalizeSessionID(frameSessionID) !== normalizeSessionID(sessionIDRef.current)
      ) {
        if (
          frameType === "delta" ||
          frameType === "reasoning_delta" ||
          frameType === "tool_start" ||
          frameType === "tool_end" ||
          frameType === "done" ||
          frameType === "warning" ||
          frameType === "turn_alive" ||
          frameType === "turn_tokens" ||
          frameType === "tool_progress" ||
          frameType === "cancelled" ||
          frameType === "error"
        ) {
          updateParkedFlightFromFrame(frameSessionID, data);
          return;
        }
        return;
      }

      if (
        !frameSessionID &&
        (frameType === "delta" ||
          frameType === "reasoning_delta" ||
          frameType === "tool_start" ||
          frameType === "tool_end" ||
          frameType === "done" ||
          frameType === "warning" ||
          frameType === "turn_alive" ||
          frameType === "turn_tokens" ||
          frameType === "tool_progress" ||
          frameType === "tool_cancel_miss" ||
          frameType === "error" ||
          frameType === "cancelled")
      ) {
        return;
      }

      if (frameType === "goal_updated") {
        const snapshot = parseGoalUpdatedFrame(data);
        if (
          snapshot &&
          sessionGoalIdRef.current &&
          snapshot.id === sessionGoalIdRef.current
        ) {
          setSessionGoal(snapshot);
        }
        return;
      }

      if (frameType === "turn_tokens") {
        const record = data as unknown as Record<string, unknown>;
        const rawTurnTotal = record.turnTotalTokens;
        const rawRoundIndex = record.roundIndex;
        const rawRoundTokens = record.roundTokens;
        const parsedTurnTotal = toNonNegativeInt(rawTurnTotal);
        if (parsedTurnTotal == null) {
          return;
        }
        if (toNonNegativeInt(rawRoundIndex) == null) {
          return;
        }
        if (toNonNegativeInt(rawRoundTokens) == null) {
          return;
        }
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
        }
        if (cancelledRef.current) return;
        const turnTotal = parsedTurnTotal;
        setLastTurnTokens(turnTotal);
        const base = sessionBaseRef.current;
        const safeBase = toNonNegativeInt(base);
        if (safeBase != null) {
          setSessionTokens(safeBase + turnTotal);
        }
        const rawContextTokens = record.contextTokens;
        const liveContextTokens = toNonNegativeInt(rawContextTokens);
        if (typeof liveContextTokens === "number") {
          setContextTokens(liveContextTokens);
        }
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
          armTurnTimeout();
        }
        return;
      }

      if (frameType === "turn_alive") {
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
          armTurnTimeout();
        }
        return;
      }

      if (frameType === "tool_progress") {
        if (cancelledRef.current) return;
        const progress = parseToolProgress(data);
        if (!progress) return;
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
        }
        const callID = progress.callID;
        setToolProgressByCallID((previous) => {
          const next = new Map(previous);
          next.set(callID, progress);
          return next;
        });
        if (pendingRef.current && turnSessionIDRef.current != null) {
          armTurnTimeout();
        }
        return;
      }

      if (frameType === "tool_start") {
        if (cancelledRef.current) return;
        const rawCallID: unknown = data.callID;
        const rawToolName: unknown = data.toolName;
        const rawArgs: unknown = data.argumentsJSON;
        if (!isValidToolIDs(rawToolName, rawCallID)) {
          return;
        }
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
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
        setMessages((prev) => removeResumedCallFromMessages(prev, callID));
        setInFlightTurn((prev) => {
          const existing = prev ? prev.toolActions : [];
          const existingSegments = prev ? prev.segments : [];
          const nextActions = existing.some((a) => a.callID === callID)
            ? existing.map((a) => (a.callID === callID ? { ...a, ...started } : a))
            : [...existing, started];
          return {
            toolActions: nextActions,
            text: prev ? prev.text : "",
            held: prev ? (prev.held ?? "") : "",
            segments: appendToolStartToSegments(existingSegments, started),
          };
        });
        if (pendingRef.current && turnSessionIDRef.current != null) {
          armTurnTimeout();
        }
        return;
      }

      if (frameType === "tool_end") {
        if (cancelledRef.current) return;
        const rawCallID: unknown = data.callID;
        const rawToolName: unknown = data.toolName;
        const rawResult: unknown = data.result;
        if (!isValidToolIDs(rawToolName, rawCallID)) {
          return;
        }
        if (rawResult != null && !isToolResult(rawResult)) return;
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
        }
        const result: ToolResult | null = isToolResult(rawResult) ? rawResult : null;
        const callID = (rawCallID as string).trim();
        const toolName = (rawToolName as string).trim();
        const round = normalizeRoundIndex(
          (data as WSToolEndFrame).roundIndex,
        );
        forgetToolCall(callID);
        setMessages((prev) => removeResumedCallFromMessages(prev, callID));
        setInFlightTurn((prev) => {
          if (!prev) return null;
          const hasMatch = prev.toolActions.some(
            (action) => action.callID === callID,
          );
          let updatedActions = prev.toolActions;
          if (hasMatch) {
            updatedActions = prev.toolActions.map((action) =>
              action.callID === callID
                ? {
                    ...action,
                    result,
                    ...(round !== undefined ? { roundIndex: round } : {}),
                  }
                : action,
            );
          } else {
            const fallbackIndex = prev.toolActions.findIndex(
              (action) => !action.result && action.toolName === toolName,
            );
            if (fallbackIndex !== -1) {
              updatedActions = prev.toolActions.map((action, index) =>
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
          return {
            ...prev,
            toolActions: updatedActions,
            segments: updateToolEndInSegments(
              prev.segments,
              callID,
              toolName,
              result,
              round,
            ),
          };
        });
        if (pendingRef.current && turnSessionIDRef.current != null) {
          armTurnTimeout();
        }
        return;
      }

      if (frameType === "tool_cancel_miss") {
        const rawCallID: unknown = (data as unknown as Record<string, unknown>).callID;
        if (typeof rawCallID === "string" && rawCallID.trim().length > 0) {
          forgetToolCancelMark(rawCallID.trim());
        }
        return;
      }

      if (frameType === "delta") {
        if (cancelledRef.current) return;
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
          armTurnTimeout();
        }
        const rawDelta: unknown = data.delta;
        const deltaText = typeof rawDelta === "string" ? rawDelta : "";
        if (deltaText) {
          setInFlightTurn((prev) => {
            const currentText = prev ? prev.text : "";
            const currentHeld = prev ? (prev.held ?? "") : "";
            const currentSegments = prev ? prev.segments : [];
            const buffered = appendLiveDelta(currentText, currentHeld, deltaText);
            return {
              toolActions: prev ? prev.toolActions : [],
              text: buffered.committed,
              held: buffered.held,
              segments: appendDeltaToSegments(currentSegments, deltaText),
            };
          });
        }
      } else if (frameType === "reasoning_delta") {
        if (cancelledRef.current) return;
        if (pendingRef.current && turnSessionIDRef.current != null) {
          if (
            !frameSessionID ||
            normalizeSessionID(frameSessionID) !==
              normalizeSessionID(turnSessionIDRef.current)
          ) {
            return;
          }
          armTurnTimeout();
        }
        const rawDelta: unknown = data.delta;
        const deltaText = typeof rawDelta === "string" ? rawDelta : "";
        if (deltaText) {
          setInFlightTurn((prev) => ({
            toolActions: prev ? prev.toolActions : [],
            text: prev ? prev.text : "",
            held: prev ? (prev.held ?? "") : "",
            segments: appendReasoningDeltaToSegments(
              prev ? prev.segments : [],
              deltaText,
            ),
          }));
        }
      } else if (frameType === "approval") {
        const request = mergeApprovalFrame(data);
        if (!request) {
          return;
        }
        if (pendingRef.current && turnSessionIDRef.current != null) {
          armTurnTimeout();
        }
        setPendingApprovals((previous) =>
          previous.some((item) => item.id === request.id)
            ? previous.map((item) => (item.id === request.id ? request : item))
            : [...previous, request],
        );
      } else if (frameType === "warning") {
        const rawWarning: unknown = data.message;
        if (typeof rawWarning !== "string" || rawWarning.trim().length === 0) {
          return;
        }
        if (pendingRef.current && turnSessionIDRef.current != null) {
          armTurnTimeout();
        }
        const line = rawWarning;
        setTurnWarnings((previous) =>
          previous.includes(line) ? previous : [...previous, line],
        );
      } else if (frameType === "done") {
        clearTurnTimeout();
        clearAllToolProgress();
        turnSessionIDRef.current = null;
        activeTurnStartMsRef.current = null;
        const doneRecord = data as unknown as Record<string, unknown>;
        const rawRetained = doneRecord.retainedSteerCount;
        const retained = toNonNegativeInt(rawRetained);
        if (retained != null) {
          pendingSteerRef.current =
            retained === 0 ? [] : pendingSteerRef.current.slice(-retained);
        } else {
          pendingSteerRef.current = [];
        }
        pendingNormalRef.current = null;
        const earlyWarnings = sanitizeWarnings(
          (data as unknown as Record<string, unknown>).warnings,
        );
        if (earlyWarnings.length > 0) {
          setTurnWarnings((previous) => mergeWarningLists(previous, earlyWarnings));
        }
        if (cancelledRef.current) {
          setInFlightTurn(null);
          inFlightTurnRef.current = null;
          pendingRef.current = false;
          setPending(false);
          return;
        }
        const currentSid = frameSessionID || sessionIDRef.current;
        if (
          frameSessionID &&
          normalizeSessionID(frameSessionID) !== normalizeSessionID(sessionIDRef.current)
        ) {
          inputHistoryRef.current = carryHistoryForward(
            inputHistoryRef.current,
            frameSessionID,
            sessionIDRef.current,
          );
          setSessionID(frameSessionID);
        }
        const rawModelName: unknown = data.modelName;
        const rawContextLength: unknown = data.contextLength;
        const rawTotalTokens: unknown = data.totalTokens;
        const rawSessionTokens: unknown = data.sessionTokens;
        const rawContextTokens: unknown = data.contextTokens;
        const rawDoneText: unknown = data.text;
        const rawToolActions: unknown = data.toolActions;
        const rawIsParked: unknown = data.isParked;
        const isParked = rawIsParked === true;
        const modelName = typeof rawModelName === "string" ? rawModelName : undefined;
        const contextLength =
          typeof rawContextLength === "number" ? rawContextLength : undefined;
        const totalTokens = toNonNegativeInt(rawTotalTokens);
        const sessionTokensValue = toNonNegativeInt(rawSessionTokens);
        const contextTokensValue = toNonNegativeInt(rawContextTokens);
        const doneText = typeof rawDoneText === "string" ? rawDoneText : undefined;
        const doneToolActions = Array.isArray(rawToolActions)
          ? rawToolActions.filter(isToolAction)
          : undefined;
        if (modelName) setActiveModel(modelName);
        if (contextLength) setContextLimit(contextLength);
        if (typeof totalTokens === "number") {
          setLastTurnTokens(totalTokens);
        }
        if (typeof contextTokensValue === "number") {
          setContextTokens(contextTokensValue);
          try {
            localStorage.setItem(contextTokensKey(currentSid), String(contextTokensValue));
          } catch {
            // Storage is best-effort only.
          }
        }
        if (typeof sessionTokensValue === "number") {
          const cumulative = sessionTokensValue;
          setSessionTokens(cumulative);
          if (!isParked) {
            sessionBaseRef.current = cumulative;
          }
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(cumulative));
          } catch {
            // Storage is best-effort only.
          }
        } else if (typeof totalTokens === "number") {
          const turnTotal = totalTokens;
          const base = sessionBaseRef.current;
          const fallbackBase =
            toNonNegativeInt(base) ?? sessionTokensRef.current;
          const next = fallbackBase + turnTotal;
          setSessionTokens(next);
          if (!isParked) {
            sessionBaseRef.current = next;
          }
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(next));
          } catch {
            // Storage is best-effort only.
          }
        }

        preNameSessionIfFirst(currentSid, latestPromptRef.current);

        const snapshot = inFlightTurnRef.current;
        const snapshotFullText =
          (snapshot?.text ?? "") + (snapshot?.held ?? "");
        const orderedDoneActions = deduplicateToolActionsByCallID([
          ...(doneToolActions ?? []),
        ]).sort(compareToolActionsByRound);
        const finalActions =
          orderedDoneActions.length > 0
            ? orderedDoneActions
            : deduplicateToolActionsByCallID([
                ...(snapshot?.toolActions ?? []),
              ]).sort(compareToolActionsByRound);
        const doneSegments = buildDoneSegments(
          snapshot?.segments ?? [],
          finalActions,
          doneText,
          snapshotFullText,
        );
        const flatText =
          doneSegments.length > 0
            ? flatTextFromSegments(doneSegments)
            : (doneText ?? snapshotFullText ?? "");
        const flatActions = flatActionsFromSegments(doneSegments);
        const doneCompletedAt = normalizeCompletedAtMs(
          (data as unknown as Record<string, unknown>).completedAt,
        );
        const doneRecall = parseRecallDiagnostics(
          (data as unknown as Record<string, unknown>).recallDiagnostics,
        );
        const finalMsg: MessageItem = {
          id: newSessionId(),
          role: "assistant",
          text: flatText,
          toolActions: flatActions.length > 0 ? flatActions : undefined,
          segments: doneSegments.length > 0 ? doneSegments : undefined,
          ...(doneCompletedAt != null ? { completedAt: doneCompletedAt } : {}),
          ...(doneRecall ? { recallDiagnostics: doneRecall } : {}),
        };
        setMessages((prev) => {
          const base = prev.filter((m) => {
            if (m.role !== "assistant") return true;
            const overlaps =
              finalActions.length > 0 &&
              ((m.toolActions?.some((a) =>
                finalActions.some(
                  (fa) => fa.callID && fa.callID === a.callID,
                ),
              ) ??
                false) ||
                finalActions.some(
                  (fa) =>
                    fa.callID &&
                    textContainsPlaceholderForCall(m.text, fa.callID),
                ));
            if (overlaps) return false;
            if (isParked) return true;
            const isWaiting = m.text.trim().startsWith(WAITING_PREFIX);
            if (!isWaiting) return true;
            const hasActions =
              !!m.toolActions && m.toolActions.length > 0;
            if (!hasActions) return false;
            return true;
          });
          return [...base, finalMsg].slice(-MAX_MESSAGES);
        });
        setInFlightTurn(null);
        inFlightTurnRef.current = null;
        setPending(false);
        pendingRef.current = false;
        refreshApprovals();
        if (sessionGoalIdRef.current) {
          getGoal(sessionGoalIdRef.current)
            .then((detail: { goal?: Goal }) => {
              if (detail?.goal) setSessionGoal(detail.goal);
            })
            .catch(() => {});
        }
      } else if (frameType === "cancelled") {
        clearTurnTimeout();
        clearAllToolProgress();
        turnSessionIDRef.current = null;
        activeTurnStartMsRef.current = null;
        pendingSteerRef.current = [];
        pendingNormalRef.current = null;
        inFlightTurnRef.current = null;
        pendingRef.current = false;
        setInFlightTurn(null);
        setPending(false);
      } else if (frameType === "error") {
        const errorRecord = data as unknown as Record<string, unknown>;
        const ownsSession =
          !!frameSessionID &&
          (normalizeSessionID(frameSessionID) ===
            normalizeSessionID(sessionIDRef.current) ||
            (turnSessionIDRef.current != null &&
              normalizeSessionID(frameSessionID) ===
                normalizeSessionID(turnSessionIDRef.current)));
        if (ownsSession) {
          if (isSteerMissFrame(errorRecord) || isTooLongFrame(errorRecord)) {
            if (pendingSteerRef.current.length > 0) {
              const rejectedSteer = pendingSteerRef.current.pop();
              if (rejectedSteer) {
                const rejectedId = rejectedSteer.id;
                const rejectedText = rejectedSteer.text;
                setMessages((prev) => prev.filter((m) => m.id !== rejectedId));
                setInput((prev) =>
                  prev ? `${prev}\n${rejectedText}` : rejectedText,
                );
              }
              pendingNormalRef.current = null;
            } else if (pendingNormalRef.current) {
              const rejectedNormal = pendingNormalRef.current;
              pendingNormalRef.current = null;
              setMessages((prev) =>
                prev.filter((m) => m.id !== rejectedNormal.id),
              );
              setInput((prev) =>
                prev ? `${prev}\n${rejectedNormal.text}` : rejectedNormal.text,
              );
            }
          } else {
            pendingNormalRef.current = null;
          }
        }
        if (!ownsSession) {
          return;
        }
        clearTurnTimeout();
        clearAllToolProgress();
        const rawMessage: unknown = data.message;
        const message =
          typeof rawMessage === "string" && rawMessage.trim().length > 0
            ? rawMessage.trim()
            : "Chat turn failed";
        if (!cancelledRef.current) {
          setError(message);
        }

        const snapshot = inFlightTurnRef.current;
        const snapshotFullText =
          (snapshot?.text ?? "") + (snapshot?.held ?? "");
        const orderedDoneActions = deduplicateToolActionsByCallID([
          ...(snapshot?.toolActions ?? []),
        ]).sort(compareToolActionsByRound);
        const errorSegments =
          snapshot?.segments && snapshot.segments.length > 0
            ? [...snapshot.segments]
            : [];
        if (
          errorSegments.length === 0 &&
          snapshotFullText &&
          snapshotFullText.trim().length > 0
        ) {
          errorSegments.push({ kind: "text" as const, text: snapshotFullText });
        }

        const errorMsg: MessageItem = {
          id: newSessionId(),
          role: "assistant",
          text: snapshotFullText ?? "",
          toolActions:
            orderedDoneActions.length > 0 ? orderedDoneActions : undefined,
          segments: errorSegments.length > 0 ? errorSegments : undefined,
          isError: true,
          errorText: message,
          completedAt: Date.now(),
        };
        setMessages((prev) => {
          const base = prev.filter((m) => {
            if (m.role !== "assistant") return true;
            if (!m.text.trim().startsWith(WAITING_PREFIX)) return true;
            if (!m.toolActions || m.toolActions.length === 0) return false;
            return true;
          });
          return [...base, errorMsg].slice(-MAX_MESSAGES);
        });

        turnSessionIDRef.current = null;
        activeTurnStartMsRef.current = null;
        setInFlightTurn(null);
        inFlightTurnRef.current = null;
        pendingRef.current = false;
        setPending(false);
      } else if (frameType === "run_started" || frameType === "run_completed") {
        const nestedRun: unknown = (data as unknown as Record<string, unknown>).run;
        const owner = runSessionID(
          nestedRun as Parameters<typeof runSessionID>[0],
        );
        const normalizedOwner = normalizeSessionID(owner);
        const nestedStatus =
          typeof (nestedRun as Record<string, unknown> | null)?.status ===
          "string"
            ? ((nestedRun as Record<string, unknown>).status as string)
            : undefined;
        if (normalizedOwner) {
          if (
            frameType === "run_started" &&
            isActiveRunStatus(nestedStatus)
          ) {
            markBackgroundRunning(normalizedOwner, true);
            if (normalizedOwner === normalizeSessionID(sessionIDRef.current)) {
              // Never re-arm a settled turn: ghost run_started frames after
              // cancel arrive with no live turn and must leave pending false.
              // A resumed turn still needs correlation even before it is live.
              if (!cancelledRef.current) {
                const wasLive = turnSessionIDRef.current != null;
                if (turnSessionIDRef.current == null) {
                  turnSessionIDRef.current = normalizedOwner;
                  if (activeTurnStartMsRef.current == null) {
                    activeTurnStartMsRef.current = Date.now();
                  }
                }
                if (wasLive) {
                  setPending(true);
                  pendingRef.current = true;
                  turnSessionIDRef.current = normalizedOwner;
                  activeTurnStartMsRef.current = Date.now();
                  armTurnTimeout();
                } else {
                  armTurnTimeout();
                }
              }
            } else {
              const existing = parkedFlightsRef.current.get(normalizedOwner);
              if (!existing) {
                const base = loadSessionTokens(normalizedOwner);
                storeParkedFlight(parkedFlightsRef.current, normalizedOwner, {
                  turn: { toolActions: [], text: "", held: "", segments: [] },
                  pending: true,
                  warnings: [],
                  turnTokens: null,
                  base,
                  cancelled: false,
                  updatedAt: Date.now(),
                });
              } else {
                const refreshed: ParkedFlight = {
                  ...existing,
                  pending: true,
                  updatedAt: Date.now(),
                };
                parkedFlightsRef.current.delete(normalizedOwner);
                parkedFlightsRef.current.set(normalizedOwner, refreshed);
              }
            }
          } else {
            markBackgroundRunning(normalizedOwner, false);
            const parked = parkedFlightsRef.current.get(normalizedOwner);
            if (parked && !parked.pending) {
              parkedFlightsRef.current.delete(normalizedOwner);
            } else if (parked && parked.pending) {
              markBackgroundRunning(normalizedOwner, false);
            }
          }
        }
        refreshApprovals();
      } else if (
        frameType === "approval_decided" ||
        frameType === "approval_resolved" ||
        frameType === "approval_removed" ||
        frameType === "approval_deleted" ||
        frameType === "approval_completed" ||
        frameType === "approval_cancelled"
      ) {
        const rawRemovalID: unknown = data.id;
        const rawRemovalApprovalID: unknown = data.approvalID;
        const rawRemovalApprovalId: unknown = data.approvalId;
        const rawRemovalRequest: unknown = data.request;
        const rawRemovalApproval: unknown = data.approval;
        let removalID: string | undefined;
        if (typeof rawRemovalID === "string" && rawRemovalID.trim().length > 0) {
          removalID = rawRemovalID;
        } else if (
          typeof rawRemovalApprovalID === "string" &&
          rawRemovalApprovalID.trim().length > 0
        ) {
          removalID = rawRemovalApprovalID;
        } else if (
          typeof rawRemovalApprovalId === "string" &&
          rawRemovalApprovalId.trim().length > 0
        ) {
          removalID = rawRemovalApprovalId;
        } else if (isRecord(rawRemovalRequest)) {
          const nestedID: unknown = rawRemovalRequest.id;
          if (typeof nestedID === "string" && nestedID.trim().length > 0) {
            removalID = nestedID;
          }
        } else if (isRecord(rawRemovalApproval)) {
          const nestedID: unknown = rawRemovalApproval.id;
          if (typeof nestedID === "string" && nestedID.trim().length > 0) {
            removalID = nestedID;
          }
        }
        if (removalID != null) {
          const decidedID = removalID;
          setPendingApprovals((previous) =>
            previous.filter((item) => item.id !== decidedID),
          );
        }
        if (
          frameSessionID &&
          normalizeSessionID(frameSessionID) === normalizeSessionID(sessionIDRef.current) &&
          data.approved === true
        ) {
          setPending(true);
          pendingRef.current = true;
          activeTurnStartMsRef.current = Date.now();
          // Resumed turns start without correlation; seed it so run_started validates.
          if (turnSessionIDRef.current == null && !cancelledRef.current) {
            turnSessionIDRef.current = frameSessionID;
          }
        }
        refreshApprovals();
      }
    },
    [sessionIDRef, updateParkedFlightFromFrame, sessionGoalIdRef, setSessionGoal, pendingRef, turnSessionIDRef, cancelledRef, sessionBaseRef, setSessionTokens, sessionTokensRef, setContextTokens, armTurnTimeout, setToolProgressByCallID, setInFlightTurn, forgetToolCall, forgetToolCancelMark, setPendingApprovals, setTurnWarnings, clearTurnTimeout, clearAllToolProgress, activeTurnStartMsRef, pendingSteerRef, pendingNormalRef, inputHistoryRef, setSessionID, setActiveModel, setContextLimit, setLastTurnTokens, preNameSessionIfFirst, latestPromptRef, inFlightTurnRef, setMessages, setPending, refreshApprovals, setError, setInput, markBackgroundRunning, parkedFlightsRef],
  );

  return { handleWSMessage };
}
