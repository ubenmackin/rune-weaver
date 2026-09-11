import Foundation

/// A single turn in a conversation history.
///
/// Messages are the unit of context passed to an ``LLMProvider``.
/// They persist in working memory for the session and are mirrored raw
/// into episodic memory every turn for session resume.
public struct Message: Sendable, Codable, Equatable, Identifiable {
    /// Prefix marking the rolling summary of truncated turns.
    ///
    /// Single source of truth shared by `ConversationManager.history(for:)`
    /// (which prepends the summary) and `[Message].withSystemPrompt(_:)`
    /// (which preserves it) so the marker never drifts.
    public static let rollingSummaryPrefix = "Earlier in this conversation:"

    /// Conversation role for this message.
    public enum Role: String, Sendable, Codable, Equatable {
        /// Developer- or system-provided instructions.
        case system
        /// Human input (text or voice transcription).
        case user
        /// Model output, possibly including tool calls.
        case assistant
        /// Result returned from a tool execution.
        case tool
    }

    /// Unique identifier for this message.
    public let id: UUID
    /// Who produced this message.
    public let role: Role
    /// Text content of the message.
    public let content: String
    /// Tool-call identifier this message answers, if `role == .tool`.
    public let toolCallID: String?
    /// Creation timestamp.
    public let createdAt: Date

    /// Creates a new message.
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID.
    ///   - role: Who produced the message.
    ///   - content: Text content.
    ///   - toolCallID: Tool-call identifier, for tool results.
    ///   - createdAt: Creation date. Defaults to now.
    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCallID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.createdAt = createdAt
    }
}

public extension [Message] {
    /// Returns the history with the system prompt first, without duplication.
    ///
    /// This is the single dedup helper shared by the orchestrator and the
    /// CLI chat loop: an identical leading system message is kept as-is, a
    /// stale leading system message is replaced (never stacked), and an
    /// empty/nil prompt leaves the history untouched. A rolling summary
    /// injected by `ConversationManager.history(for:)` (a leading `system`
    /// message starting with `Message/rollingSummaryPrefix`) is always
    /// preserved: the prompt is prepended ahead of it instead of
    /// replacing it. When the history is `[summary, stalePrompt, ...]`
    /// the stale prompt at `[1]` is dropped so repeated calls never
    /// accumulate stacked prompts.
    /// - Parameter prompt: Developer instructions to ensure, if any.
    /// - Returns: Messages for the next LLM call.
    func withSystemPrompt(_ prompt: String?) -> [Message] {
        guard let prompt, !prompt.isEmpty else {
            return self
        }
        let promptMessage = Message(role: .system, content: prompt)
        guard let first, first.role == .system else {
            return [promptMessage] + self
        }
        if first.content == prompt {
            return self
        }
        if first.content.hasPrefix(Message.rollingSummaryPrefix) {
            var rest = self
            if rest.count > 1, rest[1].role == .system, !rest[1].content.hasPrefix(Message.rollingSummaryPrefix) {
                rest.remove(at: 1)
            }
            return [promptMessage] + rest
        }
        return [promptMessage] + Array(dropFirst())
    }
}
