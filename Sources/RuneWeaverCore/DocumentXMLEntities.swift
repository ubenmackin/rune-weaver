// Rune Weaver Core — Spreadsheet cells and entity decoding for extraction.
//
// Holds the worksheet and entity layer for `DocumentTextExtractor`: cell value
// resolution over the shared string table, cell and regex match helpers,
// named plus numeric XML entity decoding, and the segment plus word-wrap
// helpers behind overlapping chunking. Text normalization lives beside it
// while ZIP reading stays in its own file.

import Foundation

extension DocumentTextExtractor {
    /// Resolves one worksheet cell to its display value.
    /// - Parameters:
    ///   - cell: Cell attributes plus inner XML.
    ///   - sharedStrings: Shared string table in index order.
    /// - Returns: Cell value, empty when the cell carries none.
    static func worksheetCellValue(_ cell: (attributes: String, inner: String), sharedStrings: [String]) -> String {
        if let type = attributeValue("t", in: cell.attributes) {
            switch type {
            case "s":
                guard let raw = firstMatch("<v>(.*?)</v>", in: cell.inner),
                      let index = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      sharedStrings.indices.contains(index)
                else {
                    return ""
                }
                return sharedStrings[index]
            case "inlineStr":
                let inner = firstMatch("<is>(.*?)</is>", in: cell.inner) ?? cell.inner
                return decodeXMLEntities(inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            case "str", "e":
                return firstMatch("<v>(.*?)</v>", in: cell.inner).map { decodeXMLEntities($0) } ?? ""
            default:
                break
            }
        }
        guard let raw = firstMatch("<v>(.*?)</v>", in: cell.inner) else { return "" }
        return decodeXMLEntities(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Splits worksheet rows into cell attribute and inner-XML pairs.
    /// - Parameter rowXML: One `<row>` element.
    /// - Returns: Cells in document order.
    static func cellMatches(in rowXML: String) -> [(attributes: String, inner: String)] {
        guard let regex = try? NSRegularExpression(pattern: "<c([^>]*?)(?:/>|>(.*?)</c>)", options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let source = rowXML as NSString
        return regex.matches(in: rowXML, options: [], range: NSRange(location: 0, length: source.length)).map { match in
            let attributesRange = match.range(at: 1)
            let attributes = attributesRange.location == NSNotFound ? "" : source.substring(with: attributesRange)
            var inner = ""
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                inner = source.substring(with: match.range(at: 2))
            }
            return (attributes, inner)
        }
    }

    /// Reads one quoted attribute value from an XML start tag body.
    /// - Parameters:
    ///   - name: Attribute name.
    ///   - attributes: Attribute body without the tag name.
    /// - Returns: Attribute value, or nil when absent.
    static func attributeValue(_ name: String, in attributes: String) -> String? {
        firstMatch("\\b\(name)=\"([^\"]*)\"", in: attributes)
    }

    /// Returns the first capture group of a regex match.
    /// - Parameters:
    ///   - pattern: Regular expression with at least one capture group.
    ///   - text: Text to search.
    ///   - group: Capture group index (defaults to the first group).
    /// - Returns: Captured substring, or nil when the pattern does not match.
    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: source.length)),
              match.numberOfRanges > group,
              match.range(at: group).location != NSNotFound
        else {
            return nil
        }
        return source.substring(with: match.range(at: group))
    }

    /// Returns every capture group match of a regex.
    /// - Parameters:
    ///   - pattern: Regular expression with at least one capture group.
    ///   - text: Text to search.
    ///   - group: Capture group index (defaults to the first group).
    /// - Returns: Captured substrings in match order.
    static func allMatches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let source = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard match.numberOfRanges > group, match.range(at: group).location != NSNotFound else {
                return nil
            }
            return source.substring(with: match.range(at: group))
        }
    }

    /// Decodes the XML entities that appear in document and HTML text.
    ///
    /// `&amp;` decodes last so a double-escaped sequence such as `&amp;lt;` ends
    /// as the literal `&lt;` instead of collapsing all the way to `<`.
    /// - Parameter text: Text containing entities.
    /// - Returns: Text with named and numeric entities decoded.
    static func decodeXMLEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in namedXMLEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return decodeNumericEntities(result)
    }

    /// Named entities decoded before numeric ones; `&amp;` is intentionally last.
    static let namedXMLEntities: [(String, String)] = [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&amp;", "&")
    ]

    /// Decodes decimal and hexadecimal numeric character references.
    /// - Parameter text: Text that may contain `&#NNN;` or `&#xHH;` references.
    /// - Returns: Text with valid references decoded and invalid ones left intact.
    static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#"), let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else {
            return text
        }
        let source = text as NSString
        var result = ""
        var lastLocation = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: lastLocation, length: match.range.location - lastLocation))
            let body = source.substring(with: match.range(at: 1))
            let scalarValue: UInt32? = if body.hasPrefix("x") || body.hasPrefix("X") {
                UInt32(body.dropFirst(), radix: 16)
            } else {
                UInt32(body)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                result.append(Character(scalar))
            } else {
                result += source.substring(with: match.range)
            }
            lastLocation = match.range.location + match.range.length
        }
        result += source.substring(from: lastLocation)
        return result
    }

    /// Splits normalized text into segments no longer than the character budget.
    /// - Parameters:
    ///   - text: Normalized extracted text.
    ///   - characterBudget: Maximum characters per segment.
    /// - Returns: Non-empty segments in reading order.
    static func chunkSegments(from text: String, characterBudget: Int) -> [String] {
        var segments: [String] = []
        for line in NormalizedText.splitLines(text) where !line.isEmpty {
            if line.count <= characterBudget {
                segments.append(line)
            } else {
                segments.append(contentsOf: splitLongLine(line, characterBudget: characterBudget))
            }
        }
        return segments
    }

    /// Word-wraps an over-long line, hard-splitting a single oversized word.
    /// - Parameters:
    ///   - line: Line longer than the character budget.
    ///   - characterBudget: Maximum characters per piece.
    /// - Returns: Wrapped pieces in order.
    static func splitLongLine(_ line: String, characterBudget: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            let wordString = String(word)
            if current.isEmpty {
                if wordString.count <= characterBudget {
                    current = wordString
                } else {
                    pieces.append(contentsOf: hardSplit(wordString, characterBudget: characterBudget))
                }
            } else if current.count + 1 + wordString.count <= characterBudget {
                current += " " + wordString
            } else {
                pieces.append(current)
                if wordString.count <= characterBudget {
                    current = wordString
                } else {
                    pieces.append(contentsOf: hardSplit(wordString, characterBudget: characterBudget))
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    /// Hard-splits a word that exceeds the character budget.
    /// - Parameters:
    ///   - word: Word longer than the budget.
    ///   - characterBudget: Maximum characters per piece.
    /// - Returns: Fixed-width pieces in order.
    static func hardSplit(_ word: String, characterBudget: Int) -> [String] {
        var pieces: [String] = []
        var start = word.startIndex
        while start < word.endIndex {
            let end = word.index(start, offsetBy: characterBudget, limitedBy: word.endIndex) ?? word.endIndex
            pieces.append(String(word[start ..< end]))
            start = end
        }
        return pieces
    }

    /// Estimates tokens with the shared ~4 characters-per-token rule.
    /// - Parameter text: Text to estimate.
    /// - Returns: Estimated token count.
    static func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.count) / charactersPerToken))
    }
}
