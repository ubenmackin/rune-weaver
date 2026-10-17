// Rune Weaver Core — Local document text extraction for the retrieval index.

import Foundation
import os
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

// MARK: - Public types

/// Document family recognized by ``DocumentTextExtractor``.
public enum DocumentFormat: String, Sendable, Codable, Equatable, CaseIterable {
    /// Portable Document Format.
    case pdf
    /// Office Open XML word-processing document.
    case docx
    /// Office Open XML spreadsheet.
    case xlsx
    /// Office Open XML presentation.
    case pptx
    /// Apple Pages package.
    case pages
    /// Apple Numbers package.
    case numbers
    /// Apple Keynote package.
    case keynote
    /// Rich Text Format (.rtf).
    case rtf
    /// Plain text such as `.txt`, `.text`, or `.log`.
    case plainText
    /// Markdown source.
    case markdown
    /// Comma-separated values.
    case csv
    /// JSON document.
    case json
    /// RFC 822 email message.
    case eml
    /// Hypertext Markup Language.
    case html
    /// Image document (PNG, JPEG, HEIC, TIFF, WebP).
    case image
    /// Audio file (MP3, M4A, WAV, AAC, FLAC).
    case audio
    /// Video file (MP4, MOV, M4V).
    case video
    /// Format outside the supported set.
    case unsupported
}

/// One bounded slice of extracted document text.
public struct DocumentChunk: Sendable, Equatable {
    /// Zero-based position of this chunk in extraction order.
    public let index: Int
    /// Chunk text with folded line endings, collapsed space runs, and preserved tabs.
    public let text: String
    /// Estimated token count using the shared ~4 characters-per-token rule of thumb.
    public let estimatedTokens: Int

    /// Creates a document chunk. index: Zero-based position in extraction order.
    public init(index: Int, text: String, estimatedTokens: Int) {
        self.index = index
        self.text = text
        self.estimatedTokens = estimatedTokens
    }
}

/// Result of extracting text from one document.
public struct DocumentExtraction: Sendable, Equatable {
    /// How completely the body was extracted, using the shared index ``ExtractStatus``: clean
    /// success is `.extracted`, best-effort iWork or a source past the byte bound is `.partial`, an
    /// empty text layer is `.metadataOnly` for the vision path, an unknown format is `.unsupported`.
    public let status: ExtractStatus
    /// Recognized format family, or `.unsupported` when dispatch failed.
    public let format: DocumentFormat
    /// Extracted chunks in reading order (empty unless status is `.extracted` or `.partial`).
    public let chunks: [DocumentChunk]
    /// Human-readable explanation for non-`.extracted` outcomes; nil on clean success.
    public let reason: String?
    /// Bytes considered, bounded by the configured cap.
    public let byteCount: Int
    /// Whether the byte cap or an internal bound shortened the extraction.
    public let truncated: Bool

    /// Creates a document extraction result. status: Outcome classification.
    public init(
        status: ExtractStatus,
        format: DocumentFormat,
        chunks: [DocumentChunk],
        reason: String?,
        byteCount: Int,
        truncated: Bool
    ) {
        self.status = status
        self.format = format
        self.chunks = chunks
        self.reason = reason
        self.byteCount = byteCount
        self.truncated = truncated
    }

    /// Full extracted text joined from chunks with blank-line separators.
    public var text: String {
        chunks.map(\.text).joined(separator: "\n\n")
    }
}

/// Protocol seam for document text extraction so an indexer can inject a stub.
public protocol DocumentTextExtracting: Sendable {
    /// Extracts text from raw document bytes. data: Raw document bytes.
    func extract(data: Data, fileName: String, contentType: String?) -> DocumentExtraction

    /// Extracts text from a file URL asynchronously. fileURL: Document file
    /// location on disk.
    func extract(fileURL: URL, contentType: String?) async -> DocumentExtraction
}

extension DocumentTextExtracting {
    /// Default async extraction from file URL delegating to data extraction.
    public func extract(fileURL: URL, contentType: String? = nil) async -> DocumentExtraction {
        let fileName = fileURL.lastPathComponent
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return DocumentExtraction(
                status: .failed,
                format: .unsupported,
                chunks: [],
                reason: "Could not read file at \(fileURL.path)",
                byteCount: 0,
                truncated: false
            )
        }
        return extract(data: data, fileName: fileName, contentType: contentType)
    }
}

// MARK: - Extractor

/// Dispatches by file extension or content type and extracts bounded text chunks.
public struct DocumentTextExtractor: DocumentTextExtracting {
    /// Default byte bound for one document (25 MB).
    public static let defaultMaxFileBytes = 25 * 1024 * 1024
    /// Default target tokens per chunk (about 512).
    public static let defaultChunkTokenBudget = 512
    /// Default token overlap between adjacent chunks (about 64).
    public static let defaultChunkOverlapTokens = 64

