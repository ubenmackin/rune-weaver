// Rune Weaver Core — Text tokenization and BM25-style keyword matching.

import Foundation

/// Shared keyword helpers for memory search.
enum Tokenization {
    /// Lowercased alphanumeric tokens for keyword scoring.
    /// - Parameter text: Text to tokenize.
    /// - Returns: Token set.
    static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty })
    }

    /// Keyword relevance for token overlap plus substring fallback.
    static func keywordScore(
        queryTokens: Set<String>,
        contentTokens: Set<String>,
        content: String,
        query: String
    ) -> Int? {
        let overlap = queryTokens.intersection(contentTokens).count
        let substring = content.range(of: query, options: .caseInsensitive) != nil
        guard overlap > 0 || substring else { return nil }
        return overlap * 2 + (substring ? 1 : 0)
    }
}
