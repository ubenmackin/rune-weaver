// Rune Weaver Dashboard — Morning Recommendations (Proactive Ideas Radar).
//
// Surfaces the agent's proactive initiatives (proposed ideas) directly on
// the dashboard. Rather than waiting passively for instructions, RuneWeaver
// uses its Ideas engine to spot codebase drift, test failures, or workflow
// optimizations, allowing the operator to accept or dismiss with one click.

import { useCallback, useEffect, useState } from "react";
import {
  acceptIdea,
  dismissIdea,
  ideaKindLabel,
  isIdeaProposedProactive,
  listIdeas,
  parseIdea,
  type Idea,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import MarkdownText from "../MarkdownText";
import { CheckIcon, CloseIcon, MessageSquareIcon, SparklesIcon } from "../icons";

interface MorningRecommendationsProps {
  onOpenChatWithIdea?: (prompt: string) => void;
  onIdeaAccepted?: (idea: Idea) => void;
}

export default function MorningRecommendations({
  onOpenChatWithIdea,
  onIdeaAccepted,
}: MorningRecommendationsProps) {
  const [ideas, setIdeas] = useState<Idea[]>([]);
  const [actionInProgress, setActionInProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fetchProposedIdeas = useCallback(async () => {
    try {
      setError(null);
      const res = await listIdeas("proposed");
      const parsed = res.ideas.map(parseIdea).filter((i): i is Idea => i !== null);
      setIdeas(parsed);
    } catch (err) {
      // Non-blocking: fail quietly if ideas are disabled or unreachable
      console.warn("Failed to fetch proactive ideas:", err);
    }
  }, []);

  useEffect(() => {
    fetchProposedIdeas();
  }, [fetchProposedIdeas]);

  // WebSocket push updates for proactive messages announcing proposed ideas
  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      if (isIdeaProposedProactive(frame)) {
        fetchProposedIdeas();
      }
    },
    [fetchProposedIdeas],
  );

  useSharedWebSocket(handleWSFrame);

  // Tab visibility resync ensures returning to the tab immediately refreshes ideas
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchProposedIdeas();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [fetchProposedIdeas]);

  // Periodic heartbeat polling keeps recommendations synced
  useEffect(() => {
    const interval = setInterval(fetchProposedIdeas, 15000);
    return () => clearInterval(interval);
  }, [fetchProposedIdeas]);

  async function handleAccept(idea: Idea) {
    try {
      setActionInProgress(idea.id);
      const updated = await acceptIdea(idea.id);
      setIdeas((prev) => prev.filter((i) => i.id !== idea.id));
      onIdeaAccepted?.(updated);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to accept idea");
    } finally {
      setActionInProgress(null);
    }
  }

  async function handleDismiss(idea: Idea) {
    try {
      setActionInProgress(idea.id);
      await dismissIdea(idea.id);
      setIdeas((prev) => prev.filter((i) => i.id !== idea.id));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to dismiss idea");
    } finally {
      setActionInProgress(null);
    }
  }

  function handleDiscuss(idea: Idea) {
    const prompt = `Let's discuss your recommendation: "${idea.title}"\n\nDetails: ${idea.body}`;
    onOpenChatWithIdea?.(prompt);
  }

  if (ideas.length === 0) {
    return null;
  }

  return (
    <section className="dashboard-recommendations-section" aria-label="Morning recommendations">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <SparklesIcon size={18} className="dashboard-section-icon accent-purple" />
          <h2 className="dashboard-section-title">Morning Recommendations</h2>
          <span className="dashboard-count-badge">{ideas.length}</span>
        </div>
        <span className="dashboard-section-subtitle">
          Proactive suggestions synthesized by the Ideas engine
        </span>
      </div>

      {error && <div className="notice-banner error">{error}</div>}

      <div className="dashboard-recommendations-list">
        {ideas.map((idea) => {
          const isBusy = actionInProgress === idea.id;
          return (
            <article key={idea.id} className="dashboard-recommendation-card">
              <div className="recommendation-header">
                <div className="recommendation-badge-row">
                  <span className="badge recommendation-kind-badge">
                    {ideaKindLabel(idea.kind)}
                  </span>
                  <span className="recommendation-status-pill">Proposed</span>
                </div>
                <h3 className="recommendation-title">{idea.title}</h3>
              </div>

              <div className="recommendation-body">
                <MarkdownText text={idea.body} />
              </div>

              <div className="recommendation-actions">
                <button
                  type="button"
                  className="btn btn-primary accept-btn"
                  onClick={() => handleAccept(idea)}
                  disabled={isBusy}
                  aria-label={`Accept idea: ${idea.title}`}
                >
                  <CheckIcon size={15} />
                  <span>{isBusy ? "Applying…" : "Accept & Execute"}</span>
                </button>

                <button
                  type="button"
                  className="btn chat-btn"
                  onClick={() => handleDiscuss(idea)}
                  disabled={isBusy}
                  aria-label={`Discuss idea in chat: ${idea.title}`}
                >
                  <MessageSquareIcon size={15} />
                  <span>Discuss in Chat</span>
                </button>

                <button
                  type="button"
                  className="btn dismiss-btn"
                  onClick={() => handleDismiss(idea)}
                  disabled={isBusy}
                  aria-label={`Dismiss idea: ${idea.title}`}
                >
                  <CloseIcon size={15} />
                  <span>Dismiss</span>
                </button>
              </div>
            </article>
          );
        })}
      </div>
    </section>
  );
}
