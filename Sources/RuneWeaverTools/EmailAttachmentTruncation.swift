// Rune Weaver Tools — Email attachment size-cap truncation helpers.

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
    static func cappedExtractedText(for data: Data) -> (text: String, truncated: Bool)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.count > EmailAttachmentLifecycle.maxPreviewChars {
            return (String(text.prefix(EmailAttachmentLifecycle.maxPreviewChars)), true)
        }
        return (text, false)
    }

    /// Encodes image bytes as vision Base64 unless over the vision cap.
    static func cappedVisionBase64(for data: Data) -> String? {
        guard data.count <= maxVisionBytes else { return nil }
        return data.base64EncodedString()
    }

    /// Rejects control bytes in an export destination before policy checks.
    static func validateSaveToPathSyntax(_ path: String) throws {
        guard !path.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid saveToPath: path must not be empty")
        }
        if path.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 || $0.value == 0 }) {
            throw EmailIMAPError.bridgeFailed("Invalid saveToPath: path must not contain CR, LF, or NUL")
        }
    }
}
