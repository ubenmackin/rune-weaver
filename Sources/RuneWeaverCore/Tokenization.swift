// Rune Weaver Core — Text tokenization and BM25-style keyword matching.
//
// Shared lexical tokenization, stopword filtering, and keyword scoring
// used across vector stores, memory engines, and fallback search indexes.

import Foundation

/// Shared keyword helpers for memory search.
///
/// Centralizes tokenization and keyword scoring so `VectorStore`,
/// `MemoryEngine`, and the JSON episode fallback rank matches
/// identically and scale changes stay in one place.
enum Tokenization {
    /// Lowercased alphanumeric tokens for keyword scoring.
    /// - Parameter text: Text to tokenize.
    /// - Returns: Token set.
    static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty })
    }

    /// Keyword relevance for token overlap plus substring fallback.
    ///
    /// Scores `overlap * 2 + (substring ? 1 : 0)` so token matches
    /// outweigh a bare substring hit while either still recalls.
    /// - Parameters:
    ///   - queryTokens: Tokenized query text.
    ///   - contentTokens: Tokenized content text.
    ///   - content: Raw content for the substring check.
    ///   - query: Raw query text for the substring check.
    /// - Returns: Raw score, or nil when there is no overlap and no
    ///   substring match.
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
