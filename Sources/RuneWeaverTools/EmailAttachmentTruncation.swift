// Rune Weaver Tools — Email attachment size-cap truncation helpers.
//
// Isolates the shared byte and character bounds for staged downloads so the
// attachment tool stays focused on orchestration while inline payload shaping
// lives in one place without touching the network or filesystem.

import Foundation
import RuneWeaverCore

extension EmailAttachmentTool {
    /// Builds the skip note for an oversized part.
    /// - Parameter sizeBytes: Decoded size of the skipped part.
    /// - Returns: Human-readable note naming the size cap.
    public static func oversizeNote(sizeBytes: Int) -> String {
        "Attachment skipped: \(sizeBytes) bytes exceeds the 10 MB download cap."
    }

    /// Decodes bytes as UTF-8 and truncates to the shared preview char cap.
    ///
    /// A 10 MB document would otherwise flood the model context; bounding
    /// `extractedText` to the same 2000-char window as `preview` keeps inline
    /// payloads predictable, with the truncation surfaced via the envelope
    /// note so callers know to use `files.read` or `saveToPath` for the rest.
    /// - Parameter data: Raw attachment or archive-entry bytes.
    /// - Returns: Capped text plus whether truncation occurred, or nil when the bytes are not UTF-8 text.
    static func cappedExtractedText(for data: Data) -> (text: String, truncated: Bool)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.count > EmailAttachmentLifecycle.maxPreviewChars {
            return (String(text.prefix(EmailAttachmentLifecycle.maxPreviewChars)), true)
        }
        return (text, false)
    }

    /// Encodes image bytes as vision Base64 unless over the vision cap.
    ///
    /// Oversized images stay staged/export-only so a multi-megabyte photo
    /// cannot balloon the tool output; the caller falls back to `files.read`
    /// or `saveToPath` for the full bytes.
    /// - Parameter data: Raw image bytes.
    /// - Returns: Base64 payload, or nil when over the vision cap.
    static func cappedVisionBase64(for data: Data) -> String? {
        guard data.count <= maxVisionBytes else { return nil }
        return data.base64EncodedString()
    }

    /// Rejects control bytes in an export destination before policy checks.
    ///
    /// Keeps header-injection payloads out even when the workspace guard
    /// would deny them anyway, so malformed input reports a field error
    /// before any account lookup or credential resolution.
    /// - Parameter path: Trimmed candidate destination.
    /// - Throws: Failure when the path is empty or holds CR, LF, or NUL.
    static func validateSaveToPathSyntax(_ path: String) throws {
        guard !path.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid saveToPath: path must not be empty")
        }
        if path.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 || $0.value == 0 }) {
            throw EmailIMAPError.bridgeFailed("Invalid saveToPath: path must not contain CR, LF, or NUL")
        }
    }
}