    /// Byte bound applied before any parsing; larger documents return `.partial`.
    public let maxFileBytes: Int
    /// Target token budget per chunk.
    public let chunkTokenBudget: Int
    /// Token overlap carried from the tail of one chunk into the next.
    public let chunkOverlapTokens: Int

    /// Creates an extractor with an explicit byte bound and chunk sizing.
    /// maxFileBytes: Byte bound applied before parsing.
    public init(
        maxFileBytes: Int = defaultMaxFileBytes,
        chunkTokenBudget: Int = defaultChunkTokenBudget,
        chunkOverlapTokens: Int = defaultChunkOverlapTokens
    ) {
        self.maxFileBytes = max(1, maxFileBytes)
        let budget = max(1, chunkTokenBudget)
        self.chunkTokenBudget = budget
        self.chunkOverlapTokens = max(0, min(chunkOverlapTokens, budget / 2))
    }

    /// Extracts text using the file name alone for format dispatch. data: Raw
    /// document bytes.
    public func extract(data: Data, fileName: String) -> DocumentExtraction {
        extract(data: data, fileName: fileName, contentType: nil)
    }

    /// Extracts text from a file URL, applying the byte bound before reading. The size check runs
    /// before the bytes are loaded so an oversized document never spends memory on the read.
    public func extract(fileURL: URL, contentType: String? = nil) async -> DocumentExtraction {
        let fileName = fileURL.lastPathComponent
        let format = Self.detectFormat(fileName: fileName, contentType: contentType)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let isMedia = format == .audio || format == .video
        if !isMedia, let size, size > maxFileBytes {
            return makeResult(
                status: .partial,
                format: format,
                reason: "Document is \(size) bytes and exceeds the \(maxFileBytes)-byte extraction bound.",
                byteCount: size,
                truncated: true
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            RuneWeaverLog.stores.warning("DocumentTextExtractor: failed to read '\(fileName)' at \(fileURL.path): \(error.localizedDescription)")
            return makeResult(
                status: .failed,
                format: format,
                reason: "The document at '\(fileName)' could not be read: \(error.localizedDescription).",
                byteCount: 0
            )
        }
        if format == .audio || format == .video {
            let transcript = await (try? MediaTextExtractor.transcribeAudio(fileURL: fileURL))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !transcript.isEmpty {
                return makeTextResult(
                    text: transcript,
                    format: format,
                    byteCount: (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count,
                    missingReason: "The media contains no extractable speech transcript."
                )
            }
            // The file-backed path attempted on-device transcription and found nothing, so this
            // reason honestly reports an attempt was made.
            return makeResult(
                status: .metadataOnly,
                format: format,
                reason: "Audio/video media: stored metadata-only; on-device speech transcription detected no speech.",
                byteCount: data.count
            )
        }
        return extract(data: data, fileName: fileName, contentType: contentType)
    }

    /// Extracts text from raw bytes, dispatching on extension then content type.
    /// data: Raw document bytes.
    public func extract(data: Data, fileName: String, contentType: String?) -> DocumentExtraction {
        let format = Self.detectFormat(fileName: fileName, contentType: contentType)
        guard data.count <= maxFileBytes else {
            return makeResult(
                status: .partial,
                format: format,
                reason: "Document is \(data.count) bytes and exceeds the \(maxFileBytes)-byte extraction bound.",
                byteCount: data.count,
                truncated: true
            )
        }
        switch format {
        case .plainText, .markdown, .csv, .json, .eml:
            return makeTextResult(
                text: Self.decodeText(data),
                format: format,
                byteCount: data.count,
                missingReason: "The document contains no extractable text."
            )
        case .html:
            return makeTextResult(
                text: Self.plainTextFromHTML(Self.decodeText(data) ?? ""),
                format: .html,
                byteCount: data.count,
                missingReason: "The HTML document contains no extractable text."
            )
        case .rtf:
            return extractRTF(data: data)
        case .pdf:
            return extractPDF(data: data)
        case .docx:
            return extractDOCX(data: data)
        case .xlsx:
            return extractXLSX(data: data)
        case .pptx:
            return extractPPTX(data: data)
        case .pages, .numbers, .keynote:
            return extractIWork(data: data, format: format, fileName: fileName)
        case .image:
            let ocrText = MediaTextExtractor.recognizeTextSync(in: data)
            let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return makeTextResult(
                    text: trimmed,
                    format: .image,
                    byteCount: data.count,
                    missingReason: "The image contains no extractable text."
                )
            } else {
                // OCR found no text, so extraction stays interim: callers attempt
                // visual embedding separately and promote to `.extracted` only
                // after it succeeds, instead of claiming visual work up front.
                let fallbackText = fileName.isEmpty ? "Image" : fileName
                let tokens = max(1, fallbackText.count / 4)
                return makeResult(
                    status: .partial,
                    format: .image,
                    chunks: [DocumentChunk(index: 0, text: fallbackText, estimatedTokens: tokens)],
                    reason: "Image contains no OCR text; visual embedding pending.",
                    byteCount: data.count
                )
            }
        case .audio, .video:
            // Bytes-only extraction cannot reach the async on-device recognizer,
            // so the reason honestly reports that transcription requires on-disk file URL.
            return makeResult(
                status: .metadataOnly,
                format: format,
                reason: "Audio/video media: stored metadata-only; speech transcription requires on-disk file URL.",
                byteCount: data.count
            )
        case .unsupported:
            return makeResult(
                status: .unsupported,
                format: .unsupported,
                reason: "Unsupported document format.",
                byteCount: data.count
            )
        }
    }

    /// Extracts text from Rich Text Format (RTF) data.
    private func extractRTF(data: Data) -> DocumentExtraction {
        #if canImport(AppKit)
            if let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
                return makeTextResult(
                    text: text,
                    format: .rtf,
                    byteCount: data.count,
                    missingReason: "The RTF document contains no extractable text."
                )
            }
        #endif
        return makeTextResult(
            text: Self.decodeText(data),
            format: .rtf,
            byteCount: data.count,
            missingReason: "The RTF document contains no extractable text."
        )
    }

