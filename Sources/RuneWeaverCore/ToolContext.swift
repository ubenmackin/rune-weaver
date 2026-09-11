import Foundation

/// Minimal JSON Schema descriptor for a tool's input.
///
/// Holds the raw JSON Schema document so the LLM knows the expected
/// function-calling arguments. Decoded lazily by callers that need
/// structured access.
public struct JSONSchema: Sendable, Codable, Equatable {
    /// Raw JSON Schema document (a JSON object string).
    public let rawValue: String

    /// Creates a schema from its raw JSON document.
    /// - Parameter rawValue: JSON object string describing the input.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// An empty object schema (`{"type":"object"}`).
    public static var emptyObject: JSONSchema {
        JSONSchema(rawValue: #"{"type":"object"}"#)
    }
}

/// Input passed to a tool execution.
public struct ToolInput: Sendable, Codable, Equatable {
    /// Name of the tool being invoked.
    public let toolName: String
    /// Raw JSON arguments matching the tool's ``JSONSchema``.
    public let argumentsJSON: String
    /// Identifier correlating this call with an LLM tool call.
    public let callID: String

    /// Creates a tool input.
    /// - Parameters:
    ///   - toolName: Name of the tool being invoked.
    ///   - argumentsJSON: Raw JSON arguments.
    ///   - callID: Correlation identifier. Defaults to a new UUID string.
    public init(toolName: String, argumentsJSON: String, callID: String = UUID().uuidString) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.callID = callID
    }
}

/// Ambient context available to a tool while it executes.
///
/// Secrets are injected at execution time via this context and are
/// never part of the LLM prompt.
public struct ToolContext: Sendable, Equatable {
    /// Identifier of the owning conversation/session.
    public let conversationID: UUID
    /// When true, the tool must not mutate external state.
    public let dryRun: Bool

    /// Creates an execution context.
    /// - Parameters:
    ///   - conversationID: Owning conversation identifier.
    ///   - dryRun: Whether to avoid mutating state.
    public init(conversationID: UUID, dryRun: Bool = false) {
        self.conversationID = conversationID
        self.dryRun = dryRun
    }
}
