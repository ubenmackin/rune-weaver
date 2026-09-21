// Rune Weaver Tools — Attachment file signature verification, executable blocking, and quarantine.

import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// Security validation for downloaded email attachments before staging or processing.
public enum AttachmentSecurity: Sendable {
    /// Result of an attachment security inspection.
    public enum Classification: Sendable, Equatable {
        /// Executable binary or script that should never be staged to the host.
        case executable(String)
        /// Archive or compound container format (e.g. ZIP, Office doc) that must detonate in a microVM.
        case archive(String)
        /// Validated image matching known image magic bytes.
        case image(String)
        /// Validated PDF document.
        case pdf
        /// Plaintext data.
        case text
        /// Other non-executable data.
        case other
    }

    /// Determines the security classification of the attachment data.
    public static func classify(data: Data, contentType: String = "", filename: String = "") -> Classification {
        let lowerFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Check for executable signatures (Mach-O, ELF, Windows PE, Shebang scripts)
        if let executableReason = detectedExecutable(data: data, filename: lowerFilename) {
            return .executable(executableReason)
        }

        // 2. Check for archive signatures (ZIP, GZIP, BZIP2, 7z, RAR, Office OpenXML)
        if let archiveFormat = detectedArchive(data: data, contentType: contentType, filename: lowerFilename) {
            return .archive(archiveFormat)
        }

        // 3. Check for valid image signatures
        if let imageFormat = detectedImage(data: data) {
            return .image(imageFormat)
        }

        // 4. Check for PDF signature
        if isPDF(data: data) {
            return .pdf
        }

        // 5. Check for text
        if isText(data: data, contentType: contentType, filename: lowerFilename) {
            return .text
        }

        return .other
    }

    /// Whether the attachment data is an executable or script.
    public static func isExecutable(data: Data, filename: String = "") -> Bool {
        detectedExecutable(data: data, filename: filename.lowercased()) != nil
    }

    /// Whether the attachment requires Tier-3 Apple Container microVM detonation.
    public static func requiresMicroVMDetonation(data: Data, contentType: String, filename: String) -> Bool {
        let lowerFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return detectedArchive(data: data, contentType: contentType, filename: lowerFilename) != nil
    }

    /// Validates whether data matches genuine image magic bytes.
    public static func isValidImage(data: Data) -> Bool {
        detectedImage(data: data) != nil
    }

    // MARK: - Signatures

    private static func detectedExecutable(data: Data, filename: String) -> String? {
        // High-risk executable extensions, blocked on name alone so plain-text
        // interpreter scripts and libraries without magic bytes still fail closed.
        let dangerousExtensions = [
            ".a", ".app", ".action", ".bat", ".bin", ".cjs", ".cmd", ".com",
            ".command", ".csh", ".dll", ".dylib", ".exe",
            ".gadget", ".inf", ".ins", ".inx", ".isu", ".job", ".js", ".jse", ".ksh",
            ".lua", ".mjs", ".msc", ".msi", ".msp", ".mst", ".o", ".paf", ".php",
            ".pif", ".pl", ".ps1", ".py", ".pyc", ".pyw", ".rb", ".reg",
            ".rgs", ".scpt", ".scr", ".sct", ".sh", ".so", ".u3p", ".vb", ".vbe",
            ".vbs", ".vbscript", ".workflow", ".ws", ".wsc", ".wsf", ".wsh"
        ]
        for ext in dangerousExtensions where filename.hasSuffix(ext) {
            return "File extension '\(ext)' is a restricted executable type"
        }

        guard data.count >= 2 else { return nil }

        // Shebang script: `#!`
        if data[0] == 0x23 && data[1] == 0x21 {
            return "Shell or script interpreter shebang ('#!') detected"
        }

        // Windows PE executable: `MZ`
        if data[0] == 0x4D && data[1] == 0x5A {
            return "Windows PE executable ('MZ') signature detected"
        }

        guard data.count >= 4 else { return nil }

        // Mach-O 32-bit: 0xFEEDFACE (big/little endian)
        if (data[0] == 0xFE && data[1] == 0xED && data[2] == 0xFA && data[3] == 0xCE) ||
            (data[0] == 0xCE && data[1] == 0xFA && data[2] == 0xED && data[3] == 0xFE)
        {
            return "macOS Mach-O 32-bit executable signature detected"
        }

        // Mach-O 64-bit: 0xFEEDFACF (big/little endian)
        if (data[0] == 0xFE && data[1] == 0xED && data[2] == 0xFA && data[3] == 0xCF) ||
            (data[0] == 0xCF && data[1] == 0xFA && data[2] == 0xED && data[3] == 0xFE)
        {
            return "macOS Mach-O 64-bit executable signature detected"
        }

        // Mach-O Universal / Fat Binary: 0xCAFEBABE or 0xBEBAFECA
        if (data[0] == 0xCA && data[1] == 0xFE && data[2] == 0xBA && data[3] == 0xBE) ||
            (data[0] == 0xBE && data[1] == 0xBA && data[2] == 0xFE && data[3] == 0xCA)
        {
            // Note: Java class files also start with 0xCAFEBABE, which are also compiled bytecode
            return "macOS Mach-O Universal Binary / Java bytecode signature detected"
        }

        // Linux ELF: 0x7F 'E' 'L' 'F'
        if data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46 {
            return "Linux ELF executable signature detected"
        }

        // Compiled AppleScript: `FasdUAS `
        if data.count >= 8 {
            if data[0] == 0x46, data[1] == 0x61, data[2] == 0x73, data[3] == 0x64 {
                return "Compiled AppleScript signature detected"
            }
        }

        return nil
    }

