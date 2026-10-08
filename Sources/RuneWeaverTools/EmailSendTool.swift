// Rune Weaver Tools — Approval-gated email sending over SMTP (HTML, attachments, threading).

import Foundation
import RuneWeaverCore

/// Send arguments for the `email.send` tool.
public struct EmailSendArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// Bare recipient addresses.
    public let to: [String]
    /// `cc` is RFC 5322 standard field name, so the short name is intentional.
    /// Optional CC recipients.
    public let cc: [String]?
    /// Optional BCC recipients.
    public let bcc: [String]?
    /// Subject header text (1-998 chars, no CR or LF).
    public let subject: String
    /// Optional plain-text body (derived from HTML when omitted).
    public let bodyText: String?
    /// Optional HTML body (standard; at least one of text/HTML is required).
    public let bodyHtml: String?
    /// Optional sandbox-confined absolute attachment paths.
    public let attachmentPaths: [String]?
    /// Optional IMAP id of the message being replied to.
    public let replyToId: String?
    /// Optional mailbox holding the replied-to message (omitted means INBOX).
    public let mailbox: String?

    /// Memberwise initializer.
    public init(
        account: String,
        to: [String],
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        cc: [String]? = nil,
        bcc: [String]? = nil,
        subject: String,
        bodyText: String? = nil,
        bodyHtml: String? = nil,
        attachmentPaths: [String]? = nil,
        replyToId: String? = nil,
        mailbox: String? = nil
    ) {
        self.account = account
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.attachmentPaths = attachmentPaths
        self.replyToId = replyToId
        self.mailbox = mailbox
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case to
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        case cc
        case bcc
        case subject
        case bodyText
        case bodyHtml
        case attachmentPaths
        case replyToId
        case mailbox
        case folder
        case body
    }

    /// Decodes arguments; `folder` and `body` are compatibility-only aliases kept out of strict schema,
    /// which advertises bodyText/mailbox only, so wire stays fail-closed while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        to = try container.decode([String].self, forKey: .to)
        cc = try container.decodeIfPresent([String].self, forKey: .cc)
        bcc = try container.decodeIfPresent([String].self, forKey: .bcc)
        subject = try container.decode(String.self, forKey: .subject)
        if let text = try container.decodeIfPresent(String.self, forKey: .bodyText) {
            bodyText = text
        } else {
            bodyText = try container.decodeIfPresent(String.self, forKey: .body)
        }
        bodyHtml = try container.decodeIfPresent(String.self, forKey: .bodyHtml)
        attachmentPaths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths)
        replyToId = try container.decodeIfPresent(String.self, forKey: .replyToId)
        if let box = try container.decodeIfPresent(String.self, forKey: .mailbox) {
            mailbox = box
        } else {
            mailbox = try container.decodeIfPresent(String.self, forKey: .folder)
        }
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed reply id, or nil when omitted or blank.
    public var trimmedReplyToId: String? {
        guard let replyToId else { return nil }
        let trimmed = replyToId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed mailbox, or nil when omitted or blank (meaning INBOX).
    public var trimmedMailbox: String? {
        EmailMailboxNormalization.trimmed(mailbox)
    }
}

/// Envelope wrapping `email.send` tool output.
public struct EmailSendEnvelope: Sendable, Equatable, Codable {
    /// Account nickname the message was sent through.
    public let account: String
    /// Sender address (always the account username).
    public let from: String
    /// Recipient addresses as sent.
    public let to: [String]
    /// `cc` is RFC 5322 standard field name, so the short name is intentional.
    /// CC recipients as sent (empty when omitted).
    public let cc: [String]
    /// BCC recipients as sent (empty when omitted).
    public let bcc: [String]
    /// Subject header as sent (Re:-prefixed when replying).
    public let subject: String
    /// UTF-8 byte count of the effective plain body.
    public let bodyTextBytes: Int
    /// UTF-8 byte count of the HTML alternative (nil when plain-only).
    public let bodyHtmlBytes: Int?
    /// Whether this envelope previews a send without network use.
    public let dryRun: Bool
    /// Human-readable outcome note (dry-run preview or send confirmation).
    public let note: String?
    /// Validated attachment paths as sent (nil when none).
    public let attachmentPaths: [String]?
    /// Total attachment bytes staged for the send (nil when none).
    public let attachmentBytes: Int?
    /// `In-Reply-To` header as sent (nil when not a reply).
    public let inReplyTo: String?
    /// `References` header as sent (nil when not a reply).
    public let references: String?
    /// Leading 2000 chars of the effective plain body (preview only).
    public let bodyPreview: String?
    /// Best-effort Sent-append warning (nil when archived or not attempted).
    public let appendWarning: String?

