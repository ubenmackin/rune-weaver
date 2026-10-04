// Rune Weaver Core Tests — Document text extraction across supported formats.
//
// Exercises extension and content-type dispatch, the per-format extraction
// paths (plain text, HTML, PDF, DOCX, XLSX, PPTX, iWork), the byte bound, the
// empty-text metadata path, unsupported formats, and the overlapping chunk
// split. Fixtures are built in-process: office packages are hand-assembled ZIP
// archives (one stored and one deflated entry so both decompression paths run)
// and PDFs are drawn with CoreGraphics so no binary fixtures are checked in.

import CoreGraphics
import CoreText
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Document Text Extractor")
struct DocumentTextExtractorTests {
    private let extractor = DocumentTextExtractor()

    @Test
    func `Plain text extracts a single chunk`() {
        let data = Data("First line\nSecond line".utf8)
        let result = extractor.extract(data: data, fileName: "notes.txt")
        #expect(result.format == .plainText)
        #expect(result.status == .extracted)
        #expect(result.chunks.count == 1)
        #expect(result.text.contains("First line"))
        #expect(result.text.contains("Second line"))
    }

    @Test
    func `Markdown and JSON dispatch as plain text`() {
        let markdown = extractor.extract(data: Data("# Title\nBody".utf8), fileName: "readme.md")
        #expect(markdown.format == .markdown)
        #expect(markdown.status == .extracted)

        let json = extractor.extract(data: Data(#"{"key":"value"}"#.utf8), fileName: "data.json")
        #expect(json.format == .json)
        #expect(json.status == .extracted)
    }

    @Test
    func `Content type fallback dispatches when extension is unknown`() {
        let result = extractor.extract(data: Data("hello".utf8), fileName: "noextension", contentType: "text/plain")
        #expect(result.format == .plainText)
        #expect(result.status == .extracted)
    }

    @Test
    func `HTML is stripped to readable text`() {
        let html = """
        <html><head><style>p{color:red}</style><script>alert('x')</script></head>
        <body><h1>Title</h1><p>Hello &amp; welcome</p></body></html>
        """
        let result = extractor.extract(data: Data(html.utf8), fileName: "page.html")
        #expect(result.status == .extracted)
        #expect(result.text.contains("Title"))
        #expect(result.text.contains("Hello & welcome"))
        #expect(!result.text.contains("alert"))
        #expect(!result.text.contains("color:red"))
    }

    @Test
    func `Empty text reports metadataOnly`() {
        let result = extractor.extract(data: Data(), fileName: "empty.txt")
        #expect(result.status == .metadataOnly)
        #expect(result.chunks.isEmpty)
        #expect(result.reason != nil)
    }

    @Test
    func `Unsupported format reports unsupported without throwing`() {
        let result = extractor.extract(data: Data("binary".utf8), fileName: "archive.xyz")
        #expect(result.status == .unsupported)
        #expect(result.format == .unsupported)
        #expect(result.reason != nil)
    }

    @Test
    func `Oversized document reports partial before parsing`() {
        let small = DocumentTextExtractor(maxFileBytes: 8)
        let result = small.extract(data: Data("0123456789".utf8), fileName: "big.txt")
        #expect(result.status == .partial)
        #expect(result.truncated)
        #expect(result.reason != nil)
    }

    @Test
    func `DOCX package extracts paragraph text through deflate`() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>Hello DOCX</w:t></w:r></w:p>
        <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let data = makeZIP(entries: [(name: "word/document.xml", content: xml, deflate: true)])
        let result = extractor.extract(data: data, fileName: "letter.docx")
        #expect(result.status == .extracted)
        #expect(result.text.contains("Hello DOCX"))
        #expect(result.text.contains("Second paragraph"))
        #expect(result.text.contains("\n"))
    }

    @Test
    func `DOCX package without document part reports failed`() {
        let data = makeZIP(entries: [(name: "word/styles.xml", content: "<x/>", deflate: false)])
        let result = extractor.extract(data: data, fileName: "broken.docx")
        #expect(result.status == .failed)
        #expect(result.reason != nil)
    }

    @Test
    func `XLSX shared strings flatten rows with tabs`() {
        let shared = """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Name</t></si><si><t>Age</t></si><si><t>Ada</t></si></sst>
        """
        let sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>42</v></c></row>
        </sheetData></worksheet>
        """
        let data = makeZIP(entries: [
            (name: "xl/sharedStrings.xml", content: shared, deflate: false),
            (name: "xl/worksheets/sheet1.xml", content: sheet, deflate: true)
        ])
        let result = extractor.extract(data: data, fileName: "table.xlsx")
        #expect(result.status == .extracted)
        #expect(result.text.contains("Name\tAge"))
        #expect(result.text.contains("Ada\t42"))
    }

    @Test
    func `PPTX slide text is extracted`() {
        let slide = """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>
        <a:p><a:r><a:t>Slide One</a:t></a:r></a:p>
        <a:p><a:r><a:t>Bullet</a:t></a:r></a:p>
        </p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
        let data = makeZIP(entries: [(name: "ppt/slides/slide1.xml", content: slide, deflate: true)])
        let result = extractor.extract(data: data, fileName: "deck.pptx")
        #expect(result.status == .extracted)
        #expect(result.text.contains("Slide One"))
        #expect(result.text.contains("Bullet"))
    }

    @Test
    func `iWork package is best-effort partial`() {
        let xml = "<document><body>Legacy Pages Text</body></document>"
        let data = makeZIP(entries: [(name: "index.xml", content: xml, deflate: false)])
        let result = extractor.extract(data: data, fileName: "notes.pages")
        #expect(result.status == .partial)
        #expect(result.text.contains("Legacy Pages Text"))
        #expect(result.reason != nil)
    }

    @Test
    func `PDF text layer is extracted`() {
        let data = makePDF(text: "Hello PDF layer")
        let result = extractor.extract(data: data, fileName: "report.pdf")
        #expect(result.format == .pdf)
        #expect(result.status == .extracted)
        #expect(result.text.contains("Hello"))
    }

    @Test
    func `PDF without a text layer reports metadataOnly`() {
        let data = makePDF(text: nil)
        let result = extractor.extract(data: data, fileName: "scan.pdf")
        #expect(result.status == .metadataOnly)
        #expect(result.chunks.isEmpty)
        #expect(result.reason != nil)
    }

    @Test
    func `Long text splits into overlapping chunks`() {
        let text = (1 ... 400).map { "Paragraph \($0) carries a handful of searchable words." }.joined(separator: "\n")
        let result = extractor.extract(data: Data(text.utf8), fileName: "long.txt")
        #expect(result.status == .extracted)
        #expect(result.chunks.count > 1)
        #expect(result.chunks.map(\.index) == Array(0 ..< result.chunks.count))
        let first = result.chunks[0].text
        let second = result.chunks[1].text
        #expect(first.count > 128)
        #expect(second.contains(String(first.suffix(32))))
    }
}

// MARK: - ZIP fixture builder

/// Builds a minimal ZIP archive with stored or deflated entries.
///
/// Deflated entries use a raw DEFLATE stored block (BFINAL set, BTYPE 00), which
/// is a valid uncompressed stream, so the extractor's inflate path is exercised
/// without needing a compressor in the test target.
/// - Parameter entries: Entry name, UTF-8 content, and whether to mark the entry deflated.
/// - Returns: A complete ZIP archive with a central directory and EOCD record.
private func makeZIP(entries: [(name: String, content: String, deflate: Bool)]) -> Data {
    var archive = Data()
    var directory = Data()
    for entry in entries {
        let payload = Data(entry.content.utf8)
        let compressed = entry.deflate ? storedDeflateBlock(payload) : payload
        let method: UInt16 = entry.deflate ? 8 : 0
        let checksum = crc32(payload)
        let nameData = Data(entry.name.utf8)
        let localOffset = UInt32(archive.count)

        archive.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        archive.appendLittleEndian(UInt16(20))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(method)
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(checksum)
        archive.appendLittleEndian(UInt32(compressed.count))
        archive.appendLittleEndian(UInt32(payload.count))
        archive.appendLittleEndian(UInt16(nameData.count))
        archive.appendLittleEndian(UInt16(0))
        archive.append(nameData)
        archive.append(compressed)

        directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        directory.appendLittleEndian(UInt16(20))
        directory.appendLittleEndian(UInt16(20))
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(method)
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(checksum)
        directory.appendLittleEndian(UInt32(compressed.count))
        directory.appendLittleEndian(UInt32(payload.count))
        directory.appendLittleEndian(UInt16(nameData.count))
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(UInt16(0))
        directory.appendLittleEndian(UInt32(0))
        directory.appendLittleEndian(localOffset)
        directory.append(nameData)
    }

    let directoryOffset = UInt32(archive.count)
    let directorySize = UInt32(directory.count)
    archive.append(directory)

    archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(entries.count))
    archive.appendLittleEndian(UInt16(entries.count))
    archive.appendLittleEndian(directorySize)
    archive.appendLittleEndian(directoryOffset)
    archive.appendLittleEndian(UInt16(0))
    return archive
}

