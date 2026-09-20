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

    /// Runs the tool.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
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

/// Single-sourced prompt display rules so every prompt surface compacts identically.
/// Descriptions stay one line in the prompt because multi-sentence summaries
/// multiply across the full registry and crowd out conversation context.
public enum ToolPromptDisplay: Sendable {
    /// Collapses a tool description to its first sentence for prompt display.
    /// Single-sentence summaries pass through unchanged so concise tools pay nothing.
    public static func oneLine(_ description: String) -> String {
        let collapsed = description
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return collapsed }
        // First sentence carries the use-when; trailing detail lives in schemas and policy.
        // Abbreviations that only introduce examples or titles never end a sentence,
        // so splitting inside one (like the "e.g." in a refs hint) would drop
        // guidance the model needs. Only an uppercase sentence start past a
        // terminator counts; falling back to the full text beats a truncated fragment.
        if let boundary = firstSentenceBoundary(in: collapsed) {
            let first = String(collapsed[..<boundary]).trimmingCharacters(in: .whitespaces)
            // Preserve the original terminator so questions and exclamations
            // keep their tone instead of being rewritten as statements.
            return first + String(collapsed[boundary])
        }
        return collapsed
    }

    /// Locates the end of the first sentence without stopping inside abbreviations.
    /// - Parameter text: Collapsed single-line description.
    /// - Returns: Index of the sentence-ending terminator (`.`, `?`, or `!`), or nil when no valid boundary exists.
    private static func firstSentenceBoundary(in text: String) -> String.Index? {
        // Shorthands that introduce examples or titles rather than ending a
        // sentence; matching stays case-insensitive via the lowercased prefix.
        // These never terminate even before an uppercase word ("e.g. Foo" is a
        // mid-sentence example, "Mr. Smith" is a name), so they are always skipped.
        let neverEnding = ["e.g.", "i.e.", "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st."]
        // Dotted shorthands that usually sit mid-sentence but do terminate when
        // they close one ("Supports A, B, etc. It also does C."). Treating them
        // as always mid-sentence would skip a true boundary and defeat the
        // per-round-bytes budget by falling back to the full text, so an
        // uppercase continuation promotes them to a boundary.
        let sometimesEnding = [
            "etc.", "vs.", "fig.", "inc.", "no.", "co.", "ltd.", "corp.", "dept.",
            "est.", "approx.", "al.", "ed.", "ref.", "ave.", "blvd.", "rd.", "lib.", "univ."
        ]
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex {
            // Find the earliest terminator-plus-space among the three closers so
            // questions and exclamations truncate like statements instead of
            // falling through to the full-text fallback.
            var earliest: Range<String.Index>?
            for closer in [". ", "? ", "! "] {
                if let range = text.range(of: closer, range: searchFrom ..< text.endIndex),
                   earliest.map({ range.lowerBound < $0.lowerBound }) ?? true
                {
                    earliest = range
                }
            }
            guard let range = earliest else { return nil }
            guard range.upperBound < text.endIndex else { break }
            // Sentence starts read uppercase; a lowercase continuation (like the
            // "e12" in "(e.g. e12)") proves the terminator sits mid-sentence.
            let startsSentence = text[range.upperBound].isUppercase
            guard startsSentence else {
                searchFrom = range.upperBound
                continue
            }
            if text[range.lowerBound] == "." {
                let prefix = String(text[..<range.upperBound]).lowercased()
                if neverEnding.contains(where: { isStandaloneAbbreviation(prefix: prefix, abbreviation: $0) }) {
                    searchFrom = range.upperBound
                    continue
                }
                if sometimesEnding.contains(where: { isStandaloneAbbreviation(prefix: prefix, abbreviation: $0) }) {
                    // Abbreviation period doubles as the sentence stop here.
                    return range.lowerBound
                }
            }
            return range.lowerBound
        }
        return nil
    }

    /// Determines whether a candidate shorthand stands alone rather than ending a longer word.
    /// - Parameters:
    ///   - prefix: Lowercased text through the trailing space after the candidate terminator.
    ///   - abbreviation: Lowercased dotted shorthand including its period (e.g. `"e.g."`).
    /// - Returns: True when the shorthand is delimited rather than embedded in a word.
    private static func isStandaloneAbbreviation(prefix: String, abbreviation: String) -> Bool {
        // A missing suffix means no match at all, so there is nothing to delimit.
        guard prefix.hasSuffix(abbreviation + " ") else { return false }
        // Strip the shorthand plus its trailing space to inspect what precedes it.
        // An empty remainder means the description opens with the shorthand.
        let remainder = prefix.dropLast(abbreviation.count + 1)
        guard let preceding = remainder.last else { return true }
        // A bare suffix check would mistake word endings for shorthands ("first."
        // ends with "st."), so the preceding character must delimit. Examples
        // often open with brackets, braces, quotes, or dashes ("[e.g. Foo]",
        // "{i.e. Bar}", ": e.g. Baz"), so any punctuation boundary counts
        // except a period, which would otherwise treat a word-internal dot as
        // a delimiter ("foo.e.g." is embedded, not standalone).
        return preceding.isWhitespace || (preceding.isPunctuation && preceding != ".")
    }
}
