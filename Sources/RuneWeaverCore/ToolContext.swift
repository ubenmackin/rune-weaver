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
    /// When true, the tool must not mutate external state.
    public let dryRun: Bool

    /// Creates an execution context.
    public init(conversationID: UUID, dryRun: Bool = false) {
        self.conversationID = conversationID
        self.dryRun = dryRun
    }
}

// MARK: - Tool call placeholder

public extension ToolInput {
    /// Builds the assistant placeholder stored when a turn contains only tool calls.
    static func placeholderContent(for calls: [ToolInput]) -> String {
        guard !calls.isEmpty else { return "Calling tool…" }
        let lines = calls.map { call in
            "Calling \(call.toolName) \(inline(call.argumentsJSON, limit: 160)) [\(call.callID)]"
        }
        return lines.joined(separator: "\n")
    }

    /// Collapses whitespace and truncates text for single-line display.
    static func inline(_ text: String, limit: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }

    /// Parses one persisted assistant placeholder line into a structured input.
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
