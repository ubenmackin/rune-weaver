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
                // Suffix alone over-matches word endings ("first." ends with "st. ",
                // "forms." ends with "ms. "), so require a word boundary: the
                // abbreviation must stand alone after start or whitespace.
                if neverEnding.contains(where: { prefix == $0 + " " || prefix.hasSuffix(" " + $0 + " ") }) {
                    searchFrom = range.upperBound
                    continue
                }
                if sometimesEnding.contains(where: { prefix == $0 + " " || prefix.hasSuffix(" " + $0 + " ") }) {
                    // Abbreviation period doubles as the sentence stop here.
                    return range.lowerBound
                }
            }
            return range.lowerBound
        }
        return nil
    }
}
