// Rune Weaver Core Tests — Pure Swift Snappy decompressor unit tests.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("DocumentSnappy")
struct DocumentSnappyTests {
    @Test
    func `Decompresses short literal run`() throws {
        // Snappy encoding of "Hello, world!" Varint length: 13 (0x0d) Literal tag: (13 - 1) << 2 |
        // 0b00 = 12 << 2 = 48 (0x30) Followed by bytes "Hello, world!"
        let message = "Hello, world!"
        var bytes = Data([0x0D, 0x30])
        bytes.append(Data(message.utf8))

        let decompressed = DocumentSnappy.decompress(bytes)
        #expect(decompressed != nil)
        #expect(try String(data: #require(decompressed?.data), encoding: .utf8) == message)
    }

    @Test
    func `Decompresses copy with 1-byte offset`() throws {
        // "abcabcabc" Length: 9 (0x09) Literal "abc": tag (3-1)<<2 = 8 (0x08), "abc" Copy 6 bytes
        // with offset 3: Tag 0b01: (len - 4) << 2 | 0b01 | ((offset >> 8) & 0x7) << 5 len = 6 -> len
        // - 4 = 2.
        var bytes = Data([0x09, 0x08])
        bytes.append(Data("abc".utf8))
        bytes.append(contentsOf: [0x09, 0x03])

        let decompressed = DocumentSnappy.decompress(bytes)
        #expect(decompressed != nil)
        #expect(try String(data: #require(decompressed?.data), encoding: .utf8) == "abcabcabc")
    }

    @Test
    func `Decompresses copy with 2-byte offset`() throws {
        // Pattern "12345" repeated Literal "12345", then copy 10 bytes with offset 5 using tag 0b10
        // Tag 0b10: (len - 1) << 2 | 0b10. len = 10 -> (9 << 2) | 2 = 38 (0x26) Offset 5 as 2-byte
        // LE: 0x05, 0x00
        var bytes = Data([15, 0x10])
        bytes.append(Data("12345".utf8))
        bytes.append(contentsOf: [0x26, 0x05, 0x00])

        let decompressed = DocumentSnappy.decompress(bytes)
        #expect(decompressed != nil)
        #expect(try String(data: #require(decompressed?.data), encoding: .utf8) == "123451234512345")
    }

    @Test
    func `Safely returns nil on empty input`() {
        #expect(DocumentSnappy.decompress(Data()) == nil)
    }

    @Test
    func `Safely returns nil on truncated literal bytes`() {
        // Header claims 10 bytes, literal tag claims 5 bytes, but only 2 bytes follow
        let bytes = Data([10, 0x10, 0x41, 0x42])
        #expect(DocumentSnappy.decompress(bytes) == nil)
    }

    @Test
    func `Safely returns nil on copy with offset larger than output buffer`() {
        // Literal "ab", then copy with offset 10 (which is beyond the 2 bytes generated)
        var bytes = Data([10, 0x04])
        bytes.append(Data("ab".utf8))
        bytes.append(contentsOf: [0x09, 0x0A]) // tag 0b01, offset 10
        #expect(DocumentSnappy.decompress(bytes) == nil)
    }

    @Test
    func `Safely returns nil on output buffer overflow`() {
        // Header claims 2 bytes uncompressed length, but literal provides 5 bytes
        var bytes = Data([0x02, 0x10])
        bytes.append(Data("12345".utf8))
        #expect(DocumentSnappy.decompress(bytes) == nil)
    }
}
