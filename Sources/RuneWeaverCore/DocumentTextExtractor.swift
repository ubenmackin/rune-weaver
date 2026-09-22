// Rune Weaver Core — Local document text extraction for the retrieval index.
//
// Turns supported local documents into bounded, overlapping text chunks plus an
// honest status so an indexer can store searchable content without ever throwing
// on an unknown or malformed file. Extraction is read-only and network-free:
// office and iWork packages are opened as in-memory ZIP archives, PDFs use the
// native text layer, and everything else falls back to plain-text or
// tag-stripped decoding. An empty text layer reports `metadataOnly` so the caller
// can route the original bytes to a vision path instead of silently indexing
// nothing. The byte bound is injected by the caller so the extractor never reads
// past the indexer's configured `max_file_bytes` policy.
// Format-specific extraction lives in `DocumentOfficeExtraction.swift`, shared
// decoding in `DocumentTextParsing.swift` and `DocumentXMLEntities.swift`, and
// ZIP reading in `DocumentZipArchive.swift`.

import Foundation

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

    /// Creates a document chunk.
    /// - Parameters:
    ///   - index: Zero-based position in extraction order.
    ///   - text: Normalized chunk text.
    ///   - estimatedTokens: Estimated token count for the chunk.
    public init(index: Int, text: String, estimatedTokens: Int) {
        self.index = index
        self.text = text
        self.estimatedTokens = estimatedTokens
    }
}

/// Result of extracting text from one document.
public struct DocumentExtraction: Sendable, Equatable {
    /// How completely the body was extracted, using the shared index
    /// ``ExtractStatus``: clean success is `.extracted`, best-effort iWork or a
    /// source past the byte bound is `.partial`, an empty text layer is
    /// `.metadataOnly` for the vision path, an unknown format is `.unsupported`,
    /// and an unreadable recognized package is `.failed`.
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

    /// Creates a document extraction result.
    /// - Parameters:
    ///   - status: Outcome classification.
    ///   - format: Recognized format family.
    ///   - chunks: Extracted chunks in reading order.
    ///   - reason: Explanation for non-`.extracted` outcomes.
    ///   - byteCount: Bytes considered.
    ///   - truncated: Whether the source was shortened.
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
    /// Extracts text from raw document bytes.
    /// - Parameters:
    ///   - data: Raw document bytes.
    ///   - fileName: File name used for extension-based dispatch.
    ///   - contentType: Optional MIME type or UTI used when the extension is unknown.
    /// - Returns: Extraction result; never throws for an unsupported format.
    func extract(data: Data, fileName: String, contentType: String?) -> DocumentExtraction
}

// MARK: - Extractor

