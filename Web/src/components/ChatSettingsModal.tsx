// Rune Weaver Dashboard — Chat settings configuration dialog.
//
// Offers user controls for chat behavior including default thinking process expansion,
// keyboard send shortcuts, and auto-scrolling preferences.

import { type FC } from "react";
import Modal from "./Modal";
import { CloseIcon, SparklesIcon } from "./icons";
import type { ChatSettings, ThinkingDefaultState } from "../chatSettings";

interface ChatSettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  settings: ChatSettings;
  onUpdateSettings: (patch: Partial<ChatSettings>) => void;
  onResetSettings: () => void;
}

export const ChatSettingsModal: FC<ChatSettingsModalProps> = ({
  isOpen,
  onClose,
  settings,
  onUpdateSettings,
  onResetSettings,
}) => {
  if (!isOpen) return null;

  const handleThinkingChange = (mode: ThinkingDefaultState) => {
    onUpdateSettings({ thinkingDefault: mode });
  };

  const handleToggleSendOnEnter = () => {
    onUpdateSettings({ sendOnEnter: !settings.sendOnEnter });
  };

  const handleToggleAutoScroll = () => {
    onUpdateSettings({ autoScrollOnStream: !settings.autoScrollOnStream });
  };

  return (
    <Modal
      label="Chat Settings"
      onClose={onClose}
      containerClassName="modal-container chat-settings-modal"
    >
      <div className="modal-header">
        <div className="chat-settings-modal-title">
          <SparklesIcon size={18} />
          <h3>Chat Settings</h3>
        </div>
        <button
          type="button"
          className="icon-button"
          onClick={onClose}
          aria-label="Close settings"
        >
          <CloseIcon size={16} />
        </button>
      </div>

      <div className="modal-body chat-settings-modal-body">
        {/* Section 1: Thinking Process Display */}
        <div className="chat-settings-section">
          <div className="chat-settings-section-header">
            <h4>Thinking Process</h4>
            <p className="chat-settings-hint">
              Control whether model reasoning and thought blocks are expanded or collapsed by default.
            </p>
          </div>

          <div
            className="chat-settings-radio-group"
            role="radiogroup"
            aria-label="Default thinking process display"
          >
            <label
              className={`chat-settings-radio-card ${
                settings.thinkingDefault === "collapsed" ? "active" : ""
              }`}
            >
              <input
                type="radio"
                name="thinkingDefault"
                value="collapsed"
                checked={settings.thinkingDefault === "collapsed"}
                onChange={() => handleThinkingChange("collapsed")}
                className="chat-settings-radio-input"
              />
              <div className="chat-settings-radio-content">
                <span className="chat-settings-option-title">Collapsed by default</span>
                <span className="chat-settings-option-desc">
                  Keep reasoning hidden in collapsible details; click to reveal thoughts.
                </span>
              </div>
            </label>

            <label
              className={`chat-settings-radio-card ${
                settings.thinkingDefault === "expanded" ? "active" : ""
              }`}
            >
              <input
                type="radio"
                name="thinkingDefault"
                value="expanded"
                checked={settings.thinkingDefault === "expanded"}
                onChange={() => handleThinkingChange("expanded")}
                className="chat-settings-radio-input"
              />
              <div className="chat-settings-radio-content">
                <span className="chat-settings-option-title">Expanded by default</span>
                <span className="chat-settings-option-desc">
                  Automatically show the full model thinking and reasoning process.
                </span>
              </div>
            </label>
          </div>
        </div>

        {/* Section 2: Keyboard & Input Preferences */}
        <div className="chat-settings-section">
          <div className="chat-settings-section-header">
            <h4>Message Input</h4>
            <p className="chat-settings-hint">
              Configure submission shortcuts for the chat composer.
            </p>
          </div>

          <div className="chat-settings-toggle-row">
            <div className="chat-settings-toggle-label">
              <span className="chat-settings-option-title">Send with Return</span>
              <span className="chat-settings-option-desc">
                {settings.sendOnEnter
                  ? "Press Return to send. Use Shift+Return for a new line."
                  : "Press ⌘+Return (or Ctrl+Return) to send. Return inserts a new line."}
              </span>
            </div>
            <label className="tool-switch" aria-label="Toggle send on Enter">
              <input
                type="checkbox"
                className="tool-switch-input"
                checked={settings.sendOnEnter}
                onChange={handleToggleSendOnEnter}
                aria-label="Send message on Return"
              />
              <div
                className="tool-switch-track"
                data-on={settings.sendOnEnter ? "true" : "false"}
              >
                <div className="tool-switch-thumb" />
              </div>
            </label>
          </div>
        </div>

        {/* Section 3: Viewport & Scrolling */}
        <div className="chat-settings-section">
          <div className="chat-settings-section-header">
            <h4>Display & Scrolling</h4>
            <p className="chat-settings-hint">
              Configure how the view responds while generating turns.
            </p>
          </div>

          <div className="chat-settings-toggle-row">
            <div className="chat-settings-toggle-label">
              <span className="chat-settings-option-title">Auto-scroll during response</span>
              <span className="chat-settings-option-desc">
                Automatically keep the latest tokens and tool actions in view.
              </span>
            </div>
            <label className="tool-switch" aria-label="Toggle auto-scroll on stream">
              <input
                type="checkbox"
                className="tool-switch-input"
                checked={settings.autoScrollOnStream}
                onChange={handleToggleAutoScroll}
                aria-label="Auto-scroll during response generation"
              />
              <div
                className="tool-switch-track"
                data-on={settings.autoScrollOnStream ? "true" : "false"}
              >
                <div className="tool-switch-thumb" />
              </div>
            </label>
          </div>
        </div>
      </div>

      <div className="modal-footer chat-settings-footer">
        <button
          type="button"
          className="ghost"
          onClick={onResetSettings}
          title="Reset chat settings to default"
        >
          Reset to defaults
        </button>
        <button
          type="button"
          className="primary"
          onClick={onClose}
          aria-label="Close chat settings"
        >
          Done
        </button>
      </div>
    </Modal>
  );
};

export default ChatSettingsModal;
