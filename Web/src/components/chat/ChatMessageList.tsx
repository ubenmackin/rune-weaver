// Rune Weaver Dashboard — Chat message stream, in-flight turns, tools, inline approvals, and liveness indicator.

import type { RefObject } from "react";
import {
  isRecallDiagnosticsVisible,
  parseRecallDiagnostics,
  type FileReviewStates,
  type PermissionRequest,
  type ToolAction,
  type ToolProgress,
  type TrustDuration,
} from "../../api";
import type { ChatSettings } from "../../chatSettings";
import {
  AlertTriangleIcon,
  CheckIcon,
  CopyIcon,
  WrenchIcon,
} from "../icons";
import InlineApprovalBanner from "../InlineApprovalBanner";
import InlineQuestionCard from "../InlineQuestionCard";
import MarkdownText from "../MarkdownText";
import ThoughtContainer from "../ThoughtContainer";
import ToolActionRow from "../ToolActionRow";
import { isWriteReviewOwner } from "../writeReviewOwnership";
import { formatCompletionRelative, getMessageCopyContent } from "./chatHelpers";
import type { InFlightTurn, MessageItem } from "./chatTypes";
import RecallChip from "./RecallChip";

interface ChatMessageListProps {
  messages: MessageItem[];
  pending: boolean;
  inFlightTurn: InFlightTurn | null;
  chatSettings: ChatSettings;
  writeReviewOwners: Map<string, ToolAction>;
  writeReviewStates: FileReviewStates | null;
  toolProgressByCallID: Map<string, ToolProgress>;
  cancellingToolCallIDs: Set<string>;
  copiedMessageId: string | null;
  handleCopyMessage: (id: string, text: string) => Promise<void>;
  handleCancelTool: (callID: string, reason?: string) => void;
  messageListRef: RefObject<HTMLDivElement>;
  messageListEndRef: RefObject<HTMLDivElement>;
  onScroll: () => void;
  error: string | null;
  trimmedLiveFlights: string[];
  onDismissTrimmedFlights: () => void;
  turnWarnings: string[];
  onDismissWarnings: () => void;
  sessionApprovals: PermissionRequest[];
  decidingApprovalIDs: Set<string>;
  onDecideApproval: (id: string, approved: boolean, duration: TrustDuration) => void;
  onRespondQuestion: (id: string, answer?: string, cancelled?: boolean) => void;
}

