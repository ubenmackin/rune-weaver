// Rune Weaver Dashboard — Interactive chat interface with session history sidebar,
// animated typing indicator, distinct tool activity display, and attached status bar.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  cancelChat,
  getSession,
  getSessionToolActions,
  newSessionId,
  postChat,
  updateSessionTitle,
  type HealthResponse,
  type SessionMessageToolActions,
  type ToolAction,
} from "../api";
import SessionSidebar from "./SessionSidebar";
import MarkdownText from "./MarkdownText";
import ToolActionRow from "./ToolActionRow";
import { WrenchIcon } from "./icons";
import { useSharedWebSocket } from "../hooks/useSharedWebSocket";

interface MessageItem {
  id: string;
  role: "user" | "assistant" | "system" | "tool";
  text: string;
  toolActions?: ToolAction[];
}

interface InFlightTurn {
  toolActions: ToolAction[];
  text: string;
}

const MAX_MESSAGES = 200;

// Per-session cached cumulative token total so a reload hydrates the status
// bar instead of resetting to zero; the authoritative `sessionTokens` from
// the next done frame always overwrites it.
function sessionTokensKey(id: string): string {
  return `rw_session_tokens_${id}`;
}

function loadSessionTokens(id: string): number {
  try {
    const raw = localStorage.getItem(sessionTokensKey(id));
    const parsed = raw != null ? Number(raw) : 0;
    return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0;
  } catch {
    return 0;
  }
}

// Bounds a WebSocket-started turn with no done/error frame: a socket
// that drops after send but before the terminal frame must not strand
// the input disabled forever.
const TURN_TIMEOUT_MS = 120_000;

interface ChatViewProps {
  health?: HealthResponse | null;
}

// Indexes server-derived per-message groups by parent message ID.
//
// Single source for history correlation: the server groups tool actions
// by assistant message (`GET /sessions/:id/tool-actions`), so the client
// never reimplements the placeholder shape and only hides lines covered
// by the authoritative call identifiers.
export function toolActionMap(
  groups: SessionMessageToolActions[] | undefined,
): Map<string, ToolAction[]> {
  const map = new Map<string, ToolAction[]>();
  for (const group of groups ?? []) {
    map.set(group.messageID, [...(group.actions ?? [])]);
  }
  return map;
}

