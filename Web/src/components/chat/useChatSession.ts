// Rune Weaver Dashboard — Chat session lifecycle, goal attachment, URL synchronization, and session switching.

import type { MutableRefObject } from "react";
import { useEffect, useRef, useState } from "react";
import { getGoal, newSessionId, type Goal } from "../../api";
import { normalizeSessionID } from "../../approvalsSession";
import { getURLSessionID } from "./chatHistoryRecall";

interface UseChatSessionOptions {
  initialPrompt?: string | null;
  onClearInitialPrompt?: () => void;
  targetSessionId?: string | null;
  onClearTargetSessionId?: () => void;
  onParkActiveFlight: () => void;
  onRestoreParkedFlight: (id: string) => void;
  onResetSessionTurnState: (newID: string) => void;
  onSendPrompt: (promptText: string, sessionID: string) => void;
  sessionIDRef?: MutableRefObject<string>;
}

export function useChatSession({
  initialPrompt,
  onClearInitialPrompt,
  targetSessionId,
  onClearTargetSessionId,
  onParkActiveFlight,
  onRestoreParkedFlight,
  onResetSessionTurnState,
  onSendPrompt,
  sessionIDRef: externalSessionIDRef,
}: UseChatSessionOptions) {
  const [sessionID, setSessionID] = useState<string>(() => {
    const urlSession = getURLSessionID();
    if (urlSession) return urlSession;
    return localStorage.getItem("rw_active_session_id") || newSessionId();
  });
  const internalSessionIDRef = useRef(sessionID);
  const sessionIDRef = externalSessionIDRef ?? internalSessionIDRef;
  sessionIDRef.current = sessionID;
  const [sessionRefreshKey, setSessionRefreshKey] = useState(0);

  const [sessionGoalId, setSessionGoalId] = useState<string | null>(null);
  const [sessionGoal, setSessionGoal] = useState<Goal | null>(null);
  const [goalDrawerOpen, setGoalDrawerOpen] = useState(false);
  const goalChipRef = useRef<HTMLButtonElement | null>(null);
  const sessionGoalIdRef = useRef<string | null>(null);

  const didRecoverSessionRef = useRef(false);
  const knownDraftIDRef = useRef<string | null>(
    localStorage.getItem("rw_active_session_id") ? null : sessionID,
  );

  useEffect(() => {
    sessionIDRef.current = sessionID;
  }, [sessionID, sessionIDRef]);

  useEffect(() => {
    sessionGoalIdRef.current = sessionGoalId;
  }, [sessionGoalId]);

  useEffect(() => {
    localStorage.setItem("rw_active_session_id", sessionID);
  }, [sessionID]);

  useEffect(() => {
    if (!sessionGoalId) {
      setSessionGoal(null);
      return;
    }
    let cancelled = false;
    getGoal(sessionGoalId)
      .then((detail) => {
        if (!cancelled) setSessionGoal(detail.goal);
      })
      .catch(() => {
        if (!cancelled) setSessionGoal(null);
      });
    return () => {
      cancelled = true;
    };
  }, [sessionGoalId]);

  function resetFreshSessionState(): string {
    onParkActiveFlight();
    const nextID = newSessionId();
    knownDraftIDRef.current = nextID;
    sessionIDRef.current = nextID;
    setSessionID(nextID);
    setGoalDrawerOpen(false);
    onResetSessionTurnState(nextID);
    return nextID;
  }

  function handleNewSession() {
    resetFreshSessionState();
  }

  function handleSelectSession(id: string) {
    if (normalizeSessionID(id) === normalizeSessionID(sessionIDRef.current)) return;
    onParkActiveFlight();
    knownDraftIDRef.current = null;
    setSessionID(id);
    setGoalDrawerOpen(false);
    onRestoreParkedFlight(id);
  }
  const handleSelectSessionRef = useRef(handleSelectSession);
  handleSelectSessionRef.current = handleSelectSession;

  useEffect(() => {
    function handleURLSessionChange() {
      const targetSession = getURLSessionID();
      if (
        targetSession &&
        normalizeSessionID(targetSession) !== normalizeSessionID(sessionIDRef.current)
      ) {
        handleSelectSessionRef.current(targetSession);
      }
    }
    window.addEventListener("hashchange", handleURLSessionChange);
    window.addEventListener("popstate", handleURLSessionChange);
    return () => {
      window.removeEventListener("hashchange", handleURLSessionChange);
      window.removeEventListener("popstate", handleURLSessionChange);
    };
  }, [sessionIDRef]);

  function handleStartNewSessionWithPrompt(promptText: string) {
    const nextID = resetFreshSessionState();
    if (typeof window !== "undefined") {
      window.location.hash = `chat/${nextID}`;
    }
    onSendPrompt(promptText, nextID);
  }
  const handleStartNewSessionWithPromptRef = useRef(handleStartNewSessionWithPrompt);
  handleStartNewSessionWithPromptRef.current = handleStartNewSessionWithPrompt;

  useEffect(() => {
    if (initialPrompt && initialPrompt.trim()) {
      const promptText = initialPrompt.trim();
      onClearInitialPrompt?.();
      handleStartNewSessionWithPromptRef.current(promptText);
    }
  }, [initialPrompt, onClearInitialPrompt]);

  useEffect(() => {
    if (targetSessionId && targetSessionId.trim()) {
      handleSelectSessionRef.current(targetSessionId.trim());
      onClearTargetSessionId?.();
    }
  }, [targetSessionId, onClearTargetSessionId]);

  return {
    sessionID,
    setSessionID,
    sessionIDRef,
    sessionRefreshKey,
    setSessionRefreshKey,
    sessionGoalId,
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
    resetFreshSessionState,
  };
}
