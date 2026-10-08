import CryptoKit
import Foundation

// MARK: - Value helpers

extension MailIndexer {
    /// Reports whether a mailbox joins the Trash-class denylist.
    ///
    /// The mail run gate owns this match: every pattern and every candidate
    /// lowercases first to mirror the files walker, and the full mailbox name
    /// plus each slash-separated hierarchy segment is tested so `Trash`
    /// covers both `Trash` and `INBOX/Trash` while `Deleted*` still spans the
    /// space in `Deleted Messages`.
    /// - Parameters:
    ///   - mailbox: Mailbox name from the gateway.
    ///   - patterns: Raw denylist globs from `IndexConfig.mailboxDeny`.
    /// - Returns: True when any pattern matches the mailbox or a segment.
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
    ///
    /// The wording owner is `MailErrorClassification`: cancellation never
    /// retries, authentication failures never retry, transient transport
    /// phrases retry, and everything else skips at once. Authentication wins
    /// over transport so a message carrying both signals still skips.
    /// - Parameter error: Fetch failure under test.
    /// - Returns: True for retryable transport failures, false otherwise.
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
    ///
    /// Only authentication, fail-closed validation, and unknown-account
    /// failures skip: a bad credential or bad argument cannot succeed on the
    /// message path. Every other probe failure falls back to the unanchored
    /// path with a nil probe, matching the one-shot empty-query fallback.
    /// Auth wording stays owned by `MailErrorClassification`; validation plus
    /// unknown-account arrive as Core-owned `MailIndexError` cases mapped by
    /// the gateway adapter so this layer matches by type without importing
    /// the tool layer.
    /// - Parameter error: STATUS probe failure under test.
    /// - Returns: True when the mailbox must be skipped, false to page unanchored.
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
    ///
    /// The mailbox bracket owns this close: the evict runs detached so a
    /// cancelled caller still releases the pooled connection instead of
    /// leaking it, and the detached task is awaited so the close lands before
    /// the mailbox returns and stays observable to callers. The adapter close
    /// is an idempotent no-op when absent.
    /// - Parameters:
    ///   - gateway: Gateway owning the pooled session.
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox whose session ends.
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

    /// Filters to UIDs above the watermark and sorts ascending for contiguous advance.
    ///
    /// Newest-first pages are re-sorted so the watermark only advances past
    /// messages that were actually considered, never jumping a gap.
    static func freshSortedMessages(_ fetched: [MailIndexMessage], watermark: Int) -> [MailIndexMessage] {
        fetched
            .filter { Self.uid(of: $0.id) > watermark }
            .sorted { Self.uid(of: $0.id) < Self.uid(of: $1.id) }
    }

    /// Whether the watermark must be held over an unfetched gap.
    ///
    /// A burst larger than the gateway's widest page leaves IDs between the
    /// watermark and the fetched middle; holding keeps them eligible while
    /// hashes still dedupe on revisit.
    static func holdsWatermark(windowComplete: Bool, fresh: [MailIndexMessage], watermark: Int) -> Bool {
        let minFreshUID = fresh.map { Self.uid(of: $0.id) }.filter { $0 > 0 }.min()
        return !windowComplete && (minFreshUID ?? watermark + 1) > watermark + 1
    }

    /// Composes the source-scoped identifier for one message.
    /// The mailbox is trimmed so padded spellings share one document identity with the pooled
    /// session and checkpoint watermark, which already normalize through the shared mailbox key;
    /// otherwise one mailbox would fork pool and watermark from document identity.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    ///   - messageID: IMAP UID.
    /// - Returns: A stable document identifier.
    static func documentExternalID(account: String, mailbox: String, messageID: String) -> String {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(account)/\(trimmedMailbox)/\(messageID)"
    }

    /// Joins a subject and body into the indexed message text.
    /// - Parameters:
    ///   - subject: Decoded subject header.
    ///   - body: Decoded plain-text body.
    /// - Returns: Subject plus body, each trimmed, separated by a blank line.
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

    /// Classifies how completely a message was extracted.
    /// - Parameters:
    ///   - hasText: Whether any chunk text was produced.
    ///   - degraded: Whether any part was partial, oversized, or unreadable.
    /// - Returns: The extraction status to persist.
    static func extractStatus(hasText: Bool, degraded: Bool) -> ExtractStatus {
        guard hasText else { return .metadataOnly }
        return degraded ? .partial : .extracted
    }

    /// Reduces an attachment filename to a safe base name.
    ///
    /// The staged binary is only ever read back for extraction and then deleted,
    /// so this only needs to prevent path traversal and control characters.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - fallback: Name used when nothing safe remains.
    /// - Returns: A sanitized base name.
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
