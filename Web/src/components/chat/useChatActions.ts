// Rune Weaver Dashboard — Chat action dispatchers for send, steer, cancel, and tool-level aborts.

import { useCallback, type MutableRefObject, type RefObject } from "react";
import {
  ApiError,
  cancelChat,
  compareToolActionsByRound,
  concurrentTurnsBusyMessage,
  MAX_CHAT_TEXT_LENGTH,
  newSessionId,
  parseRecallDiagnostics,
  postChat,
  resolveMaxConcurrentChatTurns,
  toNonNegativeInt,
  toolCancel,
  updateSessionTitle,
  type HealthResponse,
} from "../../api";
import { sanitizeWarnings } from "../../warnings";
import { normalizeSessionID } from "../../approvalsSession";
import { logWarn } from "../../logger";
import { publishAgentActivity } from "../PersonaAvatar";
import {
  autoTitleFromPrompt,
  chatTextLength,
  isTooLongText,
  mergeWarningLists,
  parkedFlightKey,
} from "./chatHelpers";
import {
  carryHistoryForward,
  contextTokensKey,
  persistInputHistory,
  sessionTokensKey,
} from "./chatHistoryRecall";
import {
  buildCancelledMessageItem,
  buildRestSegments,
  commitCancelledMessage,
  flatActionsFromSegments,
  flatTextFromSegments,
  normalizeCompletedAtMs,
} from "./chatTimeline";
import {
  MAX_INPUT_HISTORY,
  MAX_MESSAGES,
  MAX_PENDING_STEERS,
  STEER_CANCEL_DEBOUNCE_MS,
  type InFlightTurn,
  type MessageItem,
  type ParkedFlight,
} from "./chatTypes";

interface UseChatActionsOptions {
  input: string;
  setInput: (value: string | ((prev: string) => string)) => void;
  pending: boolean;
  setPending: (pending: boolean) => void;
  sessionID: string;
  setSessionID: (id: string) => void;
  messages: MessageItem[];
  setMessages: (updater: (prev: MessageItem[]) => MessageItem[]) => void;
  inFlightTurnRef: MutableRefObject<InFlightTurn | null>;
  setInFlightTurn: (
    turn:
      | InFlightTurn
      | null
      | ((prev: InFlightTurn | null) => InFlightTurn | null),
  ) => void;
  setError: (err: string | null) => void;
  setTurnWarnings: (updater: string[] | ((prev: string[]) => string[])) => void;
  setActiveModel: (model: string) => void;
  setContextLimit: (limit: number) => void;
  setLastTurnTokens: (tokens: number | null) => void;
  setSessionTokens: (tokens: number) => void;
  setContextTokens: (tokens: number) => void;
  setCancellingToolCallIDs: (
    updater: Set<string> | ((prev: Set<string>) => Set<string>),
  ) => void;
  clearAllToolProgress: () => void;
  forgetToolCall: (callID: string) => void;
  armTurnTimeout: () => void;
  clearTurnTimeout: () => void;
  refreshApprovals: () => void;
  reconcileReconnecting: () => void;
  setSessionRefreshKey: (updater: (k: number) => number) => void;
  isOpen: () => boolean;
  sendMessage: (msg: unknown) => boolean;
  health?: HealthResponse | null;
  markBackgroundRunning: (key: string, running: boolean) => void;

  sessionIDRef: MutableRefObject<string>;
  turnSessionIDRef: MutableRefObject<string | null>;
  cancelledRef: MutableRefObject<boolean>;
  knownDraftIDRef: MutableRefObject<string | null>;
  pendingRef: MutableRefObject<boolean>;
  isFirstMessageRef: MutableRefObject<boolean>;
  latestPromptRef: MutableRefObject<string>;
  pendingSteerRef: MutableRefObject<Array<{ id: string; text: string }>>;
  pendingNormalRef: MutableRefObject<{ id: string; text: string } | null>;
  lastSteerTimestampRef: MutableRefObject<number>;
  sessionTokensRef: MutableRefObject<number>;
  sessionBaseRef: MutableRefObject<number>;
  activeTurnStartMsRef: MutableRefObject<number | null>;
  inputHistoryRef: MutableRefObject<string[]>;
  historyIndexRef: MutableRefObject<number>;
  draftRef: MutableRefObject<string>;
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  userHasScrolledUpRef: MutableRefObject<boolean>;
  parkedFlightsRef: MutableRefObject<Map<string, ParkedFlight>>;
}