/// Wraps bytes in a single raw DEFLATE stored block.
/// - Parameter data: Uncompressed bytes.
/// - Returns: A valid raw DEFLATE stream carrying the bytes verbatim.
private func storedDeflateBlock(_ data: Data) -> Data {
    var output = Data()
    let length = UInt16(data.count)
    output.append(0x01)
    output.appendLittleEndian(length)
    output.appendLittleEndian(~length)
    output.append(data)
    return output
}

/// Computes the reflected CRC-32 used by ZIP local and central headers.
/// - Parameter data: Bytes to checksum.
/// - Returns: CRC-32 value.
private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0 ..< 8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
    }
    return crc ^ 0xFFFF_FFFF
}

/// Draws a one-page PDF with an optional text layer using CoreGraphics.
/// - Parameter text: Text to draw, or nil for a page with no text layer.
/// - Returns: PDF bytes, or empty data when the context could not be created.
private func makePDF(text: String?) -> Data {
    let pdfData = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
    guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        return Data()
    }
    context.beginPDFPage(nil)
    if let text, !text.isEmpty {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
    }
    context.endPDFPage()
    context.closePDF()
    return pdfData as Data
}

extension Data {
    /// Appends a little-endian 16-bit integer.
    /// - Parameter value: Value to append.
    fileprivate mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    /// Appends a little-endian 32-bit integer.
    /// - Parameter value: Value to append.
    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}
