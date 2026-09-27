// Rune Weaver Dashboard — Collapsible thought process container.
//
// Renders assistant reasoning / thinking process with configurable default
// expansion while preserving user manual toggles across re-renders and streaming.

import { useEffect, useState } from "react";
import MarkdownText from "./MarkdownText";
import { SparklesIcon } from "./icons";

interface ThoughtContainerProps {
  /**
   * Raw text content of the thought segment.
   */
  text: string;
  /**
   * Whether this block should be expanded by default according to chat settings.
   */
  defaultExpanded: boolean;
  /**
   * Optional flag indicating this thought block is currently streaming live.
   */
  isLive?: boolean;
}

export default function ThoughtContainer({
  text,
  defaultExpanded,
  isLive = false,
}: ThoughtContainerProps) {
  const [isOpen, setIsOpen] = useState(defaultExpanded);

  // Sync state when the default preference changes (e.g. user toggles setting in modal)
  useEffect(() => {
    setIsOpen(defaultExpanded);
  }, [defaultExpanded]);

  if (!text || text.trim().length === 0) {
    return null;
  }

  return (
    <details
      className={`chat-thought-container${isLive ? " live-thought" : ""}`}
      open={isOpen}
      onToggle={(event) => {
        // Keep the local state in sync when user manually clicks <summary>
        setIsOpen(event.currentTarget.open);
      }}
    >
      <summary className="chat-thought-heading">
        <SparklesIcon size={12} />
        <span>Thinking Process</span>
      </summary>
      <div className="chat-thought-content">
        <MarkdownText text={text} />
      </div>
    </details>
  );
}
