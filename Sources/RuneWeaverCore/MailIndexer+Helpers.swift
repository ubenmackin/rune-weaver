// Rune Weaver Core — Mail indexer helper methods and extensions.

import CryptoKit
import Foundation

// MARK: - Value helpers

extension MailIndexer {
    /// Reports whether a mailbox joins the Trash-class denylist.
    public static func isMailboxDenied(_ mailbox: String, patterns: [String]) -> Bool {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMailbox.isEmpty else { return false }
        let loweredMailbox = trimmedMailbox.lowercased()
        let segments = loweredMailbox.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var candidates = [loweredMailbox]
        candidates.append(contentsOf: segments)
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            for candidate in candidates where SharedGlobMatching.matches(pattern: pattern, relativePath: candidate) {
                return true
            }
        }
        return false
    }

    /// Whether a mail fetch error is worth retrying.
    public static func isRetryableMailError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        if MailErrorClassification.isAuthFailureDetail(described) {
            return false
        }
        return MailErrorClassification.isTransportFailureDetail(described)
    }

    /// Whether a STATUS probe failure must skip the mailbox without paging.
    static func isSkippableStatusError(_ error: Error) -> Bool {
        if let indexError = error as? MailIndexError {
            switch indexError {
            case .validationFailed, .unknownAccount:
                return true
            case .stagingFailed:
                return false
            }
        }
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        return MailErrorClassification.isAuthFailureDetail(described)
    }

    /// Closes a pooled mailbox session without inheriting cancellation.
    static func closeMailboxSessionAssumingOpen(
        gateway: any MailIndexGateway,
        credentials: MailIndexCredentials,
        mailbox: String
    ) async {
        await gateway.closeMailboxSession(credentials: credentials, mailbox: mailbox)
    }

    /// Parses an IMAP UID, returning zero for anything non-numeric.
    /// - Parameter id: Message identifier from the gateway.
    /// - Returns: The UID, or zero when the identifier is not numeric.
    static func uid(of id: String) -> Int {
        Int(id.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Filters to UIDs above the watermark and sorts ascending for contiguous advance. Newest-first
    /// pages are re-sorted so the watermark only advances past messages that were actually
    /// considered, never jumping a gap.
    static func freshSortedMessages(_ fetched: [MailIndexMessage], watermark: Int) -> [MailIndexMessage] {
        fetched
            .filter { Self.uid(of: $0.id) > watermark }
            .sorted { Self.uid(of: $0.id) < Self.uid(of: $1.id) }
    }

    /// Whether the watermark must be held over an unfetched gap.
    static func holdsWatermark(windowComplete: Bool, fresh: [MailIndexMessage], watermark: Int) -> Bool {
        let minFreshUID = fresh.map { Self.uid(of: $0.id) }.filter { $0 > 0 }.min()
        return !windowComplete && (minFreshUID ?? watermark + 1) > watermark + 1
    }

    /// Composes the source-scoped identifier for one message.
    static func documentExternalID(account: String, mailbox: String, messageID: String) -> String {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(account)/\(trimmedMailbox)/\(messageID)"
    }

    /// Joins a subject and body into the indexed message text. subject: Decoded
    /// subject header.
    static func messageText(subject: String, body: String) -> String {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubject.isEmpty {
            return trimmedBody
        }
        if trimmedBody.isEmpty {
            return trimmedSubject
        }
        return "\(trimmedSubject)\n\n\(trimmedBody)"
    }

    /// Hashes message text for change detection and duplicate suppression.
    /// - Parameter text: Normalized message text.
    /// - Returns: Lowercase SHA-256 hex digest.
    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable name for a message document.
    /// - Parameter subject: Decoded subject header.
    /// - Returns: The trimmed subject, or a placeholder when blank.
    static func displayName(subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no subject)" : trimmed
    }

    /// Classifies how completely a message was extracted. hasText: Whether any
    /// chunk text was produced.
    static func extractStatus(hasText: Bool, degraded: Bool) -> ExtractStatus {
        guard hasText else { return .metadataOnly }
        return degraded ? .partial : .extracted
    }

    /// Reduces an attachment filename to a safe base name. The staged binary is only ever read back
    /// for extraction and then deleted, so this only needs to prevent path traversal and control
    /// characters.
    static func sanitizedFilename(_ filename: String, fallback: String) -> String {
        let base = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