    /// Whether filename or MIME type alone marks the payload as an archive.
    /// Single source of truth for the filename/MIME archive table; magic-byte
    /// inspection layers on top inside `detectedArchive`, and lifecycle helpers
    /// delegate here so the tables cannot drift.
    public static func isArchiveFilenameOrMime(contentType: String, filename: String) -> Bool {
        archiveFilenameOrMimeReason(contentType: contentType, filename: filename) != nil
    }

    private static func archiveFilenameOrMimeReason(contentType: String, filename: String) -> String? {
        let baseMime = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        // Normalize here so direct callers and internal magic-byte routing share
        // case-insensitive matching without relying on caller normalization.
        let lowerFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let knownArchiveMimes = [
            "application/zip", "application/x-zip-compressed", "application/x-tar",
            "application/tar", "application/gzip", "application/x-gzip",
            "application/x-7z-compressed", "application/x-rar-compressed"
        ]
        if knownArchiveMimes.contains(baseMime) {
            return "mime: \(baseMime)"
        }

        let archiveExtensions = [
            ".zip", ".tar", ".tgz", ".tar.gz", ".tar.bz2", ".tbz", ".tbz2",
            ".gz", ".7z", ".rar", ".bz2", ".xz",
            // Office OpenXML and compound archive formats
            ".docx", ".docm", ".dotx", ".dotm",
            ".xlsx", ".xlsm", ".xltx", ".xltm",
            ".pptx", ".pptm", ".potx", ".potm",
            ".jar", ".war", ".ear"
        ]
        for ext in archiveExtensions where lowerFilename.hasSuffix(ext) {
            return "extension: \(ext)"
        }
        return nil
    }

    private static func detectedArchive(data: Data, contentType: String, filename: String) -> String? {
        if let reason = archiveFilenameOrMimeReason(contentType: contentType, filename: filename) {
            return reason
        }

        // Magic bytes inspection
        guard data.count >= 2 else { return nil }

        // GZIP: 0x1F 0x8B
        if data[0] == 0x1F, data[1] == 0x8B {
            return "gzip"
        }

        // BZIP2: 'B' 'Z' 'h'
        if data.count >= 3, data[0] == 0x42, data[1] == 0x5A, data[2] == 0x68 {
            return "bzip2"
        }

        guard data.count >= 4 else { return nil }

        // ZIP (including docx, xlsx, pptx, jar, apk): 'P' 'K' 0x03 0x04 or 'P' 'K' 0x05 0x06 (empty)
        if data[0] == 0x50, data[1] == 0x4B,
           (data[2] == 0x03 && data[3] == 0x04) || (data[2] == 0x05 && data[3] == 0x06)
        {
            return "zip"
        }

        // 7-Zip: '7' 'z' 0xBC 0xAF 0x27 0x1C
        if data.count >= 6,
           data[0] == 0x37, data[1] == 0x7A, data[2] == 0xBC,
           data[3] == 0xAF, data[4] == 0x27, data[5] == 0x1C
        {
            return "7z"
        }

        // RAR: 'R' 'a' 'r' '!' 0x1A 0x07
        if data.count >= 6,
           data[0] == 0x52, data[1] == 0x61, data[2] == 0x72,
           data[3] == 0x21, data[4] == 0x1A, data[5] == 0x07
        {
            return "rar"
        }

        // TAR: 'ustar' at offset 257
        if data.count >= 262 {
            if data[257] == 0x75, data[258] == 0x73, data[259] == 0x74,
               data[260] == 0x61, data[261] == 0x72
            {
                return "tar"
            }
        }

        return nil
    }

