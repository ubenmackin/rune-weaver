// Rune Weaver Core — Office and PDF extraction for document text.
//
// Holds the format-specific extraction paths for `DocumentTextExtractor`:
// native PDF text layers, DOCX word-processing XML, XLSX worksheets via the
// shared string table, PPTX slide XML, and best-effort iWork packages. Plain
// text, HTML, dispatch, and chunking stay in `DocumentTextExtractor.swift`
// while shared decoding lives beside it.

import Foundation
#if canImport(PDFKit)
    import PDFKit
#endif

extension DocumentTextExtractor {
    /// Extracts the PDF text layer, or reports `metadataOnly` for a scanned document.
    /// - Parameter data: PDF bytes.
    /// - Returns: Extraction result.
    func extractPDF(data: Data) -> DocumentExtraction {
        #if canImport(PDFKit)
            guard let document = PDFDocument(data: data) else {
                return makeResult(
                    status: .failed,
                    format: .pdf,
                    reason: "The PDF could not be parsed.",
                    byteCount: data.count
                )
            }
            var pages: [String] = []
            for index in 0 ..< document.pageCount {
                if let pageText = document.page(at: index)?.string, NormalizedText.value(pageText) != nil {
                    pages.append(pageText)
                }
            }
            return makeTextResult(
                text: pages.joined(separator: "\n\n"),
                format: .pdf,
                byteCount: data.count,
                missingReason: "The PDF has no extractable text layer; route the original bytes to a vision path."
            )
        #else
            return makeResult(
                status: .unsupported,
                format: .pdf,
                reason: "PDF extraction is unavailable on this platform.",
                byteCount: data.count
            )
        #endif
    }

    /// Extracts text from `word/document.xml` inside a DOCX package.
    /// - Parameter data: DOCX package bytes.
    /// - Returns: Extraction result.
    func extractDOCX(data: Data) -> DocumentExtraction {
        guard let archive = ZipArchiveReader(data: data) else {
            return makeResult(
                status: .failed,
                format: .docx,
                reason: "The DOCX package could not be read.",
                byteCount: data.count
            )
        }
        guard let documentData = archive.data(forEntryNamed: "word/document.xml"),
              let xml = Self.decodeText(documentData)
        else {
            return makeResult(
                status: .failed,
                format: .docx,
                reason: "The DOCX package has no readable word/document.xml.",
                byteCount: data.count
            )
        }
        return makeTextResult(
            text: Self.textFromWordProcessingXML(xml),
            format: .docx,
            byteCount: data.count,
            missingReason: "The DOCX document contains no extractable text."
        )
    }

    /// Flattens worksheet rows using the shared string table of an XLSX package.
    /// - Parameter data: XLSX package bytes.
    /// - Returns: Extraction result.
    func extractXLSX(data: Data) -> DocumentExtraction {
        guard let archive = ZipArchiveReader(data: data) else {
            return makeResult(
                status: .failed,
                format: .xlsx,
                reason: "The XLSX package could not be read.",
                byteCount: data.count
            )
        }
        let sharedStrings = Self.sharedStrings(from: archive)
        let sheetNames = archive.entryNames
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        guard !sheetNames.isEmpty else {
            return makeResult(
                status: .failed,
                format: .xlsx,
                reason: "The XLSX package has no worksheets.",
                byteCount: data.count
            )
        }
        var sheets: [String] = []
        for name in sheetNames {
            guard let sheetData = archive.data(forEntryNamed: name), let xml = Self.decodeText(sheetData) else { continue }
            if let text = Self.textFromWorksheetXML(xml, sharedStrings: sharedStrings) {
                sheets.append(text)
            }
        }
        return makeTextResult(
            text: sheets.joined(separator: "\n\n"),
            format: .xlsx,
            byteCount: data.count,
            missingReason: "The XLSX workbook contains no extractable cell values."
        )
    }

