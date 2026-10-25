// Rune Weaver Dashboard — Inline and dashboard question picker card.

import { useState } from "react";
import type { ReactNode } from "react";
import type { PermissionRequest } from "../api";
import { CheckIcon, CloseIcon, MessageSquareIcon, RefreshIcon } from "./icons";

export interface InlineQuestionCardProps {
  request: PermissionRequest;
  deciding: boolean;
  onRespond: (id: string, answer?: string, cancelled?: boolean) => void;
  onOpenSession?: (sessionId: string) => void;
  variant?: "chat" | "dashboard" | "inbox";
  // Optional trailing header control, beside the thread link. The dashboard
  // queue passes its Approvals Inbox route here so a question card carries the
  // same escape hatch as every other card on that surface.
  headerLink?: ReactNode;
}

export function parseQuestionArgs(argumentsJSON?: string | null): {
  question: string;
  options: string[];
} {
  if (!argumentsJSON) {
    return { question: "Input requested by agent", options: [] };
  }
  try {
    const parsed = JSON.parse(argumentsJSON);
    const question =
      typeof parsed.question === "string" && parsed.question.trim().length > 0
        ? parsed.question.trim()
        : "Input requested by agent";
    const options = Array.isArray(parsed.options)
      ? parsed.options
          .filter((opt: unknown) => typeof opt === "string" && (opt as string).trim().length > 0)
          .map((opt: string) => opt.trim())
      : [];
    return { question, options };
  } catch {
    return { question: "Input requested by agent", options: [] };
  }
}

export default function InlineQuestionCard({
  request,
  deciding,
  onRespond,
  onOpenSession,
  variant = "chat",
  headerLink,
}: InlineQuestionCardProps) {
  const { question, options } = parseQuestionArgs(request.input?.argumentsJSON);
  const [selectedIndex, setSelectedIndex] = useState<number | null>(null);
  const [isOtherSelected, setIsOtherSelected] = useState(false);
  const [customText, setCustomText] = useState("");

  const effectiveAnswer = isOtherSelected
    ? customText.trim()
    : selectedIndex !== null && selectedIndex >= 0 && selectedIndex < options.length
    ? options[selectedIndex]
    : "";

  const canSubmit = effectiveAnswer.length > 0 && effectiveAnswer.length <= 2000 && !deciding;

  const handleSelectOption = (index: number) => {
    setIsOtherSelected(false);
    setSelectedIndex(index);
  };

  const handleSelectOther = () => {
    setIsOtherSelected(true);
    setSelectedIndex(null);
  };

  const handleSubmit = () => {
    if (!canSubmit) return;
    onRespond(request.id, effectiveAnswer, false);
  };

  const handleCancel = () => {
    if (deciding) return;
    onRespond(request.id, undefined, true);
  };

  return (
    <div
      className={`card inline-approval-banner inline-question-card ${
        variant === "dashboard" ? "action-card" : ""
      }`}
      data-testid={`inline-question-${request.id}`}
    >
      <div className="inline-approval-header">
        <span className="badge badge-blue inline-question-badge">Question</span>
        <span className="approval-desc inline-question-title">{question}</span>
        {onOpenSession && request.sessionID ? (
          <button
            type="button"
            className="btn-link open-session-link ml-auto"
            onClick={() => onOpenSession(request.sessionID!)}
            title="Open chat thread for this question"
          >
            <MessageSquareIcon size={13} />
            <span>Open Thread</span>
          </button>
        ) : null}
        {headerLink ? (
          <span className="inline-question-header-link">{headerLink}</span>
        ) : null}
      </div>

      <div className="inline-question-options">
        {options.map((opt, idx) => (
          <label
            key={`opt-${idx}`}
            className={`inline-question-option ${
              selectedIndex === idx && !isOtherSelected
                ? "inline-question-option-selected"
                : ""
            }`}
          >
            <input
              type="radio"
              name={`question-${request.id}`}
              checked={selectedIndex === idx && !isOtherSelected}
              onChange={() => handleSelectOption(idx)}
              disabled={deciding}
            />
            <span className="text-sm">{opt}</span>
          </label>
        ))}

        {/* Automatic "Other" write-in escape hatch */}
        <label
          className={`inline-question-option ${
            isOtherSelected ? "inline-question-option-selected" : ""
          }`}
        >
          <input
            type="radio"
            name={`question-${request.id}`}
            checked={isOtherSelected}
            onChange={handleSelectOther}
            disabled={deciding}
          />
          <span className="text-sm inline-question-other-label">Other:</span>
          <input
            type="text"
            className="inline-question-other-input"
            value={customText}
            placeholder="Type your own answer…"
            disabled={deciding}
            maxLength={2000}
            onChange={(e) => {
              setCustomText(e.target.value);
              setIsOtherSelected(true);
              setSelectedIndex(null);
            }}
            onFocus={handleSelectOther}
            onKeyDown={(e) => {
              if (e.key === "Enter" && canSubmit) {
                e.preventDefault();
                handleSubmit();
              }
            }}
          />
        </label>
      </div>

      <div className="inline-approval-actions">
        {deciding ? (
          <span className="text-xs muted inline-approval-deciding inline-question-deciding">
            <RefreshIcon size={12} className="spin" />
            <span>Submitting…</span>
          </span>
        ) : null}

        <button
          type="button"
          className="btn danger reject-action-btn"
          disabled={deciding}
          onClick={handleCancel}
          aria-label="Cancel question"
        >
          <CloseIcon size={14} />
          <span>Cancel</span>
        </button>

        <button
          type="button"
          className="btn primary approve-action-btn"
          disabled={!canSubmit}
          onClick={handleSubmit}
          aria-label="Submit choice"
        >
          <CheckIcon size={14} />
          <span>Submit Choice</span>
        </button>
      </div>
    </div>
  );
}