    private static func detectedImage(data: Data) -> String? {
        guard data.count >= 3 else { return nil }

        // JPEG: 0xFF 0xD8 0xFF
        if data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return "jpeg"
        }

        // PNG: 0x89 'P' 'N' 'G' 0x0D 0x0A 0x1A 0x0A
        if data.count >= 8,
           data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47,
           data[4] == 0x0D, data[5] == 0x0A, data[6] == 0x1A, data[7] == 0x0A
        {
            return "png"
        }

        // GIF: 'G' 'I' 'F' '8' ('7' or '9') 'a'
        if data.count >= 6,
           data[0] == 0x47, data[1] == 0x49, data[2] == 0x46, data[3] == 0x38,
           data[4] == 0x37 || data[4] == 0x39, data[5] == 0x61
        {
            return "gif"
        }

        // WebP: 'R' 'I' 'F' 'F' ... 'W' 'E' 'B' 'P'
        if data.count >= 12,
           data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50
        {
            return "webp"
        }

        // TIFF: 'I' 'I' 0x2A 0x00 (little-endian) or 'M' 'M' 0x00 0x2A (big-endian)
        if data.count >= 4 {
            if (data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A && data[3] == 0x00) ||
                (data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x00 && data[3] == 0x2A)
            {
                return "tiff"
            }
        }

        // BMP: 'B' 'M'
        if data[0] == 0x42, data[1] == 0x4D {
            return "bmp"
        }

        // ISO Base Media File Format (HEIC, HEIF, AVIF): 'f' 't' 'y' 'p' at byte 4
        if data.count >= 12,
           data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70
        {
            let brand = String(bytes: data[8 ..< 12], encoding: .ascii)?.lowercased() ?? ""
            if brand.contains("heic") || brand.contains("heix") || brand.contains("mif1") ||
                brand.contains("avif") || brand.contains("msf1")
            {
                return "heif"
            }
        }

        return nil
    }

    private static func isPDF(data: Data) -> Bool {
        // PDF: `%PDF-`
        guard data.count >= 5 else { return false }
        return data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46 && data[4] == 0x2D
    }

    private static func isText(data: Data, contentType: String, filename: String) -> Bool {
        let isTextMime = contentType.hasPrefix("text/") || contentType == "application/json" || contentType == "text/csv"
        let isTextExt = filename.hasSuffix(".txt") || filename.hasSuffix(".md") || filename.hasSuffix(".json") ||
            filename.hasSuffix(".csv") || filename.hasSuffix(".log") || filename.hasSuffix(".xml")
        guard isTextMime || isTextExt else { return false }
        // Verify valid UTF-8
        return String(data: data, encoding: .utf8) != nil
    }

    // MARK: - Quarantine

    /// Applies the macOS `com.apple.quarantine` extended attribute to the staged file.
    public static func applyQuarantine(to url: URL, source: String = "RuneWeaver") {
        #if canImport(Darwin)
            let cPath = url.path
            // Format: flag;timestamp;agent_name;UUID
            let uuid = UUID().uuidString
            let timestampHex = String(format: "%08x", Int(Date().timeIntervalSince1970))
            let value = "0081;\(timestampHex);\(source);\(uuid)"
            _ = value.withCString { cValue in
                setxattr(cPath, "com.apple.quarantine", cValue, strlen(cValue), 0, 0)
            }
        #endif
    }
}
