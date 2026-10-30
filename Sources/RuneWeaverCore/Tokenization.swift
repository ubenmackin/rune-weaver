// Rune Weaver Core — Text tokenization and BM25-style keyword matching.

import Foundation

/// Shared keyword helpers for memory search.
public enum Tokenization: Sendable {
    /// Lowercased alphanumeric tokens for keyword scoring.
    /// - Parameter text: Text to tokenize.
    /// - Returns: Token set.
    public static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty })
    }

    /// Curated English stop words and conversational filler words.
    public static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "aren't",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "can't", "cannot", "could", "couldn't", "did", "didn't", "do", "does", "doesn't", "doing",
        "don't", "down", "during", "each", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't",
        "have", "haven't", "having", "he", "he'd", "he'll", "he's", "her", "here", "here's", "hers", "herself",
        "him", "himself", "his", "how", "how's", "i", "i'd", "i'll", "i'm", "i've", "im", "if", "in", "into",
        "is", "isn't", "it", "it's", "its", "itself", "just", "let's", "me", "more", "most", "mustn't", "my",
        "myself", "no", "nor", "not", "of", "off", "on", "once", "only", "or", "other", "ought", "our", "ours",
        "ourselves", "out", "over", "own", "same", "shan't", "she", "she'd", "she'll", "she's", "should",
        "shouldn't", "so", "some", "such", "than", "that", "that's", "the", "their", "theirs", "them",
        "themselves", "then", "there", "there's", "these", "they", "they'd", "they'll", "they're", "they've",
        "this", "those", "through", "to", "too", "under", "until", "up", "very", "was", "wasn't", "we", "we'd",
        "we'll", "we're", "we've", "were", "weren't", "what", "what's", "when", "when's", "where", "where's",
        "which", "while", "who", "who's", "whom", "why", "why's", "with", "won't", "would", "wouldn't", "you",
        "you'd", "you'll", "you're", "you've", "your", "yours", "yourself", "yourselves",
        // Conversational query fillers
        "trying", "figure", "tell", "help", "know", "find", "search", "looking", "please",
        "show"
    ]

    /// Extracts salient (non-stop, non-noise) tokens in query order.
    /// Falls back to raw tokens when all tokens are stop words so queries like "to be or not to be" don't become empty.
    public static func salientTokens(from text: String) -> [String] {
        let raw = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        let filtered = raw.filter { $0.count > 1 && !stopWords.contains($0) }
        if !filtered.isEmpty {
            return filtered
        }
        let multiChar = raw.filter { $0.count > 1 }
        return multiChar.isEmpty ? raw : multiChar
    }

    /// Keyword relevance for token overlap plus substring fallback.
    public static func keywordScore(
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

/// Canonical forward-looking markers, matched word-boundary outside the stop list.
public enum FutureIntent: Sendable {
    /// Words marking forward-looking intent.
    public static let tokens = ["next", "upcoming", "following"]

    /// Narrowed forward-intent check so spatial "next to" never reads as temporal.
    /// Bare markers still count, preserving dated and undated future windows.
    public static func isFutureIntent(in query: String) -> Bool {
        let words = query.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return false }
        for (index, word) in words.enumerated() {
            guard tokens.contains(word) else { continue }
            // Spatial "next to <place>" names a location, not a date window.
            if word == "next", index + 1 < words.count, words[index + 1] == "to" {
                continue
            }
            return true
        }
        return false
    }
}
