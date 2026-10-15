// Rune Weaver Core Tests — Tests for supervisor and provisioners.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

struct LlamaEmbeddingSupervisorTests {
    @Test
    func `EmbeddingModelProvisioner reports availability and downloads model`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadCalled = OSAllocatedUnfairLock(initialState: false)
        let provisioner = EmbeddingModelProvisioner(
            modelFileName: "test-model.gguf",
            modelDirectoryPath: tempDir.path,
            fileExistsCheck: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            downloadAction: { _, destURL in
                downloadCalled.withLock { $0 = true }
                try Data("fake-gguf-content".utf8).write(to: destURL)
            }
        )

        #expect(!provisioner.isModelAvailable())
        let dest = try await provisioner.ensureModelAvailable()
        #expect(downloadCalled.withLock { $0 } == true)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(provisioner.isModelAvailable())
    }

    @Test
    func `EmbeddingModelProvisioner rejects truncated file below minExpectedSize`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provisioner = EmbeddingModelProvisioner(
            modelFileName: "truncated-model.gguf",
            modelDirectoryPath: tempDir.path,
            minExpectedSize: 1024,
            downloadAction: { _, destURL in
                try Data(repeating: 0, count: 500).write(to: destURL)
            }
        )

        #expect(!provisioner.isModelAvailable())
        await #expect(throws: EmbeddingModelProvisionError.self) {
            try await provisioner.ensureModelAvailable()
        }
    }

    @Test
    func `LlamaServerProvisioner finds existing binary or bootstraps via mock`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bootstrapCalled = OSAllocatedUnfairLock(initialState: false)
        let provisioner = LlamaServerProvisioner(
            binDirectoryPath: tempDir.path,
            fileExistsCheck: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            downloadAndExtractAction: { _, destDir in
                bootstrapCalled.withLock { $0 = true }
                let binURL = destDir.appendingPathComponent("llama-server")
                try Data("fake-binary".utf8).write(to: binURL)
            }
        )

        #expect(!provisioner.isBinaryAvailable())
        let binURL = try await provisioner.ensureBinaryAvailable()
        #expect(bootstrapCalled.withLock { $0 } == true)
        #expect(binURL.lastPathComponent == "llama-server")
    }

    @Test
    func `LlamaEmbeddingSupervisor manages mock lifecycle cleanly`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let startCount = OSAllocatedUnfairLock(initialState: 0)
        let supervisor = LlamaEmbeddingSupervisor(
            modelPath: tempDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path,
            socketPath: tempDir.appendingPathComponent("test.sock").path,
            pidPath: tempDir.appendingPathComponent("test.pid").path,
            logPath: tempDir.appendingPathComponent("test.log").path,
            testRunner: {
                startCount.withLock { $0 += 1 }
            }
        )

        let runningBefore = await supervisor.isRunning
        #expect(!runningBefore)
        let statusBefore = await supervisor.status
        #expect(statusBefore == .idle)

        let observedStatuses = OSAllocatedUnfairLock(initialState: [LlamaSupervisorStatus]())
        await supervisor.setStatusHandler { status, _, _ in
            observedStatuses.withLock { $0.append(status) }
        }

        try await supervisor.start()
        #expect(startCount.withLock { $0 } == 1)
        let statusAfterStart = await supervisor.status
        #expect(statusAfterStart == .ready)

        let recorded = observedStatuses.withLock { $0 }
        #expect(recorded == [.starting, .ready])

        let socketURL = supervisor.resolvedSocketURL
        #expect(socketURL.path.hasSuffix("test.sock"))
        await supervisor.stop()
        let runningAfter = await supervisor.isRunning
        #expect(!runningAfter)
        let statusAfterStop = await supervisor.status
        #expect(statusAfterStop == .idle)
    }

    @Test
    func `LlamaEmbeddingSupervisor transitions to error status on failure`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        struct MockError: Error, LocalizedError {
            var errorDescription: String? {
                "Mock launch failure"
            }
        }

        let supervisor = LlamaEmbeddingSupervisor(
            modelPath: tempDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path,
            socketPath: tempDir.appendingPathComponent("test-error.sock").path,
            pidPath: tempDir.appendingPathComponent("test-error.pid").path,
            logPath: tempDir.appendingPathComponent("test-error.log").path,
            testRunner: {
                throw MockError()
            }
        )

        do {
            try await supervisor.start()
            #expect(Bool(false), "Expected start to throw")
        } catch {
            let status = await supervisor.status
            #expect(status == .error)
            let lastError = await supervisor.lastError
            #expect(lastError == "Mock launch failure")
        }
    }

    @Test
    func `LlamaEmbeddingSupervisor coalesces concurrent start calls into single invocation`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let startCount = OSAllocatedUnfairLock(initialState: 0)
        let supervisor = LlamaEmbeddingSupervisor(
            modelPath: tempDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path,
            socketPath: tempDir.appendingPathComponent("test-coalesce.sock").path,
            pidPath: tempDir.appendingPathComponent("test-coalesce.pid").path,
            logPath: tempDir.appendingPathComponent("test-coalesce.log").path,
            testRunner: {
                startCount.withLock { $0 += 1 }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        )

        // Launch 10 concurrent tasks calling ensureRunning
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    try await supervisor.ensureRunning()
                }
            }
            try await group.waitForAll()
        }

        #expect(startCount.withLock { $0 } == 1)
        let status = await supervisor.status
        #expect(status == .ready)
        await supervisor.stop()
    }

    @Test
    func `LlamaEmbeddingSupervisor cleans up PID file on stop`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pidURL = tempDir.appendingPathComponent("test.pid")
        let socketURL = tempDir.appendingPathComponent("test.sock")
        let logURL = tempDir.appendingPathComponent("test.log")
        try "99999999".write(to: pidURL, atomically: true, encoding: .utf8)
        try "socket".write(to: socketURL, atomically: true, encoding: .utf8)

        let supervisor = LlamaEmbeddingSupervisor(
            socketPath: socketURL.path,
            pidPath: pidURL.path,
            logPath: logURL.path
        )

        #expect(FileManager.default.fileExists(atPath: pidURL.path))
        #expect(FileManager.default.fileExists(atPath: socketURL.path))

        supervisor.stopSync()

        #expect(!FileManager.default.fileExists(atPath: pidURL.path))
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }
}
