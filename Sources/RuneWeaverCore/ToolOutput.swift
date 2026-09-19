// Rune Weaver Core — Tool execution output and failure constructors.

import Foundation

/// Result returned from a tool execution.
public struct ToolOutput: Sendable, Codable, Equatable {
    /// Human- or machine-readable result content.
    public let content: String
    /// Whether the execution failed.
    public let isError: Bool
    /// Correlation identifier matching the originating ``ToolInput/callID``.
    public let callID: String?
    /// Classification of the failure if failed, or nil when the tool left it for the bus to infer.
    public let errorKind: ToolErrorKind?

    /// Creates a tool output.
    public init(content: String, isError: Bool = false, callID: String? = nil, errorKind: ToolErrorKind? = nil) {
        self.content = content
        self.isError = isError
        self.callID = callID
        // An unspecified failure category stays nil so ``ToolResult`` can classify it by
        // content prefix at the bus boundary. Forcing `.executionError` here would make
        // argument errors indistinguishable from runtime failures. Successes carry none.
        self.errorKind = isError ? errorKind : nil
    }

    /// Convenience success output.
    public static func success(_ content: String, callID: String? = nil) -> ToolOutput {
        ToolOutput(content: content, isError: false, callID: callID, errorKind: nil)
    }

    /// Convenience failure output.
    public static func failure(_ content: String, callID: String? = nil, errorKind: ToolErrorKind? = nil) -> ToolOutput {
        ToolOutput(content: content, isError: true, callID: callID, errorKind: errorKind)
    }
}
