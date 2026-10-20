// Rune Weaver Core — Task-steered prompt formatting for EmbeddingGemma 2.

import Foundation

/// EmbeddingGemma 2 task prompt formatting (following Google DeepMind and DigUp).
/// Task prompts steer the model's unified 768-dimensional latent space.
public enum EmbeddingGemmaPrompts {
    /// Formats a query string for general semantic retrieval.
    public static func query(_ text: String) -> String {
        "task: search result | query: \(text)"
    }

    /// Formats a query string specifically for code retrieval.
    public static func codeQuery(_ text: String) -> String {
        "task: code retrieval | query: \(text)"
    }

    /// Formats a document body or chunk with its title/filename.
    public static func document(title: String?, text: String) -> String {
        let effectiveTitle = if let title, !title.isEmpty {
            title
        } else {
            "none"
        }
        return "title: \(effectiveTitle) | text: \(text)"
    }
}
