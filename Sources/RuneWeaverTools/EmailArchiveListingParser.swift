// Rune Weaver Tools — Guest archive listing parser for email attachments.
//
// Isolates `unzip -l` and `tar -tvf` stdout parsing behind a shared parser so
// attachment detonation stays focused on orchestration while manifest shaping
// lives in one place without touching the network or filesystem.

import Foundation
import RuneWeaverCore

/// Best-effort parser for guest archive listings.
///
/// Tries ZIP (`unzip -l`) before TAR (`tar -tvf`) mirroring the guest probe
/// order; unparseable output yields an empty manifest so the caller fails
/// closed instead of fabricating entries. Sizes fall back to zero when the
/// row carries no parseable count, with the extraction byte cap remaining
/// the authoritative bound.
public enum EmailArchiveListingParser: Sendable {
    /// Parses guest listing stdout into manifest entries.
    /// - Parameters:
    ///   - output: Stdout from the guest list script.
    ///   - filename: Original archive filename (unused; kept for format hints in future probes).
    /// - Returns: Parsed entries in listing order, possibly empty when unparseable.
    public static func parseListOutput(_ output: String, filename _: String) -> [EmailArchiveEntry] {
        let zipped = parseUnzipListing(output)
        if !zipped.isEmpty {
            return zipped
        }
        return parseTarListing(output)
    }

    /// Parses `unzip -l` rows into entries.
    ///
    /// Skips the archive header, column titles, dash separators, and the
    /// trailing summary line by requiring a leading integer size; the entry
    /// name is the remainder after the size/date/time columns so names
    /// containing spaces survive.
    /// - Parameter output: Guest stdout.
    /// - Returns: Parsed entries, possibly empty.
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
    ///
    /// Finds the size as the first integer token after the permission bits
    /// and takes the entry name from the tail after the date/time columns;
    /// `->` symlink suffixes are stripped so the manifest names the archived
    /// path rather than its target. Rows without a parseable shape are
    /// skipped rather than guessed.
    /// - Parameter output: Guest stdout.
    /// - Returns: Parsed entries, possibly empty.
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
