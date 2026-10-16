// Rune Weaver Tools — IMAP bridge payload codecs for the email tool suite.

import Foundation

/// Pure JSON parsing for the IMAP bridge payloads.
public enum EmailBridgeParsing {
    /// Bridge `search` response shape.
    struct SearchResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Hits when `ok` is true.
        let messages: [EmailSearchHit]?
    }

    /// Bridge `fetch` response shape.
    struct FetchResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Message when `ok` is true.
        let message: EmailFullMessage?
    }

    /// Bridge `batch_fetch` response shape.
    struct BatchFetchResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Messages when `ok` is true.
        let messages: [EmailFullMessage]?
    }

    /// Bridge `attachment` payload shape.
    struct BridgeAttachmentPayload: Decodable {
        /// Original filename.
        let filename: String
        /// MIME type.
        let contentType: String
        /// Decoded byte size.
        let sizeBytes: Int?
        /// Base64-encoded attachment bytes (nil for Python-enforced oversize skips).
        let contentBase64: String?
        /// Oversize marker set by the bridge when the part exceeds the download cap before base64 encoding.
        let oversize: Bool?
    }

    /// Bridge `attachment` response shape.
    struct AttachmentResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Attachment payload when `ok` is true.
        let attachment: BridgeAttachmentPayload?
    }

    /// Decodes a bridge `search` stdout payload.
    public static func parseSearchPayload(_ data: Data) throws -> [EmailSearchHit] {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP search failed")
        }
        return response.messages ?? []
    }

    /// Decodes a bridge `fetch` stdout payload.
    public static func parseFetchPayload(_ data: Data) throws -> EmailFullMessage {
        let response = try JSONDecoder().decode(FetchResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP fetch failed")
        }
        guard let message = response.message else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no message")
        }
        return message
    }

    /// Decodes a bridge `batch_fetch` stdout payload.
    public static func parseBatchFetchPayload(_ data: Data) throws -> [EmailFullMessage] {
        let response = try JSONDecoder().decode(BatchFetchResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP batch fetch failed")
        }
        return response.messages ?? []
    }

    /// Encodes search hits as the `email.search` tool output document.
    public static func encodeSearchEnvelope(
        account: String,
        query: String,
        messages: [EmailSearchHit],
        mailbox: String? = nil,
        mailboxes: [String]? = nil,
        accounts: [String]? = nil,
        failedAccounts: [String]? = nil
    ) throws -> String {
        let envelope = EmailSearchEnvelope(
            account: account,
            query: query,
            messages: messages,
            mailbox: mailbox,
            mailboxes: mailboxes,
            accounts: accounts,
            failedAccounts: failedAccounts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a message as the `email.read` tool output document.
    public static func encodeReadEnvelope(account: String, message: EmailFullMessage, mailbox: String = "INBOX") throws -> String {
        let envelope = EmailReadEnvelope(account: account, message: message, mailbox: mailbox)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Decodes a bridge `attachment` stdout payload.
    public static func parseAttachmentPayload(_ data: Data) throws -> EmailAttachmentData {
        let response: AttachmentResponse
        do {
            response = try JSONDecoder().decode(AttachmentResponse.self, from: data)
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP attachment fetch failed")
        }
        guard let payload = response.attachment else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no attachment")
        }
        if payload.contentBase64 == nil || payload.contentBase64?.isEmpty == true, payload.oversize == true {
            guard let reported = payload.sizeBytes else {
                throw EmailIMAPError.decodeFailed("IMAP bridge returned no attachment bytes")
            }
            return EmailAttachmentData(
                filename: payload.filename,
                contentType: payload.contentType,
                sizeBytes: reported,
                data: Data()
            )
        }
        guard let encoded = payload.contentBase64, !encoded.isEmpty else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no attachment bytes")
        }
        guard let bytes = Data(base64Encoded: encoded) else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned invalid base64")
        }
        if let reported = payload.sizeBytes, reported != bytes.count {
            throw EmailIMAPError.decodeFailed(
                "IMAP bridge size mismatch: reported \(reported) bytes but decoded \(bytes.count) bytes"
            )
        }
        let size = payload.sizeBytes ?? bytes.count
        return EmailAttachmentData(
            filename: payload.filename,
            contentType: payload.contentType,
            sizeBytes: size,
            data: bytes
        )
    }

    /// Encodes an attachment result as the `email.attachment` tool output document.
    public static func encodeAttachmentEnvelope(_ envelope: EmailAttachmentEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Bridge `append` response shape.
    struct AppendResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
    }

    /// Decodes a bridge `append` stdout payload.
    public static func parseAppendPayload(_ data: Data) throws {
        let response = try JSONDecoder().decode(AppendResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP append failed")
        }
    }
}
