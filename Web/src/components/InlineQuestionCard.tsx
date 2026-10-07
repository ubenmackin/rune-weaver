// Rune Weaver Dashboard — Inline and dashboard question picker card.
// Renders single-select candidate options with a write-in "Other" field
// and Cancel / Submit actions for `question.ask` tools.

import { useState } from "react";
import type { PermissionRequest } from "../api";
import { CheckIcon, CloseIcon, MessageSquareIcon, RefreshIcon } from "./icons";

export interface InlineQuestionCardProps {
  request: PermissionRequest;
  deciding: boolean;
  onRespond: (id: string, answer?: string, cancelled?: boolean) => void;
  onOpenSession?: (sessionId: string) => void;
  variant?: "chat" | "dashboard" | "inbox";
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
        <span
          className="badge approval-tool-badge question-badge"
          style={{ backgroundColor: "#2563eb", color: "#fff" }}
        >
          Question
        </span>
        <span className="approval-desc question-title" style={{ fontWeight: 600 }}>
          {question}
        </span>
        {onOpenSession && request.sessionID ? (
          <button
            type="button"
            className="btn-link open-session-link"
            style={{ marginLeft: "auto" }}
            onClick={() => onOpenSession(request.sessionID!)}
            title="Open chat thread for this question"
          >
            <MessageSquareIcon size={13} />
            <span>Open Thread</span>
          </button>
        ) : null}
      </div>

      <div
        className="question-options-list"
        style={{ display: "flex", flexDirection: "column", gap: "8px", margin: "8px 0" }}
      >
        {options.map((opt, idx) => (
          <label
            key={`opt-${idx}`}
            className={`question-option-item ${
              selectedIndex === idx && !isOtherSelected ? "selected" : ""
            }`}
            style={{
              display: "flex",
              alignItems: "center",
              gap: "8px",
              padding: "6px 10px",
              borderRadius: "6px",
              background:
                selectedIndex === idx && !isOtherSelected
                  ? "rgba(37, 99, 235, 0.15)"
                  : "rgba(255, 255, 255, 0.04)",
              border:
                selectedIndex === idx && !isOtherSelected
                  ? "1px solid #2563eb"
                  : "1px solid rgba(255, 255, 255, 0.08)",
              cursor: "pointer",
            }}
          >
            <input
              type="radio"
              name={`question-${request.id}`}
              checked={selectedIndex === idx && !isOtherSelected}
              onChange={() => handleSelectOption(idx)}
              disabled={deciding}
            />
            <span style={{ fontSize: "13px" }}>{opt}</span>
          </label>
        ))}

        {/* Automatic "Other" write-in escape hatch */}
        <label
          className={`question-option-item ${isOtherSelected ? "selected" : ""}`}
          style={{
            display: "flex",
            alignItems: "center",
            gap: "8px",
            padding: "6px 10px",
            borderRadius: "6px",
            background: isOtherSelected
              ? "rgba(37, 99, 235, 0.15)"
              : "rgba(255, 255, 255, 0.04)",
            border: isOtherSelected
              ? "1px solid #2563eb"
              : "1px solid rgba(255, 255, 255, 0.08)",
            cursor: "pointer",
          }}
        >
          <input
            type="radio"
            name={`question-${request.id}`}
            checked={isOtherSelected}
            onChange={handleSelectOther}
            disabled={deciding}
          />
          <span style={{ fontSize: "13px", whiteSpace: "nowrap" }}>Other:</span>
          <input
            type="text"
            className="question-other-input"
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
            style={{
              flex: 1,
              padding: "4px 8px",
              fontSize: "13px",
              background: "rgba(0, 0, 0, 0.3)",
              border: "1px solid rgba(255, 255, 255, 0.15)",
              borderRadius: "4px",
              color: "inherit",
            }}
          />
        </label>
      </div>

      <div className="inline-approval-actions">
        {deciding ? (
          <span
            className="text-xs muted inline-approval-deciding"
            style={{ display: "flex", alignItems: "center", gap: "4px" }}
          >
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