    private enum CodingKeys: String, CodingKey {
        case account
        case from
        case to
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        case cc
        case bcc
        case subject
        case bodyTextBytes
        case bodyHtmlBytes
        case dryRun
        case note
        case attachmentPaths
        case attachmentBytes
        case inReplyTo
        case references
        case bodyPreview
        case appendWarning
    }

    /// Creates a send envelope.
    public init(
        account: String,
        from: String,
        to: [String],
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        bodyTextBytes: Int,
        bodyHtmlBytes: Int? = nil,
        dryRun: Bool = false,
        note: String? = nil,
        attachmentPaths: [String]? = nil,
        attachmentBytes: Int? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        bodyPreview: String? = nil,
        appendWarning: String? = nil
    ) {
        self.account = account
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyTextBytes = bodyTextBytes
        self.bodyHtmlBytes = bodyHtmlBytes
        self.dryRun = dryRun
        self.note = note
        self.attachmentPaths = attachmentPaths
        self.attachmentBytes = attachmentBytes
        self.inReplyTo = inReplyTo
        self.references = references
        self.bodyPreview = bodyPreview
        self.appendWarning = appendWarning
    }

    /// Decodes an envelope, defaulting omitted threading keys to nil.
    /// - Parameter decoder: Decoder for the envelope document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode([String].self, forKey: .to)
        cc = try container.decodeIfPresent([String].self, forKey: .cc) ?? []
        bcc = try container.decodeIfPresent([String].self, forKey: .bcc) ?? []
        subject = try container.decode(String.self, forKey: .subject)
        bodyTextBytes = try container.decode(Int.self, forKey: .bodyTextBytes)
        bodyHtmlBytes = try container.decodeIfPresent(Int.self, forKey: .bodyHtmlBytes)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note)
        attachmentPaths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths)
        attachmentBytes = try container.decodeIfPresent(Int.self, forKey: .attachmentBytes)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try container.decodeIfPresent(String.self, forKey: .references)
        bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview)
        appendWarning = try container.decodeIfPresent(String.self, forKey: .appendWarning)
    }

    /// Encodes an envelope, omitting unset threading keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encode(bcc, forKey: .bcc)
        try container.encode(subject, forKey: .subject)
        try container.encode(bodyTextBytes, forKey: .bodyTextBytes)
        try container.encodeIfPresent(bodyHtmlBytes, forKey: .bodyHtmlBytes)
        try container.encode(dryRun, forKey: .dryRun)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(attachmentPaths, forKey: .attachmentPaths)
        try container.encodeIfPresent(attachmentBytes, forKey: .attachmentBytes)
        try container.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
        try container.encodeIfPresent(references, forKey: .references)
        try container.encodeIfPresent(bodyPreview, forKey: .bodyPreview)
        try container.encodeIfPresent(appendWarning, forKey: .appendWarning)
    }
}

/// Fail-closed validation for `email.send` inputs.
public enum EmailSendValidation: Sendable {
    /// Maximum recipients accepted per address field.
    public static let maxRecipientsPerField = 20
    /// Maximum recipients accepted total across to/cc/bcc.
    public static let maxTotalRecipients = 20
    /// Maximum subject characters (RFC 5322 line limit).
    public static let maxSubjectChars = 998
    /// Maximum body bytes combined across text plus HTML (1 MB).
    public static let maxBodyBytes = 1_048_576
    /// Maximum address characters (RFC 5321 path limit).
    public static let maxAddressChars = 254
    /// Maximum bytes per attachment file (10 MB).
    public static let maxAttachmentBytesPerFile = 10 * 1024 * 1024
    /// Maximum bytes total across all attachments (25 MB).
    public static let maxAttachmentBytesTotal = 25 * 1024 * 1024
    /// Maximum chars in the dry-run/sent body preview.
    public static let maxBodyPreviewChars = 2000

