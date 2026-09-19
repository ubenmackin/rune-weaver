// Rune Weaver Core — Canonical derivation of SSRF-exempt LLM server origins.
//
// The API/browser SSRF guard trusts configured LLM `server_url` values so the
// agent can reach its own local model endpoint. The shared builtin tool
// registry, the menu-bar app, and the CLI/serve paths all need that exemption
// list, so it is derived here once instead of re-implemented per entry point.
// One derivation keeps every caller exempting the same origins and gives the
// trimming/de-duplication contract a single owner.

import Foundation

/// Derives the configured LLM server origins exempted from the SSRF loopback
/// deny. Trims surrounding whitespace, drops blanks, and de-duplicates while
/// preserving first-seen order so all call sites resolve one list.
public enum LLMOrigins: Sendable {
    /// Non-empty, whitespace-trimmed, de-duplicated `server_url` values from
    /// the `[llm.providers]` table.
    /// - Parameter llmConfig: `[llm]` section carrying provider endpoints, or nil.
    /// - Returns: Exempt origins in first-seen order; empty when none configured.
    public static func serverURLs(from llmConfig: LLMConfig?) -> [String] {
        guard let llmConfig else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in llmConfig.providers.values.compactMap(\.serverURL) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}