    /// Builds a result with explicit fields. status: Outcome classification.
    func makeResult(
        status: ExtractStatus,
        format: DocumentFormat,
        chunks: [DocumentChunk] = [],
        reason: String? = nil,
        byteCount: Int,
        truncated: Bool = false
    ) -> DocumentExtraction {
        DocumentExtraction(
            status: status,
            format: format,
            chunks: chunks,
            reason: reason,
            byteCount: byteCount,
            truncated: truncated
        )
    }

    /// Normalizes decoded text and chunks it, or reports `metadataOnly` when blank.
    /// text: Decoded text, or nil when decoding failed.
    func makeTextResult(
        text: String?,
        format: DocumentFormat,
        byteCount: Int,
        missingReason: String
    ) -> DocumentExtraction {
        guard let normalized = Self.normalizedExtractedText(text ?? "") else {
            return makeResult(status: .metadataOnly, format: format, reason: missingReason, byteCount: byteCount)
        }
        let chunks = makeChunks(from: normalized)
        guard !chunks.isEmpty else {
            return makeResult(status: .metadataOnly, format: format, reason: missingReason, byteCount: byteCount)
        }
        return makeResult(status: .extracted, format: format, chunks: chunks, byteCount: byteCount)
    }

    /// Splits normalized text into ~budget-sized chunks with tail overlap.
    func makeChunks(from text: String) -> [DocumentChunk] {
        let characterBudget = max(1, chunkTokenBudget * Int(Self.charactersPerToken))
        let overlapCharacters = max(0, min(chunkOverlapTokens * Int(Self.charactersPerToken), characterBudget / 2))
        let segments = Self.chunkSegments(from: text, characterBudget: characterBudget)
        guard !segments.isEmpty else { return [] }

        var chunkTexts: [String] = []
        var current: [String] = []
        var currentLength = 0
        for segment in segments {
            let separatorLength = current.isEmpty ? 0 : 1
            if !current.isEmpty, currentLength + separatorLength + segment.count > characterBudget {
                let chunkText = current.joined(separator: "\n")
                chunkTexts.append(chunkText)
                let overlapLength = min(overlapCharacters, chunkText.count / 2)
                current = overlapLength > 0 ? [String(chunkText.suffix(overlapLength))] : []
                currentLength = overlapLength
            }
            current.append(segment)
            currentLength += (current.count > 1 ? 1 : 0) + segment.count
        }
        if !current.isEmpty {
            chunkTexts.append(current.joined(separator: "\n"))
        }

        return chunkTexts.enumerated().map { index, chunkText in
            DocumentChunk(index: index, text: chunkText, estimatedTokens: Self.estimatedTokens(in: chunkText))
        }
    }
}

// MARK: - Format dispatch

