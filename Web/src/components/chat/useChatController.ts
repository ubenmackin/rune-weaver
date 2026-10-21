// Rune Weaver Dashboard — Main controller hook coordinating chat session, WebSocket stream, tool actions, and metrics.

import { useCallback, useEffect, useRef, useState, type ChangeEvent, type KeyboardEvent } from "react";
import {
  isActiveRunStatus,
  parseRunTimestamp,
  personaAssistantName,
  toNonNegativeInt,
  type ToolProgress,
} from "../../api";
import { normalizeSessionID } from "../../approvalsSession";
import { useChatSettings } from "../../chatSettings";
import { useFileReviewHydration } from "../../hooks/useFileReviewHydration";
import { isMobileViewport, useIsMobile } from "../../hooks/useIsMobile";
import { useRunningRuns, type FrozenRunLogEntry } from "../../hooks/useRunningRuns";
import { useSharedWebSocket } from "../../hooks/useSharedWebSocket";
import {
  publishAgentWorking,
  usePersonaSignals,
} from "../PersonaAvatar";
import {
  collectWriteHydrationTargets,
  collectWriteReviewOwners,
} from "../writeReviewOwnership";
import {
  approvalsForSession,
  copyToClipboard,
  messageListHasActiveSelection,
} from "./chatHelpers";
import {
  formatSessionShort,
  loadContextTokens,
  loadInputHistory,
  loadSessionTokens,
  turnTimeoutMs,
} from "./chatHistoryRecall";
import { renderedToolActions } from "./chatTimeline";
import {
  PARKED_SETTLE_GRACE_MS,
  type ChatViewProps,
  type InFlightTurn,
  type MessageItem,
} from "./chatTypes";
import { useChatActions } from "./useChatActions";
import { useChatApprovals } from "./useChatApprovals";
import { useChatHistoryLoader } from "./useChatHistoryLoader";
import { useChatSession } from "./useChatSession";
import { useChatWebSocketHandler } from "./useChatWebSocketHandler";
import { useParkedFlights } from "./useParkedFlights";

