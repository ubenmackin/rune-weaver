// Rune Weaver Core — Out-of-process llama-server supervisor for Apple Silicon Metal embeddings.

import Foundation
import os

/// Errors raised by ``LlamaEmbeddingSupervisor``.
public enum LlamaSupervisorError: Error, Sendable, Equatable {
    /// The `llama-server` binary could not be found.
    case binaryNotFound(String)
    /// The target GGUF model file was not found on disk.
    case modelNotFound(String)
    /// Process failed to launch.
    case launchFailed(String)
    /// Health check or socket readiness timed out.
    case readinessTimeout(String)
}

/// Lifecycle status for ``LlamaEmbeddingSupervisor``.
public enum LlamaSupervisorStatus: String, Sendable, Codable, Equatable {
    /// Server is stopped or uninitialized.
    case idle
    /// Downloading precompiled llama-server binary.
    case downloadingBinary = "downloading_binary"
    /// Downloading EmbeddingGemma 2 GGUF model.
    case downloadingModel = "downloading_model"
    /// Spawning process and awaiting socket readiness.
    case starting
    /// Server is active and accepting embedding requests.
    case ready
    /// Provisioning or process launch encountered an error.
    case error
}

/// Actor managing the lifecycle of a dedicated `llama-server` process for on-device embeddings.
public actor LlamaEmbeddingSupervisor {
    /// Shared singleton supervisor instance for the application process.
    public static let shared = LlamaEmbeddingSupervisor()

    /// Default UNIX domain socket path under user home.
    public static let defaultSocketPath = "~/.runeweaver/run/embedding.sock"
    /// Default GGUF model path under user home.
    public static let defaultModelPath = "~/.runeweaver/models/embeddinggemma-2-Q8_0.gguf"
    /// Default log path for supervised llama-server output under user home.
    public static let defaultLogPath = ("~/.runeweaver/logs/llama-server.log" as NSString).expandingTildeInPath
    /// Default PID file path for supervised llama-server process.
    public static let defaultPIDPath = ("~/.runeweaver/run/llama-server.pid" as NSString).expandingTildeInPath

    /// Known search paths for the `llama-server` Mach-O binary.
    public static let candidateBinaryPaths = LlamaServerProvisioner.candidateBinaryPaths

    /// Configured model path.
    public let modelPath: String
    /// Configured UNIX domain socket path.
    public let socketPath: String
    /// Configured PID file path.
    public let pidPath: String
    /// Configured log path.
    public let logPath: String
    /// Optional TCP port fallback if not using UNIX domain socket.
    public let tcpPort: Int?
    /// Number of layers to offload to Apple Silicon Metal GPU (default 99).
    public let gpuLayers: Int
    /// Context size tokens (default 8192).
    public let ctxSize: Int
    /// Pooling type (default "mean").
    public let pooling: String

    /// In-flight start task to coalesce concurrent callers into a single startup flight.
    private var inFlightStartTask: Task<Void, any Error>?

    /// Override executable URL, or nil to auto-discover.
    private let customBinaryURL: URL?
    /// The running Process instance, if active.
    private var process: Process?
    /// Process identifier if running.
    private var activePID: pid_t?

    /// Current lifecycle status.
    public private(set) var status: LlamaSupervisorStatus = .idle
    /// Human-readable message describing active status (e.g. downloading progress).
    public private(set) var statusMessage: String?
    /// Last error encountered during provisioning or launch.
    public private(set) var lastError: String?

    /// Listener invoked on status changes.
    public typealias StatusHandler = @Sendable (LlamaSupervisorStatus, String?, String?) async -> Void
    private var statusHandler: StatusHandler?

    /// Injected start hook for testing.
    private var testRunner: (@Sendable () async throws -> Void)?

    /// Sets the status change listener.
    public func setStatusHandler(_ handler: StatusHandler?) {
        self.statusHandler = handler
    }

    /// Sets an injected start hook for testing, bypassing binary and model provisioning.
    public func setTestRunner(_ runner: (@Sendable () async throws -> Void)?) {
        self.testRunner = runner
    }

    /// Updates status and notifies listener.
    private func updateStatus(_ newStatus: LlamaSupervisorStatus, message: String?, error: String? = nil) async {
        self.status = newStatus
        self.statusMessage = message
        if let error {
            self.lastError = error
        }
        if let statusHandler {
            await statusHandler(newStatus, message, error)
        }
    }

    /// Creates a supervisor actor.
    public init(
        modelPath: String = defaultModelPath,
        socketPath: String = defaultSocketPath,
        pidPath: String = defaultPIDPath,
        logPath: String = defaultLogPath,
        tcpPort: Int? = nil,
        gpuLayers: Int = 99,
        ctxSize: Int = 8192,
        pooling: String = "mean",
        customBinaryURL: URL? = nil,
        testRunner: (@Sendable () async throws -> Void)? = nil
    ) {
        self.modelPath = modelPath
        self.socketPath = socketPath
        self.pidPath = pidPath
        self.logPath = logPath
        self.tcpPort = tcpPort
        self.gpuLayers = gpuLayers
        self.ctxSize = ctxSize
        self.pooling = pooling
        self.customBinaryURL = customBinaryURL
        self.testRunner = testRunner
    }

    /// Whether the supervised process is currently running.
    public var isRunning: Bool {
        if let proc = process {
            return proc.isRunning
        }
        return false
    }

    /// Resolves the canonical expanded socket file URL.
    public nonisolated var resolvedSocketURL: URL {
        let expanded = (socketPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Resolves the canonical expanded PID file URL.
    public nonisolated var resolvedPIDURL: URL {
        let expanded = (pidPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Resolves the canonical expanded model file URL.
    public nonisolated var resolvedModelURL: URL {
        let expanded = (modelPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Resolves the canonical expanded log file URL.
    public nonisolated var resolvedLogURL: URL {
        let expanded = (logPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Finds the `llama-server` executable URL on the host.
    public func resolveBinaryURL() -> URL? {
        if let custom = customBinaryURL, FileManager.default.isExecutableFile(atPath: custom.path) {
            return custom
        }
        for candidate in Self.candidateBinaryPaths where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        // Check PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let check = URL(fileURLWithPath: String(dir)).appendingPathComponent("llama-server")
                if FileManager.default.isExecutableFile(atPath: check.path) {
                    return check
                }
            }
        }
        return nil
    }

    /// Starts `llama-server` if not already running.
    public func start() async throws {
        if isRunning {
            if status != .ready {
                await updateStatus(.ready, message: "EmbeddingGemma 2 ready (Apple Silicon Metal)")
            }
            return
        }

        if let inFlight = inFlightStartTask {
            try await inFlight.value
            return
        }

        let startTask = Task { [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        self.inFlightStartTask = startTask

        do {
            try await startTask.value
            self.inFlightStartTask = nil
        } catch {
            self.inFlightStartTask = nil
            throw error
        }
    }

    private func performStart() async throws {
        if let testRunner {
            await updateStatus(.starting, message: "Starting local Metal server…")
            do {
                try await testRunner()
                await updateStatus(.ready, message: "EmbeddingGemma 2 ready (Apple Silicon Metal)")
                return
            } catch {
                await updateStatus(.error, message: error.localizedDescription, error: error.localizedDescription)
                throw error
            }
        }

        if isRunning {
            if status != .ready {
                await updateStatus(.ready, message: "EmbeddingGemma 2 ready (Apple Silicon Metal)")
            }
            return
        }

        do {
            let binaryURL = try await provisionBinary()
            let (modelURL, mmprojURL) = try await provisionModel()

            try Task.checkCancellation()

            await updateStatus(.starting, message: "Starting local Metal server…")

            let socketURL = resolvedSocketURL
            let socketDir = socketURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)

            let pidURL = resolvedPIDURL
            let pidDir = pidURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)

            reapStaleProcesses(socketURL: socketURL, pidURL: pidURL)

            var arguments = [
                "--model", modelURL.path,
                "--embeddings",
                "--pooling", pooling,
                "--ctx-size", String(ctxSize),
                "--batch-size", String(ctxSize),
                "--ubatch-size", String(ctxSize),
                "--n-gpu-layers", String(gpuLayers),
                "--sleep-idle-seconds", "60"
            ]

            if let mmprojURL, FileManager.default.fileExists(atPath: mmprojURL.path) {
                arguments.append(contentsOf: ["--mmproj", mmprojURL.path])
            }

            if let tcpPort {
                arguments.append(contentsOf: ["--host", "127.0.0.1", "--port", String(tcpPort)])
            } else {
                arguments.append(contentsOf: ["--host", socketURL.path])
            }

            let newProcess = Process()
            newProcess.executableURL = binaryURL
            newProcess.arguments = arguments
            newProcess.environment = ProcessInfo.processInfo.environment

            let logURL = resolvedLogURL
            let logDir = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let logHandle = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
            _ = try? logHandle.seekToEnd()
            newProcess.standardOutput = logHandle
            newProcess.standardError = logHandle

            newProcess.terminationHandler = { [weak self] proc in
                guard let self else { return }
                Task {
                    await self.handleProcessTermination(proc)
                }
            }

            RuneWeaverLog.stores.info("LlamaEmbeddingSupervisor: Spawning llama-server at \(binaryURL.path) with model \(modelURL.path)...")

            do {
                try newProcess.run()
                self.process = newProcess
                self.activePID = newProcess.processIdentifier
                try? String(newProcess.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
            } catch {
                throw LlamaSupervisorError.launchFailed("Failed to spawn llama-server: \(error.localizedDescription)")
            }

            try await waitForReadiness(process: newProcess, socketURL: socketURL, logURL: logURL)
            await updateStatus(.ready, message: "EmbeddingGemma 2 ready (Apple Silicon Metal)")
            RuneWeaverLog.stores.info(
                "LlamaEmbeddingSupervisor: llama-server is ready and listening on \(socketURL.path) (PID \(newProcess.processIdentifier))."
            )
        } catch {
            await updateStatus(.error, message: error.localizedDescription, error: error.localizedDescription)
            throw error
        }
    }

    private func reapStaleProcesses(socketURL: URL, pidURL: URL) {
        if let pidString = (try? String(contentsOf: pidURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = pid_t(pidString), pid > 1, kill(pid, 0) == 0
        {
            RuneWeaverLog.stores.info("LlamaEmbeddingSupervisor: Reaping stale llama-server process (PID \(pid))...")
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.1)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: pidURL)

        if FileManager.default.fileExists(atPath: socketURL.path) {
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    private func handleProcessTermination(_ proc: Process) async {
        guard self.process === proc else { return }
        self.process = nil
        self.activePID = nil
        try? FileManager.default.removeItem(at: resolvedPIDURL)
        let code = proc.terminationStatus
        if status == .ready || status == .starting {
            if code == 0 {
                let msg = "Local embedding engine entered standby to save power."
                RuneWeaverLog.stores.info("LlamaEmbeddingSupervisor: \(msg)")
                await updateStatus(.idle, message: msg)
            } else {
                let msg = "llama-server process exited unexpectedly with code \(code)"
                RuneWeaverLog.stores.error("LlamaEmbeddingSupervisor: \(msg)")
                await updateStatus(.error, message: msg, error: msg)
            }
        }
    }

    /// Stops the running `llama-server` process gracefully with SIGTERM, escalating to SIGKILL.
    public func stop() {
        inFlightStartTask?.cancel()
        inFlightStartTask = nil

        if let proc = process {
            proc.terminationHandler = nil
        }
        if status == .ready || status == .starting {
            status = .idle
            statusMessage = nil
        }

        let pidURL = resolvedPIDURL
        let recordedPID: pid_t? = {
            if let str = (try? String(contentsOf: pidURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = pid_t(str), parsed > 1
            {
                return parsed
            }
            return nil
        }()

        let pid = activePID ?? process?.processIdentifier ?? recordedPID
        process = nil
        activePID = nil

        if let pid, pid > 1 {
            kill(pid, SIGTERM)
            // Schedule SIGKILL after 1 second if still running
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        try? FileManager.default.removeItem(at: pidURL)
        let socketURL = resolvedSocketURL
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// Synchronously terminates any running llama-server process recorded in the PID file.
    /// Safe to call from atexit or synchronous termination handlers.
    public nonisolated func stopSync() {
        let pidURL = resolvedPIDURL
        if let str = (try? String(contentsOf: pidURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = pid_t(str), pid > 1
        {
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(at: pidURL)
        }
        let socketURL = resolvedSocketURL
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// Ensures the process is running, launching it if stopped.
    public func ensureRunning() async throws {
        if isRunning, status == .ready {
            return
        }
        try await start()
    }

    deinit {
        stopSync()
    }
}

extension LlamaEmbeddingSupervisor {
    /// Reads up to `maxBytes` from the tail of a log file.
    static func readLogTail(at logURL: URL, maxBytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = max(0, Int64(size) - Int64(maxBytes))
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func provisionBinary() async throws -> URL {
        if let custom = customBinaryURL, FileManager.default.isExecutableFile(atPath: custom.path) {
            return custom
        }
        let serverProvisioner = LlamaServerProvisioner()
        if serverProvisioner.findExistingBinary() == nil {
            await updateStatus(.downloadingBinary, message: "Downloading llama-server (~60 MB)…")
        }
        do {
            return try await serverProvisioner.ensureBinaryAvailable()
        } catch {
            throw LlamaSupervisorError.binaryNotFound("Could not locate or bootstrap llama-server binary: \(error.localizedDescription)")
        }
    }

    private func provisionModel() async throws -> (modelURL: URL, mmprojURL: URL?) {
        let resolvedTarget = resolvedModelURL
        let modelProvisioner = EmbeddingModelProvisioner(
            modelFileName: resolvedTarget.lastPathComponent,
            modelDirectoryPath: resolvedTarget.deletingLastPathComponent().path
        )
        if !modelProvisioner.isModelAvailable() {
            await updateStatus(.downloadingModel, message: "Downloading EmbeddingGemma 2 (~310 MB)…")
        }
        let modelURL: URL
        do {
            modelURL = try await modelProvisioner.ensureModelAvailable()
        } catch {
            throw LlamaSupervisorError.modelNotFound("Could not locate or download embedding model: \(error.localizedDescription)")
        }

        var mmprojURL: URL?
        if !modelProvisioner.isMMProjAvailable() {
            await updateStatus(.downloadingModel, message: "Downloading multimodal projector (~555 MB)…")
        }
        do {
            mmprojURL = try await modelProvisioner.ensureMMProjAvailable()
        } catch {
            RuneWeaverLog.stores.warning(
                "EmbeddingModelProvisioner: Multimodal projector download failed: \(error.localizedDescription); falling back to text-only embeddings."
            )
            mmprojURL = nil
        }
        return (modelURL, mmprojURL)
    }

    private func waitForReadiness(process: Process, socketURL: URL, logURL: URL) async throws {
        let deadline = Date().addingTimeInterval(30.0)
        var ready = false
        do {
            while Date() < deadline {
                try Task.checkCancellation()

                if !process.isRunning {
                    let errMsg = Self.readLogTail(at: logURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
                    self.process = nil
                    self.activePID = nil
                    throw LlamaSupervisorError.launchFailed("llama-server exited immediately: \(errMsg)")
                }

                if let tcpPort {
                    if await checkTCPHealth(port: tcpPort) {
                        ready = true
                        break
                    }
                } else {
                    if await probeHealth(socketURL: socketURL) {
                        ready = true
                        break
                    }
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        } catch is CancellationError {
            stop()
            throw CancellationError()
        }

        if !ready {
            stop()
            throw LlamaSupervisorError.readinessTimeout(
                "Timed out waiting for llama-server socket at \(socketURL.path) to become ready."
            )
        }
    }

    private func checkTCPHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        guard let (_, res) = try? await URLSession.shared.data(for: req),
              let http = res as? HTTPURLResponse
        else {
            return false
        }
        return http.statusCode == 200
    }

    private func probeHealth(socketURL: URL) async -> Bool {
        UnixSocketHTTPClient.probeHealth(socketPath: socketURL.path)
    }
}