    /// Lite address pattern: bare `local@domain.tld` without display names.
    private static let addressPattern = "^[A-Z0-9._%+\\-]+@[A-Z0-9.\\-]+\\.[A-Z]{2,}$"

    /// Whether an address looks like a bare mailbox.
    public static func isValidEmail(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxAddressChars else { return false }
        if trimmed.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            return false
        }
        return trimmed.range(of: addressPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Validates one address, rejecting header injection and bad shapes.
    public static func validateAddress(_ address: String, field: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid recipient in '\(field)': address must not contain CR or LF")
        }
        guard isValidEmail(trimmed) else {
            throw EmailIMAPError.bridgeFailed("Invalid recipient in '\(field)': each address must be a valid email like name@example.com")
        }
    }

    /// Validates and normalizes one recipient list.
    public static func validateRecipients(_ values: [String], field: String, required: Bool) throws -> [String] {
        if required, values.isEmpty {
            throw EmailIMAPError.bridgeFailed("Invalid recipients in '\(field)': provide 1-\(maxRecipientsPerField) email addresses")
        }
        guard values.count <= maxRecipientsPerField else {
            throw EmailIMAPError.bridgeFailed("Invalid recipients in '\(field)': at most \(maxRecipientsPerField) addresses")
        }
        var normalized: [String] = []
        normalized.reserveCapacity(values.count)
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw EmailIMAPError.bridgeFailed("Invalid recipient in '\(field)': address must not be empty")
            }
            try validateAddress(trimmed, field: field)
            normalized.append(trimmed)
        }
        return normalized
    }

    /// Validates the total recipient count across to/cc/bcc.
    public static func validateTotalRecipients(to: [String], cc: [String], bcc: [String]) throws {
        let total = to.count + cc.count + bcc.count
        guard total <= maxTotalRecipients else {
            throw EmailIMAPError.bridgeFailed("Invalid recipients: at most \(maxTotalRecipients) recipients total across to/cc/bcc")
        }
    }

    /// Validates a subject header, rejecting folding and overlong lines.
    public static func validateSubject(_ subject: String) throws -> String {
        if subject.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid subject: subject must not contain CR or LF")
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid subject: subject must not be empty")
        }
        guard trimmed.count <= maxSubjectChars else {
            throw EmailIMAPError.bridgeFailed("Invalid subject: subject must be at most \(maxSubjectChars) characters")
        }
        if trimmed.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid subject: subject must not contain CR or LF")
        }
        return trimmed
    }

    /// Validates a required plain body by UTF-8 byte size.
    public static func validateBody(_ body: String, field: String) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid body: '\(field)' must not be empty")
        }
        let bytes = body.utf8.count
        guard bytes <= maxBodyBytes else {
            throw EmailIMAPError.bridgeFailed("Invalid body: '\(field)' exceeds the 1 MB size cap")
        }
    }

    /// Validates an optional HTML alternative, treating blank as absent.
    public static func validateOptionalBody(_ body: String?, field: String) throws -> String? {
        guard let body else { return nil }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard body.utf8.count <= maxBodyBytes else {
            throw EmailIMAPError.bridgeFailed("Invalid body: '\(field)' exceeds the 1 MB size cap")
        }
        return body
    }

    /// Validates the combined text-plus-HTML byte budget.
    public static func validateCombinedBody(text: String, html: String?) throws {
        let total = text.utf8.count + (html?.utf8.count ?? 0)
        guard total <= maxBodyBytes else {
            throw EmailIMAPError.bridgeFailed("Invalid body: combined body exceeds the 1 MB size cap")
        }
    }

    /// Validates an optional threading header, rejecting folding.
    public static func validateThreadingHeader(_ value: String?, field: String) throws {
        guard let value else { return }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if value.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid threading header '\(field)': header must not contain CR or LF")
        }
    }

    /// Derives a plain-text fallback from HTML by stripping tags.
    public static func deriveText(fromHtml html: String) -> String {
        var text = html.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the 2000-char body preview for envelopes.
    public static func bodyPreview(for body: String) -> String {
        let single = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > maxBodyPreviewChars else { return single }
        return String(single.prefix(maxBodyPreviewChars))
    }

    /// Whether a subject already carries a reply prefix.
    /// - Parameter subject: Trimmed subject.
    /// - Returns: True when it starts with `Re:` case-insensitively.
    public static func hasReplyPrefix(_ subject: String) -> Bool {
        subject.lowercased().hasPrefix("re:")
    }

    /// Prefixes `Re:` when missing for threaded replies.
    /// - Parameter subject: Trimmed subject.
    /// - Returns: Subject with the reply prefix.
    public static func replySubject(for subject: String) -> String {
        hasReplyPrefix(subject) ? subject : "Re: \(subject)"
    }

    /// Quotes an original text body for a reply.
    public static func quotedOriginal(_ body: String) -> String {
        // Shared split keeps reply quoting on the same CRLF/CR/LF boundaries as
        // narration and history parsing; a trailing newline stays a terminator.
        NormalizedText.splitLines(body).map { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "> \(line)"
        }.joined(separator: "\n")
    }
}

