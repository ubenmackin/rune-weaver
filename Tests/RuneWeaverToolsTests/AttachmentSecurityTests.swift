// Rune Weaver Tools Tests — Attachment security, magic byte validation, and quarantine tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing
#if canImport(Darwin)
    import Darwin
#endif

@Suite("Attachment Security")
struct AttachmentSecurityTests {
    @Test
    func `Detects Mach-O and ELF executables by magic bytes`() {
        // Mach-O 64-bit big endian
        let macho64 = Data([0xFE, 0xED, 0xFA, 0xCF, 0x00, 0x00, 0x00, 0x01])
        #expect(AttachmentSecurity.isExecutable(data: macho64))
        if case .executable = AttachmentSecurity.classify(data: macho64, filename: "tool") {
            // expected
        } else {
            Issue.record("Expected executable classification for Mach-O")
        }

        // Linux ELF
        let elf = Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00])
        #expect(AttachmentSecurity.isExecutable(data: elf))
        if case .executable = AttachmentSecurity.classify(data: elf, filename: "tool.bin") {
            // expected
        } else {
            Issue.record("Expected executable classification for ELF")
        }
    }

    @Test
    func `Detects Windows PE and Shebang scripts`() {
        // Windows PE (MZ)
        let pe = Data([0x4D, 0x5A, 0x90, 0x00])
        #expect(AttachmentSecurity.isExecutable(data: pe))

        // Shebang script (without dangerous extension to test magic bytes directly)
        let shebang = Data("#!/bin/bash\necho hello\n".utf8)
        #expect(AttachmentSecurity.isExecutable(data: shebang))
        if case let .executable(reason) = AttachmentSecurity.classify(data: shebang, filename: "run_script") {
            #expect(reason.contains("shebang"))
        } else {
            Issue.record("Expected executable classification for shebang script")
        }
    }

    @Test
    func `Rejects dangerous executable extensions regardless of content`() {
        let dummy = Data([0x01, 0x02, 0x03, 0x04])
        #expect(AttachmentSecurity.isExecutable(data: dummy, filename: "malware.exe"))
        #expect(AttachmentSecurity.isExecutable(data: dummy, filename: "script.sh"))
        #expect(AttachmentSecurity.isExecutable(data: dummy, filename: "payload.app"))
    }

    @Test
    func `Flags archive formats and compound office documents for zero-mount container detonation`() {
        // ZIP magic bytes: PK\x03\x04
        let zipData = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(AttachmentSecurity.requiresZeroMountDetonation(data: zipData, contentType: "application/octet-stream", filename: "archive.bin"))
        #expect(AttachmentSecurity.requiresZeroMountDetonation(data: zipData, contentType: "application/pdf", filename: "fake.pdf"))

        // GZIP magic bytes: 0x1F 0x8B
        let gzipData = Data([0x1F, 0x8B, 0x08, 0x00])
        #expect(AttachmentSecurity.requiresZeroMountDetonation(data: gzipData, contentType: "", filename: "data.gz"))

        // Compound Office docs (docx, xlsx, docm)
        let officeData = Data([0x50, 0x4B, 0x03, 0x04])
        #expect(AttachmentSecurity.requiresZeroMountDetonation(data: officeData, contentType: "application/vnd.openxmlformats", filename: "invoice.docx"))
        #expect(AttachmentSecurity.requiresZeroMountDetonation(data: officeData, contentType: "", filename: "macro.docm"))
    }

    @Test
    func `Validates authentic image magic bytes`() {
        // PNG magic bytes
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
        #expect(AttachmentSecurity.isValidImage(data: png))
        if case let .image(format) = AttachmentSecurity.classify(data: png, filename: "photo.png") {
            #expect(format == "png")
        } else {
            Issue.record("Expected image classification for PNG")
        }

        // JPEG magic bytes
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        #expect(AttachmentSecurity.isValidImage(data: jpeg))

        // Fake image (executable disguised as .png) is not a valid image
        let fakeImage = Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00])
        #expect(!AttachmentSecurity.isValidImage(data: fakeImage))
        if case .executable = AttachmentSecurity.classify(data: fakeImage, filename: "photo.png") {
            // correctly classified as executable
        } else {
            Issue.record("Executable disguised as image must be classified as executable")
        }
    }

    #if canImport(Darwin)
        @Test
        func `Applies com.apple.quarantine extended attribute on macOS`() throws {
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("quarantine-test-\(UUID().uuidString).txt")
            try "test data".write(to: tempFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            AttachmentSecurity.applyQuarantine(to: tempFile)

            var buffer = [UInt8](repeating: 0, count: 256)
            let size = buffer.withUnsafeMutableBytes { rawBuf in
                getxattr(tempFile.path, "com.apple.quarantine", rawBuf.baseAddress, rawBuf.count, 0, 0)
            }
            #expect(size > 0)
            let xattrVal = String(decoding: buffer.prefix(max(0, size)), as: UTF8.self)
            #expect(xattrVal.contains("RuneWeaver"))
        }
    #endif

    @Test
    func `Handles sliced Data with non-zero startIndex without crashing`() {
        let fullData = Data([0xAA, 0xBB, 0xCC, 0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        let slice = fullData[3...]
        #expect(slice.startIndex == 3)
        #expect(AttachmentSecurity.requiresZeroMountDetonation(data: slice, contentType: "", filename: "test.zip"))
        let imageHeader = Data([0x00, 0x00, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let imageSlice = imageHeader[2...]
        #expect(imageSlice.startIndex == 2)
        #expect(AttachmentSecurity.isValidImage(data: imageSlice))
    }
}
