// Rune Weaver Core — Conversation turns, message roles, and context helpers.

import Foundation

/// A single turn in a conversation history.
public struct Message: Sendable, Codable, Equatable, Identifiable {
    /// Prefix marking the rolling summary of truncated turns.
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
    /// Whether a `tool`-role message represents a failure.
    public let isError: Bool?
    /// Creation timestamp.
    public let createdAt: Date

    /// Creates a new message.
    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCallID: String? = nil,
        isError: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.isError = isError
        self.createdAt = createdAt
    }
}

public extension [Message] {
    /// Returns the history with the system prompt first, without duplication.
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