export default function ChatMessageList({
  messages,
  pending,
  inFlightTurn,
  chatSettings,
  writeReviewOwners,
  writeReviewStates,
  toolProgressByCallID,
  cancellingToolCallIDs,
  copiedMessageId,
  handleCopyMessage,
  handleCancelTool,
  messageListRef,
  messageListEndRef,
  onScroll,
  error,
  trimmedLiveFlights,
  onDismissTrimmedFlights,
  turnWarnings,
  onDismissWarnings,
  sessionApprovals,
  decidingApprovalIDs,
  onDecideApproval,
  onRespondQuestion,
}: ChatMessageListProps) {
  const hasRunningTools =
    inFlightTurn?.toolActions.some((action) => !action.result) ?? false;
  const hasPartialText =
    ((inFlightTurn?.text ?? "") + (inFlightTurn?.held ?? "")).trim().length > 0;
  const liveHeld = inFlightTurn?.held ?? "";
  const liveSegments = inFlightTurn?.segments ?? [];
  let liveLastTextIndex = -1;
  for (let liveIndex = liveSegments.length - 1; liveIndex >= 0; liveIndex--) {
    if (liveSegments[liveIndex].kind === "text") {
      liveLastTextIndex = liveIndex;
      break;
    }
  }

  return (
    <>
      {/* Message Stream */}
      <div
        className="message-list"
        aria-live="polite"
        ref={messageListRef}
        onScroll={onScroll}
      >
        {messages.length === 0 && !pending ? (
          <div className="chat-empty-state">
            <h3>What would you like to work on?</h3>
            <p className="muted">
              Ask questions, inspect mail, manage schedules, or recall notes.
            </p>
          </div>
        ) : null}

        {messages.map((message) => {
          const actions =
            message.role === "assistant" ? (message.toolActions ?? []) : [];
          const hasTools = actions.length > 0;
          const hasText = Boolean(message.text && message.text.trim().length > 0);
          if (!hasText && !hasTools && !message.isError) return null;
          const isPersistedErrorText = (text: string) =>
            text.trim().startsWith("Error:") ||
            text.trim().startsWith("Chat request failed");
          const isSuppressedErrorText = (text: string) => {
            if (!message.isError) return false;
            const failure = message.errorText?.trim();
            if (failure && failure.length > 0) {
              return text.trim() === failure;
            }
            return isPersistedErrorText(text);
          };
          const segments =
            message.role === "assistant" && message.segments
              ? message.segments
              : undefined;

          return (
            <div
              key={message.id}
              className={`message ${message.role}${message.isError ? " message-error" : ""}`}
            >
              {message.role === "assistant" && message.recallDiagnostics
                ? (() => {
                    const parsed = parseRecallDiagnostics(message.recallDiagnostics);
                    if (!parsed || !isRecallDiagnosticsVisible(parsed)) return null;
                    return <RecallChip diagnostics={parsed} />;
                  })()
                : null}
              {segments && segments.length > 0 ? (
                <>
                  {segments.map((segment, segmentIndex) =>
                    segment.kind === "tools" ? (
                      <div
                        key={`tools-${segmentIndex}`}
                        className="chat-tool-container"
                      >
                        <div className="chat-tool-heading">
                          <WrenchIcon size={12} />
                          <span>Tool Activity ({segment.actions.length})</span>
                        </div>
                        <div className="chat-tool-list">
                          {segment.actions.map((action, i) => (
                            <ToolActionRow
                              key={action.callID || `${segmentIndex}-${i}`}
                              action={action}
                              isLive={false}
                              ownsFileReview={isWriteReviewOwner(writeReviewOwners, action)}
                              fileWriteDefaultExpanded={
                                chatSettings.fileWriteDefault === "expanded"
                              }
                              fileReviewStates={writeReviewStates}
                            />
                          ))}
                        </div>
                      </div>
                    ) : segment.kind === "thought" ? (
                      <ThoughtContainer
                        key={`thought-${segmentIndex}`}
                        text={segment.text}
                        defaultExpanded={chatSettings.thinkingDefault === "expanded"}
                      />
                    ) : segment.text.trim().length > 0 ? (
                      message.isError && isSuppressedErrorText(segment.text) ? null : (
                        <div
                          key={`text-${segmentIndex}`}
                          className="message-text"
                        >
                          {message.role === "assistant" ? (
                            <MarkdownText text={segment.text} />
                          ) : (
                            segment.text
                          )}
                        </div>
                      )
                    ) : null,
                  )}
                </>
              ) : (
                <>
                  {hasTools ? (
                    <div className="chat-tool-container">
                      <div className="chat-tool-heading">
                        <WrenchIcon size={12} />
                        <span>Tool Activity ({actions.length})</span>
                      </div>
                      <div className="chat-tool-list">
                        {actions.map((action, i) => (
                          <ToolActionRow
                            key={action.callID || i}
                            action={action}
                            isLive={false}
                            ownsFileReview={isWriteReviewOwner(writeReviewOwners, action)}
                            fileWriteDefaultExpanded={
                              chatSettings.fileWriteDefault === "expanded"
                            }
                            fileReviewStates={writeReviewStates}
                          />
                        ))}
                      </div>
                    </div>
                  ) : null}

                  {hasText && (!message.isError || !isSuppressedErrorText(message.text)) ? (
                    <div className="message-text">
                      {message.role === "assistant" ? (
                        <MarkdownText text={message.text} />
                      ) : (
                        message.text
                      )}
                    </div>
                  ) : null}
                </>
              )}

              {/* Turn error callout */}
              {message.isError ? (
                <div
                  className="chat-turn-error-card"
                  role="alert"
                  style={{
                    marginTop: "8px",
                    padding: "10px 14px",
                    background: "rgba(239, 68, 68, 0.12)",
                    border: "1px solid rgba(239, 68, 68, 0.35)",
                    borderRadius: "8px",
                    color: "var(--color-danger, #ef4444)",
                    fontSize: "0.875rem",
                    display: "flex",
                    alignItems: "flex-start",
                    gap: "10px",
                  }}
                >
                  <AlertTriangleIcon size={18} style={{ flexShrink: 0, marginTop: "2px" }} />
                  <div style={{ wordBreak: "break-word" }}>
                    Turn failed: {message.errorText || message.text.replace(/^Error:\s*/, "")}
                  </div>
                </div>
              ) : null}

              {(() => {
                const copyContent = getMessageCopyContent(message);
                const hasFooter =
                  (message.role === "assistant" && message.completedAt != null) ||
                  copyContent.length > 0;
                if (!hasFooter) return null;
                return (
                  <div className="message-bubble-footer">
                    {message.role === "assistant" && message.completedAt != null ? (
                      <div
                        className="message-completed-footer muted text-xs"
                        title={new Date(message.completedAt).toLocaleString()}
                      >
                        {formatCompletionRelative(message.completedAt)}
                      </div>
                    ) : (
                      <div />
                    )}
                    {copyContent.length > 0 ? (
                      <button
                        type="button"
                        className={`message-copy-btn${copiedMessageId === message.id ? " copied" : ""}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleCopyMessage(message.id, copyContent);
                        }}
                        aria-label={
                          copiedMessageId === message.id
                            ? "Copied message to clipboard"
                            : "Copy message"
                        }
                        title={
                          copiedMessageId === message.id
                            ? "Copied!"
                            : "Copy message"
                        }
                      >
                        {copiedMessageId === message.id ? (
                          <>
                            <CheckIcon size={12} className="copy-icon-success" />
                            <span className="copy-status-text">Copied</span>
                          </>
                        ) : (
                          <CopyIcon size={12} />
                        )}
                      </button>
                    ) : null}
                  </div>
                );
              })()}
            </div>
          );
        })}

        {/* Active in-flight assistant response with live tools and streaming text */}
        {pending && inFlightTurn && (inFlightTurn.toolActions.length > 0 || inFlightTurn.text.trim().length > 0 || (inFlightTurn.segments && inFlightTurn.segments.some((s) => s.kind === "thought" && s.text.trim().length > 0))) ? (
          <div className="message assistant streaming-bubble">
            {inFlightTurn.segments && inFlightTurn.segments.length > 0 ? (
              <>
                {inFlightTurn.segments.map((segment, segmentIndex) =>
                  segment.kind === "tools" ? (
                    <div
                      key={`live-tools-${segmentIndex}`}
                      className="chat-tool-container"
                    >
                      <div className="chat-tool-heading">
                        <WrenchIcon size={12} />
                        <span>Tool Activity ({segment.actions.length})</span>
                      </div>
                      <div className="chat-tool-list">
                        {segment.actions.map((action, i) => (
                          <ToolActionRow
                            key={action.callID || `live-${segmentIndex}-${i}`}
                            action={action}
                            isLive
                            progress={
                              toolProgressByCallID.get(action.callID) ?? null
                            }
                            cancelling={cancellingToolCallIDs.has(
                              action.callID,
                            )}
                            onCancelTool={handleCancelTool}
                            ownsFileReview={isWriteReviewOwner(
                              writeReviewOwners,
                              action,
                            )}
                            fileWriteDefaultExpanded={
                              chatSettings.fileWriteDefault === "expanded"
                            }
                            fileReviewStates={writeReviewStates}
                          />
                        ))}
                      </div>
                    </div>
                  ) : segment.kind === "thought" ? (
                    <ThoughtContainer
                      key={`live-thought-${segmentIndex}`}
                      text={segment.text}
                      defaultExpanded={chatSettings.thinkingDefault === "expanded"}
                      isLive
                    />
                  ) : (() => {
                    const rawText =
                      segment.kind === "text" ? segment.text : "";
                    const liveDisplay =
                      segmentIndex === liveLastTextIndex &&
                      liveHeld.length > 0 &&
                      rawText.endsWith(liveHeld)
                        ? rawText.slice(0, rawText.length - liveHeld.length)
                        : rawText;
                    if (liveDisplay.trim().length === 0) return null;
                    return (
                      <div
                        key={`live-text-${segmentIndex}`}
                        className="message-text"
                      >
                        <MarkdownText text={liveDisplay} />
                      </div>
                    );
                  })(),
                )}
              </>
            ) : (
              <>
                {inFlightTurn.toolActions.length > 0 ? (
                  <div className="chat-tool-container">
                    <div className="chat-tool-heading">
                      <WrenchIcon size={12} />
                      <span>Tool Activity ({inFlightTurn.toolActions.length})</span>
                    </div>
                    <div className="chat-tool-list">
                      {inFlightTurn.toolActions.map((action, i) => (
                        <ToolActionRow
                          key={action.callID || i}
                          action={action}
                          isLive
                          progress={
                            toolProgressByCallID.get(action.callID) ?? null
                          }
                          cancelling={cancellingToolCallIDs.has(action.callID)}
                          onCancelTool={handleCancelTool}
                          ownsFileReview={isWriteReviewOwner(
                            writeReviewOwners,
                            action,
                          )}
                          fileWriteDefaultExpanded={
                            chatSettings.fileWriteDefault === "expanded"
                          }
                          fileReviewStates={writeReviewStates}
                        />
                      ))}
                    </div>
                  </div>
                ) : null}

                {inFlightTurn.text.trim().length > 0 ? (
                  <div className="message-text">
                    <MarkdownText text={inFlightTurn.text} />
                  </div>
                ) : null}
              </>
            )}
            {inFlightTurn.text.trim().length > 0 ? (
              <div className="message-bubble-footer">
                <div />
                <button
                  type="button"
                  className={`message-copy-btn${copiedMessageId === "in-flight" ? " copied" : ""}`}
                  onClick={(e) => {
                    e.stopPropagation();
                    void handleCopyMessage("in-flight", inFlightTurn.text.trim());
                  }}
                  aria-label={
                    copiedMessageId === "in-flight"
                      ? "Copied message to clipboard"
                      : "Copy message"
                  }
                  title={
                    copiedMessageId === "in-flight"
                      ? "Copied!"
                      : "Copy message"
                  }
                >
                  {copiedMessageId === "in-flight" ? (
                    <>
                      <CheckIcon size={12} className="copy-icon-success" />
                      <span className="copy-status-text">Copied</span>
                    </>
                  ) : (
                    <CopyIcon size={12} />
                  )}
                </button>
              </div>
            ) : null}
          </div>
        ) : null}

        {/* Persistent liveness footer */}
        {pending ? (
          <div className="message assistant pending-bubble">
            <div className="typing-indicator" aria-label="Rune Weaver is thinking">
              <span className="typing-dot" />
              <span className="typing-dot" />
              <span className="typing-dot" />
            </div>
            <span className="typing-text">
              {hasRunningTools
                ? "Executing tools…"
                : hasPartialText
                  ? "Thinking…"
                  : "Still thinking — large prompts take a while…"}
            </span>
          </div>
        ) : null}

        <div ref={messageListEndRef} />
      </div>

      {error ? <p className="error chat-error">{error}</p> : null}

      {/* Trimmed-flight notice */}
      {trimmedLiveFlights.length > 0 ? (
        <p
          className="muted flight-eviction-notice"
          role="status"
          aria-label="Background turn trimmed"
          data-testid="flight-eviction-notice"
        >
          A background turn view was trimmed to stay within memory bounds; it
          rebuilds from the next live update.
          <button
            type="button"
            className="ghost flight-eviction-dismiss"
            aria-label="Dismiss trim notice"
            onClick={onDismissTrimmedFlights}
          >
            Dismiss
          </button>
        </p>
      ) : null}

      {/* Degraded-tool banner */}
      {turnWarnings.length > 0 ? (
        <div
          data-testid="turn-warnings-banner"
          role="status"
          aria-label="Degraded tool warnings"
          className="turn-warnings-banner"
        >
          <div className="turn-warnings-header">
            <strong>
              {turnWarnings.length === 1
                ? "A tool was skipped for this turn"
                : `${turnWarnings.length} tools were skipped for this turn`}
            </strong>
            <button
              type="button"
              className="ghost turn-warnings-dismiss"
              aria-label="Dismiss warnings"
              onClick={onDismissWarnings}
            >
              Dismiss
            </button>
          </div>
          <ul className="turn-warnings-list">
            {turnWarnings.map((warning) => (
              <li key={warning}>{warning}</li>
            ))}
          </ul>
        </div>
      ) : null}

      {/* Inline session approvals */}
      {sessionApprovals.length > 0 ? (
        <div
          className="inline-approval-list"
          aria-label="Session approvals awaiting decision"
        >
          {sessionApprovals.map((request) =>
            request.toolName === "question.ask" ? (
              <InlineQuestionCard
                key={request.id}
                request={request}
                deciding={decidingApprovalIDs.has(request.id)}
                onRespond={(id, answer, cancelled) =>
                  void onRespondQuestion(id, answer, cancelled)
                }
              />
            ) : (
              <InlineApprovalBanner
                key={request.id}
                request={request}
                deciding={decidingApprovalIDs.has(request.id)}
                onDecide={(id, approved, duration) =>
                  void onDecideApproval(id, approved, duration)
                }
              />
            ),
          )}
        </div>
      ) : null}
    </>
  );
}
