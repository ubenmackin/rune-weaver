// Rune Weaver Core Tests — Modern Apple iWork (.iwa) Snappy archive extraction unit tests.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("DocumentIWorkExtraction")
struct DocumentIWorkExtractionTests {
    /// Builds a single framed Snappy payload.
    /// Frame header: 4 bytes (0x00 + 24-bit LE uncompressed length).
    /// Followed by Snappy compressed block.
    static func makeFramedIWA(uncompressedPayload: Data) -> Data {
        let uncompressedLen = uncompressedPayload.count
        // Compress using pure Snappy literal format
        var snappyBlock = Data()
        // Varint uncompressed length
        var lenVal = uncompressedLen
        while lenVal >= 0x80 {
            snappyBlock.append(UInt8((lenVal & 0x7F) | 0x80))
            lenVal >>= 7
        }
        snappyBlock.append(UInt8(lenVal))

        // Literal tags (can split if > 60)
        var offset = 0
        while offset < uncompressedLen {
            let chunk = min(60, uncompressedLen - offset)
            let tag = UInt8((chunk - 1) << 2)
            snappyBlock.append(tag)
            snappyBlock.append(uncompressedPayload.subdata(in: offset ..< (offset + chunk)))
            offset += chunk
        }

        // 4-byte frame header
        var framed = Data()
        framed.append(0x00)
        framed.append(UInt8(uncompressedLen & 0xFF))
        framed.append(UInt8((uncompressedLen >> 8) & 0xFF))
        framed.append(UInt8((uncompressedLen >> 16) & 0xFF))
        framed.append(snappyBlock)
        return framed
    }

    /// Builds a minimal uncompressed ZIP archive with given entries.
    static func makeZipArchive(entries: [(name: String, data: Data)]) -> Data {
        var zip = Data()
        var centralDirectory = Data()
        var localOffsets: [Int] = []

        for entry in entries {
            localOffsets.append(zip.count)
            let nameBytes = Array(entry.name.utf8)
            let dataBytes = entry.data

            // Local file header: 30 bytes + name + data
            var local = Data([0x50, 0x4B, 0x03, 0x04]) // signature
            local.append(contentsOf: [20, 0]) // version needed
            local.append(contentsOf: [0, 0]) // flags
            local.append(contentsOf: [0, 0]) // compression: 0 (stored)
            local.append(contentsOf: [0, 0, 0, 0]) // mod time / date
            local.append(contentsOf: [0, 0, 0, 0]) // crc-32 (0 for test)
            let size = UInt32(dataBytes.count)
            local.append(UInt8(size & 0xFF))
            local.append(UInt8((size >> 8) & 0xFF))
            local.append(UInt8((size >> 16) & 0xFF))
            local.append(UInt8((size >> 24) & 0xFF))
            local.append(UInt8(size & 0xFF))
            local.append(UInt8((size >> 8) & 0xFF))
            local.append(UInt8((size >> 16) & 0xFF))
            local.append(UInt8((size >> 24) & 0xFF))
            let nameLen = UInt16(nameBytes.count)
            local.append(UInt8(nameLen & 0xFF))
            local.append(UInt8((nameLen >> 8) & 0xFF))
            local.append(contentsOf: [0, 0]) // extra field len
            local.append(contentsOf: nameBytes)
            local.append(dataBytes)

            zip.append(local)
        }

        let cdOffset = zip.count
        for (i, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)
            let size = UInt32(entry.data.count)
            let offset = UInt32(localOffsets[i])

            var cd = Data([0x50, 0x4B, 0x01, 0x02]) // signature
            cd.append(contentsOf: [20, 0, 20, 0]) // version made by / needed
            cd.append(contentsOf: [0, 0, 0, 0]) // flags / compression (stored)
            cd.append(contentsOf: [0, 0, 0, 0]) // mod time / date
            cd.append(contentsOf: [0, 0, 0, 0]) // crc32
            cd.append(UInt8(size & 0xFF))
            cd.append(UInt8((size >> 8) & 0xFF))
            cd.append(UInt8((size >> 16) & 0xFF))
            cd.append(UInt8((size >> 24) & 0xFF))
            cd.append(UInt8(size & 0xFF))
            cd.append(UInt8((size >> 8) & 0xFF))
            cd.append(UInt8((size >> 16) & 0xFF))
            cd.append(UInt8((size >> 24) & 0xFF))
            let nameLen = UInt16(nameBytes.count)
            cd.append(UInt8(nameLen & 0xFF))
            cd.append(UInt8((nameLen >> 8) & 0xFF))
            cd.append(contentsOf: [UInt8](repeating: 0, count: 12)) // extra (2), comment (2), disk (2), internal attrs (2), external attrs (4)
            cd.append(UInt8(offset & 0xFF))
            cd.append(UInt8((offset >> 8) & 0xFF))
            cd.append(UInt8((offset >> 16) & 0xFF))
            cd.append(UInt8((offset >> 24) & 0xFF))
            cd.append(contentsOf: nameBytes)

            centralDirectory.append(cd)
        }

