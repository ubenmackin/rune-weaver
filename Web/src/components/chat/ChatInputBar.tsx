// Rune Weaver Dashboard — Chat prompt input bar with send, steer, cancel controls and ephemeral trust chip.

import type { ChangeEvent, KeyboardEvent, RefObject } from "react";
import type { ChatSettings } from "../../chatSettings";
import EphemeralTrustChip from "../EphemeralTrustChip";

interface ChatInputBarProps {
  textareaRef: RefObject<HTMLTextAreaElement>;
  chatSettings: ChatSettings;
  pending: boolean;
  input: string;
  onInputChange: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  onCancel: () => void | Promise<void>;
  onSteer: () => void;
  onSend: () => void | Promise<void>;
  sessionID: string;
}

export default function ChatInputBar({
  textareaRef,
  chatSettings,
  pending,
  input,
  onInputChange,
  onKeyDown,
  onCancel,
  onSteer,
  onSend,
  sessionID,
}: ChatInputBarProps) {
  return (
    <>
      <div className="chat-input-row">
        <textarea
          ref={textareaRef}
          id="chat-message-prompt"
          name="chat_message_prompt"
          rows={3}
          aria-label="Chat input"
          placeholder={
            chatSettings.sendOnEnter
              ? pending
                ? "Steer agent mid-turn… (Shift+Return for newline)"
                : "Message Rune Weaver… (Shift+Return for newline)"
              : pending
                ? "Steer agent mid-turn… (⌘+Return to send)"
                : "Message Rune Weaver… (⌘+Return to send)"
          }
          value={input}
          onChange={onInputChange}
          onKeyDown={onKeyDown}
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          data-lpignore="true"
          data-1p-ignore="true"
          data-form-type="other"
        />
        {pending ? (
          <>
            <button
              type="button"
              className="chat-cancel-btn"
              onClick={() => void onCancel()}
              aria-label="Cancel turn"
              title="Cancel the active turn (briefly paused right after steering so fresh guidance isn't dropped)"
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary chat-send-btn"
              onClick={onSteer}
              aria-label="Steer turn"
              disabled={input.trim().length === 0}
            >
              Steer
            </button>
          </>
        ) : (
          <button
            type="button"
            className="primary chat-send-btn"
            onClick={() => void onSend()}
            disabled={input.trim().length === 0}
          >
            Send
          </button>
        )}
      </div>

      {/* Ephemeral session trust sits directly below the input row */}
      <EphemeralTrustChip sessionID={sessionID} />
    </>
  );
}
