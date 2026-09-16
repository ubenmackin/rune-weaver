// Rune Weaver Tools — Seatbelt-confined staging for email attachments.
//
// Resolves per-request isolated-temp destinations and sanitizes filenames
// under a single staging root, so downloads stay confined and never
// executable while path escapes fail closed before any bytes are written.

import Foundation
import RuneWeaverCore

public extension EmailAttachmentTool {
    /// Resolves the Seatbelt-confined isolated-temp destination for a download.
    /// - Parameters:
    ///   - stagingPath: Configured staging directory (`~` is expanded).
    ///   - account: Account nickname used in the file prefix.
    ///   - messageID: Message UID used in the file prefix.
    ///   - index: Attachment position used in the file prefix.
    ///   - filename: Original attachment filename, sanitized to its base name.
    /// - Returns: Destination URL strictly under the staging area.
    /// - Throws: A failure when the staging path is empty or escapes isolated temp.
    static func stagedDestination(
        stagingPath: String,
        account: String,
        messageID: String,
        index: Int,
        filename: String
    ) throws -> URL {
        let trimmed = stagingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid isolated-temp staging path")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // Resolve symlinks on both sides so a symlinked staging directory
        // cannot bypass confinement. The check runs before `createDirectory`
        // and `write` create anything; callers stage only under the
        // returned URL.
        let stagingURL = URL(fileURLWithPath: expanded, isDirectory: true).standardized
        let resolvedStaging = stagingURL.resolvingSymlinksInPath()
        let sanitized = sanitizedFilename(filename, fallback: "attachment-\(index)")
        let prefix = "\(safeSegment(account))-\(safeSegment(messageID))-\(index)-\(sanitized)"
        let destination = stagingURL
            .appendingPathComponent(attachmentsSubdirectory, isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: false)
            .standardized
        let resolvedDestination = destination.resolvingSymlinksInPath()
        let stagingPrefix = resolvedStaging.path.hasSuffix("/") ? resolvedStaging.path : resolvedStaging.path + "/"
        guard resolvedDestination.path.hasPrefix(stagingPrefix) else {
            throw EmailIMAPError.bridgeFailed("Attachment path escapes the isolated temp staging area")
        }
        return destination
    }

    /// Sanitizes a filename to its base name, falling back when empty.
    ///
    /// Strips path separators (`/` and `\`), NUL, colons, and ASCII
    /// control characters, drops leading dots and dashes so the result
    /// cannot hide as dotfiles or parse as a flag, and truncates to
    /// 255 characters (`NAME_MAX`) to stay within filesystem limits.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - fallback: Name used when the base name is empty.
    /// - Returns: Base name safe to append under the staging area.
    static func sanitizedFilename(_ filename: String, fallback: String) -> String {
        let base = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = base
            .replacingOccurrences(of: "\0", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        cleaned = cleaned.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if value < 32 || value == 127 {
                return "_"
            }
            return String(scalar)
        }.joined()
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 255 {
            cleaned = String(cleaned.prefix(255))
        }
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            return fallback
        }
        return cleaned
    }

    /// Maps an account or message segment to filesystem-safe text.
    /// - Parameter segment: Raw account or message identifier.
    /// - Returns: Text with only alphanumerics, dash, underscore, and dot.
    static func safeSegment(_ segment: String) -> String {
        let mapped = segment.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUpper = value >= 65 && value <= 90
            let isLower = value >= 97 && value <= 122
            let isDash = value == 45
            let isUnderscore = value == 95
            let isDot = value == 46
            if isDigit || isUpper || isLower || isDash || isUnderscore || isDot {
                return String(scalar)
            }
            return "_"
        }.joined()
        return mapped.isEmpty ? "_" : mapped
    }
}