export function useChatController({
  health,
  isActive,
  initialPrompt,
  onClearInitialPrompt,
  targetSessionId,
  onClearTargetSessionId,
}: ChatViewProps) {
  const {
    settings: chatSettings,
    updateSettings: updateChatSettings,
    resetSettings: resetChatSettings,
  } = useChatSettings();
  const [chatSettingsOpen, setChatSettingsOpen] = useState(false);
  const [messages, setMessages] = useState<MessageItem[]>([]);
  const [input, setInput] = useState("");
  const [pending, setPending] = useState(false);
  const [inFlightTurn, setInFlightTurn] = useState<InFlightTurn | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [turnWarnings, setTurnWarnings] = useState<string[]>([]);
  const [copiedMessageId, setCopiedMessageId] = useState<string | null>(null);
  const copyTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [reconnecting, setReconnecting] = useState(false);
  const [reconnectDismissed, setReconnectDismissed] = useState(false);
  const [toolProgressByCallID, setToolProgressByCallID] = useState<
    Map<string, ToolProgress>
  >(() => new Map());
  const [cancellingToolCallIDs, setCancellingToolCallIDs] = useState<Set<string>>(
    () => new Set<string>(),
  );

  // Status bar metrics
  const [lastTurnTokens, setLastTurnTokens] = useState<number | null>(null);
  const [sessionTokens, setSessionTokens] = useState<number>(0);
  const [contextTokens, setContextTokens] = useState<number>(0);
  const [activeModel, setActiveModel] = useState<string>(
    () => health?.model || "Local LLM",
  );
  const [contextLimit, setContextLimit] = useState<number>(
    () => health?.contextLength || 8192,
  );
  const [footerExpanded, setFooterExpanded] = useState(false);

  const [sidebarOpen, setSidebarOpen] = useState(() => !isMobileViewport());
  const isMobile = useIsMobile();
  const historyButtonRef = useRef<HTMLButtonElement | null>(null);

  const handleCloseSidebar = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const handleToggleSidebar = useCallback(() => {
    setSidebarOpen((previous) => !previous);
  }, []);

  const messageListEndRef = useRef<HTMLDivElement | null>(null);
  const messageListRef = useRef<HTMLDivElement | null>(null);
  const userHasScrolledUpRef = useRef(false);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const inputHistoryRef = useRef<string[]>([]);
  const historyIndexRef = useRef<number>(-1);
  const draftRef = useRef<string>("");
  const isFirstMessageRef = useRef(false);
  const latestPromptRef = useRef("");
  const sessionIDRef = useRef<string>("");
  const cancelledRef = useRef(false);
  const turnSessionIDRef = useRef<string | null>(null);
  const turnTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingRef = useRef(false);
  const pendingSteerRef = useRef<Array<{ id: string; text: string }>>([]);
  const lastSteerTimestampRef = useRef<number>(0);
  const pendingNormalRef = useRef<{ id: string; text: string } | null>(null);
  const inFlightTurnRef = useRef<InFlightTurn | null>(null);
  const messagesRef = useRef<MessageItem[]>(messages);
  const turnWarningsRef = useRef<string[]>([]);
  const lastTurnTokensRef = useRef<number | null>(null);
  const sessionTokensRef = useRef(sessionTokens);
  const sessionBaseRef = useRef<number>(0);
  const activeTurnStartMsRef = useRef<number | null>(null);
  const sharedRunsRef = useRef<ReadonlyArray<FrozenRunLogEntry>>([]);
  const sharedRunningIDsRef = useRef<string[]>([]);
  const contextLimitRef = useRef(contextLimit);

  useEffect(() => {
    pendingRef.current = pending;
  }, [pending]);
  useEffect(() => {
    inFlightTurnRef.current = inFlightTurn;
  }, [inFlightTurn]);
  useEffect(() => {
    messagesRef.current = messages;
  }, [messages]);
  useEffect(() => {
    turnWarningsRef.current = turnWarnings;
  }, [turnWarnings]);
  useEffect(() => {
    lastTurnTokensRef.current = lastTurnTokens;
  }, [lastTurnTokens]);
  useEffect(() => {
    sessionTokensRef.current = sessionTokens;
  }, [sessionTokens]);
  useEffect(() => {
    contextLimitRef.current = contextLimit;
  }, [contextLimit]);
  useEffect(() => {
    if (health?.model) setActiveModel(health.model);
    if (health?.contextLength) setContextLimit(health.contextLength);
  }, [health]);

  useEffect(() => {
    return () => {
      if (copyTimeoutRef.current) {
        clearTimeout(copyTimeoutRef.current);
      }
    };
  }, []);

  const handleCopyMessage = async (id: string, text: string) => {
    const success = await copyToClipboard(text);
    if (success) {
      if (copyTimeoutRef.current) {
        clearTimeout(copyTimeoutRef.current);
      }
      setCopiedMessageId(id);
      copyTimeoutRef.current = setTimeout(() => {
        setCopiedMessageId(null);
        copyTimeoutRef.current = null;
      }, 2000);
    }
  };

  const {
    parkedFlightsRef,
    backgroundRunningIDs,
    backgroundRunningRef,
    trimmedLiveFlights,
    setTrimmedLiveFlights,
    markBackgroundRunning,
    reapExpiredFlightsAndSurface,
    parkFlight,
    updateParkedFlightFromFrame,
  } = useParkedFlights();

  const { persona } = usePersonaSignals();
  const personaDisplayName = personaAssistantName(persona);
  const agentWorking = pending || backgroundRunningIDs.length > 0;
  useEffect(() => {
    publishAgentWorking(agentWorking);
  }, [agentWorking]);

  const clearTurnTimeout = useCallback(() => {
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
  }, []);

  const armTurnTimeout = useCallback(() => {
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
    }
    const schedule = () => {
      const budgetMs = turnTimeoutMs(contextLimitRef.current);
      turnTimeoutRef.current = setTimeout(() => {
        turnTimeoutRef.current = null;
        const budgetMinutes = Math.max(1, Math.round(budgetMs / 60000));
        setError(
          `Still working. No progress for ${budgetMinutes} minutes but the turn is still running. Cancel remains available if you want to stop it.`,
        );
        schedule();
      }, budgetMs);
    };
    schedule();
  }, []);

  const forgetToolCall = useCallback((callID: string) => {
    setToolProgressByCallID((previous) => {
      if (!previous.has(callID)) return previous;
      const next = new Map(previous);
      next.delete(callID);
      return next;
    });
    setCancellingToolCallIDs((previous) => {
      if (!previous.has(callID)) return previous;
      const next = new Set(previous);
      next.delete(callID);
      return next;
    });
  }, []);

  const forgetToolCancelMark = useCallback((callID: string) => {
    setCancellingToolCallIDs((previous) => {
      if (!previous.has(callID)) return previous;
      const next = new Set(previous);
      next.delete(callID);
      return next;
    });
  }, []);

  const clearAllToolProgress = useCallback(() => {
    setToolProgressByCallID((previous) =>
      previous.size === 0 ? previous : new Map<string, ToolProgress>(),
    );
    setCancellingToolCallIDs((previous) =>
      previous.size === 0 ? previous : new Set<string>(),
    );
  }, []);

  const { runs: sharedRuns, runningIDs: sharedRunningIDs } = useRunningRuns();

  const handleParkActiveFlight = useCallback(() => {
    parkFlight(
      sessionIDRef.current,
      inFlightTurnRef.current,
      messagesRef.current,
      turnWarningsRef.current,
      lastTurnTokensRef.current,
      sessionBaseRef.current,
      cancelledRef.current,
    );
    clearTurnTimeout();
  }, [parkFlight, clearTurnTimeout, sessionIDRef]);

  const handleRestoreParkedFlight = useCallback(
    (id: string) => {
      const key = normalizeSessionID(id);
      if (!key) return;
      reapExpiredFlightsAndSurface();
      const parked = parkedFlightsRef.current.get(key);
      if (!parked) {
        if (backgroundRunningRef.current.has(key)) {
          markBackgroundRunning(key, false);
          setInFlightTurn({ toolActions: [], text: "", held: "", segments: [] });
          setPending(true);
          pendingRef.current = true;
          turnSessionIDRef.current = id;
          activeTurnStartMsRef.current = Date.now();
          armTurnTimeout();
        }
        return;
      }
      if (!parked.pending) {
        if (parked.warnings.length > 0) {
          setTurnWarnings([...parked.warnings]);
        }
        if (parked.turnTokens != null) {
          setLastTurnTokens(parked.turnTokens);
        }
        if (parked.completedMessage) {
          const restoredMessages = [
            ...(parked.messages ?? []),
            parked.completedMessage,
          ];
          setMessages(restoredMessages);
          messagesRef.current = restoredMessages;
        }
        parkedFlightsRef.current.delete(key);
        markBackgroundRunning(key, false);
        return;
      }
      parkedFlightsRef.current.delete(key);
      markBackgroundRunning(key, false);
      cancelledRef.current = parked.cancelled;
      sessionBaseRef.current = parked.base;
      if (parked.turnTokens != null) {
        setLastTurnTokens(parked.turnTokens);
        lastTurnTokensRef.current = parked.turnTokens;
        setSessionTokens(parked.base + parked.turnTokens);
      }
      if (parked.warnings.length > 0) {
        setTurnWarnings([...parked.warnings]);
      }
      if (parked.messages) {
        setMessages(parked.messages);
        messagesRef.current = parked.messages;
      }
      if (parked.turn) {
        setInFlightTurn(parked.turn);
        inFlightTurnRef.current = parked.turn;
      }
      setPending(true);
      pendingRef.current = true;
      turnSessionIDRef.current = id;
      activeTurnStartMsRef.current = Date.now();
      armTurnTimeout();
    },
    [reapExpiredFlightsAndSurface, parkedFlightsRef, backgroundRunningRef, markBackgroundRunning, armTurnTimeout],
  );

  const handleResetSessionTurnState = useCallback((nextID: string) => {
    userHasScrolledUpRef.current = false;
    setMessages([]);
    setInFlightTurn(null);
    inFlightTurnRef.current = null;
    setPending(false);
    pendingRef.current = false;
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    cancelledRef.current = false;
    clearAllToolProgress();
    setError(null);
    setTurnWarnings([]);
    turnWarningsRef.current = [];
    setLastTurnTokens(null);
    lastTurnTokensRef.current = null;
    const fresh = loadSessionTokens(nextID);
    setSessionTokens(fresh);
    sessionTokensRef.current = fresh;
    sessionBaseRef.current = fresh;
    const freshContext = loadContextTokens(nextID);
    setContextTokens(freshContext);
    inputHistoryRef.current = loadInputHistory(nextID);
    historyIndexRef.current = -1;
    draftRef.current = "";
  }, [clearAllToolProgress]);

  const {
    sessionID,
    setSessionID,
    sessionRefreshKey,
    setSessionRefreshKey,
    setSessionGoalId,
    sessionGoal,
    setSessionGoal,
    sessionGoalIdRef,
    goalDrawerOpen,
    setGoalDrawerOpen,
    goalChipRef,
    didRecoverSessionRef,
    knownDraftIDRef,
    handleNewSession,
    handleSelectSession,
  } = useChatSession({
    initialPrompt,
    onClearInitialPrompt,
    targetSessionId,
    onClearTargetSessionId,
    onParkActiveFlight: handleParkActiveFlight,
    onRestoreParkedFlight: handleRestoreParkedFlight,
    onResetSessionTurnState: handleResetSessionTurnState,
    onSendPrompt: (promptText, sid) => {
      void send(promptText, sid);
    },
    sessionIDRef,
  });

  const {
    pendingApprovals,
    setPendingApprovals,
    decidingApprovalIDs,
    refreshApprovals,
    handleDecideApproval,
    handleRespondQuestion,
  } = useChatApprovals({ sessionID, onError: setError });

  const { reloadActiveHistory, tryAdoptReloadedTurn } = useChatHistoryLoader({
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
    reconcileReconnecting: () => {
      if (reconnecting && isOpen()) setReconnecting(false);
    },
    isOpen: () => isOpen(),
    sharedRuns,
    sharedRunningIDs,
  });

  const {
    preNameSessionIfFirst,
    handleCancelTool,
    handleSteer,
    handleCancel,
    send,
  } = useChatActions({
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
    reconcileReconnecting: () => {
      if (reconnecting && isOpen()) setReconnecting(false);
    },
    setSessionRefreshKey,
    isOpen: () => isOpen(),
    sendMessage: (msg) => sendMessage(msg as Parameters<typeof sendMessage>[0]),
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
  });

  const { handleWSMessage } = useChatWebSocketHandler({
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
  });

  const handleWSClose = useCallback(() => {
    setReconnecting(true);
    setReconnectDismissed(false);
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
  }, []);

  const handleWSOpen = useCallback(() => {
    setReconnecting(false);
    reapExpiredFlightsAndSurface();
    if (!pendingRef.current || cancelledRef.current) {
      tryAdoptReloadedTurn();
      return;
    }
    const activeNorm = normalizeSessionID(sessionIDRef.current);
    if (!activeNorm) {
      armTurnTimeout();
      return;
    }
    const turnSID = turnSessionIDRef.current;
    if (turnSID != null && normalizeSessionID(turnSID) !== activeNorm) {
      return;
    }
    if (sharedRunningIDsRef.current.includes(activeNorm)) {
      armTurnTimeout();
      return;
    }
    const startedAt = activeTurnStartMsRef.current;
    if (startedAt == null || Date.now() - startedAt < PARKED_SETTLE_GRACE_MS) {
      armTurnTimeout();
      return;
    }
    let hasSettledEvidence = false;
    let stillRunning = false;
    for (const run of sharedRunsRef.current) {
      const raw = (run as { sessionID?: unknown }).sessionID;
      if (typeof raw !== "string" || !raw.trim()) continue;
      if (raw.trim().toLowerCase() !== activeNorm) continue;
      const status = (run as { status?: unknown }).status;
      if (isActiveRunStatus(typeof status === "string" ? status : undefined)) {
        stillRunning = true;
        break;
      }
      const ts = parseRunTimestamp(
        (run as { timestamp?: unknown }).timestamp as string | number,
      ).getTime();
      if (!Number.isFinite(ts) || ts <= 0) continue;
      if (ts >= startedAt - 5000) {
        hasSettledEvidence = true;
        break;
      }
    }
    if (stillRunning || !hasSettledEvidence) {
      armTurnTimeout();
      return;
    }
    clearTurnTimeout();
    turnSessionIDRef.current = null;
    activeTurnStartMsRef.current = null;
    pendingRef.current = false;
    setInFlightTurn(null);
    inFlightTurnRef.current = null;
    setPending(false);
    markBackgroundRunning(activeNorm, false);
    reloadActiveHistory(sessionIDRef.current);
  }, [armTurnTimeout, clearTurnTimeout, markBackgroundRunning, reloadActiveHistory, reapExpiredFlightsAndSurface, tryAdoptReloadedTurn, sessionIDRef]);

  const { sendMessage, isOpen, retryConnection } = useSharedWebSocket(
    handleWSMessage,
    handleWSClose,
    handleWSOpen,
  );

  const handleRetryConnection = useCallback(() => {
    retryConnection();
    if (isOpen()) setReconnecting(false);
  }, [retryConnection, isOpen]);

  useEffect(() => {
    return () => {
      if (turnTimeoutRef.current != null) {
        clearTimeout(turnTimeoutRef.current);
        turnTimeoutRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    if (
      !userHasScrolledUpRef.current &&
      chatSettings.autoScrollOnStream &&
      messageListHasActiveSelection(messageListRef.current) === false
    ) {
      messageListEndRef.current?.scrollIntoView?.({ behavior: "smooth" });
    }
  }, [messages, pending, inFlightTurn, chatSettings.autoScrollOnStream]);

  const handleMessageListScroll = useCallback(() => {
    const el = messageListRef.current;
    if (!el) return;
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    userHasScrolledUpRef.current = distanceFromBottom > 150;
  }, []);

  const handleInputChange = (event: ChangeEvent<HTMLTextAreaElement>) => {
    const next = event.target.value;
    if (historyIndexRef.current !== -1) {
      historyIndexRef.current = -1;
      draftRef.current = next;
    }
    setInput(next);
    const target = event.target;
    target.style.height = "auto";
    const maxHeight = 240;
    target.style.height = `${Math.min(target.scrollHeight, maxHeight)}px`;
  };

  const applyHistoryRecall = (value: string, target: HTMLTextAreaElement) => {
    setInput(value);
    const settle = () => {
      const el = textareaRef.current ?? target;
      el.style.height = "auto";
      el.style.height = `${Math.min(el.scrollHeight, 240)}px`;
      const end = el.value.length;
      el.selectionStart = end;
      el.selectionEnd = end;
    };
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(settle);
    } else {
      setTimeout(settle, 0);
    }
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.nativeEvent?.isComposing || (event as unknown as { isComposing?: boolean }).isComposing) return;
    if (
      event.key === "ArrowUp" &&
      !event.shiftKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey
    ) {
      const target = event.currentTarget;
      const caret = target.selectionStart ?? 0;
      const end = target.selectionEnd ?? 0;
      if (caret === end && !target.value.slice(0, caret).includes("\n")) {
        event.preventDefault();
        const history = inputHistoryRef.current;
        if (history.length === 0) return;
        if (historyIndexRef.current === -1) {
          draftRef.current = target.value;
          historyIndexRef.current = history.length - 1;
        } else if (historyIndexRef.current > 0) {
          historyIndexRef.current -= 1;
        }
        applyHistoryRecall(history[historyIndexRef.current], target);
        return;
      }
    }
    if (
      event.key === "ArrowDown" &&
      !event.shiftKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey
    ) {
      const target = event.currentTarget;
      const caret = target.selectionStart ?? 0;
      const end = target.selectionEnd ?? 0;
      if (caret === end && !target.value.slice(caret).includes("\n")) {
        event.preventDefault();
        const history = inputHistoryRef.current;
        if (historyIndexRef.current === -1) return;
        if (historyIndexRef.current < history.length - 1) {
          historyIndexRef.current += 1;
          applyHistoryRecall(history[historyIndexRef.current], target);
        } else {
          historyIndexRef.current = -1;
          applyHistoryRecall(draftRef.current, target);
        }
        return;
      }
    }
    const isSubmit = chatSettings.sendOnEnter
      ? event.key === "Enter" && !event.shiftKey
      : event.key === "Enter" && (event.metaKey || event.ctrlKey);

    if (isSubmit) {
      event.preventDefault();
      if (pending) {
        handleSteer();
      } else {
        void send();
      }
    }
  };

  const safeContextTokens = toNonNegativeInt(contextTokens) ?? 0;
  const safeSessionTokens = toNonNegativeInt(sessionTokens) ?? 0;
  const safeContextLimit = toNonNegativeInt(contextLimit) ?? 0;
  const safeTurnTokens =
    lastTurnTokens == null ? null : (toNonNegativeInt(lastTurnTokens) ?? 0);
  const pct =
    safeContextLimit > 0
      ? Math.min(
          100,
          Math.max(0, Math.round((safeContextTokens / safeContextLimit) * 100)),
        )
      : 0;
  const sessionShort = formatSessionShort(safeSessionTokens);
  const sessionApprovals = approvalsForSession(pendingApprovals, sessionID);
  const sessionPendingCount = sessionApprovals.length;

  const renderedActions = renderedToolActions(
    messages,
    pending ? inFlightTurn : null,
  );
  const writeReviewOwners = collectWriteReviewOwners(renderedActions);
  const writeHydrationTargets = collectWriteHydrationTargets(renderedActions);
  const writeReviewStates = useFileReviewHydration(writeHydrationTargets);

  return {
    sessionID,
    sessionRefreshKey,
    sessionGoal,
    sessionPendingCount,
    sessionApprovals,
    sidebarOpen,
    setSidebarOpen,
    isMobile,
    historyButtonRef,
    goalChipRef,
    goalDrawerOpen,
    setGoalDrawerOpen,
    handleCloseSidebar,
    handleToggleSidebar,
    handleSelectSession,
    handleNewSession,
    personaDisplayName,
    chatSettings,
    chatSettingsOpen,
    setChatSettingsOpen,
    updateChatSettings,
    resetChatSettings,
    reconnecting,
    reconnectDismissed,
    setReconnectDismissed,
    handleRetryConnection,
    messages,
    pending,
    inFlightTurn,
    messageListRef,
    messageListEndRef,
    handleMessageListScroll,
    error,
    trimmedLiveFlights,
    setTrimmedLiveFlights,
    turnWarnings,
    setTurnWarnings,
    toolProgressByCallID,
    cancellingToolCallIDs,
    copiedMessageId,
    handleCopyMessage,
    handleCancelTool,
    writeReviewOwners,
    writeReviewStates,
    decidingApprovalIDs,
    handleDecideApproval,
    handleRespondQuestion,
    textareaRef,
    input,
    handleInputChange,
    handleKeyDown,
    handleCancel,
    handleSteer,
    send,
    footerExpanded,
    setFooterExpanded,
    pct,
    sessionShort,
    safeTurnTokens,
    safeContextTokens,
    safeContextLimit,
    safeSessionTokens,
    activeModel,
    pendingApprovals,
    backgroundRunningIDs,
    isActive,
  };
}
