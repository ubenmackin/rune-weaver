// Rune Weaver Core — Tool execution output and failure constructors.
//
// Represents raw results yielded by tool execution, providing standard
// constructors for success, failure, and correlation ID preservation.

import Foundation

/// Result returned from a tool execution.
public struct ToolOutput: Sendable, Codable, Equatable {
    /// Human- or machine-readable result content.
    public let content: String
    /// Whether the execution failed.
    public let isError: Bool
    /// Correlation identifier matching the originating ``ToolInput/callID``.
    public let callID: String?

    /// Creates a tool output.
    /// - Parameters:
    ///   - content: Result content.
    ///   - isError: Whether this represents a failure.
    ///   - callID: Correlation identifier.
    public init(content: String, isError: Bool = false, callID: String? = nil) {
        self.content = content
        self.isError = isError
        self.callID = callID
    }

    /// Convenience success output.
    /// - Parameters:
    ///   - content: Result content.
    ///   - callID: Correlation identifier.
    /// - Returns: A non-error output.
    public static func success(_ content: String, callID: String? = nil) -> ToolOutput {
        ToolOutput(content: content, isError: false, callID: callID)
    }

    /// Convenience failure output.
    /// - Parameters:
    ///   - content: Error description.
    ///   - callID: Correlation identifier.
    /// - Returns: An error output.
    public static func failure(_ content: String, callID: String? = nil) -> ToolOutput {
        ToolOutput(content: content, isError: true, callID: callID)
    }
}
