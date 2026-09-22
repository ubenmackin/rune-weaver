// Rune Weaver Core — Shared file-glob matching for indexer excludes and file tools.
//
// Purpose: single regex-based Git/VS Code-shaped glob matcher so the files
// indexer excludes and the file tools (`files.grep` includes, `files.glob`)
// agree on what a pattern means.
// Scope: pure string predicates only; filesystem walking stays with callers.
// Architectural role: owned by `RuneWeaverCore` so both the indexer and
// `RuneWeaverTools` resolve the same patterns. Matching is case-sensitive;
// callers lowercase both sides for the case-insensitive macOS view.

import Foundation

/// Shared glob matching for file excludes, grep includes, and glob search.
///
/// Patterns follow the Git and VS Code convention: a pattern without a slash
/// matches the filename component at any depth, while a slash-bearing pattern
/// matches the root-relative path. `*` spans within one segment, `?` matches
/// one non-separator character, `**` spans separators, and `[...]` classes
/// (with `[!...]` negation) match one character.
public enum SharedGlobMatching: Sendable {
    /// Reports whether a glob tries to climb with a `..` segment.
    /// - Parameter pattern: Glob pattern.
    /// - Returns: True when any `/`-separated segment is `..`.
    public static func containsDotDot(_ pattern: String) -> Bool {
        pattern.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == ".." }
    }

    /// Reports whether a relative path matches a glob.
    /// - Parameters:
    ///   - pattern: Glob pattern.
    ///   - relativePath: Path to match against.
    /// - Returns: True when the whole path matches.
    public static func matches(pattern: String, relativePath: String) -> Bool {
        let source = regexSource(fromGlob: pattern)
        guard let expression = try? NSRegularExpression(pattern: source) else {
            return false
        }
        let range = NSRange(relativePath.startIndex ..< relativePath.endIndex, in: relativePath)
        return expression.firstMatch(in: relativePath, range: range) != nil
    }

    /// Reports whether a path matches a glob pattern, following the Git and
    /// VS Code convention: patterns without a slash match against the filename
    /// component at any depth; slash-bearing patterns match against the root-relative path.
    /// - Parameters:
    ///   - pattern: Glob pattern.
    ///   - relativePath: Path relative to the walk root.
    ///   - filename: Final path component.
    /// - Returns: True when the filename or the relative path matches.
    public static func matchesPath(pattern: String, relativePath: String, filename: String) -> Bool {
        if !pattern.contains("/") {
            if matches(pattern: pattern, relativePath: filename) {
                return true
            }
        }
        return matches(pattern: pattern, relativePath: relativePath)
    }

    /// Converts a glob to an anchored regular-expression source.
    /// - Parameter pattern: Glob pattern.
    /// - Returns: Anchored regex source matching the whole input.
    public static func regexSource(fromGlob pattern: String) -> String {
        var source = "^"
        let chars = Array(pattern)
        var index = chars.startIndex
        while index < chars.endIndex {
            let char = chars[index]
            if char == "*" {
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == "*" {
                    let afterStars = chars.index(after: next)
                    if afterStars < chars.endIndex, chars[afterStars] == "/" {
                        source += "(.*/)?"
                        index = chars.index(after: afterStars)
                    } else {
                        source += ".*"
                        index = afterStars
                    }
                } else {
                    source += "[^/]*"
                    index = next
                }
            } else if char == "?" {
                source += "[^/]"
                index = chars.index(after: index)
            } else if char == "[" {
                // Copy character classes verbatim, translating glob
                // negation `[!...]` to regex `[^...]`; an unterminated
                // class falls back to a literal bracket.
                var closing: Int?
                var cursor = chars.index(after: index)
                var first = true
                while cursor < chars.endIndex {
                    if chars[cursor] == "]", !first {
                        closing = cursor
                        break
                    }
                    // A leading `]` or `!` is literal content, not the end.
                    first = false
                    cursor = chars.index(after: cursor)
                }
                if let closing {
                    var content = String(chars[chars.index(after: index) ..< closing])
                    if content.hasPrefix("!") {
                        content = "^" + String(content.dropFirst())
                    }
                    // Escape backslashes inside the class so the regex
                    // engine sees the intended set.
                    content = content.replacingOccurrences(of: "\\", with: "\\\\")
                    source += "[" + content + "]"
                    index = chars.index(after: closing)
                } else {
                    source += "\\["
                    index = chars.index(after: index)
                }
            } else if char == "\\" || char == "." || char == "+" || char == "(" || char == ")"
                || char == "|" || char == "^" || char == "$" || char == "{" || char == "}"
            {
                source += "\\\(char)"
                index = chars.index(after: index)
            } else {
                source.append(char)
                index = chars.index(after: index)
            }
        }
        source += "$"
        return source
    }
}
