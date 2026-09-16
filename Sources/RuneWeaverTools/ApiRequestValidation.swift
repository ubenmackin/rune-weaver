// Rune Weaver Tools — Validation and output policy for constrained API requests.
//
// Holds the header allowlist with secret redaction, body and output caps, and
// content classification for `api.request`, single-sourced so the tool chain
// and the fetch classifier cannot diverge on what counts as text.

import Foundation

/// Header allowlist and secret redaction for `api.request`.
public enum ApiHeaderPolicy: Sendable {
    /// Lowercased header names the model may supply.
    public static let allowedHeaders: Set<String> = ["accept", "content-type", "authorization"]
    /// Placeholder standing in for the secret in logs and previews.
    public static let redactedPlaceholder = "[redacted]"

    /// Whether a header name is on the allowlist (case-insensitive).
    /// - Parameter name: Raw header name.
    /// - Returns: True for `Accept`, `Content-Type`, or `Authorization`.
    public static func isAllowed(_ name: String) -> Bool {
        allowedHeaders.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Validates model-supplied headers against the allowlist.
    public static func validated(_ headers: [String: String]?) throws -> [String: String] {
        guard let headers, !headers.isEmpty else { return [:] }
        var checked: [String: String] = [:]
        checked.reserveCapacity(headers.count)
        for (name, value) in headers {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw ApiRequestError.invalidHeaders("Invalid api.request headers: header name must not be empty.")
            }
            guard isAllowed(trimmedName) else {
                throw ApiRequestError.invalidHeaders("Unsupported header '\(trimmedName)': only Accept, Content-Type, and Authorization are allowed.")
            }
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else {
                throw ApiRequestError.invalidHeaders("Invalid header '\(trimmedName)': value must not be empty.")
            }
            if trimmedValue.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
                throw ApiRequestError.invalidHeaders("Invalid header '\(trimmedName)': value must not contain CR or LF.")
            }
            checked[trimmedName] = trimmedValue
        }
        return checked
    }

    /// Redacts the secret for logs and preview envelopes.
    public static func redacted(_ headers: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(headers.count)
        for (name, value) in headers {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "authorization" {
                sanitized[name] = redactedPlaceholder
            } else {
                sanitized[name] = value
            }
        }
        return sanitized
    }

    /// Single-line log-safe header summary with the secret already redacted.
    /// - Parameter headers: Validated headers.
    /// - Returns: Compact `Name:value` pairs joined by commas, or `(none)`.
    public static func logSummary(_ headers: [String: String]) -> String {
        let sanitized = redacted(headers)
        guard !sanitized.isEmpty else { return "(none)" }
        return sanitized.sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ", ")
    }
}

/// Typed validation failures that never echo secrets.
public enum ApiRequestError: Error, Sendable, Equatable {
    /// Arguments failed to decode or named an unknown method.
    case invalidArguments(String)
    /// A header fell outside the allowlist or held CR/LF.
    case invalidHeaders(String)
    /// The URL failed the shared allowlist or the SSRF guard.
    case unsafeURL(String)
    /// The request body exceeded the 64KB cap.
    case bodyTooLarge(String)

    /// Human-readable message without secret values.
    public var message: String {
        switch self {
        case let .invalidArguments(detail): detail
        case let .invalidHeaders(detail): detail
        case let .unsafeURL(detail): detail
        case let .bodyTooLarge(detail): detail
        }
    }
}

extension ApiRequestError: LocalizedError {
    /// Returns `message` for display.
    public var errorDescription: String? {
        message
    }
}

/// Pure validation for API bodies, output caps, and content classification.
public enum ApiRequestValidation: Sendable {
    /// Maximum request body bytes accepted (64KB).
    public static let maxBodyBytes = 64 * 1024
    /// Maximum response bytes retained per call (256KB).
    public static let maxOutputBytes = 256 * 1024
    /// Characters of request body previewed in approval targets.
    public static let maxBodyPreviewChars = 200
    /// Characters of request body previewed in dry-run envelopes.
    public static let maxDryRunPreviewChars = 2000

    /// Validates a request body against the 64KB cap.
    public static func validateBody(_ body: String?) throws {
        guard let body, !body.isEmpty else { return }
        guard body.utf8.count <= maxBodyBytes else {
            throw ApiRequestError.bodyTooLarge("Invalid api.request body: exceeds the 64KB body cap (\(body.utf8.count) bytes).")
        }
    }

    /// Collapses a body to a single-line preview for approvals and dry runs.
    public static func bodyPreview(_ body: String, limit: Int = maxBodyPreviewChars) -> String {
        let single = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > limit else { return single }
        return String(single.prefix(limit))
    }

    /// Whether a MIME type carries inlineable text.
    public static func isTextContentType(_ mimeType: String) -> Bool {
        let lowered = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty {
            return true
        }
        if lowered.hasPrefix("text/") {
            return true
        }
        if lowered.contains("json") || lowered.contains("xml") {
            return true
        }
        if lowered == "application/xhtml+xml" || lowered == "application/javascript" {
            return true
        }
        return false
    }

    /// Truncates decoded text to the output budget.
    public static func truncateForOutput(_ text: String) -> (String, Bool) {
        let cap = maxOutputBytes
        let bytes = text.utf8.count
        guard bytes > cap else { return (text, false) }
        var prefix = String(text.prefix(cap))
        while !prefix.isEmpty, prefix.utf8.count > cap {
            prefix = String(prefix.dropLast())
        }
        return (prefix, true)
    }

    /// Derives a download filename without touching the filesystem.
    public static func downloadFilename(for url: URL, contentDisposition: String?) -> String {
        if let header = contentDisposition?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
            for part in header.split(separator: ";") {
                let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = piece.lowercased()
                if lowered.hasPrefix("filename*=") {
                    var value = String(piece.dropFirst("filename*=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let encodedRange = value.range(of: "''") {
                        value = String(value[encodedRange.upperBound...])
                    }
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !value.isEmpty {
                        return value.removingPercentEncoding ?? value
                    }
                } else if lowered.hasPrefix("filename=") {
                    var value = String(piece.dropFirst("filename=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !value.isEmpty {
                        return value
                    }
                }
            }
        }
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, last != "/" {
            return last
        }
        return "download"
    }
}
