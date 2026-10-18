// Rune Weaver Core — Text extraction from modern Apple iWork packages (.numbers, .pages, .keynote).

import Foundation

/// Extractor for modern Apple iWork packages (Pages, Numbers, Keynote).
enum DocumentIWorkArchive: Sendable {
    /// Noise prefixes in decompressed iWork archives that represent internal schema/style IDs.
    private static let noisePrefixes = [
        "Index/", "Tables/", "Metadata/", "TSP.", "TST.", "TSK.", "TSS.", "TSD.", "TSWP.", "TSCH.",
        "TN.", "KN.", "schema:", "format:",
        "tableCell", "tableName", "tableHeader", "headerRow", "footerRow"
    ]

    /// Extracts text from all relevant `.iwa` entries in an open iWork package. - maxFileBytes:
    /// Maximum bytes to consider before capping.
    static func extractText(from archive: ZipArchiveReader, maxFileBytes: Int) -> String? {
        let iwaNames = archive.entryNames.filter { name in
            name.hasSuffix(".iwa") && !name.hasPrefix("Metadata/") && !isStylesheetEntry(name)
        }

        // Sort prioritizing table data lists, document structure, and calculation data
        let sortedNames = iwaNames.sorted { lhs, rhs in
            priority(for: lhs) < priority(for: rhs)
        }

        var extractedLines: [String] = []
        var seenLines = Set<String>()
        var totalBytesRead = 0
        var totalDecompressedBytes = 0
        var totalOutputChars = 0

        for name in sortedNames {
            guard totalBytesRead < maxFileBytes, totalDecompressedBytes < maxFileBytes else { break }
            guard let entryData = archive.data(forEntryNamed: name) else { continue }
            totalBytesRead += entryData.count
            let remainingBudget = maxFileBytes - totalDecompressedBytes
            guard remainingBudget > 0 else { break }

            let strings = extractStrings(
                fromIWA: entryData,
                maxDecompressedBytes: remainingBudget,
                consumedDecompressedBytes: &totalDecompressedBytes
            )
            for str in strings {
                guard totalOutputChars < maxFileBytes else { break }
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2, !isNoise(trimmed) else { continue }
                if !seenLines.contains(trimmed) {
                    seenLines.insert(trimmed)
                    extractedLines.append(trimmed)
                    totalOutputChars += trimmed.count
                }
            }
            if totalOutputChars >= maxFileBytes {
                break
            }
        }

        guard !extractedLines.isEmpty else { return nil }
        return extractedLines.joined(separator: "\n")
    }

    /// Component-anchored stylesheet exclusion so only true stylesheet paths filter out.
    private static func isStylesheetEntry(_ name: String) -> Bool {
        name.split(separator: "/").contains(where: { $0 == "Stylesheet" || $0 == "Stylesheet.iwa" })
    }

    /// Sorting priority for IWA files so table data and document text precede metadata.
    private static func priority(for name: String) -> Int {
        if name.contains("DataList") {
            return 0
        }
        if name.contains("Document.iwa") {
            return 1
        }
        if name.contains("Tile") {
            return 2
        }
        if name.contains("CalculationEngine") {
            return 3
        }
        return 4
    }

    /// Decompresses all Snappy frames in an IWA payload and extracts text strings.
    ///
    /// Undecodable frames are skipped while later frames still decode.
    static func extractStrings(fromIWA data: Data) -> [String] {
        var consumed = 0
        return extractStrings(fromIWA: data, maxDecompressedBytes: Int.max, consumedDecompressedBytes: &consumed)
    }

    /// Budgeted frame walk capping total decompressed output. Only a bounded prefix near the
    /// declared length reaches the Snappy decoder so one frame never copies the remaining tail.
    static func extractStrings(
        fromIWA data: Data,
        maxDecompressedBytes: Int,
        consumedDecompressedBytes: inout Int
    ) -> [String] {
        var results: [String] = []
        var cursor = 0
        var decompressedTotal = 0

        while cursor + 4 <= data.count {
            guard decompressedTotal < maxDecompressedBytes else { break }
            // Non-zero lead byte cannot start a valid frame; slide one byte to resync.
            guard data[cursor] == 0x00 else {
                cursor += 1
                continue
            }
            // Apple IWA frame header: 1 byte (0x00) + 3 bytes (24-bit LE uncompressed length)
            let lenByte0 = Int(data[cursor + 1])
            let lenByte1 = Int(data[cursor + 2])
            let lenByte2 = Int(data[cursor + 3])
            let uncompressedLen = lenByte0 | (lenByte1 << 8) | (lenByte2 << 16)
            guard uncompressedLen > 0,
                  uncompressedLen <= DocumentSnappy.maxUncompressedBlockBytes,
                  decompressedTotal + uncompressedLen <= maxDecompressedBytes
            else {
                cursor += 4
                continue
            }

            let frameStart = cursor + 4
            let remaining = data.count - frameStart
            guard remaining > 0 else { break }
            let sliceLength = min(remaining, uncompressedLen + uncompressedLen / 4 + 128)
            guard sliceLength > 0 else {
                cursor += 4
                continue
            }
            let slice = data.subdata(in: frameStart ..< (frameStart + sliceLength))
            guard let (decompressed, consumed) = DocumentSnappy.decompress(slice) else {
                cursor += 4
                continue
            }

            cursor += 4 + consumed
            // Header length must match the decompressed payload; otherwise the frame is corrupt.
            guard decompressed.count == uncompressedLen else {
                continue
            }
            decompressedTotal += decompressed.count
            results.append(contentsOf: extractUTF8Strings(from: decompressed))
        }

        consumedDecompressedBytes += decompressedTotal
        return results
    }

    /// Scans raw decompressed bytes for sequences of printable UTF-8 characters.
    private static func extractUTF8Strings(from data: Data) -> [String] {
        var strings: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(256)

        for rawByte in data {
            // Printable ASCII (32..126) or UTF-8 continuation/multibyte (> 127)
            if (rawByte >= 32 && rawByte <= 126) || rawByte > 127 {
                current.append(rawByte)
            } else {
                if current.count >= 2, let decoded = String(bytes: current, encoding: .utf8) {
                    let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 2 {
                        strings.append(trimmed)
                    }
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        if current.count >= 2, let decoded = String(bytes: current, encoding: .utf8) {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 {
                strings.append(trimmed)
            }
        }

        return strings
    }

    /// Determines if a string is internal protobuf or style noise.
    private static func isNoise(_ text: String) -> Bool {
        for prefix in noisePrefixes where text.hasPrefix(prefix) {
            return true
        }
        // Exclude strings that are purely punctuation or hex-like IDs
        if text.allSatisfy({ $0.isPunctuation || $0.isWhitespace || $0.isSymbol }) {
            return true
        }
        return false
    }
}