        zip.append(centralDirectory)

        // End of central directory record: 22 bytes
        var eocd = Data([0x50, 0x4B, 0x05, 0x06])
        eocd.append(contentsOf: [0, 0, 0, 0]) // disk numbers
        let count = UInt16(entries.count)
        eocd.append(UInt8(count & 0xFF))
        eocd.append(UInt8((count >> 8) & 0xFF))
        eocd.append(UInt8(count & 0xFF))
        eocd.append(UInt8((count >> 8) & 0xFF))
        let cdSize = UInt32(centralDirectory.count)
        eocd.append(UInt8(cdSize & 0xFF))
        eocd.append(UInt8((cdSize >> 8) & 0xFF))
        eocd.append(UInt8((cdSize >> 16) & 0xFF))
        eocd.append(UInt8((cdSize >> 24) & 0xFF))
        let cdOff = UInt32(cdOffset)
        eocd.append(UInt8(cdOff & 0xFF))
        eocd.append(UInt8((cdOff >> 8) & 0xFF))
        eocd.append(UInt8((cdOff >> 16) & 0xFF))
        eocd.append(UInt8((cdOff >> 24) & 0xFF))
        eocd.append(contentsOf: [0, 0]) // comment len

        zip.append(eocd)
        return zip
    }

    @Test
    func `Extracts text strings from modern iWork Snappy archive`() {
        // Construct protobuf-like mock payload containing strings
        // including cell text and noise tokens
        var payload = Data()
        payload.append(contentsOf: [0x0A, 0x07]) // tag
        payload.append(Data("TSP.PackageMetadata".utf8)) // protobuf token that should be filtered
        payload.append(contentsOf: [0x12, 0x12])
        payload.append(Data("Month Bill is Paid".utf8)) // real table header
        payload.append(contentsOf: [0x1A, 0x06])
        payload.append(Data("Amount".utf8)) // real table header
        payload.append(contentsOf: [0x22, 0x04])
        payload.append(Data("When".utf8)) // real table header

        let framedIWA = Self.makeFramedIWA(uncompressedPayload: payload)
        let zipData = Self.makeZipArchive(entries: [
            ("Index/Tables/DataList-1.iwa", framedIWA)
        ])

        let reader = ZipArchiveReader(data: zipData)
        #expect(reader != nil)
        #expect(reader?.entryNames == ["Index/Tables/DataList-1.iwa"])
        let extractedEntry = reader?.data(forEntryNamed: "Index/Tables/DataList-1.iwa")
        #expect(extractedEntry != nil)
        let extractedStrings = DocumentIWorkArchive.extractStrings(fromIWA: framedIWA)
        #expect(!extractedStrings.isEmpty)

        let extractor = DocumentTextExtractor()
        let result = extractor.extract(data: zipData, fileName: "Money.numbers", contentType: nil)

        #expect(result.status == .extracted)
        #expect(result.format == .numbers)
        #expect(!result.chunks.isEmpty)

        let allText = result.chunks.map(\.text).joined(separator: "\n")
        #expect(allText.contains("Month Bill is Paid"))
        #expect(allText.contains("Amount"))
        #expect(allText.contains("When"))
        #expect(!allText.contains("TSP.PackageMetadata"))
    }

    @Test
    func `Falls back to metadata chunk when iWork archive contains no readable strings`() {
        // Empty frame with no strings
        let framedIWA = Self.makeFramedIWA(uncompressedPayload: Data([0x01, 0x02, 0x03]))
        let zipData = Self.makeZipArchive(entries: [
            ("Index/Document.iwa", framedIWA)
        ])

        let extractor = DocumentTextExtractor()
        let result = extractor.extract(data: zipData, fileName: "Empty.numbers", contentType: nil)

        #expect(result.format == .numbers)
        #expect(result.chunks.count == 1)
        #expect(result.chunks[0].text.contains("Document: Empty.numbers"))
    }
}
