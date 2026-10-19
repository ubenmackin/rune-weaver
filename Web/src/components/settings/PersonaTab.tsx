// Rune Weaver Dashboard — Persona tab pane.

import { useState } from "react";
import {
  MAX_PERSONA_ASSISTANT_NAME_LENGTH,
  MAX_PERSONA_STYLE_LENGTH,
  MAX_PERSONA_USER_NAME_LENGTH,
  normalizePersonaTone,
  PERSONA_AVATAR_COLORS,
  PERSONA_TONE_OPTIONS,
  DEFAULT_PERSONA_AVATAR,
} from "../../api";
import { PersonaAvatar } from "../PersonaAvatar";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import { countPersonaAdvancedChanged } from "./settingsAdvancedCounts";

export interface PersonaTabProps {
  personaAssistantNameDraft: string;
  setPersonaAssistantNameDraft: (val: string) => void;
  personaToneDraft: string;
  setPersonaToneDraft: (val: string) => void;
  personaUserNameDraft: string;
  setPersonaUserNameDraft: (val: string) => void;
  personaStyleDraft: string;
  setPersonaStyleDraft: (val: string) => void;
  personaAvatarDraft: string;
  setPersonaAvatarDraft: (val: string) => void;
  validationError?: string | null;
}

function matchesAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return (
    lowered.includes("avatar") ||
    lowered.includes("style") ||
    lowered.includes("persona.style") ||
    lowered.includes("persona.avatar")
  );
}

export function PersonaTab({
  personaAssistantNameDraft,
  setPersonaAssistantNameDraft,
  personaToneDraft,
  setPersonaToneDraft,
  personaUserNameDraft,
  setPersonaUserNameDraft,
  personaStyleDraft,
  setPersonaStyleDraft,
  personaAvatarDraft,
  setPersonaAvatarDraft,
  validationError,
}: PersonaTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const changedCount = countPersonaAdvancedChanged(
    personaAvatarDraft,
    personaStyleDraft,
    DEFAULT_PERSONA_AVATAR
  );
  const advancedError = matchesAdvancedError(validationError)
    ? validationError
    : null;

  const handleResetAdvanced = () => {
    setPersonaAvatarDraft(DEFAULT_PERSONA_AVATAR);
    setPersonaStyleDraft("");
  };

  return (
    <div className="settings-section card" data-testid="persona-pane">
      <div className="settings-section-title-group">
        <h3>Persona</h3>
        <p className="settings-section-hint">
          Assistant name, tone, style guidance, and avatar accent. Applies live with no restart.
        </p>
      </div>
      <div className="form-row" style={{ marginTop: "1rem" }}>
        <div className="form-group flex-1">
          <label htmlFor="persona-assistant-name">Assistant Name</label>
          <input
            id="persona-assistant-name"
            type="text"
            className="input-field"
            maxLength={MAX_PERSONA_ASSISTANT_NAME_LENGTH}
            placeholder="Rune Weaver"
            value={personaAssistantNameDraft}
            onChange={(e) => setPersonaAssistantNameDraft(e.target.value)}
          />
          <p
            className="settings-field-hint"
            style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}
          >
            How the agent names itself. Blank falls back to the stock identity. Max {MAX_PERSONA_ASSISTANT_NAME_LENGTH} characters.
          </p>
        </div>
        <div className="form-group flex-1">
          <label htmlFor="persona-tone">Tone</label>
          <select
            id="persona-tone"
            className="input-field"
            value={personaToneDraft}
            onChange={(e) =>
              setPersonaToneDraft(
                normalizePersonaTone(e.target.value) || personaToneDraft,
              )
            }
          >
            {PERSONA_TONE_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
          <span className="form-group-hint">
            One preset posture sentence folded into the identity line.
          </span>
        </div>
      </div>
      <div className="form-row" style={{ marginTop: "1rem" }}>
        <div className="form-group flex-1">
          <label htmlFor="persona-user-name">Your Name</label>
          <input
            id="persona-user-name"
            type="text"
            className="input-field"
            maxLength={MAX_PERSONA_USER_NAME_LENGTH}
            placeholder="(leave blank for no address clause)"
            value={personaUserNameDraft}
            onChange={(e) => setPersonaUserNameDraft(e.target.value)}
          />
          <p
            className="settings-field-hint"
            style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}
          >
            Preferred spelling for the address clause. Optional. Max {MAX_PERSONA_USER_NAME_LENGTH} characters.
          </p>
        </div>
      </div>
      <AdvancedDisclosure
        tabName="Persona"
        changedCount={changedCount}
        summary={
          changedCount > 0
            ? `${changedCount} advanced persona ${changedCount === 1 ? "setting" : "settings"} changed`
            : undefined
        }
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        validationError={advancedError}
        onReset={handleResetAdvanced}
      >
        <div className="form-group" style={{ marginTop: "1rem" }}>
          <label htmlFor="persona-style">Style Guidance</label>
          <textarea
            id="persona-style"
            className="input-field"
            rows={4}
            maxLength={MAX_PERSONA_STYLE_LENGTH}
            placeholder="Free-form guidance the agent appends to its identity."
            value={personaStyleDraft}
            onChange={(e) => setPersonaStyleDraft(e.target.value)}
          />
          <p
            className="settings-field-hint"
            data-testid="persona-style-count"
            style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)", marginTop: "0.25rem" }}
          >
            {personaStyleDraft.length} / {MAX_PERSONA_STYLE_LENGTH} characters
          </p>
        </div>
        <div className="form-group" style={{ marginTop: "1rem" }}>
          <p
            className="settings-field-hint"
            style={{ fontSize: "0.85rem", color: "var(--text-muted, #888)" }}
          >
            Avatar accent — a client-side colorway for the assistant sprite. It never reaches the prompt.
          </p>
          <div
            className="persona-avatar-grid"
            role="group"
            aria-label="Avatar accent"
            data-testid="persona-avatar-grid"
          >
            {PERSONA_AVATAR_COLORS.map((accent) => (
              <button
                key={accent}
                type="button"
                data-testid={`persona-avatar-${accent}`}
                className={`persona-avatar-option${
                  personaAvatarDraft === accent ? " selected" : ""
                }`}
                aria-pressed={personaAvatarDraft === accent}
                aria-label={`Avatar accent ${accent}`}
                onClick={() => setPersonaAvatarDraft(accent)}
              >
                <PersonaAvatar
                  color={accent}
                  state="idle"
                  size={64}
                  blink={false}
                  label=""
                />
              </button>
            ))}
          </div>
        </div>
      </AdvancedDisclosure>
    </div>
  );
}

export default PersonaTab;