extension DocumentTextExtractor {
    /// Extension-to-format map used for primary dispatch and fallback.
    fileprivate static let formatByExtension: [String: DocumentFormat] = [
        "pdf": .pdf,
        "docx": .docx,
        "xlsx": .xlsx,
        "pptx": .pptx,
        "pages": .pages,
        "numbers": .numbers,
        "key": .keynote,
        "keynote": .keynote,
        "rtf": .rtf,
        "txt": .plainText,
        "text": .plainText,
        "log": .plainText,
        "md": .markdown,
        "markdown": .markdown,
        "csv": .csv,
        "json": .json,
        "eml": .eml,
        "html": .html,
        "htm": .html,
        "png": .image,
        "jpg": .image,
        "jpeg": .image,
        "heic": .image,
        "heif": .image,
        "tiff": .image,
        "tif": .image,
        "webp": .image,
        "mp3": .audio,
        "m4a": .audio,
        "wav": .audio,
        "aac": .audio,
        "flac": .audio,
        "mp4": .video,
        "mov": .video,
        "m4v": .video
    ]

    /// MIME type and UTI-to-format map used when the extension is unknown.
    fileprivate static let formatByContentType: [String: DocumentFormat] = [
        "application/pdf": .pdf,
        "com.adobe.pdf": .pdf,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .docx,
        "org.openxmlformats.wordprocessingml.document": .docx,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": .xlsx,
        "org.openxmlformats.spreadsheetml.sheet": .xlsx,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": .pptx,
        "org.openxmlformats.presentationml.presentation": .pptx,
        "com.apple.iwork.pages.pages": .pages,
        "com.apple.iwork.numbers.numbers": .numbers,
        "com.apple.iwork.keynote.key": .keynote,
        "public.rtf": .rtf,
        "text/rtf": .rtf,
        "application/rtf": .rtf,
        "public.plain-text": .plainText,
        "text/plain": .plainText,
        "net.daringfireball.markdown": .markdown,
        "text/markdown": .markdown,
        "public.comma-separated-values-text": .csv,
        "text/csv": .csv,
        "public.json": .json,
        "application/json": .json,
        "public.html": .html,
        "text/html": .html,
        "message/rfc822": .eml,
        "public.email-message": .eml,
        "image/png": .image,
        "image/jpeg": .image,
        "image/heic": .image,
        "image/tiff": .image,
        "image/webp": .image,
        "audio/mpeg": .audio,
        "audio/mp4": .audio,
        "audio/wav": .audio,
        "audio/x-m4a": .audio,
        "video/mp4": .video,
        "video/quicktime": .video
    ]

    /// Developer source code and configuration extensions recognized from DigUp catalog.
    fileprivate static let developerCodeExtensions: Set<String> = [
        "py", "pyi", "pyx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm",
        "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "go", "rs",
        "java", "kt", "kts", "scala", "groovy", "rb", "php", "cs", "fs",
        "sh", "bash", "zsh", "fish", "ps1", "lua", "pl", "pm", "r", "jl", "dart",
        "sql", "vue", "svelte", "astro", "css", "scss", "sass", "less",
        "gradle", "cmake", "mk", "proto", "graphql", "gql", "tf", "hcl",
        "nix", "zig", "hs", "ex", "exs", "erl", "clj", "cljs", "elm", "ml", "mli",
        "vim", "el", "lisp", "asm", "s", "metal", "glsl", "hlsl", "wgsl", "cu", "cuh",
        "ino", "v", "sv", "tex", "toml", "yaml", "yml", "xml", "plist",
        "ini", "cfg", "conf", "lock", "rst", "adoc", "org", "txt", "text", "log"
    ]

    /// Known developer filenames without file extensions.
    fileprivate static let developerCodeFileNames: Set<String> = [
        "makefile", "gnumakefile", "dockerfile", "containerfile", "justfile",
        "rakefile", "gemfile", "podfile", "brewfile", "procfile", "vagrantfile", "jenkinsfile"
    ]

    /// Security & archive guard: checks whether a file is a credential/secret or unsafe archive.
    public static func isSecretOrUnsafeFile(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let fileExtension = (lower as NSString).pathExtension

        let secretExtensions: Set = [
            "pem", "key", "p12", "pfx", "keystore", "jks", "ppk", "kdbx", "gpg", "asc",
            "crt", "cer", "der", "p8", "mobileprovision"
        ]
        if secretExtensions.contains(fileExtension) {
            return true
        }

        let secretPrefixes = [
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", "secret", "credential",
            ".netrc", ".npmrc", ".pypirc", "htpasswd", ".htpasswd"
        ]
        if secretPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let unsafeArchiveExtensions: Set = [
            "zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz",
            "exe", "dmg", "pkg", "app", "bin", "iso"
        ]
        if unsafeArchiveExtensions.contains(fileExtension) {
            return true
        }

        return false
    }