export function reconstructMessages(
  rawMessages: Array<{
    id?: string;
    role: string;
    content: string;
    toolCallID?: string | null;
    isError?: boolean | null;
    createdAt?: string | number;
  }> = [],
  // Authoritative server-derived actions keyed by parent message ID (from
  // `GET /sessions/:id/tool-actions` via `toolActionMap`). History renders
  // solely from this record plus raw prose: a line is hidden only when it
  // references a covered call identifier, so prose containing `]` or
  // spaces cannot misrender and uncovered text stays visible.
  structuredByMessageID?: Map<string, ToolAction[]> | Record<string, ToolAction[]>,
): MessageItem[] {
  const getStructured = (messageID: string | undefined): ToolAction[] | undefined => {
    if (!structuredByMessageID || !messageID) return undefined;
    if (structuredByMessageID instanceof Map) {
      return structuredByMessageID.get(messageID);
    }
    return (structuredByMessageID as Record<string, ToolAction[]>)[messageID];
  };
  const result: MessageItem[] = [];
  let pendingToolActions: ToolAction[] = [];
  let pendingProse: string[] = [];

  for (let i = 0; i < rawMessages.length; i++) {
    const m = rawMessages[i];
    if (m.role === "user") {
      if (pendingToolActions.length > 0 || pendingProse.length > 0) {
        result.push({
          id: `interim_${i}`,
          role: "assistant",
          text: pendingProse.join("\n").trim(),
          toolActions: pendingToolActions.length > 0 ? pendingToolActions : undefined,
        });
        pendingToolActions = [];
        pendingProse = [];
      }
      result.push({
        id: m.id || `${m.createdAt || i}`,
        role: "user",
        text: m.content,
      });
      continue;
    }

    if (m.role === "tool") {
      continue;
    }

    if (m.role === "assistant") {
      const structured = getStructured(m.id);
      if (structured && structured.length > 0) {
        const coveredCallIDs = new Set(
          structured.map((action) => action.callID).filter(Boolean),
        );
        const leftoverLines: string[] = [];
        for (const rawLine of m.content.split("\n")) {
          if (!rawLine.trim()) continue;
          // Hide only lines the server record covers, identified by the
          // authoritative call identifier, so unrelated prose stays visible.
          let isCovered = false;
          for (const callID of coveredCallIDs) {
            if (rawLine.includes(`[${callID}]`)) {
              isCovered = true;
              break;
            }
          }
          if (isCovered) continue;
          leftoverLines.push(rawLine);
        }
        pendingToolActions.push(...structured);
        if (leftoverLines.length > 0) {
          pendingProse.push(leftoverLines.join("\n").trim());
        }
        continue;
      }
      const leftoverLines: string[] = [];
      for (const rawLine of m.content.split("\n")) {
        if (!rawLine.trim()) continue;
        // Without a server record tool activity stays unknown, so every
        // line stays visible as prose instead of guessing its shape.
        leftoverLines.push(rawLine);
      }
      if (leftoverLines.length > 0) {
        const fullProse = [...pendingProse, leftoverLines.join("\n")].filter(Boolean).join("\n\n").trim();
        const actions = pendingToolActions.length > 0 ? pendingToolActions : undefined;
        result.push({
          id: m.id || `${m.createdAt || i}`,
          role: "assistant",
          text: fullProse,
          toolActions: actions,
        });
        pendingToolActions = [];
        pendingProse = [];
      } else if (pendingToolActions.length > 0) {
        // Empty message with no server record: keep pending tool context
        // for the next prose turn instead of synthesizing.
        continue;
      } else {
        continue;
      }
    }
  }

  if (pendingToolActions.length > 0 || pendingProse.length > 0) {
    result.push({
      id: `trailing_${rawMessages.length}`,
      role: "assistant",
      text: pendingProse.join("\n").trim(),
      toolActions: pendingToolActions.length > 0 ? pendingToolActions : undefined,
    });
  }

  return result.filter(
    (m) => m.text.trim().length > 0 || (m.toolActions && m.toolActions.length > 0)
  );
}