export function useChatActions({
  input,
  setInput,
  pending,
  setPending,
  sessionID,
  setSessionID,
  messages,
  setMessages,
  inFlightTurnRef,
  setInFlightTurn,
  setError,
  setTurnWarnings,
  setActiveModel,
  setContextLimit,
  setLastTurnTokens,
  setSessionTokens,
  setContextTokens,
  setCancellingToolCallIDs,
  clearAllToolProgress,
  forgetToolCall,
  armTurnTimeout,
  clearTurnTimeout,
  refreshApprovals,
  reconcileReconnecting,
  setSessionRefreshKey,
  isOpen,
  sendMessage,
  health,
  markBackgroundRunning,

  sessionIDRef,
  turnSessionIDRef,
  cancelledRef,
  knownDraftIDRef,
  pendingRef,
  isFirstMessageRef,
  latestPromptRef,
  pendingSteerRef,
  pendingNormalRef,
  lastSteerTimestampRef,
  sessionTokensRef,
  sessionBaseRef,
  activeTurnStartMsRef,
  inputHistoryRef,
  historyIndexRef,
  draftRef,
  textareaRef,
  userHasScrolledUpRef,
  parkedFlightsRef,
}: UseChatActionsOptions) {
  const preNameSessionIfFirst = useCallback(
    (sessionId: string, promptText: string) => {
      if (!isFirstMessageRef.current) return;
      const title = autoTitleFromPrompt(promptText);
      if (!title.trim()) return;
      updateSessionTitle(sessionId, title)
        .then(() => {
          isFirstMessageRef.current = false;
          setSessionRefreshKey((k) => k + 1);
        })
        .catch(() => {
          logWarn(
            "[ChatView] session pre-name failed; will retry on next terminal frame",
          );
        });
    },
    [isFirstMessageRef, setSessionRefreshKey],
  );

  const handleCancelTool = useCallback(
    (callID: string, reason?: string) => {
      const trimmedCallID = callID.trim();
      if (!trimmedCallID) return;
      const cancelSID = turnSessionIDRef.current ?? sessionIDRef.current;
      const trimmedReason = reason?.trim();
      setCancellingToolCallIDs((previous) => {
        if (previous.has(trimmedCallID)) return previous;
        const next = new Set(previous);
        next.add(trimmedCallID);
        return next;
      });
      const sent = sendMessage({
        type: "tool_cancel",
        sessionID: cancelSID,
        callID: trimmedCallID,
        ...(trimmedReason ? { reason: trimmedReason } : {}),
      });
      if (!sent) {
        void toolCancel(cancelSID, trimmedCallID, trimmedReason)
          .then((response) => {
            if (!response.cancelled) {
              forgetToolCall(trimmedCallID);
              setError("Tool cancel missed: the tool call already settled");
            }
          })
          .catch((failure) => {
            forgetToolCall(trimmedCallID);
            setError(
              failure instanceof ApiError
                ? failure.message
                : "Tool cancel failed",
            );
          });
      }
    },
    [turnSessionIDRef, sessionIDRef, setCancellingToolCallIDs, sendMessage, forgetToolCall, setError],
  );

  const handleSteer = useCallback(() => {
    const text = input.trim();
    if (!text) return;
    // A steer raced with cancel has no live turn; surface the miss instead
    // of sending into a settled turn.
    if (cancelledRef.current) {
      setError("No active turn. Steering was not applied because the turn was cancelled.");
      return;
    }
    if (!pending) return;
    if (chatTextLength(text) > MAX_CHAT_TEXT_LENGTH) {
      setError(
        `Message too long: keep steering under ${MAX_CHAT_TEXT_LENGTH} characters.`,
      );
      return;
    }
    const sent = sendMessage({
      text,
      sessionID,
      steer: true,
      source: "dashboard",
    });
    if (!sent) {
      setError(
        "Connection is closed. Steering was not sent. Wait for reconnect, then try again.",
      );
      return;
    }
    lastSteerTimestampRef.current = Date.now();
    setInput("");
    inputHistoryRef.current = [...inputHistoryRef.current, text].slice(
      -MAX_INPUT_HISTORY,
    );
    historyIndexRef.current = -1;
    draftRef.current = "";
    persistInputHistory(sessionID, inputHistoryRef.current);
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
    const steerId = newSessionId();
    const userMsg: MessageItem = {
      id: steerId,
      role: "user",
      text,
    };
    pendingSteerRef.current.push({ id: steerId, text });
    let shedSteerId: string | null = null;
    if (pendingSteerRef.current.length > MAX_PENDING_STEERS) {
      const shed = pendingSteerRef.current.shift();
      if (shed) shedSteerId = shed.id;
    }

    const currentTurn = inFlightTurnRef.current;
    const currentFullText =
      (currentTurn?.text ?? "") + (currentTurn?.held ?? "");
    const hasPreSteerActivity =
      currentTurn &&
      (currentTurn.toolActions.length > 0 ||
        currentFullText.trim().length > 0 ||
        (currentTurn.segments && currentTurn.segments.length > 0));

    let preSteerMsg: MessageItem | null = null;
    if (hasPreSteerActivity && currentTurn) {
      preSteerMsg = {
        id: newSessionId(),
        role: "assistant",
        text: currentFullText,
        toolActions:
          currentTurn.toolActions.length > 0
            ? [...currentTurn.toolActions]
            : undefined,
        segments:
          currentTurn.segments && currentTurn.segments.length > 0
            ? [...currentTurn.segments]
            : undefined,
      };
    }

    const freshTurn: InFlightTurn = {
      text: "",
      held: "",
      toolActions: [],
      segments: [],
    };
    inFlightTurnRef.current = freshTurn;
    setInFlightTurn(() => freshTurn);

    userHasScrolledUpRef.current = false;
    setMessages((prev) => {
      const withPreSteer = preSteerMsg ? [...prev, preSteerMsg] : prev;
      const withSteer = [...withPreSteer, userMsg];
      const withoutShed = shedSteerId
        ? withSteer.filter((m) => m.id !== shedSteerId)
        : withSteer;
      return withoutShed.slice(-MAX_MESSAGES);
    });
  }, [input, pending, cancelledRef, sendMessage, sessionID, lastSteerTimestampRef, setInput, inputHistoryRef, historyIndexRef, draftRef, textareaRef, pendingSteerRef, inFlightTurnRef, setInFlightTurn, userHasScrolledUpRef, setMessages, setError]);

  const handleCancel = useCallback(async () => {
    if (!pending) return;
    if (Date.now() - lastSteerTimestampRef.current < STEER_CANCEL_DEBOUNCE_MS) {
      setError(
        "Steering was just sent. Cancel is briefly paused so the steer isn't dropped; try again in a moment.",
      );
      return;
    }
    const cancelSID = turnSessionIDRef.current ?? sessionIDRef.current ?? sessionID;
    cancelledRef.current = true;
    clearTurnTimeout();
    clearAllToolProgress();
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    pendingRef.current = false;
    const cancelledMsg = buildCancelledMessageItem(inFlightTurnRef.current);
    if (cancelledMsg) {
      setMessages((prev) => commitCancelledMessage(prev, cancelledMsg));
    }
    inFlightTurnRef.current = null;
    pendingSteerRef.current = [];
    pendingNormalRef.current = null;
    parkedFlightsRef.current.delete(parkedFlightKey(cancelSID));
    markBackgroundRunning(parkedFlightKey(cancelSID), false);
    try {
      if (isOpen()) {
        sendMessage({
          type: "cancel",
          sessionID: cancelSID,
        });
      }
      await cancelChat(cancelSID);
    } catch {
      // Best-effort cancellation
    } finally {
      inFlightTurnRef.current = null;
      pendingRef.current = false;
      setInFlightTurn(null);
      setPending(false);
    }
  }, [pending, lastSteerTimestampRef, turnSessionIDRef, sessionIDRef, sessionID, cancelledRef, pendingRef, inFlightTurnRef, clearTurnTimeout, clearAllToolProgress, activeTurnStartMsRef, pendingSteerRef, pendingNormalRef, parkedFlightsRef, markBackgroundRunning, isOpen, sendMessage, setInFlightTurn, setPending, setMessages, setError]);

  const send = useCallback(
    async (overrideText?: string, overrideSessionID?: string) => {
      const text = (overrideText !== undefined ? overrideText : input).trim();
      if (!text || pending) return;
      const targetSid = overrideSessionID ?? sessionID;
      if (chatTextLength(text) > MAX_CHAT_TEXT_LENGTH) {
        setError(
          `Message too long: keep messages under ${MAX_CHAT_TEXT_LENGTH} characters.`,
        );
        return;
      }
      const parkedPendingCount = [...parkedFlightsRef.current.values()].filter(
        (flight) => flight.pending,
      ).length;
      const activeTurnCount = pendingRef.current || pending ? 1 : 0;
      const turnCap = resolveMaxConcurrentChatTurns(health);
      if (activeTurnCount + parkedPendingCount + 1 > turnCap) {
        setError(concurrentTurnsBusyMessage(turnCap));
        return;
      }
      cancelledRef.current = false;
      knownDraftIDRef.current = null;
      setPending(true);
      setError(null);
      setTurnWarnings([]);

      const isFirst = messages.length === 0;
      if (isFirst) {
        isFirstMessageRef.current = true;
        latestPromptRef.current = text;
      }

      const userMessage: MessageItem = {
        id: newSessionId(),
        role: "user",
        text,
      };
      pendingNormalRef.current = { id: userMessage.id, text };

      userHasScrolledUpRef.current = false;
      setMessages((prev) => [...prev, userMessage].slice(-MAX_MESSAGES));
      setInput("");
      inputHistoryRef.current = [...inputHistoryRef.current, text].slice(
        -MAX_INPUT_HISTORY,
      );
      historyIndexRef.current = -1;
      draftRef.current = "";
      persistInputHistory(targetSid, inputHistoryRef.current);
      if (textareaRef.current) {
        textareaRef.current.style.height = "auto";
      }

      setInFlightTurn({ toolActions: [], text: "", held: "", segments: [] });
      clearAllToolProgress();
      turnSessionIDRef.current = targetSid;
      activeTurnStartMsRef.current = Date.now();
      sessionBaseRef.current = sessionTokensRef.current;

      if (isOpen()) {
        sendMessage({
          text,
          sessionID: targetSid,
          source: "dashboard",
        });
        armTurnTimeout();
        return;
      }

      try {
        const response = await postChat(text, targetSid, "dashboard");
        reconcileReconnecting();
        pendingNormalRef.current = null;
        if (cancelledRef.current) return;
        const isParked = response.isParked === true;
        const currentSid = response.sessionID || targetSid;
        if (
          response.sessionID &&
          normalizeSessionID(response.sessionID) !== normalizeSessionID(targetSid)
        ) {
          inputHistoryRef.current = carryHistoryForward(
            inputHistoryRef.current,
            response.sessionID,
            targetSid,
          );
          setSessionID(response.sessionID);
        }

        if (response.modelName) setActiveModel(response.modelName);
        if (response.contextLength) setContextLimit(response.contextLength);
        const total = toNonNegativeInt(response.totalTokens);
        const restSessionTokens = toNonNegativeInt(response.sessionTokens);
        const restContextTokens = toNonNegativeInt(response.contextTokens);
        if (typeof total === "number") {
          setLastTurnTokens(total);
        }
        if (typeof restContextTokens === "number") {
          setContextTokens(restContextTokens);
          try {
            localStorage.setItem(contextTokensKey(currentSid), String(restContextTokens));
          } catch {
            // Storage is best-effort only.
          }
        }
        if (typeof restSessionTokens === "number") {
          const cumulative = restSessionTokens;
          setSessionTokens(cumulative);
          if (!isParked) {
            sessionBaseRef.current = cumulative;
          }
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(cumulative));
          } catch {
            // Storage is best-effort only.
          }
        } else if (typeof total === "number") {
          const turnTotal = total;
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

        preNameSessionIfFirst(currentSid, text);

        const orderedRestActions = [...response.toolActions].sort(
          compareToolActionsByRound,
        );
        const restSegments = buildRestSegments(
          orderedRestActions,
          response.text,
        );
        const restFlatText =
          restSegments.length > 0
            ? flatTextFromSegments(restSegments)
            : response.text;
        const restFlat = flatActionsFromSegments(restSegments);
        const restCompletedAt = normalizeCompletedAtMs(
          (response as unknown as Record<string, unknown>).completedAt,
        );
        const restRecall = parseRecallDiagnostics(
          (response as unknown as Record<string, unknown>).recallDiagnostics,
        );
        const assistantMessage: MessageItem = {
          id: newSessionId(),
          role: "assistant",
          text: restFlatText,
          toolActions: restFlat.length > 0 ? restFlat : undefined,
          segments: restSegments.length > 0 ? restSegments : undefined,
          ...(restCompletedAt != null ? { completedAt: restCompletedAt } : {}),
          ...(restRecall ? { recallDiagnostics: restRecall } : {}),
        };

        setMessages((prev) => [...prev, assistantMessage].slice(-MAX_MESSAGES));
        const restWarnings = sanitizeWarnings(response.warnings);
        if (restWarnings.length > 0) {
          setTurnWarnings((previous) => mergeWarningLists(previous, restWarnings));
        }
        if (isParked) {
          refreshApprovals();
        }
      } catch (failure) {
        if (cancelledRef.current) return;
        const message =
          failure instanceof ApiError ? failure.message : "Chat failed";
        const isLengthRefusal =
          (failure instanceof ApiError &&
            (failure.status === 413 || isTooLongText(failure.message))) ||
          (!(failure instanceof ApiError) && isTooLongText(message));
        if (isLengthRefusal) {
          const optimisticId = userMessage.id;
          pendingNormalRef.current = null;
          setMessages((prev) => prev.filter((m) => m.id !== optimisticId));
          setInput((prev) => (prev ? `${prev}\n${text}` : text));
        } else {
          pendingNormalRef.current = null;
        }
        setError(message);
      } finally {
        clearTurnTimeout();
        clearAllToolProgress();
        turnSessionIDRef.current = null;
        activeTurnStartMsRef.current = null;
        setInFlightTurn(null);
        setPending(false);
        publishAgentActivity(Date.now());
      }
    },
    [input, pending, sessionID, parkedFlightsRef, pendingRef, health, cancelledRef, knownDraftIDRef, setPending, setError, setTurnWarnings, messages.length, isFirstMessageRef, latestPromptRef, pendingNormalRef, userHasScrolledUpRef, setMessages, setInput, inputHistoryRef, historyIndexRef, draftRef, textareaRef, setInFlightTurn, clearAllToolProgress, turnSessionIDRef, activeTurnStartMsRef, sessionBaseRef, sessionTokensRef, isOpen, sendMessage, armTurnTimeout, reconcileReconnecting, setSessionID, setActiveModel, setContextLimit, setLastTurnTokens, setContextTokens, setSessionTokens, preNameSessionIfFirst, refreshApprovals, clearTurnTimeout],
  );

  return {
    preNameSessionIfFirst,
    handleCancelTool,
    handleSteer,
    handleCancel,
    send,
  };
}