    /// Resolves explicit primary document formats from extension.
    private static func detectPrimaryDocumentFormat(fileExtension: String) -> DocumentFormat? {
        switch fileExtension {
        case "pdf": .pdf
        case "docx": .docx
        case "xlsx": .xlsx
        case "pptx": .pptx
        case "pages": .pages
        case "numbers": .numbers
        case "key", "keynote": .keynote
        case "md", "markdown": .markdown
        case "csv": .csv
        case "json": .json
        case "eml": .eml
        case "html", "htm": .html
        case "rtf": .rtf
        default: nil
        }
    }

    #if canImport(UniformTypeIdentifiers)
        /// Resolves document format from Apple UTType conformance.
        private static func detectUTTypeFormat(_ utType: UTType) -> DocumentFormat? {
            if utType.conforms(to: .image) {
                return .image
            }
            if utType.conforms(to: .audio) {
                return .audio
            }
            if utType.conforms(to: .movie) {
                return .video
            }
            if utType.conforms(to: .sourceCode) || utType.conforms(to: .plainText) {
                return .plainText
            }
            if utType.conforms(to: .pdf) {
                return .pdf
            }
            if utType.conforms(to: .rtf) {
                return .rtf
            }
            if utType.conforms(to: .html) {
                return .html
            }
            if utType.conforms(to: .json) {
                return .json
            }
            return nil
        }
    #endif

    /// Reports whether an extension belongs to the media routing allowlist for its
    /// family, the single gate keeping removed containers out of OCR and speech lanes.
    private static func isAllowlistedMediaExtension(_ fileExtension: String, format: DocumentFormat) -> Bool {
        switch format {
        case .image:
            MediaTextExtractor.supportedImageExtensions.contains(fileExtension)
        case .audio:
            MediaTextExtractor.supportedAudioExtensions.contains(fileExtension)
        case .video:
            MediaTextExtractor.supportedVideoExtensions.contains(fileExtension)
        default:
            true
        }
    }

    /// Resolves document format from MIME type or UTI string.
    private static func detectContentTypeFormat(_ contentType: String) -> DocumentFormat? {
        let normalized = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let format = formatByContentType[normalized] {
            return format
        }
        if let base = normalized.split(separator: ";").first.map(String.init),
           let format = formatByContentType[base]
        {
            return format
        }
        #if canImport(UniformTypeIdentifiers)
            if let resolvedType = UTType(mimeType: normalized) ?? UTType(normalized),
               let format = detectUTTypeFormat(resolvedType)
            {
                // Media dispatch is extension-allowlist only; the MIME fallback
                // must never re-admit a removed container.
                guard format != .image, format != .audio, format != .video else { return nil }
                return format
            }
        #endif
        return nil
    }

    /// Resolves document format using the 3-Tier Classification Model: Tier 1: Security & Archive
    /// Guard (fail-closed on secrets and archives).
    public static func detectFormat(fileName: String, contentType: String? = nil) -> DocumentFormat {
        // Tier 1: Security & Archive Guard (Fail Closed)
        if isSecretOrUnsafeFile(fileName: fileName) {
            return .unsupported
        }

        let lowerName = fileName.lowercased()
        let fileExtension = (lowerName as NSString).pathExtension

        // DigUp known developer text file names without extension
        if developerCodeFileNames.contains(lowerName) || lowerName.hasPrefix("dockerfile") {
            return .plainText
        }

        // Explicit primary document formats
        if let format = detectPrimaryDocumentFormat(fileExtension: fileExtension) {
            return format
        }

        // Developer Code & Config catalog (mapped before UTType to avoid
        // macOS Spotlight treating .ts / .mts / etc. as movie/video)
        if developerCodeExtensions.contains(fileExtension) {
            return .plainText
        }

        // Tier 2: Apple UniformTypeIdentifiers (UTType) Conformance
        #if canImport(UniformTypeIdentifiers)
            if !fileExtension.isEmpty, let utType = UTType(filenameExtension: fileExtension),
               let format = detectUTTypeFormat(utType)
            {
                // Media families admit allowlisted extensions only; anything
                // else fails closed instead of reaching OCR or transcription.
                if format == .image || format == .audio || format == .video,
                   !Self.isAllowlistedMediaExtension(fileExtension, format: format)
                {
                    return .unsupported
                }
                return format
            }
        #endif

        // Fallback to static mapping by extension
        if let format = formatByExtension[fileExtension] {
            return format
        }

        // Content type / MIME dispatch
        if let contentType, let format = detectContentTypeFormat(contentType) {
            return format
        }
        return .unsupported
    }
}