export default function ChatView({ health }: ChatViewProps) {
  const [messages, setMessages] = useState<MessageItem[]>([]);
  const [input, setInput] = useState("");
  const [sessionID, setSessionID] = useState<string>(() => {
    return localStorage.getItem("rw_active_session_id") || newSessionId();
  });
  const [pending, setPending] = useState(false);
  const [inFlightTurn, setInFlightTurn] = useState<InFlightTurn | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Status bar metrics
  const [lastTurnTokens, setLastTurnTokens] = useState<number | null>(null);
  const [sessionTokens, setSessionTokens] = useState<number>(0);
  const [activeModel, setActiveModel] = useState<string>(
    () => health?.model || "Local LLM",
  );
  const [contextLimit, setContextLimit] = useState<number>(
    () => health?.contextLength || 8192,
  );

  // Sidebar toggle
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const messageListEndRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const sessionIDRef = useRef(sessionID);
  const isFirstMessageRef = useRef(false);
  const latestPromptRef = useRef("");
  const cancelledRef = useRef(false);
  // Owning session captured at turn start so timeout/close cancels the
  // orphaned turn instead of a session switched to mid-turn.
  const turnSessionIDRef = useRef<string | null>(null);
  // A socket that drops after send but before done/error would strand
  // the input disabled with no recovery; the timeout below bounds that
  // window and the close handler below surfaces a retry immediately.
  const turnTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingRef = useRef(false);
  // Snapshot of the live turn for terminal frames: updaters must stay pure,
  // so the done handler reads this ref instead of nesting a message append
  // inside a turn updater, which would duplicate under double-invoke.
  const inFlightTurnRef = useRef<InFlightTurn | null>(null);
  // A server-side delete leaves the stored active ID stale; regenerate
  // it exactly once instead of resurrecting the deleted UUID on send.
  const didRecoverSessionRef = useRef(false);

  // Mirror latest values after commit so concurrent rendering never observes
  // a torn ref written during render.
  useEffect(() => {
    sessionIDRef.current = sessionID;
  }, [sessionID]);
  useEffect(() => {
    pendingRef.current = pending;
  }, [pending]);
  useEffect(() => {
    inFlightTurnRef.current = inFlightTurn;
  }, [inFlightTurn]);

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
    // Capture the owning session at turn start; reading the live ref inside
    // the timeout would cancel a session switched to mid-turn instead.
    const turnSID = sessionIDRef.current;
    turnTimeoutRef.current = setTimeout(() => {
      turnTimeoutRef.current = null;
      // Best-effort cancel the orphaned server turn so a retry does not
      // duplicate it, then release the input lock with a retry message.
      void cancelChat(turnSID).catch(() => {});
      turnSessionIDRef.current = null;
      setInFlightTurn(null);
      setPending(false);
      setError(
        "Turn timed out waiting for a response. The connection may have dropped — retry your message.",
      );
    }, TURN_TIMEOUT_MS);
  }, []);

  // Release a stranded turn when the socket drops mid-turn.
  const handleWSClose = useCallback(() => {
    if (!pendingRef.current) return;
    // Cancel the turn's owning session, not whatever session is active now,
    // so switching sessions mid-turn never cancels the new session.
    const turnSID = turnSessionIDRef.current ?? sessionIDRef.current;
    void cancelChat(turnSID).catch(() => {});
    if (turnTimeoutRef.current != null) {
      clearTimeout(turnTimeoutRef.current);
      turnTimeoutRef.current = null;
    }
    turnSessionIDRef.current = null;
    setInFlightTurn(null);
    setPending(false);
    setError(
      "Connection lost during the turn. Retry your message — the interrupted turn was cancelled.",
    );
  }, []);

  useEffect(() => {
    if (health?.model) setActiveModel(health.model);
    if (health?.contextLength) setContextLimit(health.contextLength);
  }, [health]);

  useEffect(() => {
    localStorage.setItem("rw_active_session_id", sessionID);
  }, [sessionID]);

  const handleWSMessage = useCallback((data: any) => {
    if (!data || typeof data !== "object") return;

    // Ignore frames intended for another session to prevent cross-session pollution
    if (data.sessionID && data.sessionID !== sessionIDRef.current) {
      return;
    }
    // Untagged session frames carry no owner, so they must never touch the
    // current view; only global broadcasts (approval/run_*) bypass tagging.
    if (
      !data.sessionID &&
      (data.type === "delta" ||
        data.type === "tool_start" ||
        data.type === "tool_end" ||
        data.type === "done")
    ) {
      return;
    }

    if (data.type === "tool_start") {
      if (cancelledRef.current) return;
      setInFlightTurn((prev) => {
        const currentActions = prev ? [...prev.toolActions] : [];
        currentActions.push({
          toolName: data.toolName,
          callID: data.callID,
          argumentsJSON: data.argumentsJSON,
          result: null,
        });
        return {
          toolActions: currentActions,
          text: prev ? prev.text : "",
        };
      });
    } else if (data.type === "tool_end") {
      if (cancelledRef.current) return;
      setInFlightTurn((prev) => {
        if (!prev) return prev;
        const updated = prev.toolActions.map((action) => {
          if (
            action.callID === data.callID ||
            (!action.result && action.toolName === data.toolName)
          ) {
            return {
              ...action,
              result: data.result,
            };
          }
          return action;
        });
        return {
          ...prev,
          toolActions: updated,
        };
      });
    } else if (data.type === "delta") {
      if (cancelledRef.current) return;
      setInFlightTurn((prev) => ({
        toolActions: prev ? prev.toolActions : [],
        text: (prev ? prev.text : "") + (data.delta || ""),
      }));
    } else if (data.type === "done") {
      clearTurnTimeout();
      turnSessionIDRef.current = null;
      if (cancelledRef.current) {
        setInFlightTurn(null);
        setPending(false);
        return;
      }
      const currentSid = data.sessionID || sessionIDRef.current;
      if (data.sessionID && data.sessionID !== sessionIDRef.current) {
        setSessionID(data.sessionID);
      }
      if (data.modelName) setActiveModel(data.modelName);
      if (data.contextLength) setContextLimit(data.contextLength);
      if (typeof data.totalTokens === "number") {
        setLastTurnTokens(data.totalTokens);
      }
      // Authoritative cumulative total wins when present so reloads,
      // multi-client turns, and retries never drift from local sums.
      if (typeof data.sessionTokens === "number") {
        const cumulative = data.sessionTokens;
        setSessionTokens(cumulative);
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(cumulative));
        } catch {
          // Storage is best-effort only.
        }
      } else if (typeof data.totalTokens === "number") {
        setSessionTokens((prev) => {
          const next = prev + (data.totalTokens as number);
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(next));
          } catch {
            // Storage is best-effort only.
          }
          return next;
        });
      }

      if (isFirstMessageRef.current) {
        const title = autoTitleFromPrompt(latestPromptRef.current);
        void updateSessionTitle(currentSid, title);
        isFirstMessageRef.current = false;
      }

      // Snapshot the streamed turn outside any updater so each update
      // stays pure; nesting a message append inside a turn updater would
      // run twice under double-invoke and duplicate the assistant message.
      const snapshot = inFlightTurnRef.current;
      const finalActions =
        data.toolActions && data.toolActions.length > 0
          ? data.toolActions
          : snapshot?.toolActions ?? [];
      const finalMsg: MessageItem = {
        id: newSessionId(),
        role: "assistant",
        text: data.text ?? snapshot?.text ?? "",
        toolActions: finalActions.length > 0 ? finalActions : undefined,
      };
      setMessages((prev) => [...prev, finalMsg].slice(-MAX_MESSAGES));
      setInFlightTurn(null);
      inFlightTurnRef.current = null;
      setPending(false);
    } else if (data.type === "cancelled") {
      clearTurnTimeout();
      turnSessionIDRef.current = null;
      setInFlightTurn(null);
      setPending(false);
    } else if (data.type === "error") {
      clearTurnTimeout();
      turnSessionIDRef.current = null;
      if (!cancelledRef.current) {
        setError(data.message || "Chat turn failed");
      }
      setInFlightTurn(null);
      setPending(false);
    }
  }, [clearTurnTimeout]);

  const { sendMessage, isOpen } = useSharedWebSocket(handleWSMessage, handleWSClose);

  // Load active session messages on initial mount if existing
  useEffect(() => {
    let cancelled = false;
    const activeID = sessionID;
    // Hydrate the status bar from the cached cumulative total so a reload
    // does not reset a live session to zero; the next authoritative done
    // frame corrects it when the server has newer usage.
    setSessionTokens(loadSessionTokens(activeID));
    setLastTurnTokens(null);
    Promise.all([
      getSession(activeID),
      getSessionToolActions(activeID).catch(() => null),
    ])
      .then(([res, structured]) => {
        if (!cancelled && res && Array.isArray(res.messages)) {
          const mapped = reconstructMessages(
            res.messages,
            structured ? toolActionMap(structured.actions) : undefined,
          );
          setMessages(mapped);
        }
      })
      .catch((failure) => {
        // A 404 means the stored active ID was deleted server-side:
        // mint a fresh session once instead of resurrecting the stale
        // UUID on the next send. Other failures just clear the view.
        if (!cancelled) {
          if (
            failure instanceof ApiError &&
            failure.status === 404 &&
            !didRecoverSessionRef.current
          ) {
            didRecoverSessionRef.current = true;
            const next = newSessionId();
            localStorage.setItem("rw_active_session_id", next);
            setSessionID(next);
          }
          setMessages([]);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [sessionID]);

  // Never leave a turn timeout armed past unmount.
  useEffect(() => {
    return () => {
      if (turnTimeoutRef.current != null) {
        clearTimeout(turnTimeoutRef.current);
        turnTimeoutRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    messageListEndRef.current?.scrollIntoView?.({ behavior: "smooth" });
  }, [messages, pending, inFlightTurn]);

  function autoTitleFromPrompt(text: string): string {
    const firstLine = text.split("\n")[0].trim();
    if (firstLine.length <= 40) return firstLine;
    return firstLine.slice(0, 40) + "…";
  }

  const handleInputChange = (event: React.ChangeEvent<HTMLTextAreaElement>) => {
    setInput(event.target.value);
    const target = event.target;
    target.style.height = "auto";
    const maxHeight = 240; // ~10 lines
    target.style.height = `${Math.min(target.scrollHeight, maxHeight)}px`;
  };

  const handleKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void send();
    }
  };

  async function handleCancel() {
    if (!pending) return;
    cancelledRef.current = true;
    clearTurnTimeout();
    turnSessionIDRef.current = null;
    try {
      if (isOpen()) {
        sendMessage({
          type: "cancel",
          sessionID,
        });
      }
      await cancelChat(sessionID);
    } catch {
      // Best-effort cancellation
    } finally {
      setInFlightTurn(null);
      setPending(false);
    }
  }

  async function send() {
    const text = input.trim();
    if (!text || pending) return;
    cancelledRef.current = false;
    setPending(true);
    setError(null);

    const isFirst = messages.length === 0;
    isFirstMessageRef.current = isFirst;
    latestPromptRef.current = text;

    const userMessage: MessageItem = {
      id: newSessionId(),
      role: "user",
      text,
    };

    setMessages((prev) => [...prev, userMessage].slice(-MAX_MESSAGES));
    setInput("");
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }

    setInFlightTurn({ toolActions: [], text: "" });
    // Remember the owning session so timeout/close cancels this turn even
    // when the user switches sessions before the terminal frame arrives.
    turnSessionIDRef.current = sessionID;

    // Stream via WebSocket if connection is open
    if (isOpen()) {
      sendMessage({
        text,
        sessionID,
        source: "dashboard",
      });
      // Bound the terminal frame: a drop before done/error releases the
      // input lock with a retry instead of stranding it.
      armTurnTimeout();
      return;
    }

    // Fallback to REST postChat
    try {
      const response = await postChat(text, sessionID, "dashboard");
      // A cancel racing the REST round-trip must not append the late
      // reply, matching the WebSocket path that guards cancelledRef.
      if (cancelledRef.current) return;
      const currentSid = response.sessionID || sessionID;
      if (response.sessionID && response.sessionID !== sessionID) {
        setSessionID(response.sessionID);
      }

      if (response.modelName) setActiveModel(response.modelName);
      if (response.contextLength) setContextLimit(response.contextLength);
      if (typeof response.totalTokens === "number") {
        setLastTurnTokens(response.totalTokens);
      }
      if (typeof response.sessionTokens === "number") {
        setSessionTokens(response.sessionTokens);
        try {
          localStorage.setItem(sessionTokensKey(currentSid), String(response.sessionTokens));
        } catch {
          // Storage is best-effort only.
        }
      } else if (typeof response.totalTokens === "number") {
        setSessionTokens((prev) => {
          const next = prev + (response.totalTokens as number);
          try {
            localStorage.setItem(sessionTokensKey(currentSid), String(next));
          } catch {
            // Storage is best-effort only.
          }
          return next;
        });
      }

      // Pre-name session on first turn
      if (isFirst) {
        const title = autoTitleFromPrompt(text);
        void updateSessionTitle(currentSid, title);
        isFirstMessageRef.current = false;
      }

      const assistantMessage: MessageItem = {
        id: newSessionId(),
        role: "assistant",
        text: response.text,
        toolActions: response.toolActions,
      };

      setMessages((prev) => [...prev, assistantMessage].slice(-MAX_MESSAGES));
    } catch (failure) {
      // Suppress the late failure when the turn was already cancelled.
      if (cancelledRef.current) return;
      const message =
        failure instanceof ApiError ? failure.message : "Chat failed";
      setError(message);
    } finally {
      turnSessionIDRef.current = null;
      setInFlightTurn(null);
      setPending(false);
    }
  }

  function handleNewSession() {
    if (pending) {
      void handleCancel();
    }
    const nextID = newSessionId();
    setSessionID(nextID);
    setMessages([]);
    setInFlightTurn(null);
    setError(null);
    setLastTurnTokens(null);
    setSessionTokens(loadSessionTokens(nextID));
  }

  async function handleSelectSession(id: string) {
    if (id === sessionID) return;
    if (pending) {
      void handleCancel();
    }
    setSessionID(id);
    setInFlightTurn(null);
    setError(null);
    setLastTurnTokens(null);
    setSessionTokens(loadSessionTokens(id));
    try {
      const [res, structured] = await Promise.all([
        getSession(id),
        getSessionToolActions(id).catch(() => null),
      ]);
      const mapped = reconstructMessages(
        res?.messages || [],
        structured ? toolActionMap(structured.actions) : undefined,
      );
      setMessages(mapped);
    } catch (failure) {
      // A 404 means the session was deleted server-side: mint a fresh
      // session instead of resurrecting the stale UUID on the next send.
      if (failure instanceof ApiError && failure.status === 404) {
        didRecoverSessionRef.current = true;
        const next = newSessionId();
        localStorage.setItem("rw_active_session_id", next);
        setSessionID(next);
      }
      setMessages([]);
    }
  }

  const usedPercent =
    contextLimit > 0
      ? Math.round((sessionTokens / contextLimit) * 100)
      : 0;

  return (
    <div className="chat-layout">
      {/* Session History Sidebar */}
      <SessionSidebar
        currentSessionID={sessionID}
        onSelectSession={(id) => void handleSelectSession(id)}
        onNewSession={handleNewSession}
        isOpen={sidebarOpen}
        onToggleOpen={() => setSidebarOpen(!sidebarOpen)}
      />

      {/* Main Chat Area */}
      <section className="chat-main-panel" aria-label="Chat">
        <div className="chat-panel-header">
          <div className="chat-panel-title">
            {!sidebarOpen && (
              <button
                type="button"
                className="open-sidebar-btn"
                onClick={() => setSidebarOpen(true)}
                title="Open session history"
              >
                History
              </button>
            )}
            <h2>Chat</h2>
            <span className="session-id-tag font-mono">
              {sessionID.slice(0, 8)}
            </span>
          </div>

          <button
            type="button"
            className="ghost new-session-btn"
            onClick={handleNewSession}
            aria-label="New session"
          >
            New Session
          </button>
        </div>

        {/* Message Stream */}
        <div className="message-list" aria-live="polite">
          {messages.length === 0 && !pending ? (
            <div className="chat-empty-state">
              <h3>What would you like to work on?</h3>
              <p className="muted">
                Ask questions, inspect mail, manage schedules, or recall notes.
              </p>
            </div>
          ) : null}

          {messages.map((message) => {
            const hasTools = Boolean(
              message.role === "assistant" &&
              message.toolActions &&
              message.toolActions.length > 0
            );
            const hasText = Boolean(message.text && message.text.trim().length > 0);
            if (!hasText && !hasTools) return null;

            return (
              <div key={message.id} className={`message ${message.role}`}>
                {/* Distinct Tool Activity if assistant called tools */}
                {hasTools ? (
                  <div className="chat-tool-container">
                    <div className="chat-tool-heading">
                      <WrenchIcon size={12} />
                      <span>Tool Activity ({message.toolActions!.length})</span>
                    </div>
                    <div className="chat-tool-list">
                      {message.toolActions!.map((action, i) => (
                        <ToolActionRow
                          key={action.callID || i}
                          action={action}
                        />
                      ))}
                    </div>
                  </div>
                ) : null}

                {/* Message Content */}
                {hasText ? (
                  <div className="message-text">
                    {message.role === "assistant" ? (
                      <MarkdownText text={message.text} />
                    ) : (
                      message.text
                    )}
                  </div>
                ) : null}
              </div>
            );
          })}

          {/* Active in-flight assistant response with live tools and streaming text */}
          {pending && inFlightTurn && (inFlightTurn.toolActions.length > 0 || inFlightTurn.text.trim().length > 0) ? (
            <div className="message assistant streaming-bubble">
              {inFlightTurn.toolActions.length > 0 ? (
                <div className="chat-tool-container">
                  <div className="chat-tool-heading">
                    <WrenchIcon size={12} />
                    <span>Tool Activity ({inFlightTurn.toolActions.length})</span>
                  </div>
                  <div className="chat-tool-list">
                    {inFlightTurn.toolActions.map((action, i) => (
                      <ToolActionRow
                        key={action.callID || i}
                        action={action}
                      />
                    ))}
                  </div>
                </div>
              ) : null}

              {inFlightTurn.text.trim().length > 0 ? (
                <div className="message-text">
                  <MarkdownText text={inFlightTurn.text} />
                </div>
              ) : null}
            </div>
          ) : null}

          {/* Animated Loading Bubble when pending and assistant has not yet produced text */}
          {pending && (!inFlightTurn || inFlightTurn.text.trim().length === 0) ? (
            <div className="message assistant pending-bubble">
              <div className="typing-indicator" aria-label="Rune Weaver is thinking">
                <span className="typing-dot" />
                <span className="typing-dot" />
                <span className="typing-dot" />
              </div>
              <span className="typing-text">
                {inFlightTurn && inFlightTurn.toolActions.length > 0
                  ? "Executing tools…"
                  : "Rune Weaver is working…"}
              </span>
            </div>
          ) : null}

          <div ref={messageListEndRef} />
        </div>

        {error ? <p className="error chat-error">{error}</p> : null}

        {/* Input & Status Bar Container */}
        <div className="chat-footer-box">
          <div className="chat-input-row">
            <textarea
              ref={textareaRef}
              id="chat-message-prompt"
              name="chat_message_prompt"
              rows={3}
              aria-label="Chat input"
              placeholder="Message Rune Weaver… (Shift+Return for newline)"
              value={input}
              onChange={handleInputChange}
              onKeyDown={handleKeyDown}
              disabled={pending}
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              data-lpignore="true"
              data-1p-ignore="true"
              data-form-type="other"
            />
            {pending ? (
              <button
                type="button"
                className="chat-cancel-btn"
                onClick={() => void handleCancel()}
                aria-label="Cancel turn"
              >
                Cancel
              </button>
            ) : (
              <button
                type="button"
                className="primary chat-send-btn"
                onClick={() => void send()}
                disabled={input.trim().length === 0}
              >
                Send
              </button>
            )}
          </div>

          {/* Pinned Status Bar Attached Below Input */}
          <div className="chat-status-bar" aria-label="Session metrics">
            <div className="status-bar-item">
              <span className="status-bullet green" />
              <span className="status-bar-label">LLM:</span>
              <span className="status-bar-value">{activeModel}</span>
            </div>

            <div className="status-bar-divider">•</div>

            <div className="status-bar-item">
              <span className="status-bar-label">Turn:</span>
              <span className="status-bar-value">
                {lastTurnTokens != null
                  ? `${lastTurnTokens.toLocaleString()} tokens`
                  : "—"}
              </span>
            </div>

            <div className="status-bar-divider">•</div>

            <div className="status-bar-item">
              <span className="status-bar-label">Session:</span>
              <span
                className={`status-bar-value ${
                  usedPercent > 100 ? "status-warning" : ""
                }`}
              >
                {sessionTokens.toLocaleString()} /{" "}
                {contextLimit.toLocaleString()} tokens ({usedPercent}%)
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
