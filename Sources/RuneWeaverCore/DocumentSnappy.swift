// Rune Weaver Core — Snappy block decompression for compressed office archives.

import Foundation

/// Pure-Swift Snappy block decompressor for iWork archive payloads.
public enum DocumentSnappy: Sendable {
    /// Maximum uncompressed bytes permitted per single block (25 MB default cap).
    public static let maxUncompressedBlockBytes = 25 * 1024 * 1024

    /// Decompresses raw Snappy-compressed block bytes. - Returns: Tuple of `(data: Data,
    /// bytesConsumed: Int)` on success, or `nil` on failure.
    public static func decompress(_ data: Data) -> (data: Data, bytesConsumed: Int)? {
        guard !data.isEmpty else { return nil }

        let bytes = [UInt8](data)
        var pos = 0

        guard let expectedLength = readVarintLength(bytes: bytes, pos: &pos), expectedLength > 0, expectedLength <= maxUncompressedBlockBytes else {
            return nil
        }

        var output = [UInt8]()
        output.reserveCapacity(min(expectedLength, 1024 * 1024))

        while pos < bytes.count, output.count < expectedLength {
            guard decodeElement(bytes: bytes, pos: &pos, output: &output, expectedLength: expectedLength) else {
                return nil
            }
        }

        guard output.count == expectedLength else {
            return nil
        }

        return (Data(output), pos)
    }

    /// Reads an unsigned varint length from the byte buffer.
    private static func readVarintLength(bytes: [UInt8], pos: inout Int) -> Int? {
        var expectedLength = 0
        var shift = 0
        while pos < bytes.count {
            let byteVal = bytes[pos]
            pos += 1
            expectedLength |= Int(byteVal & 0x7F) << shift
            if (byteVal & 0x80) == 0 {
                return expectedLength
            }
            shift += 7
            if shift > 28 {
                return nil
            }
        }
        return nil
    }

    /// Decodes a single Snappy literal or copy element tag.
    private static func decodeElement(
        bytes: [UInt8],
        pos: inout Int,
        output: inout [UInt8],
        expectedLength: Int
    ) -> Bool {
        guard pos < bytes.count else { return false }
        let tagByte = bytes[pos]
        pos += 1
        let tag = tagByte & 0x03

        switch tag {
        case 0:
            return decodeLiteral(tagByte: tagByte, bytes: bytes, pos: &pos, output: &output, expectedLength: expectedLength)
        case 1:
            return decodeCopy1Byte(tagByte: tagByte, bytes: bytes, pos: &pos, output: &output, expectedLength: expectedLength)
        case 2:
            return decodeCopy2Bytes(tagByte: tagByte, bytes: bytes, pos: &pos, output: &output, expectedLength: expectedLength)
        case 3:
            return decodeCopy4Bytes(tagByte: tagByte, bytes: bytes, pos: &pos, output: &output, expectedLength: expectedLength)
        default:
            return false
        }
    }

    /// Decodes a literal tag (tag 00).
    private static func decodeLiteral(
        tagByte: UInt8,
        bytes: [UInt8],
        pos: inout Int,
        output: inout [UInt8],
        expectedLength: Int
    ) -> Bool {
        var litLen = Int(tagByte >> 2) + 1
        if tagByte >> 2 >= 60 {
            let extraCount = Int((tagByte >> 2) - 59)
            guard pos + extraCount <= bytes.count else { return false }
            var extraVal = 0
            for byteIndex in 0 ..< extraCount {
                extraVal |= Int(bytes[pos + byteIndex]) << (byteIndex * 8)
            }
            pos += extraCount
            litLen = extraVal + 1
        }
        guard litLen > 0, pos + litLen <= bytes.count, output.count + litLen <= expectedLength else {
            return false
        }
        output.append(contentsOf: bytes[pos ..< (pos + litLen)])
        pos += litLen
        return true
    }

    /// Decodes a copy tag with 1-byte offset (tag 01).
    private static func decodeCopy1Byte(
        tagByte: UInt8,
        bytes: [UInt8],
        pos: inout Int,
        output: inout [UInt8],
        expectedLength: Int
    ) -> Bool {
        let copyLen = Int((tagByte >> 2) & 0x07) + 4
        guard pos < bytes.count else { return false }
        let offset = (Int(tagByte >> 5) << 8) | Int(bytes[pos])
        pos += 1
        guard offset > 0, offset <= output.count, output.count + copyLen <= expectedLength else {
            return false
        }
        for _ in 0 ..< copyLen {
            output.append(output[output.count - offset])
        }
        return true
    }

    /// Decodes a copy tag with 2-byte offset (tag 10).
    private static func decodeCopy2Bytes(
        tagByte: UInt8,
        bytes: [UInt8],
        pos: inout Int,
        output: inout [UInt8],
        expectedLength: Int
    ) -> Bool {
        let copyLen = Int(tagByte >> 2) + 1
        guard pos + 2 <= bytes.count else { return false }
        let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
        pos += 2
        guard offset > 0, offset <= output.count, output.count + copyLen <= expectedLength else {
            return false
        }
        for _ in 0 ..< copyLen {
            output.append(output[output.count - offset])
        }
        return true
    }

    /// Decodes a copy tag with 4-byte offset (tag 11).
    private static func decodeCopy4Bytes(
        tagByte: UInt8,
        bytes: [UInt8],
        pos: inout Int,
        output: inout [UInt8],
        expectedLength: Int
    ) -> Bool {
        let copyLen = Int(tagByte >> 2) + 1
        guard pos + 4 <= bytes.count else { return false }
        let offset = Int(bytes[pos])
            | (Int(bytes[pos + 1]) << 8)
            | (Int(bytes[pos + 2]) << 16)
            | (Int(bytes[pos + 3]) << 24)
        pos += 4
        guard offset > 0, offset <= output.count, output.count + copyLen <= expectedLength else {
            return false
        }
        for _ in 0 ..< copyLen {
            output.append(output[output.count - offset])
        }
        return true
    }
}
