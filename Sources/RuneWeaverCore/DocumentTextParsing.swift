// Rune Weaver Core — Text decoding and normalization for document extraction.

import Foundation

extension DocumentTextExtractor {
    /// Characters per token, matching the engine-wide ~4 characters-per-token rule.
    static let charactersPerToken: Double = ConversationManager.charactersPerToken

    /// Decodes bytes as UTF-8 with UTF-16 and Latin-1 fallbacks.
    /// - Parameter data: Raw bytes.
    /// - Returns: Decoded string, or nil when no text encoding applies.
    static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Folds line endings and trims blank or space-padded lines. Tabs are preserved because
    /// spreadsheet cells are flattened with tab separators; only runs of spaces collapse.
    static func normalizedExtractedText(_ raw: String) -> String? {
        let lines = NormalizedText.splitLines(raw)
        var output: [String] = []
        var previousBlank = false
        for line in lines {
            let collapsed = line
                .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if collapsed.isEmpty {
                if previousBlank || output.isEmpty {
                    continue
                }
                previousBlank = true
                output.append("")
            } else {
                previousBlank = false
                output.append(collapsed)
            }
        }
        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    /// Strips HTML to readable text with paragraph boundaries preserved.
    /// - Parameter html: Raw HTML.
    /// - Returns: Tag-stripped text with decoded entities.
    static func plainTextFromHTML(_ html: String) -> String {
        var text = html
        // Script, style, and comment bodies are cut first so their contents never
        // leak into the index as prose.
        let cutPatterns = ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->"]
        for pattern in cutPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Block-level closers become newlines; table cells become tab separators.
        text = text.replacingOccurrences(
            of: "</(p|div|li|tr|h[1-6]|section|article|blockquote|pre)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "</t[dh]>", with: "\t", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeXMLEntities(text)
    }

    /// Extracts paragraph text from WordprocessingML, one paragraph per line.
    /// - Parameter xml: `word/document.xml` contents.
    /// - Returns: Decoded paragraph text.
    static func textFromWordProcessingXML(_ xml: String) -> String {
        var text = xml
        // Breaks and tabs map to whitespace before the generic tag strip removes them.
        text = text.replacingOccurrences(of: "<w:tab[^>]*/>", with: "\t", options: .regularExpression)
        text = text.replacingOccurrences(of: "<w:br[^>]*/>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<w:cr[^>]*/>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeXMLEntities(text)
    }

    /// Extracts paragraph text from PresentationML, one paragraph per line.
    /// - Parameter xml: One `ppt/slides/slideN.xml` document.
    /// - Returns: Decoded paragraph text.
    static func textFromPresentationXML(_ xml: String) -> String {
        var text = xml
        text = text.replacingOccurrences(of: "</a:p>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeXMLEntities(text)
    }

    /// Reads the shared string table from an XLSX package.
    /// - Parameter archive: Parsed package.
    /// - Returns: Shared strings in table order; empty when absent.
    static func sharedStrings(from archive: ZipArchiveReader) -> [String] {
        guard let data = archive.data(forEntryNamed: "xl/sharedStrings.xml"), let xml = decodeText(data) else {
            return []
        }
        return allMatches("<si[^>]*>(.*?)</si>", in: xml).map { entry in
            let stripped = entry.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return decodeXMLEntities(stripped)
        }
    }

    /// Flattens worksheet rows into tab-separated lines with resolved shared strings.
    /// - Parameters:
    /// - xml: One `xl/worksheets/sheetN.xml` document.
    static func textFromWorksheetXML(_ xml: String, sharedStrings: [String]) -> String? {
        let rows = allMatches("<row[^>]*>(.*?)</row>", in: xml)
        guard !rows.isEmpty else { return nil }
        var lines: [String] = []
        for row in rows {
            let cells = cellMatches(in: row)
            guard !cells.isEmpty else { continue }
            let values = cells.map { cell in worksheetCellValue(cell, sharedStrings: sharedStrings) }
            let line = values.joined(separator: "\t").trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
