// Rune Weaver Core — Tool capability protocol plus single-sourced prompt display rules.

import Foundation

/// A capability plugin the agent can invoke.
public protocol Tool: Sendable {
    /// Stable machine-readable identifier (e.g. `"email.search"`).
    var name: String { get }
    /// Human- and LLM-readable summary of when to use this tool.
    var description: String { get }
    /// JSON Schema describing the expected input arguments.
    var inputSchema: JSONSchema { get }
    /// Trust level enforced by the permission gate.
    var permissionLevel: PermissionLevel { get }
    /// Provenance of this tool's output for model-context labeling. Declaration-driven: each tool
    /// states its own provenance so the loop never sniffs names.
    var contentTrustLevel: ContentTrustLevel { get }

    /// Runs the tool.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}

/// Default provenance keeps local tools byte-identical without redeclaration.
extension Tool {
    /// Trusted by default; network tools override to untrusted.
    public var contentTrustLevel: ContentTrustLevel {
        .trusted
    }
}

/// A sink a tool calls to surface indeterminate progress while it executes.
public typealias ToolProgressReporter = @Sendable (ToolProgress) async -> Void

/// Indeterminate progress a long-running tool reports while it works.
public struct ToolProgress: Sendable, Codable, Equatable {
    /// Correlation identifier of the call this progress belongs to.
    public let callID: String
    /// Name of the tool reporting progress.
    public let toolName: String
    /// Human-readable status line that is safe to display verbatim.
    public let message: String
    /// Advisory broad-scope warning for `message`, when the emitter has one.
    public let warning: String?
    /// Items examined so far.
    public let scanned: Int
    /// Items matched so far.
    public let matched: Int
    /// Milliseconds elapsed since the call began.
    public let elapsedMs: Int
    /// Relative display path of the item currently being processed, when one
    /// applies. Always relative so progress can never disclose an absolute
    /// filesystem location; an absolute or traversing candidate degrades to nil.
    public let current: String?

    /// Longest relative path retained for display, bounding frame size.
    static let maxCurrentLength = 240

    /// Time-based floor an emitter keeps between progress reports (2 Hz).
    public static let minimumReportIntervalNanoseconds: UInt64 = 500_000_000

    /// Creates a progress report.
    public init(
        callID: String = "",
        toolName: String = "",
        message: String,
        warning: String? = nil,
        scanned: Int = 0,
        matched: Int = 0,
        elapsedMs: Int = 0,
        current: String? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.message = message
        self.warning = Self.normalizedWarning(warning)
        // Negative counters are an emitter bug; clamp here rather than encode a
        // payload the wire decoder would reject wholesale, which would cost the
        // viewer the whole progress line over one malformed field.
        self.scanned = max(0, scanned)
        self.matched = max(0, matched)
        self.elapsedMs = max(0, elapsedMs)
        self.current = Self.relativeCurrent(current)
    }

    /// Returns a copy re-attributed to the given call, preserving the content.
    /// callID: Authoritative call identifier.
    func attributed(callID: String, toolName: String) -> ToolProgress {
        ToolProgress(
            callID: callID,
            toolName: toolName,
            message: message,
            warning: warning,
            scanned: scanned,
            matched: matched,
            elapsedMs: elapsedMs,
            current: current
        )
    }

    /// Normalizes a warning to nil when absent or blank so empty suffixes never render.
    /// - Parameter warning: Raw warning copy supplied by the emitter.
    static func normalizedWarning(_ warning: String?) -> String? {
        let trimmed = (warning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalizes a candidate display path, dropping anything that could reveal an absolute
    /// location or climb outside its root.
    /// - Parameter current: Raw path supplied by the emitter.
    static func relativeCurrent(_ current: String?) -> String? {
        let trimmed = (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A leading slash or tilde would disclose a filesystem root or a home
        // directory, so neither is allowed to survive.
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        // A traversal segment is as revealing as an absolute path, and resolving
        // it would require a base the reporter intentionally does not know.
        guard !trimmed.split(separator: "/").contains("..") else { return nil }
        return String(trimmed.prefix(maxCurrentLength))
    }
}
