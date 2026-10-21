// Rune Weaver Dashboard — Interactive chat interface with session history sidebar,
// animated typing indicator, distinct tool activity display, and attached status bar.

import SessionSidebar from "./SessionSidebar";
import GoalDrawer from "./GoalDrawer";
import ChatSettingsModal from "./ChatSettingsModal";
import type { ChatViewProps } from "./chat/chatTypes";
import ChatHeader from "./chat/ChatHeader";
import ChatMessageList from "./chat/ChatMessageList";
import ChatInputBar from "./chat/ChatInputBar";
import ChatStatusBar from "./chat/ChatStatusBar";
import { useChatController } from "./chat/useChatController";

// Public backward-compatible exports
export {
  copyToClipboard,
  getMessageCopyContent,
  formatCompletionRelative,
  approvalsForSession,
  messageListHasActiveSelection,
  autoTitleFromPrompt,
} from "./chat/chatHelpers";
export {
  toolActionMap,
  toolActionCompletedAtMap,
  reconstructMessages,
} from "./chat/chatTimeline";

export default function ChatView(props: ChatViewProps) {
  const { onSelectTab } = props;
  const {
    sessionID,
    sessionRefreshKey,
    sessionGoal,
    sessionPendingCount,
    sessionApprovals,
    sidebarOpen,
    setSidebarOpen,
    isMobile,
    historyButtonRef,
    goalChipRef,
    goalDrawerOpen,
    setGoalDrawerOpen,
    handleCloseSidebar,
    handleToggleSidebar,
    handleSelectSession,
    handleNewSession,
    personaDisplayName,
    chatSettings,
    chatSettingsOpen,
    setChatSettingsOpen,
    updateChatSettings,
    resetChatSettings,
    reconnecting,
    reconnectDismissed,
    setReconnectDismissed,
    handleRetryConnection,
    messages,
    pending,
    inFlightTurn,
    messageListRef,
    messageListEndRef,
    handleMessageListScroll,
    error,
    trimmedLiveFlights,
    setTrimmedLiveFlights,
    turnWarnings,
    setTurnWarnings,
    toolProgressByCallID,
    cancellingToolCallIDs,
    copiedMessageId,
    handleCopyMessage,
    handleCancelTool,
    writeReviewOwners,
    writeReviewStates,
    decidingApprovalIDs,
    handleDecideApproval,
    handleRespondQuestion,
    textareaRef,
    input,
    handleInputChange,
    handleKeyDown,
    handleCancel,
    handleSteer,
    send,
    footerExpanded,
    setFooterExpanded,
    pct,
    sessionShort,
    safeTurnTokens,
    safeContextTokens,
    safeContextLimit,
    safeSessionTokens,
    activeModel,
    pendingApprovals,
    backgroundRunningIDs,
    isActive,
  } = useChatController(props);

  return (
    <div className="chat-layout">
      {/* Session History Sidebar */}
      <SessionSidebar
        currentSessionID={sessionID}
        onSelectSession={handleSelectSession}
        onNewSession={handleNewSession}
        isOpen={sidebarOpen}
        onToggleOpen={handleToggleSidebar}
        refreshTrigger={sessionRefreshKey}
        pendingApprovals={pendingApprovals}
        runningSessionIDs={backgroundRunningIDs}
        isMobile={isMobile}
        isActive={isActive ?? true}
        onClose={handleCloseSidebar}
        historyButtonRef={historyButtonRef}
      />

      {/* Main Chat Area */}
      <section className="chat-main-panel" aria-label="Chat">
        <ChatHeader
          sidebarOpen={sidebarOpen}
          historyButtonRef={historyButtonRef}
          onOpenSidebar={() => setSidebarOpen(true)}
          personaDisplayName={personaDisplayName}
          sessionID={sessionID}
          sessionGoal={sessionGoal}
          goalChipRef={goalChipRef}
          onOpenGoalDrawer={() => setGoalDrawerOpen(true)}
          sessionPendingCount={sessionPendingCount}
          onOpenSettings={() => setChatSettingsOpen(true)}
          onNewSession={handleNewSession}
        />

        {/* Reconnect notice */}
        {reconnecting && !reconnectDismissed ? (
          <div
            className="connection-toast"
            data-testid="chat-reconnecting"
            role="alert"
            aria-live="assertive"
          >
            <span className="connection-toast-message">
              Live updates paused. Reconnecting to server… Chat still sends; streaming will resume.
            </span>
            <div className="connection-toast-actions">
              <button
                type="button"
                data-testid="chat-reconnect-retry"
                onClick={handleRetryConnection}
              >
                Retry now
              </button>
              <button
                type="button"
                data-testid="chat-reconnect-dismiss"
                onClick={() => setReconnectDismissed(true)}
              >
                Dismiss
              </button>
            </div>
          </div>
        ) : null}

        {/* Message Stream */}
        <ChatMessageList
          messages={messages}
          pending={pending}
          inFlightTurn={inFlightTurn}
          chatSettings={chatSettings}
          writeReviewOwners={writeReviewOwners}
          writeReviewStates={writeReviewStates}
          toolProgressByCallID={toolProgressByCallID}
          cancellingToolCallIDs={cancellingToolCallIDs}
          copiedMessageId={copiedMessageId}
          handleCopyMessage={handleCopyMessage}
          handleCancelTool={handleCancelTool}
          messageListRef={messageListRef}
          messageListEndRef={messageListEndRef}
          onScroll={handleMessageListScroll}
          error={error}
          trimmedLiveFlights={trimmedLiveFlights}
          onDismissTrimmedFlights={() => setTrimmedLiveFlights([])}
          turnWarnings={turnWarnings}
          onDismissWarnings={() => setTurnWarnings([])}
          sessionApprovals={sessionApprovals}
          decidingApprovalIDs={decidingApprovalIDs}
          onDecideApproval={(id, approved, duration) =>
            void handleDecideApproval(id, approved, duration)
          }
          onRespondQuestion={(id, answer, cancelled) =>
            void handleRespondQuestion(id, answer, cancelled)
          }
        />

        {/* Input & Status Bar Container */}
        <div className="chat-footer-box">
          <ChatInputBar
            textareaRef={textareaRef}
            chatSettings={chatSettings}
            pending={pending}
            input={input}
            onInputChange={handleInputChange}
            onKeyDown={handleKeyDown}
            onCancel={() => void handleCancel()}
            onSteer={handleSteer}
            onSend={() => void send()}
            sessionID={sessionID}
          />

          <ChatStatusBar
            footerExpanded={footerExpanded}
            setFooterExpanded={setFooterExpanded}
            pct={pct}
            sessionShort={sessionShort}
            safeTurnTokens={safeTurnTokens}
            safeContextTokens={safeContextTokens}
            safeContextLimit={safeContextLimit}
            safeSessionTokens={safeSessionTokens}
            activeModel={activeModel}
          />
        </div>
      </section>

      <ChatSettingsModal
        isOpen={chatSettingsOpen}
        onClose={() => setChatSettingsOpen(false)}
        settings={chatSettings}
        onUpdateSettings={updateChatSettings}
        onResetSettings={resetChatSettings}
      />

      {/* Goal drawer overlays the chat column for the linked goal */}
      {goalDrawerOpen && sessionGoal ? (
        <GoalDrawer
          goalId={sessionGoal.id}
          initialGoal={sessionGoal}
          onClose={() => setGoalDrawerOpen(false)}
          onSelectTab={onSelectTab}
          returnFocusRef={goalChipRef}
        />
      ) : null}
    </div>
  );
}
