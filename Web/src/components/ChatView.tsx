// Rune Weaver Dashboard — Interactive chat interface with turn streaming and session management.

import { useState } from "react";
import { ApiError, newSessionId, postChat } from "../api";

interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
}

const MAX_MESSAGES = 200;

export default function ChatView() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [sessionID, setSessionID] = useState<string>(() => newSessionId());
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function send() {
    const text = input.trim();
    if (!text || pending) return;
    setPending(true);
    setError(null);
    setMessages((previous) => [...previous, { id: newSessionId(), role: "user" as const, text }].slice(-MAX_MESSAGES));
    setInput("");
    try {
      const response = await postChat(text, sessionID, "dashboard");
      if (response.sessionID && response.sessionID !== sessionID) setSessionID(response.sessionID);
      const trailer =
        typeof response.totalTokens === "number"
          ? `\n\n(${response.totalTokens} tokens)`
          : "";
      setMessages((previous) => [
        ...previous,
        { id: newSessionId(), role: "assistant" as const, text: `${response.text}${trailer}` },
      ].slice(-MAX_MESSAGES));
    } catch (failure) {
      const message =
        failure instanceof ApiError ? failure.message : "Chat failed";
      setError(message);
    } finally {
      setPending(false);
    }
  }

  function newSession() {
    setSessionID(newSessionId());
    setMessages([]);
    setError(null);
  }

  return (
    <section className="panel" aria-label="Chat">
      <h2>Chat</h2>
      <div className="row">
        <span className="muted">Session {sessionID.slice(0, 8)}</span>
        <button type="button" className="ghost" onClick={newSession}>
          New session
        </button>
      </div>
      <div className="message-list" aria-live="polite">
        {messages.length === 0 ? (
          <p className="muted">Ask anything to start a turn.</p>
        ) : null}
        {messages.map((message) => (
          <div key={message.id} className={`message ${message.role}`}>
            {message.text}
          </div>
        ))}
      </div>
      {error ? <p className="error">{error}</p> : null}
      <div className="row">
        <input
          type="text"
          aria-label="Chat input"
          placeholder="Message Rune Weaver…"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") void send();
          }}
        />
        <button
          type="button"
          className="primary"
          onClick={() => void send()}
          disabled={pending || input.trim().length === 0}
        >
          {pending ? "Sending…" : "Send"}
        </button>
      </div>
    </section>
  );
}