    /// Extracts slide text from the slide XML entries of a PPTX package.
    /// - Parameter data: PPTX package bytes.
    /// - Returns: Extraction result.
    func extractPPTX(data: Data) -> DocumentExtraction {
        guard let archive = ZipArchiveReader(data: data) else {
            return makeResult(
                status: .failed,
                format: .pptx,
                reason: "The PPTX package could not be read.",
                byteCount: data.count
            )
        }
        let slideNames = archive.entryNames
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted()
        guard !slideNames.isEmpty else {
            return makeResult(
                status: .failed,
                format: .pptx,
                reason: "The PPTX package has no slides.",
                byteCount: data.count
            )
        }
        var slides: [String] = []
        for name in slideNames {
            guard let slideData = archive.data(forEntryNamed: name), let xml = Self.decodeText(slideData) else { continue }
            let text = Self.textFromPresentationXML(xml)
            if !text.isEmpty {
                slides.append(text)
            }
        }
        return makeTextResult(
            text: slides.joined(separator: "\n\n"),
            format: .pptx,
            byteCount: data.count,
            missingReason: "The PPTX presentation contains no extractable text."
        )
    }

    /// Single-source fallback body for a zero-chunk office document.
    ///
    /// Guarantees one searchable row carrying the file identity when no text
    /// survives extraction, so every indexed file owns at least one chunk.
    /// - Parameters:
    ///   - displayName: File name for the `Document` line.
    ///   - formatToken: Format family for the `Format` line.
    ///   - path: Relative display path for the `File path` line.
    /// - Returns: Three-line metadata text.
    static func fallbackMetadataText(displayName: String, formatToken: String, path: String) -> String {
        let resolvedPath = path.isEmpty ? displayName : path
        return "Document: \(displayName)\nFile path: \(resolvedPath)\nFormat: \(formatToken)"
    }

    /// Best-effort text extraction from an iWork package.
    ///
    /// Tries the legacy XML entries first and returns them as `partial`, then
    /// decompresses the Snappy IWA payload via `DocumentIWorkArchive` and returns
    /// it as `extracted`, and finally returns exactly one fallback chunk as
    /// `partial` carrying `Document` plus `File path` plus `Format` lines.
    /// The fallback `File path` line carries the file name only; root-relative
    /// display paths for zero-chunk documents are owned by the indexer fallback.
    /// - Parameters:
    ///   - data: iWork package bytes.
    ///   - format: Recognized iWork format.
    ///   - fileName: Optional file name for fallback metadata chunk.
    /// - Returns: `partial` or `extracted` result, or `.failed` when the package is unreadable.
    func extractIWork(data: Data, format: DocumentFormat, fileName: String = "") -> DocumentExtraction {
        guard let archive = ZipArchiveReader(data: data) else {
            return makeResult(
                status: .failed,
                format: format,
                reason: "The iWork package could not be read.",
                byteCount: data.count
            )
        }
        let reason = "iWork text is stored in a binary IWA payload; extraction is best-effort from the package index."
        let xmlNames = archive.entryNames.filter { $0.hasSuffix(".xml") && !$0.hasPrefix("Metadata/") }.sorted()
        var parts: [String] = []
        for name in xmlNames {
            guard let entryData = archive.data(forEntryNamed: name), let xml = Self.decodeText(entryData) else { continue }
            let stripped = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            if let text = Self.normalizedExtractedText(Self.decodeXMLEntities(stripped)) {
                parts.append(text)
            }
        }
        if let normalized = Self.normalizedExtractedText(parts.joined(separator: "\n\n")) {
            let chunks = makeChunks(from: normalized)
            if !chunks.isEmpty {
                return makeResult(status: .partial, format: format, chunks: chunks, reason: reason, byteCount: data.count)
            }
        }
        if let iworkText = DocumentIWorkArchive.extractText(from: archive, maxFileBytes: maxFileBytes) {
            let chunks = makeChunks(from: iworkText)
            if !chunks.isEmpty {
                return makeResult(status: .extracted, format: format, chunks: chunks, reason: nil, byteCount: data.count)
            }
        }
        let displayName = fileName.isEmpty ? format.rawValue : fileName
        let fallbackText = Self.fallbackMetadataText(displayName: displayName, formatToken: format.rawValue, path: displayName)
        let fallbackChunks = [DocumentChunk(index: 0, text: fallbackText, estimatedTokens: Self.estimatedTokens(in: fallbackText))]
        return makeResult(status: .partial, format: format, chunks: fallbackChunks, reason: reason, byteCount: data.count)
    }
}
