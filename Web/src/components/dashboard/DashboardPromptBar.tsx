// Rune Weaver Dashboard — Quick executive prompt & command bar.

import { useEffect, useState, type FormEvent } from "react";
import { SparklesIcon } from "../icons";

interface DashboardPromptBarProps {
  onSubmitPrompt: (prompt: string) => void;
  initialPrompt?: string | null;
  attention?: boolean;
}

const QUICK_SUGGESTIONS = [
  "Review staged git changes",
  "Triage pending pull requests",
  "Run scheduled checks now",
  "Audit project dependencies",
];

export default function DashboardPromptBar({ onSubmitPrompt, initialPrompt, attention = false }: DashboardPromptBarProps) {
  const [prompt, setPrompt] = useState(initialPrompt ?? "");
  // Nudge clears on first edit or submit; a fresh prefill re-arms it.
  const [nudgeDismissed, setNudgeDismissed] = useState(false);

  // Finish landing prefills Ask without sending; clearing the landing resets the bar.
  useEffect(() => {
    if (typeof initialPrompt === "string" && initialPrompt.length > 0) {
      setPrompt(initialPrompt);
      setNudgeDismissed(false);
    } else if (initialPrompt == null || initialPrompt === "") {
      setPrompt("");
    }
  }, [initialPrompt]);

  // First turn stays user-initiated; the pulse only draws the eye to the prefilled Ask.
  const showNudge = attention === true && !nudgeDismissed && prompt.trim().length > 0;

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const trimmed = prompt.trim();
    if (!trimmed) return;
    setNudgeDismissed(true);
    onSubmitPrompt(trimmed);
  }

  function handleSelectSuggestion(suggestion: string) {
    setNudgeDismissed(true);
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
          data-testid="dashboard-prompt-input"
          placeholder="Ask RuneWeaver anything, trigger a goal, or run a skill…"
          value={prompt}
          onChange={(e) => {
            setPrompt(e.target.value);
            setNudgeDismissed(true);
          }}
          aria-label="Quick prompt for RuneWeaver"
        />
        <button
          type="submit"
          className={`dashboard-prompt-submit${showNudge ? " landing-nudge" : ""}`}
          data-testid="dashboard-prompt-submit"
          data-nudged={showNudge ? "true" : undefined}
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
