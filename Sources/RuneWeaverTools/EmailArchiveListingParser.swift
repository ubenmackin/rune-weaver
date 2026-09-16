// Rune Weaver Tools — Guest archive listing parser for email attachments.

import Foundation
import RuneWeaverCore

/// Best-effort parser for guest archive listings.
public enum EmailArchiveListingParser: Sendable {
    /// Parses guest listing stdout into manifest entries.
    public static func parseListOutput(_ output: String, filename _: String) -> [EmailArchiveEntry] {
        let zipped = parseUnzipListing(output)
        if !zipped.isEmpty {
            return zipped
        }
        return parseTarListing(output)
    }

    /// Parses `unzip -l` rows into entries.
    public static func parseUnzipListing(_ output: String) -> [EmailArchiveEntry] {
        var entries: [EmailArchiveEntry] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("Archive:") || trimmed.hasPrefix("Length") || trimmed.hasPrefix("----") {
                continue
            }
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 4, let size = Int(tokens[0]) else { continue }
            let name = tokens.dropFirst(3).joined(separator: " ")
            let lowered = name.lowercased()
            if lowered.hasSuffix(" file") || lowered.hasSuffix(" files") {
                continue
            }
            guard !name.isEmpty else { continue }
            entries.append(EmailArchiveEntry(path: name, sizeBytes: max(0, size), category: EmailAttachmentLifecycle.archiveEntryCategory(forPath: name)))
        }
        return entries
    }

    /// Parses `tar -tvf` rows into entries.
    public static func parseTarListing(_ output: String) -> [EmailArchiveEntry] {
        var entries: [EmailArchiveEntry] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 6 else { continue }
            guard tokens[0].count >= 9,
                  tokens[0].hasPrefix("-") || tokens[0].hasPrefix("d") || tokens[0].hasPrefix("l") else { continue }
            var sizeIndex: Int?
            for index in 1 ..< tokens.count where Int(tokens[index]) != nil {
                sizeIndex = index
                break
            }
            guard let found = sizeIndex, found + 3 < tokens.count, let size = Int(tokens[found]) else { continue }
            let nameTokens = Array(tokens[(found + 3)...])
            guard !nameTokens.isEmpty else { continue }
            var name = nameTokens.joined(separator: " ")
            if let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            entries.append(EmailArchiveEntry(path: name, sizeBytes: max(0, size), category: EmailAttachmentLifecycle.archiveEntryCategory(forPath: name)))
        }
        return entries
    }
}
