// Rune Weaver Core Tests — EmbeddingModelProvisionerTests for text model & mmproj verification.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

struct EmbeddingModelProvisionerTests {
    @Test
    func `isModelAvailable and isMMProjAvailable check paths and size floors accurately`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let modelFile = tempDir.appendingPathComponent("test-model.gguf")
        let mmprojFile = tempDir.appendingPathComponent("test-mmproj.gguf")

        let provisioner = EmbeddingModelProvisioner(
            modelFileName: "test-model.gguf",
            mmprojFileName: "test-mmproj.gguf",
            modelDirectoryPath: tempDir.path,
            minExpectedSize: 100,
            minMMProjExpectedSize: 200
        )

        // Neither file exists
        #expect(!provisioner.isModelAvailable())
        #expect(!provisioner.isMMProjAvailable())

        // Create truncated files (< min size)
        try Data(repeating: 0x41, count: 50).write(to: modelFile)
        try Data(repeating: 0x42, count: 150).write(to: mmprojFile)
        #expect(!provisioner.isModelAvailable())
        #expect(!provisioner.isMMProjAvailable())

        // Expand files to meet size floors
        try Data(repeating: 0x41, count: 120).write(to: modelFile)
        try Data(repeating: 0x42, count: 250).write(to: mmprojFile)
        #expect(provisioner.isModelAvailable())
        #expect(provisioner.isMMProjAvailable())
    }

    @Test
    func `ensureModelAvailable and ensureMMProjAvailable download via action and verify size`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadedURLs = OSAllocatedUnfairLock(initialState: [URL]())
        let provisioner = EmbeddingModelProvisioner(
            modelFileName: "model.gguf",
            mmprojFileName: "mmproj.gguf",
            modelDirectoryPath: tempDir.path,
            minExpectedSize: 50,
            minMMProjExpectedSize: 80,
            downloadAction: { source, target in
                downloadedURLs.withLock { $0.append(source) }
                let bytes = source.lastPathComponent.contains("mmproj") ? 100 : 60
                try Data(repeating: 0xAA, count: bytes).write(to: target)
            }
        )

        let modelURL = try await provisioner.ensureModelAvailable()
        let mmprojURL = try await provisioner.ensureMMProjAvailable()

        #expect(FileManager.default.fileExists(atPath: modelURL.path))
        #expect(FileManager.default.fileExists(atPath: mmprojURL.path))
        #expect(downloadedURLs.withLock { $0.count } == 2)
    }

    @Test
    func `ensureAllAvailable provisions both artifacts`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provisioner = EmbeddingModelProvisioner(
            modelFileName: "model.gguf",
            mmprojFileName: "mmproj.gguf",
            modelDirectoryPath: tempDir.path,
            minExpectedSize: 10,
            minMMProjExpectedSize: 10,
            downloadAction: { _, target in
                try Data(repeating: 0xFF, count: 20).write(to: target)
            }
        )

        let (model, mmproj) = try await provisioner.ensureAllAvailable()
        #expect(provisioner.isModelAvailable())
        #expect(provisioner.isMMProjAvailable())
        #expect(model.lastPathComponent == "model.gguf")
        #expect(mmproj.lastPathComponent == "mmproj.gguf")
    }
}
