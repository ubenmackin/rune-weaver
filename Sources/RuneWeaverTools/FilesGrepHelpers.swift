// Rune Weaver Tools — RE2-safe regex policy for `files.grep`.

import Foundation

extension FilesGrepTool {
    /// Explains why a pattern cannot run on the RE2-safe subset, if any.
    static func re2UnsupportedReason(for pattern: String) -> String? {
        let chars = Array(pattern)
        var index = chars.startIndex
        var inClass = false
        while index < chars.endIndex {
            let char = chars[index]
            if char == "\\" {
                // Escaped pair: `\1`-`\9` outside a class is a backreference
                // (RE2 has no backreferences); `\k` starts a named
                // backreference. Anything else is a harmless escape.
                let next = chars.index(after: index)
                if next < chars.endIndex, !inClass {
                    let escaped = chars[next]
                    if ("1" ... "9").contains(escaped) {
                        return "backreferences (e.g. \\1) are not supported; match without referring to earlier groups."
                    }
                    if escaped == "k" {
                        return "named backreferences (\\k) are not supported; match without referring to earlier groups."
                    }
                }
                index = next < chars.endIndex ? chars.index(after: next) : chars.endIndex
                continue
            }
            if char == "[" {
                inClass = true
                index = chars.index(after: index)
                continue
            }
            if char == "]" {
                inClass = false
                index = chars.index(after: index)
                continue
            }
            if inClass {
                index = chars.index(after: index)
                continue
            }
            if char == "(" {
                // Peek the group opener for lookaround/atomic heads.
                let rest = String(chars[chars.index(after: index)...].prefix(4))
                if rest.hasPrefix("?=") || rest.hasPrefix("?!") {
                    return "lookahead (e.g. (?=...)) is not supported; match the text directly."
                }
                if rest.hasPrefix("?<=") || rest.hasPrefix("?<!") {
                    return "lookbehind (e.g. (?<=...)) is not supported; match the text directly."
                }
                if rest.hasPrefix("?>") {
                    return "atomic groups ((?>...)) are not supported; use a plain group instead."
                }
            }
            if char == "*" || char == "+" || char == "?" || char == "}" {
                // A `+` immediately after a quantifier is possessive
                // (`*+`, `++`, `?+`, `{2,3}+`); lazy `*?` stays legal.
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == "+" {
                    return "possessive quantifiers (e.g. *+) are not supported; use a greedy or lazy quantifier instead."
                }
            }
            index = chars.index(after: index)
        }
        // Linear-time subset: a quantified group containing a quantified atom lets ICU
        // backtrack exponentially over many files with no timeout on the cooperative
        // pool, so such patterns fail closed before any file is opened.
        if containsNestedQuantifier(pattern) {
            return "nested quantifiers (e.g. (a+)+) are not supported; rewrite without quantifying a quantified group."
        }
        return nil
    }

    /// Reports whether a pattern quantifies a group that already contains a quantified atom. Keeps
    /// matching linear-time under ICU backtracking by failing closed on forms like `(a+)+`, `(a*)*`,
    /// `([a]+)+`, or `(a{2,3})+`.
    static func containsNestedQuantifier(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var stack: [Bool] = []
        var index = 0
        var inClass = false
        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                index += min(2, chars.count - index)
                continue
            }
            if inClass {
                if char == "]" {
                    inClass = false
                }
                index += 1
                continue
            }
            if char == "[" {
                index += 1
                if index < chars.count, chars[index] == "^" {
                    index += 1
                }
                if index < chars.count, chars[index] == "]" {
                    index += 1
                }
                inClass = true
                continue
            }
            if char == "(" {
                stack.append(false)
                index += 1
                // Group-head `?` in `(?:`, `(?=`, and friends is syntax, not quantification.
                if index < chars.count, chars[index] == "?" {
                    index += 1
                }
                continue
            }
            if char == ")" {
                guard let hasInner = stack.popLast() else {
                    index += 1
                    continue
                }
                let isQuantified = quantifierLength(at: index + 1, in: chars) > 0
                if hasInner, isQuantified {
                    return true
                }
                if hasInner || isQuantified, !stack.isEmpty {
                    stack[stack.count - 1] = true
                }
                index += 1
                continue
            }
            let length = quantifierLength(at: index, in: chars)
            if length > 0 {
                if !stack.isEmpty {
                    stack[stack.count - 1] = true
                }
                index += length
                continue
            }
            index += 1
        }
        return false
    }

    /// Length of the quantifier starting at an index, or zero when the text is literal.
    static func quantifierLength(at position: Int, in chars: [Character]) -> Int {
        guard position < chars.count else { return 0 }
        let head = chars[position]
        if head == "*" || head == "+" || head == "?" {
            var length = 1
            if position + 1 < chars.count, chars[position + 1] == "?" || chars[position + 1] == "+" {
                length = 2
            }
            return length
        }
        if head == "{" {
            var cursor = position + 1
            guard cursor < chars.count, chars[cursor].isNumber else { return 0 }
            while cursor < chars.count, chars[cursor].isNumber {
                cursor += 1
            }
            if cursor < chars.count, chars[cursor] == "," {
                cursor += 1
                while cursor < chars.count, chars[cursor].isNumber {
                    cursor += 1
                }
            }
            guard cursor < chars.count, chars[cursor] == "}" else { return 0 }
            cursor += 1
            if cursor < chars.count, chars[cursor] == "?" || chars[cursor] == "+" {
                cursor += 1
            }
            return cursor - position
        }
        return 0
    }
}
