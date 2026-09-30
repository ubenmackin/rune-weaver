// Rune Weaver Core — Tool execution context, JSON schemas, and argument wrappers.

import Foundation

/// Minimal JSON Schema descriptor for a tool's input.
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
    public init(toolName: String, argumentsJSON: String, callID: String = UUID().uuidString) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.callID = callID
    }
}

/// Ambient context available to a tool while it executes.
public struct ToolContext: Sendable, Equatable {
    /// Identifier of the owning conversation/session.
    public let conversationID: UUID
    /// Alias for conversationID representing the active session.
    public var sessionID: UUID {
        conversationID
    }

    /// When true, the tool must not mutate external state.
    public let dryRun: Bool
    /// When true, a prior approval decision authorizes the gated branch to execute.
    public let approved: Bool
    /// Sink for indeterminate progress a tool chooses to report mid-execution.
    /// Defaults to a no-op so callers that never stream (CLI, direct tool calls,
    /// tests) construct a context with only the fields they care about.
    public let progress: ToolProgressReporter

    /// No-op reporter used when a caller does not wire a streaming sink.
    public static let noProgress: ToolProgressReporter = { _ in }

    /// Creates an execution context.
    /// - Parameters:
    ///   - conversationID: Owning session identifier.
    ///   - dryRun: Whether the tool must avoid mutating external state.
    ///   - approved: Whether a prior approval decision authorizes execution.
    ///   - progress: Optional progress sink; defaults to a no-op.
    public init(
        conversationID: UUID,
        dryRun: Bool = false,
        approved: Bool = false,
        progress: @escaping ToolProgressReporter = ToolContext.noProgress
    ) {
        self.conversationID = conversationID
        self.dryRun = dryRun
        self.approved = approved
        self.progress = progress
    }

    /// Equality compares only the value fields: the reporter is a closure with no
    /// stable identity, so folding it in would make two contexts describing the
    /// same turn compare unequal and break callers that compare for change.
    /// - Returns: True when both contexts describe the same execution.
    public static func == (lhs: ToolContext, rhs: ToolContext) -> Bool {
        lhs.conversationID == rhs.conversationID && lhs.dryRun == rhs.dryRun && lhs.approved == rhs.approved
    }
}

// MARK: - Tool call placeholder

public extension ToolInput {
    /// Generous cap for arguments embedded in a persisted placeholder line.
    /// Bounds `sessions`/`messages` persistence and every subsequent wire
    /// serialization when tool payloads grow large (e.g. email bodies), while
    /// staying far above the legacy 160-char bound so ordinary calls persist
    /// intact. Over-limit lines truncate with an ellipsis and degrade to `{}`
    /// on the wire via `sanitizedToolCallArgumentsJSON`, keeping strict
    /// backends from 400ing instead of sending a non-object fragment.
    static let placeholderArgumentsLimit = 4000

    /// Builds the assistant placeholder stored when a turn contains only tool calls.
    static func placeholderContent(for calls: [ToolInput]) -> String {
        guard !calls.isEmpty else { return "Calling tool…" }
        let lines = calls.map { call in
            "Calling \(call.toolName) \(inline(call.argumentsJSON, limit: placeholderArgumentsLimit)) [\(call.callID)]"
        }
        return lines.joined(separator: "\n")
    }

    /// Collapses whitespace and optionally truncates text for single-line display.
    static func inline(_ text: String, limit: Int? = nil) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let limit, singleLine.count > limit {
            return String(singleLine.prefix(limit)) + "…"
        }
        return singleLine
    }

    /// Parses one persisted assistant placeholder line into a structured input.
    ///
    /// Wire grammar (authoritative; the dashboard `parsePlaceholderLine` in
    /// `Web/src/api.ts` mirrors these steps exactly so history coverage and
    /// plumbing stripping agree): outer whitespace trims, the last `[` wins,
    /// the char before it must be space/tab, the bracketed identifier trims
    /// and holds no space/tab/bracket, and the head splits into tool plus
    /// optional arguments with empty arguments normalizing to `{}`. Shared
    /// vectors pinning both sides: `Calling a {"limit":1} [c1]` and
    /// `Calling a [c2]` parse, double-space/tab heads parse, slash/bracket
    /// arguments keep the last bracket (`arg [inner] [c3]` → `c3`), and
    /// inside-bracket spaces trim (`[  c4  ]` → `c4`); prose mentions,
    /// spaced identifiers, and missing pre-bracket spaces reject.
    static func parsePlaceholderLine(_ line: String) -> ToolInput? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Calling ") else { return nil }
        guard trimmed.hasSuffix("]"), let bracketStart = trimmed.lastIndex(of: "[") else { return nil }
        guard trimmed.distance(from: trimmed.startIndex, to: bracketStart) > "Calling ".count else { return nil }
        let beforeBracket = trimmed[trimmed.index(before: bracketStart)]
        guard beforeBracket == " " || beforeBracket == "\t" else { return nil }
        let afterBracket = trimmed.index(after: bracketStart)
        let endIndex = trimmed.index(before: trimmed.endIndex)
        guard afterBracket <= endIndex else { return nil }
        let callID = String(trimmed[afterBracket ..< endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty, !callID.contains(" "), !callID.contains("\t"), !callID.contains("["), !callID.contains("]") else { return nil }
        let remainderStart = trimmed.index(trimmed.startIndex, offsetBy: "Calling ".count)
        let remainderEnd = trimmed.index(before: bracketStart)
        guard remainderStart < remainderEnd else { return nil }
        let remainder = String(trimmed[remainderStart ..< remainderEnd]).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        if let firstSpace = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let name = String(remainder[..<firstSpace])
            let args = String(remainder[remainder.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return nil }
            return ToolInput(toolName: name, argumentsJSON: args.isEmpty ? "{}" : args, callID: callID)
        }
        guard !remainder.contains(" "), !remainder.contains("\t") else { return nil }
        return ToolInput(toolName: remainder, argumentsJSON: "{}", callID: callID)
    }
}