/// Dispatches by file extension or content type and extracts bounded text chunks.
///
/// The extractor is a value type with no shared mutable state, so it is safe to
/// hold across concurrent indexing work. The byte bound and chunk sizing are
/// injected at construction so a caller's configured policy is the single source
/// of truth rather than a literal buried here.
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
    /// - Parameters:
    ///   - maxFileBytes: Byte bound applied before parsing.
    ///   - chunkTokenBudget: Target token budget per chunk.
    ///   - chunkOverlapTokens: Token overlap between adjacent chunks, clamped to
    ///     at most half the budget so overlap never doubles a chunk.
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

    /// Extracts text using the file name alone for format dispatch.
    /// - Parameters:
    ///   - data: Raw document bytes.
    ///   - fileName: File name used for extension-based dispatch.
    /// - Returns: Extraction result; never throws for an unsupported format.
    public func extract(data: Data, fileName: String) -> DocumentExtraction {
        extract(data: data, fileName: fileName, contentType: nil)
    }

    /// Extracts text from a file URL, applying the byte bound before reading.
    ///
    /// The size check runs before the bytes are loaded so an oversized document
    /// never spends memory on the read. A missing or unreadable file reports
    /// `.failed` with a reason instead of throwing.
    /// - Parameters:
    ///   - fileURL: Document location.
    ///   - contentType: Optional MIME type or UTI used when the extension is unknown.
    /// - Returns: Extraction result; never throws for an unreadable file.
    public func extract(fileURL: URL, contentType: String? = nil) -> DocumentExtraction {
        let fileName = fileURL.lastPathComponent
        let format = Self.detectFormat(fileName: fileName, contentType: contentType)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > maxFileBytes {
            return makeResult(
                status: .partial,
                format: format,
                reason: "Document is \(size) bytes and exceeds the \(maxFileBytes)-byte extraction bound.",
                byteCount: size,
                truncated: true
            )
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return makeResult(
                status: .failed,
                format: format,
                reason: "The document at '\(fileName)' could not be read.",
                byteCount: 0
            )
        }
        return extract(data: data, fileName: fileName, contentType: contentType)
    }

    /// Extracts text from raw bytes, dispatching on extension then content type.
    /// - Parameters:
    ///   - data: Raw document bytes.
    ///   - fileName: File name used for extension-based dispatch.
    ///   - contentType: Optional MIME type or UTI used when the extension is unknown.
    /// - Returns: Extraction result; never throws for an unsupported format.
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
        case .pdf:
            return extractPDF(data: data)
        case .docx:
            return extractDOCX(data: data)
        case .xlsx:
            return extractXLSX(data: data)
        case .pptx:
            return extractPPTX(data: data)
        case .pages, .numbers, .keynote:
            return extractIWork(data: data, format: format)
        case .unsupported:
            return makeResult(
                status: .unsupported,
                format: .unsupported,
                reason: "Unsupported document format.",
                byteCount: data.count
            )
        }
    }

    /// Builds a result with explicit fields.
    /// - Parameters:
    ///   - status: Outcome classification.
    ///   - format: Recognized format family.
    ///   - chunks: Extracted chunks in reading order.
    ///   - reason: Explanation for non-`.extracted` outcomes.
    ///   - byteCount: Bytes considered.
    ///   - truncated: Whether the source was shortened.
    /// - Returns: Assembled extraction result.
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
    /// - Parameters:
    ///   - text: Decoded text, or nil when decoding failed.
    ///   - format: Recognized format family.
    ///   - byteCount: Bytes considered.
    ///   - missingReason: Explanation used when no text survives normalization.
    /// - Returns: `.extracted` with chunks, or `.metadataOnly` when nothing is extractable.
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
    ///
    /// Segments are packed greedily so a chunk never crosses the character budget
    /// derived from the token budget, and each new chunk begins with the tail of
    /// the previous one so a passage straddling a boundary stays retrievable from
    /// either side. Overlap is clamped to half a chunk so tiny chunks cannot be
    /// duplicated wholesale.
    /// - Parameter text: Normalized extracted text.
    /// - Returns: Chunks in reading order.
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

private extension DocumentTextExtractor {
    /// Extension-to-format map used for primary dispatch.
    static let formatByExtension: [String: DocumentFormat] = [
        "pdf": .pdf,
        "docx": .docx,
        "xlsx": .xlsx,
        "pptx": .pptx,
        "pages": .pages,
        "numbers": .numbers,
        "key": .keynote,
        "keynote": .keynote,
        "txt": .plainText,
        "text": .plainText,
        "log": .plainText,
        "md": .markdown,
        "markdown": .markdown,
        "csv": .csv,
        "json": .json,
        "eml": .eml,
        "html": .html,
        "htm": .html
    ]

    /// MIME type and UTI-to-format map used when the extension is unknown.
    static let formatByContentType: [String: DocumentFormat] = [
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
        "public.email-message": .eml
    ]

    /// Resolves a format from the file extension first, then the content type.
    /// - Parameters:
    ///   - fileName: File name carrying the extension.
    ///   - contentType: Optional MIME type or UTI.
    /// - Returns: Recognized format, or `.unsupported`.
    static func detectFormat(fileName: String, contentType: String?) -> DocumentFormat {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        if let format = formatByExtension[fileExtension] {
            return format
        }
        if let contentType {
            let normalized = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let format = formatByContentType[normalized] {
                return format
            }
            // A UTI may arrive with a parameter suffix (for example `text/plain; charset=utf-8`).
            if let base = normalized.split(separator: ";").first.map(String.init),
               let format = formatByContentType[base]
            {
                return format
            }
        }
        return .unsupported
    }
}