/// Approval-gated `email.send` tool over SMTP.
public struct EmailSendTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.send"
    /// When the LLM should use this tool.
    public let description =
        "Sends an email via SMTP through the configured account. "
            + "Use when the user asks to send or compose mail. "
            + "From always defaults to the account username with no From override; sends immediately on approval with no scheduled or delayed send. "
            + "Markdown or plain text in bodyText is standard and is automatically rendered into styled HTML with a plain-text fallback; "
            + "raw bodyHtml is optional for custom HTML overrides; "
            + "attachments must be workspace-guarded absolute paths, and replyToId threads a reply. "
            + "Returns the sender, recipients, subject, body size, and Sent status."
    /// Function-calling contract for the send envelope plus threading and attachments.
    /// Schema advertises only canonical keys; decoder tolerance for retired
    /// spellings stays out of the schema as intentional compatibility so strict
    /// validators and the decoder agree on what is advertised.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. volcrypt, icloud)"},"to":{"type":"array","description":"Recipient email "#
                + #"addresses (1-20 total across to/cc/bcc, bare addresses like name@example.com)","items":{"type":"string"},"minItems":1,"maxItems":20},"#
                + #""cc":{"type":"array","description":"Optional CC recipients (counted in the 20 total)","items":{"type":"string"}, "#
                + #""minItems":0,"maxItems":20},"bcc":{"type":"array","description":"Optional BCC recipients (counted in the 20 total)", "#
                + #""items":{"type":"string"},"minItems":0,"maxItems":20},"subject":{"type":"string","description":"Subject header "#
                + #"(1-998 chars, no CR or LF)","maxLength":998},"bodyText":{"type":"string","description":"Email body formatted in standard "#
                + #"Markdown or plain text. Automatically rendered to styled HTML with a plain-text fallback."},"#
                + #""bodyHtml":{"type":"string","description":"Optional raw HTML body override. "#
                + #"If omitted, styled HTML is automatically generated from bodyText."},"#
                + #""attachmentPaths":{"type":"array","description":"Optional workspace-guarded "#
                + #"absolute attachment paths (10 MB each, 25 MB total)","items":{"type":"string"}},"replyToId":{"type":"string","description":"Optional "#
                + #"IMAP id of the message being replied to"},"mailbox":{"type":"string","description":"Mailbox holding the replied-to "#
                + #"message (omitted means INBOX)"}}"#
                + #","required":["account","to","subject"],"additionalProperties":false}"#
        )
    /// Gated: sending leaves the machine and always prompts without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// SMTP gateway (subprocess bridge by default, stub in tests).
    private let smtpGateway: any EmailSMTPGateway
    /// IMAP gateway for threading fetches and Sent appends (subprocess by default, stub in tests).
    private let imapGateway: any EmailIMAPGateway

    /// Creates a send tool.
    public init(
        emailConfig: EmailConfig,
        smtpGateway: (any EmailSMTPGateway)? = nil,
        gateway: (any EmailIMAPGateway)? = nil
    ) {
        self.emailConfig = emailConfig
        self.smtpGateway = smtpGateway ?? SubprocessSMTPGateway()
        self.imapGateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Validates, resolves credentials, and sends (or previews under dry-run).
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        do {
            let args = try decodedArgs(from: input)
            let target = try validatedTarget(from: args)
            let account = try resolvedAccount(named: target.accountName)
            let credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
            let from = credentials.username
            if context.dryRun {
                return dryRunEnvelope(target: target, accountName: account.name, from: from, callID: input.callID)
            }
            let staged = try stagedAttachments(paths: target.attachmentPaths)
            let threading = try await threadingContext(
                credentials: credentials,
                target: target
            )
            try await smtpGateway.send(
                credentials: credentials,
                message: EmailSMTPMessage(
                    from: from,
                    to: target.to,
                    cc: target.cc,
                    bcc: target.bcc,
                    subject: threading.subject,
                    bodyText: threading.bodyText,
                    bodyHtml: threading.bodyHtml,
                    inReplyTo: threading.inReplyTo,
                    references: threading.references,
                    attachments: staged.map { EmailSMTPAttachment(filename: $0.filename, contentType: $0.contentType, data: $0.data) }
                )
            )
            let appendContent = SendAppendContent(
                from: from,
                to: target.to,
                cc: target.cc,
                subject: threading.subject,
                bodyText: threading.bodyText,
                inReplyTo: threading.inReplyTo,
                references: threading.references
            )
            let appendWarning = await bestEffortSentAppend(credentials: credentials, content: appendContent)
            let confirmation = SentConfirmation(
                target: target,
                threading: threading,
                staged: staged,
                accountName: account.name,
                from: from,
                appendWarning: appendWarning,
                callID: input.callID
            )
            return sentEnvelope(confirmation)
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Trimmed send routing for `email.send`.
private struct EmailSendTarget {
    let accountName: String
    let to: [String]
    // `cc` is RFC 5322 standard field name, so the short name is intentional.
    let cc: [String]
    let bcc: [String]
    let subject: String
    let bodyText: String
    let bodyHtml: String?
    let hasCustomHtml: Bool
    let attachmentPaths: [String]
    let replyToId: String?
    let mailbox: String
}

/// One validated attachment staged for the bridge.
private struct StagedSendAttachment: Sendable, Equatable {
    let path: String
    let filename: String
    let contentType: String
    let data: Data
}

/// Threaded send content after reply resolution.
private struct SendThreading {
    let subject: String
    let bodyText: String
    let bodyHtml: String?
    let inReplyTo: String?
    let references: String?
}

/// Grouped Sent-copy content for the best-effort append path.
private struct SendAppendContent {
    let from: String
    let to: [String]
    // `cc` is RFC 5322 standard field name, so the short name is intentional.
    let cc: [String]
    let subject: String
    let bodyText: String
    let inReplyTo: String?
    let references: String?
}

/// Grouped confirmation inputs for the sent envelope.
private struct SentConfirmation {
    let target: EmailSendTarget
    let threading: SendThreading
    let staged: [StagedSendAttachment]
    let accountName: String
    let from: String
    let appendWarning: String?
    let callID: String
}

extension EmailSendTool {
    /// Decodes send arguments, rejecting bad shapes before any lookup.
    private func decodedArgs(from input: ToolInput) throws -> EmailSendArgs {
        do {
            return try JSONDecoder().decode(EmailSendArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            throw EmailIMAPError.bridgeFailed(
                "Invalid email.send arguments: expected {\"account\": \"<name>\", "
                    + "\"to\": [\"<email>\"], \"subject\": \"<text>\", "
                    + "\"bodyText\": \"<text>\" and/or \"bodyHtml\": \"<html>\"}."
            )
        }
    }

    /// Trims and fail-closed validates decoded send routing.
    private func validatedTarget(from args: EmailSendArgs) throws -> EmailSendTarget {
        let accountName = args.trimmedAccount
        guard !accountName.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.send arguments: 'account' must not be empty.")
        }
        let to = try EmailSendValidation.validateRecipients(args.to, field: "to", required: true)
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        let cc = try EmailSendValidation.validateRecipients(args.cc ?? [], field: "cc", required: false)
        let bcc = try EmailSendValidation.validateRecipients(args.bcc ?? [], field: "bcc", required: false)
        try EmailSendValidation.validateTotalRecipients(to: to, cc: cc, bcc: bcc)
        let subject = try EmailSendValidation.validateSubject(args.subject)
        // Bind the optional text body without force-unwrapping so blank or
        // missing text collapses to nil for the HTML-fallback path below.
        let rawText: String? = if let raw = args.bodyText, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw
        } else {
            nil
        }
        let rawHtml = try EmailSendValidation.validateOptionalBody(args.bodyHtml, field: "bodyHtml")
        guard rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || rawHtml != nil else {
            throw EmailIMAPError.bridgeFailed("Invalid body: provide 'bodyText' and/or 'bodyHtml'.")
        }
        // Markdown or plain text in bodyText is standard: when rawHtml is omitted,
        // styled HTML is automatically generated via Ink with a plain-text fallback.
        // When rawHtml is provided, it is honored verbatim as a custom HTML override.
        let effectiveText: String
        if let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try EmailSendValidation.validateBody(rawText, field: "bodyText")
            effectiveText = rawText
        } else if let rawHtml {
            let derived = EmailSendValidation.deriveText(fromHtml: rawHtml)
            guard !derived.isEmpty else {
                throw EmailIMAPError.bridgeFailed("Invalid body: 'bodyHtml' holds no text content.")
            }
            try EmailSendValidation.validateBody(derived, field: "bodyText")
            effectiveText = derived
        } else {
            throw EmailIMAPError.bridgeFailed("Invalid body: provide 'bodyText' and/or 'bodyHtml'.")
        }
        let hasCustomHtml = rawHtml != nil
        let effectiveHtml: String? = if let rawHtml {
            rawHtml
        } else {
            EmailMarkdownRenderer.render(markdown: effectiveText)
        }
        try EmailSendValidation.validateCombinedBody(text: effectiveText, html: effectiveHtml)
        let attachmentPaths = try validatedAttachmentSyntax(args.attachmentPaths ?? [])
        let replyToId = try validatedReplyToId(args.trimmedReplyToId)
        let mailbox = try validatedMailbox(args.trimmedMailbox)
        // Threading headers are validated when already derived (dry-run
        // preview echoes the reply id); the fetched original supplies the
        // same values for real sends without extra network in dry runs.
        if let replyToId {
            try EmailSendValidation.validateThreadingHeader(replyToId, field: "In-Reply-To")
            try EmailSendValidation.validateThreadingHeader(replyToId, field: "References")
        }
        return EmailSendTarget(
            accountName: accountName,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            bodyText: effectiveText,
            bodyHtml: effectiveHtml,
            hasCustomHtml: hasCustomHtml,
            attachmentPaths: attachmentPaths,
            replyToId: replyToId,
            mailbox: mailbox
        )
    }

    /// Validates attachment path syntax without touching the filesystem.
    private func validatedAttachmentSyntax(_ paths: [String]) throws -> [String] {
        var trimmed: [String] = []
        trimmed.reserveCapacity(paths.count)
        for raw in paths {
            if raw.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
                throw EmailIMAPError.bridgeFailed("Invalid attachment: path must not contain CR or LF")
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw EmailIMAPError.bridgeFailed("Invalid attachment: path must not be empty")
            }
            guard value.hasPrefix("/") else {
                throw EmailIMAPError.bridgeFailed("Invalid attachment '\(value)': path must be an absolute sandbox-confined path")
            }
            trimmed.append(value)
        }
        return trimmed
    }

    /// Validates an optional reply id against UID syntax.
    private func validatedReplyToId(_ replyToId: String?) throws -> String? {
        guard let replyToId else { return nil }
        try EmailIMAPValidation.validateMessageID(replyToId)
        return replyToId
    }

    /// Normalizes the threading mailbox, defaulting to INBOX.
    private func validatedMailbox(_ mailbox: String?) throws -> String {
        let value = mailbox ?? "INBOX"
        try EmailIMAPValidation.validateMailbox(value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves the configured account by exact then case-insensitive name.
    private func resolvedAccount(named accountName: String) throws -> EmailAccount {
        if let account = emailConfig.account(matching: accountName) {
            return account
        }
        throw EmailIMAPError.unknownAccount(name: accountName, available: emailConfig.accounts.map(\.name))
    }

    /// Stages workspace-guarded attachments for the bridge.
    private func stagedAttachments(paths: [String]) throws -> [StagedSendAttachment] {
        guard !paths.isEmpty else { return [] }
        var staged: [StagedSendAttachment] = []
        var totalBytes = 0
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let candidate = URL(fileURLWithPath: expanded, isDirectory: false).standardized
            let resolved = candidate.resolvingSymlinksInPath()
            let guardDecision = FilesAccessGuard.evaluate(url: resolved)
            guard guardDecision.allowed else {
                throw EmailIMAPError.bridgeFailed(guardDecision.reason ?? "Invalid attachment '\(path)': path is not in the permitted workspace")
            }
            let values: URLResourceValues
            do {
                values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                throw EmailIMAPError.bridgeFailed("Invalid attachment '\(path)': file not found")
            }
            guard values.isRegularFile == true else {
                throw EmailIMAPError.bridgeFailed("Invalid attachment '\(path)': not a regular file")
            }
            let data: Data
            do {
                data = try Data(contentsOf: resolved)
            } catch {
                throw EmailIMAPError.bridgeFailed("Invalid attachment '\(path)': could not read staged file")
            }
            guard data.count <= EmailSendValidation.maxAttachmentBytesPerFile else {
                throw EmailIMAPError.bridgeFailed("Invalid attachment '\(path)': exceeds the 10 MB per-file cap")
            }
            totalBytes += data.count
            guard totalBytes <= EmailSendValidation.maxAttachmentBytesTotal else {
                throw EmailIMAPError.bridgeFailed("Invalid attachments: exceeds the 25 MB total cap")
            }
            let filename = resolved.lastPathComponent.isEmpty ? "attachment" : resolved.lastPathComponent
            staged.append(StagedSendAttachment(
                path: path,
                filename: filename,
                contentType: Self.contentType(forPath: path),
                data: data
            ))
        }
        return staged
    }

    /// Resolves threaded content by fetching the original when replying.
    private func threadingContext(
        credentials: ResolvedEmailCredentials,
        target: EmailSendTarget
    ) async throws -> SendThreading {
        guard let replyToId = target.replyToId else {
            return SendThreading(
                subject: target.subject,
                bodyText: target.bodyText,
                bodyHtml: target.bodyHtml,
                inReplyTo: nil,
                references: nil
            )
        }
        let listed = try await imapGateway.listMailboxes(credentials: credentials)
        let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        let canonical = try EmailBridgeParsing.resolveMailboxAgainstList(requested: target.mailbox, available: available)
        let original = try await imapGateway.fetch(credentials: credentials, mailbox: canonical, messageID: replyToId)
        let effectiveSubject = EmailSendValidation.replySubject(for: target.subject)
        let quoted = EmailSendValidation.quotedOriginal(original.body)
        let headerDate = original.date.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerFrom = original.from.trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution = if !headerDate.isEmpty, !headerFrom.isEmpty {
            "\n\nOn \(headerDate), \(headerFrom) wrote:\n\n\(quoted)"
        } else if !quoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "\n\n\(quoted)"
        } else {
            ""
        }
        let effectiveText = target.bodyText + attribution
        try EmailSendValidation.validateBody(effectiveText, field: "bodyText")
        let effectiveHtml = target.hasCustomHtml ? target.bodyHtml : EmailMarkdownRenderer.render(markdown: effectiveText)
        try EmailSendValidation.validateCombinedBody(text: effectiveText, html: effectiveHtml)
        return SendThreading(
            subject: effectiveSubject,
            bodyText: effectiveText,
            bodyHtml: effectiveHtml,
            inReplyTo: replyToId,
            references: replyToId
        )
    }

    /// Best-effort appends the sent message to the Sent folder.
    private func bestEffortSentAppend(credentials: ResolvedEmailCredentials, content: SendAppendContent) async -> String? {
        do {
            let listed = try await imapGateway.listMailboxes(credentials: credentials)
            let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
            guard let sentBox = EmailSentMailbox.resolve(among: available) else {
                return "Sent copy skipped: no Sent mailbox found."
            }
            let raw = Self.rawAppendMessage(content)
            try await imapGateway.append(credentials: credentials, mailbox: sentBox, rawMessage: raw)
            return nil
        } catch {
            return "Sent copy skipped: \(error.localizedDescription)"
        }
    }

    /// Builds a minimal RFC822 copy for the Sent folder.
    private static func rawAppendMessage(_ content: SendAppendContent) -> Data {
        var lines: [String] = [
            "From: \(content.from)",
            "To: \(content.to.joined(separator: ", "))"
        ]
        if !content.cc.isEmpty {
            lines.append("Cc: \(content.cc.joined(separator: ", "))")
        }
        lines.append("Subject: \(content.subject)")
        if let inReplyTo = content.inReplyTo, !inReplyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references = content.references, !references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("References: \(references)")
        }
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("")
        lines.append(content.bodyText)
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Maps a file path to a MIME type by extension without sniffing.
    private static func contentType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "txt", "md", "markdown", "log": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// Encodes a send envelope as a success result.
    private func successEnvelope(_ envelope: EmailSendEnvelope, callID: String) -> ToolOutput {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(envelope)
            return .success(String(bytes: data, encoding: .utf8) ?? "", callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }

    /// Builds the dry-run preview without touching the network.
    private func dryRunEnvelope(target: EmailSendTarget, accountName: String, from: String, callID: String) -> ToolOutput {
        let staged: [StagedSendAttachment]
        do {
            staged = try stagedAttachments(paths: target.attachmentPaths)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
        let total = target.to.count + target.cc.count + target.bcc.count
        let effectiveSubject = target.replyToId == nil ? target.subject : EmailSendValidation.replySubject(for: target.subject)
        let preview = EmailSendValidation.bodyPreview(for: target.bodyText)
        let envelope = EmailSendEnvelope(
            account: accountName,
            from: from,
            to: target.to,
            cc: target.cc,
            bcc: target.bcc,
            subject: effectiveSubject,
            bodyTextBytes: target.bodyText.utf8.count,
            bodyHtmlBytes: target.bodyHtml?.utf8.count,
            dryRun: true,
            note: "Dry run: would send to \(total) recipient(s) via \(accountName) without network use.",
            attachmentPaths: staged.isEmpty ? nil : staged.map(\.path),
            attachmentBytes: staged.isEmpty ? nil : staged.reduce(0) { $0 + $1.data.count },
            inReplyTo: target.replyToId,
            references: target.replyToId,
            bodyPreview: preview,
            appendWarning: nil
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Builds the sent confirmation after the bridge succeeds.
    /// - Parameter confirmation: Grouped routing, threaded content, staged files, and envelope metadata.
    /// - Returns: Success envelope with the send confirmation.
    private func sentEnvelope(_ confirmation: SentConfirmation) -> ToolOutput {
        let target = confirmation.target
        let threading = confirmation.threading
        let staged = confirmation.staged
        let accountName = confirmation.accountName
        let from = confirmation.from
        let appendWarning = confirmation.appendWarning
        let callID = confirmation.callID
        let total = target.to.count + target.cc.count + target.bcc.count
        var note = "Sent to \(total) recipient(s) via \(accountName)."
        if let appendWarning {
            note += " \(appendWarning)"
        }
        let envelope = EmailSendEnvelope(
            account: accountName,
            from: from,
            to: target.to,
            cc: target.cc,
            bcc: target.bcc,
            subject: threading.subject,
            bodyTextBytes: threading.bodyText.utf8.count,
            bodyHtmlBytes: threading.bodyHtml?.utf8.count,
            dryRun: false,
            note: note,
            attachmentPaths: staged.isEmpty ? nil : staged.map(\.path),
            attachmentBytes: staged.isEmpty ? nil : staged.reduce(0) { $0 + $1.data.count },
            inReplyTo: threading.inReplyTo,
            references: threading.references,
            bodyPreview: EmailSendValidation.bodyPreview(for: threading.bodyText),
            appendWarning: appendWarning
        )
        return successEnvelope(envelope, callID: callID)
    }
}
