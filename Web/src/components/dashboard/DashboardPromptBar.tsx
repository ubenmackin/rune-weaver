// Rune Weaver Dashboard — Quick executive prompt & command bar.
// Sits prominently below the morning greeting, allowing the operator to
// immediately issue directives, questions, or goal triggers that start
// a fresh chat session with the prompt dispatched immediately.

import { useState, type FormEvent } from "react";
import { SparklesIcon } from "../icons";

interface DashboardPromptBarProps {
  onSubmitPrompt: (prompt: string) => void;
}

const QUICK_SUGGESTIONS = [
  "Review staged git changes",
  "Triage pending pull requests",
  "Run scheduled checks now",
  "Audit project dependencies",
];

export default function DashboardPromptBar({ onSubmitPrompt }: DashboardPromptBarProps) {
  const [prompt, setPrompt] = useState("");

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const trimmed = prompt.trim();
    if (!trimmed) return;
    onSubmitPrompt(trimmed);
  }

  function handleSelectSuggestion(suggestion: string) {
    onSubmitPrompt(suggestion);
  }

  return (
    <div className="dashboard-prompt-bar-wrap">
      <form onSubmit={handleSubmit} className="dashboard-prompt-form">
        <div className="dashboard-prompt-icon">
          <SparklesIcon size={18} />
        </div>
        <input
          type="text"
          className="dashboard-prompt-input"
          placeholder="Ask RuneWeaver anything, trigger a goal, or run a skill…"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          aria-label="Quick prompt for RuneWeaver"
        />
        <button
          type="submit"
          className="dashboard-prompt-submit"
          disabled={!prompt.trim()}
          aria-label="Send prompt to chat"
        >
          <span className="dashboard-prompt-submit-text">Ask</span>
          <span className="dashboard-prompt-submit-arrow">↵</span>
        </button>
      </form>
      <div className="dashboard-quick-chips">
        <span className="dashboard-chips-label">Suggestions:</span>
        {QUICK_SUGGESTIONS.map((s) => (
          <button
            key={s}
            type="button"
            className="dashboard-chip-btn"
            onClick={() => handleSelectSuggestion(s)}
          >
            {s}
          </button>
        ))}
      </div>
    </div>
  );
}
