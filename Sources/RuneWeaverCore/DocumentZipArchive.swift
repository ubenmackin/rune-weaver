// Rune Weaver Core — Minimal ZIP reader for office document extraction.
//
// Holds the read-only ZIP layer for `DocumentTextExtractor`: central-directory
// parsing for stored and deflate entries plus raw DEFLATE inflation and
// little-endian byte access. ZIP64 and encrypted archives fail closed so a
// malformed office or iWork package never misparses.

import Foundation
import zlib

/// One entry in a ZIP central directory.
struct ZipEntry: Sendable {
    /// Entry path inside the archive.
    let name: String
    /// Compression method: 0 for stored, 8 for deflate.
    let compressionMethod: UInt16
    /// Compressed byte count.
    let compressedSize: Int
    /// Uncompressed byte count.
    let uncompressedSize: Int
    /// Offset of the local file header from the start of the archive.
    let localHeaderOffset: Int
}

/// Minimal read-only ZIP reader for OOXML and iWork packages.
///
/// Only stored and deflate entries are supported; ZIP64 and encrypted archives
/// are rejected so a malformed package fails closed instead of misparsing.
struct ZipArchiveReader: Sendable {
    /// Parsed central directory entries in archive order.
    let entryNames: [String]

    /// Raw archive bytes.
    private let data: Data
    /// Entries indexed by exact path.
    private let entriesByName: [String: ZipEntry]
    /// Entries in archive order.
    private let entries: [ZipEntry]

    /// Parses the central directory, rejecting ZIP64 and encrypted archives.
    /// - Parameter data: ZIP archive bytes.
    init?(data: Data) {
        guard let endOfDirectory = Self.endOfCentralDirectoryOffset(in: data) else { return nil }
        let totalEntries = data.uint16LE(at: endOfDirectory + 10) ?? 0
        guard let directorySize = data.uint32LE(at: endOfDirectory + 12),
              let directoryOffset = data.uint32LE(at: endOfDirectory + 16)
        else {
            return nil
        }
        guard directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { return nil }

        var parsed: [ZipEntry] = []
        var cursor = Int(directoryOffset)
        let directoryEnd = cursor + Int(directorySize)
        var scanned = 0
        while scanned < Int(totalEntries), cursor + 46 <= data.count, cursor + 46 <= directoryEnd {
            guard data.uint32LE(at: cursor) == 0x0201_4B50 else { break }
            let method = data.uint16LE(at: cursor + 10) ?? 0
            let compressed = data.uint32LE(at: cursor + 20) ?? 0
            let uncompressed = data.uint32LE(at: cursor + 24) ?? 0
            let nameLength = Int(data.uint16LE(at: cursor + 28) ?? 0)
            let extraLength = Int(data.uint16LE(at: cursor + 30) ?? 0)
            let commentLength = Int(data.uint16LE(at: cursor + 32) ?? 0)
            let localOffset = data.uint32LE(at: cursor + 42) ?? 0
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count, let nameData = data.littleEndianSubdata(at: nameStart, length: nameLength) else { break }
            guard let name = String(bytes: nameData, encoding: .utf8) else { break }
            // ZIP64 sentinels are not expanded here, so those entries are skipped
            // rather than read from the wrong offset.
            if compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF {
                parsed.append(
                    ZipEntry(
                        name: name,
                        compressionMethod: method,
                        compressedSize: Int(compressed),
                        uncompressedSize: Int(uncompressed),
                        localHeaderOffset: Int(localOffset)
                    )
                )
            }
            cursor = nameStart + nameLength + extraLength + commentLength
            scanned += 1
        }
        guard !parsed.isEmpty || totalEntries == 0 else { return nil }

        self.data = data
        self.entries = parsed
        self.entryNames = parsed.map(\.name)
        self.entriesByName = Dictionary(parsed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads and decompresses one entry by exact path, then case-insensitively.
    /// - Parameter name: Entry path.
    /// - Returns: Entry bytes, or nil when absent or unsupported.
    func data(forEntryNamed name: String) -> Data? {
        if let entry = entriesByName[name] {
            return uncompressedData(for: entry)
        }
        let lowered = name.lowercased()
        guard let entry = entries.first(where: { $0.name.lowercased() == lowered }) else { return nil }
        return uncompressedData(for: entry)
    }

    /// Reads and decompresses one entry.
    /// - Parameter entry: Central directory entry.
    /// - Returns: Entry bytes, or nil when the local header or method is unsupported.
    private func uncompressedData(for entry: ZipEntry) -> Data? {
        guard data.uint32LE(at: entry.localHeaderOffset) == 0x0403_4B50 else { return nil }
        let nameLength = Int(data.uint16LE(at: entry.localHeaderOffset + 26) ?? 0)
        let extraLength = Int(data.uint16LE(at: entry.localHeaderOffset + 28) ?? 0)
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard let compressed = data.littleEndianSubdata(at: dataStart, length: entry.compressedSize) else { return nil }
        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return Self.inflateRawDeflate(compressed)
        default:
            return nil
        }
    }

    /// Finds the end-of-central-directory record by scanning backward past any comment.
    /// - Parameter data: ZIP archive bytes.
    /// - Returns: Offset of the EOCD signature, or nil when absent.
    private static func endOfCentralDirectoryOffset(in data: Data) -> Int? {
        let minimumSize = 22
        let maximumCommentLength = 0xFFFF
        guard data.count >= minimumSize else { return nil }
        let searchStart = max(0, data.count - minimumSize - maximumCommentLength)
        var offset = data.count - minimumSize
        while offset >= searchStart {
            if data.uint32LE(at: offset) == 0x0605_4B50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// Inflates a raw DEFLATE stream (no zlib header) using the system zlib.
    /// - Parameter data: Raw DEFLATE bytes.
    /// - Returns: Inflated bytes, or nil on a malformed stream.
    private static func inflateRawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        let version = String(cString: zlibVersion())
        let initStatus = version.withCString { pointer in
            inflateInit2_(&stream, -15, pointer, Int32(MemoryLayout<z_stream>.size))
        }
        guard initStatus == Int32(Z_OK) else { return nil }
        defer { inflateEnd(&stream) }

        let bufferSize = 64 * 1024
        let outputBuffer = UnsafeMutablePointer<Bytef>.allocate(capacity: bufferSize)
        defer { outputBuffer.deallocate() }

        var input = [UInt8](data)
        var output = Data()
        return input.withUnsafeMutableBufferPointer { buffer -> Data? in
            guard let base = buffer.baseAddress else { return nil }
            stream.next_in = base
            stream.avail_in = UInt32(buffer.count)
            while true {
                stream.next_out = outputBuffer
                stream.avail_out = UInt32(bufferSize)
                let status = inflate(&stream, Int32(Z_FINISH))
                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outputBuffer, count: produced)
                }
                if status == Int32(Z_STREAM_END) {
                    return output
                }
                if status != Int32(Z_OK), status != Int32(Z_BUF_ERROR) {
                    return nil
                }
                // No progress with no input left means the stream is truncated.
                if produced == 0, stream.avail_in == 0 {
                    return nil
                }
            }
        }
    }
}

