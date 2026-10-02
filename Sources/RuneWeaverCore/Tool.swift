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
    /// Provenance of this tool's output for model-context labeling.
    ///
    /// Declaration-driven: each tool states its own provenance so the loop never
    /// sniffs names. The extension default keeps every existing local tool on the
    /// trusted path without touching its declaration; only network-derived tools
    /// override to untrusted.
    var contentTrustLevel: ContentTrustLevel { get }

    /// Runs the tool.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}

/// Default provenance keeps local tools byte-identical without redeclaration.
///
/// Every pre-existing tool compiles unchanged because this default covers the
/// requirement; network-derived tools opt into labeling by declaring
/// `.untrustedExternal` on their own type.
public extension Tool {
    /// Trusted by default; network tools override to untrusted.
    var contentTrustLevel: ContentTrustLevel {
        .trusted
    }
}

/// A sink a tool calls to surface indeterminate progress while it executes.
///
/// Async because the only production sink hops actors; a no-op default lets
/// non-streaming callers (CLI turns, direct REST tool calls, tests) ignore
/// progress entirely without branching at every emitter.
public typealias ToolProgressReporter = @Sendable (ToolProgress) async -> Void

/// Indeterminate progress a long-running tool reports while it works.
///
/// Progress is advisory: emitters keep a 500 ms time floor between frames and
/// may also report once a work interval elapses, so a fast walk never runs a
/// long stretch unreported and a slow one still reports on time. It carries
/// only counts plus display copy, never arguments, file contents, or
/// credentials. Identity is stamped by ``ToolBus`` from the authoritative call,
/// so a tool cannot mis-attribute progress and does not need to know its own
/// call identifier when reporting.
public struct ToolProgress: Sendable, Codable, Equatable {
    /// Correlation identifier of the call this progress belongs to.
    public let callID: String
    /// Name of the tool reporting progress.
    public let toolName: String
    /// Human-readable status line that is safe to display verbatim.
    public let message: String
    /// Advisory broad-scope warning for `message`, when the emitter has one.
    ///
    /// Carried as its own field rather than appended to ``message`` so a
    /// delimiter is never needed: a display line that merely contains the
    /// separator (a grep/glob pattern, for example) stays a plain line instead
    /// of being misread as scope-plus-warning by any consumer.
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
    ///
    /// This bounds only the clock, so it is not a universal minimum spacing: an
    /// emitter may also report when a work interval elapses, letting a fast scan
    /// emit more often than the floor while a slow one still reports once a
    /// window closes and is never silent longer than this. Single-sourced so
    /// every tool measures its floor identically instead of each picking its own
    /// cadence; the transport trusts emitters to honor it rather than buffering,
    /// because progress is advisory and a dropped frame costs nothing.
    public static let minimumReportIntervalNanoseconds: UInt64 = 500_000_000

    /// Creates a progress report.
    ///
    /// The identity defaults are placeholders: ``ToolBus`` overwrites them with
    /// the authoritative call before the report travels to any subscriber, which
    /// keeps a tool from having to thread its own call identifier through.
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
    /// - Parameters:
    ///   - callID: Authoritative call identifier.
    ///   - toolName: Authoritative tool name.
    /// - Returns: A copy carrying the authoritative identity.
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

    /// Normalizes a warning candidate so absent or whitespace-only copy degrades
    /// to nil instead of surviving as an empty suffix the dashboard would render.
    /// - Parameter warning: Raw warning copy supplied by the emitter.
    /// - Returns: A trimmed warning, or nil when there is nothing to show.
    static func normalizedWarning(_ warning: String?) -> String? {
        let trimmed = (warning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalizes a candidate display path, dropping anything that could reveal
    /// an absolute location or climb outside its root.
    /// - Parameter current: Raw path supplied by the emitter.
    /// - Returns: A trimmed relative path capped for display, or nil when absent or unsafe.
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