/// Little-endian byte access shared by the ZIP reader.
extension Data {
    /// Reads one byte at an offset from the start of the data.
    /// - Parameter offset: Byte offset from the start.
    /// - Returns: Byte value, or nil when out of bounds.
    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    /// Reads a little-endian 16-bit integer.
    /// - Parameter offset: Byte offset from the start.
    /// - Returns: Value, or nil when out of bounds.
    func uint16LE(at offset: Int) -> UInt16? {
        guard let low = byte(at: offset), let high = byte(at: offset + 1) else { return nil }
        return UInt16(low) | (UInt16(high) << 8)
    }

    /// Reads a little-endian 32-bit integer.
    /// - Parameter offset: Byte offset from the start.
    /// - Returns: Value, or nil when out of bounds.
    func uint32LE(at offset: Int) -> UInt32? {
        guard let byte0 = byte(at: offset), let byte1 = byte(at: offset + 1),
              let byte2 = byte(at: offset + 2), let byte3 = byte(at: offset + 3)
        else {
            return nil
        }
        return UInt32(byte0) | (UInt32(byte1) << 8) | (UInt32(byte2) << 16) | (UInt32(byte3) << 24)
    }

    /// Copies a range of bytes starting at an offset.
    /// - Parameters:
    ///   - offset: Byte offset from the start.
    ///   - length: Number of bytes to copy.
    /// - Returns: Copied bytes, or nil when out of bounds.
    func littleEndianSubdata(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return subdata(in: (startIndex + offset) ..< (startIndex + offset + length))
    }
}
