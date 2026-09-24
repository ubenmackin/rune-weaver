// Rune Weaver Tests — Local index route contracts, auth gating, and settings DTOs.
//
// The `/index` surface is owner-gated and drives the injected coordinator and
// document store rather than binding a socket or touching a real index, so
// these tests pin the anonymous `401`, the control-route outcomes, the status
// shape, and the `PUT /settings` index merge that must preserve every omitted
// field while the full snapshot round-trips through the same merge path.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

// MARK: - Fixtures

/// Builds an isolated `0600` token file so auth resolution never touches a real
/// credential.
/// - Parameter contents: Token text to persist.
/// - Returns: The containing directory and the token file URL.
private func makeIndexTokenFile(contents: String) throws -> (directory: URL, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-index-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("auth_token")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return (directory, fileURL)
}

/// Makes a verifier whose persistence target is an isolated temp token file.
/// - Parameter token: Live token value.
/// - Returns: The verifier plus its isolated directory for cleanup.
private func makeIndexAuth(token: String = "owner-token") throws -> (auth: ServerAuth, directory: URL) {
    let (directory, fileURL) = try makeIndexTokenFile(contents: token)
    let store = ServerAuthTokenStore(
        authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET", tokenFile: fileURL.path),
        service: "com.runeweaver.tests.\(UUID().uuidString)"
    )
    return (ServerAuth(initialToken: token, store: store), directory)
}

/// Creates an application for in-process request construction and shutdown.
/// - Parameter body: Work performed against the test application.
/// - Returns: The body's value.
private func withIndexTestApp<T>(_ body: (Application) async throws -> T) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Builds a context around the ephemeral fallback collaborators so a test can
/// vary only the index collaborators and verifier without booting the engine.
/// - Parameters:
///   - auth: Owner verifier, or nil for the ungated posture.
///   - coordinator: Index coordinator to expose, or nil.
///   - store: Document store to expose, or nil.
/// - Returns: A context wired for the `/index` routes.
private func makeIndexTestContext(
    auth: ServerAuth? = nil,
    coordinator: IndexCoordinator? = nil,
    store: DocIndexStore? = nil
) -> ServerContext {
    let base = ServerContext.fallbackUnconfigured
    return ServerContext(
        config: .default,
        conversations: base.conversations,
        toolBus: base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: base.permissionGate,
        approvals: base.approvals,
        steeringQueue: base.steeringQueue,
        indexCoordinator: coordinator,
        indexStore: store,
        auth: auth
    )
}

/// Sends an in-process request through the registered route table.
/// - Parameters:
///   - app: Configured application.
///   - method: HTTP verb.
///   - path: Request path.
///   - token: Optional bearer credential.
/// - Returns: The response, without binding a socket.
private func indexRequest(
    app: Application,
    method: HTTPMethod,
    path: String,
    token: String? = nil
) async throws -> Response {
    var headers = HTTPHeaders()
    if let token {
        headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
    }
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        headers: headers,
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Sends a prune request with an optional JSON body through the route table.
/// An absent body exercises the missing-cutoff path, which must fail closed
/// instead of clearing the store.
/// - Parameters:
///   - app: Configured application.
///   - body: Prune request to encode, or nil for no body.
/// - Returns: The response, without binding a socket.
private func indexPruneRequest(app: Application, body: IndexPruneRequest?) async throws -> Response {
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/index/prune"),
        on: app.eventLoopGroup.next()
    )
    if let body {
        try request.content.encode(body)
    }
    return try await app.responder.respond(to: request).get()
}

/// Sends a prune request with a raw JSON dictionary body, so tests can pin the
/// missing-cutoff (`{}`) versus malformed-cutoff (`{"before":"not-a-date"}`)
/// 400 variants without constructing an `IndexPruneRequest` the required-cutoff
/// initializer no longer permits.
/// - Parameters:
///   - app: Configured application.
///   - body: Raw JSON object to encode as the request body.
/// - Returns: The response, without binding a socket.
private func indexPruneDictRequest(app: Application, body: [String: String]) async throws -> Response {
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/index/prune"),
        on: app.eventLoopGroup.next()
    )
    try request.content.encode(body)
    return try await app.responder.respond(to: request).get()
}

// MARK: - Auth gating

@Suite("Index Route Auth")
struct IndexRouteAuthTests {
    @Test
    func `Index routes reject anonymous callers with the uniform 401`() async throws {
        let (auth, directory) = try makeIndexAuth()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext(auth: auth)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            let probes: [(HTTPMethod, String)] = [
                (.GET, "/index/status"),
                (.POST, "/index/run"),
                (.POST, "/index/cancel"),
                (.POST, "/index/prune"),
                (.POST, "/index/reset"),
                (.POST, "/index/reclaim")
            ]
            for (method, path) in probes {
                let response = try await indexRequest(app: app, method: method, path: path)
                #expect(response.status == .unauthorized, "\(method) \(path) must stay gated")
            }
        }
    }

    @Test
    func `Status serves the owner credential`() async throws {
        let (auth, directory) = try makeIndexAuth()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext(auth: auth)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            let response = try await indexRequest(app: app, method: .GET, path: "/index/status", token: "owner-token")
            #expect(response.status == .ok)
        }
    }
}

// MARK: - Control routes

@Suite("Index Control Routes")
struct IndexControlRouteTests {
    /// Builds a temp directory plus a coordinator and store on isolated paths.
    private func makeIndexComponents() throws -> (coordinator: IndexCoordinator, store: DocIndexStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DocIndexStore(dbPath: directory.appendingPathComponent("index.db").path)
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [],
            store: store,
            stateStore: IndexRunStateStore(path: directory.appendingPathComponent("state.json").path)
        )
        return (coordinator, store, directory)
    }

    @Test
    func `Control routes drive the injected coordinator and store`() async throws {
        let (coordinator, store, directory) = try makeIndexComponents()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext(coordinator: coordinator, store: store)
            registerRuneWeaverRoutes(app)

            let run = try await indexRequest(app: app, method: .POST, path: "/index/run")
            #expect(run.status == .ok)
            let summary = try run.content.decode(IndexRunResponse.self)
            #expect(summary.status == IndexRunStatus.ok.rawValue)
            #expect(summary.documentsIndexed == 0)
            #expect(summary.errors == 0)

            let cancel = try await indexRequest(app: app, method: .POST, path: "/index/cancel")
            #expect(cancel.status == .ok)
            #expect(try cancel.content.decode(IndexCancelResponse.self).cancelled == false)

            let reset = try await indexRequest(app: app, method: .POST, path: "/index/reset")
            #expect(reset.status == .ok)
            #expect(try reset.content.decode(IndexResetResponse.self).reset == true)

            let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
            let prune = try await indexPruneRequest(app: app, body: IndexPruneRequest(before: cutoff))
            #expect(prune.status == .ok)
            let pruneResponse = try prune.content.decode(IndexPruneResponse.self)
            #expect(pruneResponse.removed == 0)
            #expect(pruneResponse.before == cutoff)
        }
    }

    @Test
    func `Prune requires an explicit cutoff instead of defaulting to now`() async throws {
        let (coordinator, store, directory) = try makeIndexComponents()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext(coordinator: coordinator, store: store)
            registerRuneWeaverRoutes(app)

            // No body carries no cutoff, so the route must refuse rather than
            // prune everything indexed before the request instant.
            let missing = try await indexPruneRequest(app: app, body: nil)
            #expect(missing.status == .badRequest)
            #expect((missing.body.string ?? "").contains("Missing required cutoff"))

            // An empty object carries no cutoff either, so it keeps the same
            // missing-cutoff message instead of clearing the store.
            let empty = try await indexPruneDictRequest(app: app, body: [:])
            #expect(empty.status == .badRequest)
            #expect((empty.body.string ?? "").contains("Missing required cutoff"))

            // A present-but-undecodable cutoff is a malformed request, not a
            // missing one, so it reports the invalid-cutoff message.
            let malformed = try await indexPruneDictRequest(app: app, body: ["before": "not-a-date"])
            #expect(malformed.status == .badRequest)
            #expect((malformed.body.string ?? "").contains("Invalid cutoff"))

            // An explicit cutoff still prunes honestly.
            let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
            let pruned = try await indexPruneRequest(app: app, body: IndexPruneRequest(before: cutoff))
            #expect(pruned.status == .ok)
            #expect(try pruned.content.decode(IndexPruneResponse.self).before == cutoff)
        }
    }

    @Test
    func `Control routes fail closed when indexing is not wired`() async throws {
        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext()
            registerRuneWeaverRoutes(app)

            for path in ["/index/run", "/index/cancel", "/index/prune", "/index/reset", "/index/reclaim"] {
                let response = try await indexRequest(app: app, method: .POST, path: path)
                #expect(response.status == .serviceUnavailable, "\(path) must fail closed without a coordinator")
            }
        }
    }

    @Test
    func `Reclaim reports before and after byte figures`() async throws {
        let (coordinator, store, directory) = try makeIndexComponents()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Persist one document so the database file exists on disk and the
        // route reports true filesystem figures for the reclaim window.
        let seed = IndexedDocument(
            source: .files,
            externalID: "reclaim-probe",
            displayName: "Reclaim Probe",
            contentHash: "hash-reclaim-probe"
        )
        let persisted = try await store.upsertDocument(seed)
        _ = try await store.upsertChunks(
            documentID: persisted.id,
            chunks: [IndexedChunk(documentID: persisted.id, ordinal: 0, text: "reclaim probe body")]
        )
        _ = try await store.stats()

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext(coordinator: coordinator, store: store)
            registerRuneWeaverRoutes(app)

            let response = try await indexRequest(app: app, method: .POST, path: "/index/reclaim")
            #expect(response.status == .ok)
            let reclaim = try response.content.decode(IndexReclaimResponse.self)
            #expect(reclaim.beforeBytes > 0)
            #expect(reclaim.afterBytes > 0)
            #expect(reclaim.afterBytes <= reclaim.beforeBytes)
            #expect(reclaim.reclaimedBytes == reclaim.beforeBytes - reclaim.afterBytes)
        }
    }
}

// MARK: - Status shape

@Suite("Index Status DTO")
struct IndexStatusDTOTests {
    @Test
    func `Status maps counts sources and failures`() {
        let config = IndexConfig(enabled: true, files: true, mail: false, messages: true)
        let snapshot = Date(timeIntervalSince1970: 1000)
        let stats = IndexStats(
            documents: 7,
            chunks: 21,
            vectorChunks: 14,
            keywordChunks: 7,
            bytes: 4096,
            indexAsOf: snapshot
        )
        let storage = IndexStorageBreakdown(
            dbFileBytes: 8192,
            walBytes: 512,
            textBytes: 4096,
            vectorBytes: 1024,
            ftsBytes: 2048,
            freeBytes: 256,
            contentBytes: 5120
        )

        let response = makeIndexStatusResponse(
            config: config,
            stats: stats,
            running: true,
            lastErrors: ["mail: gateway timeout"],
            storage: storage
        )

        #expect(response.enabled == true)
        #expect(response.running == true)
        #expect(response.documents == 7)
        #expect(response.chunks == 21)
        #expect(response.vectorChunks == 14)
        #expect(response.keywordChunks == 7)
        #expect(response.bytes == 4096)
        #expect(response.dbFileBytes == 8192)
        #expect(response.walBytes == 512)
        #expect(response.textBytes == 4096)
        #expect(response.vectorBytes == 1024)
        #expect(response.ftsBytes == 2048)
        #expect(response.freeBytes == 256)
        #expect(response.contentBytes == 5120)
        #expect(response.indexAsOf == snapshot)
        #expect(response.sources == [
            IndexSourceStatus(kind: "files", enabled: true),
            IndexSourceStatus(kind: "mail", enabled: false),
            IndexSourceStatus(kind: "messages", enabled: true)
        ])
        #expect(response.lastErrors == ["mail: gateway timeout"])
        // Effort resolves from the stored preset on this machine.
        #expect(response.effort?.preset == "balanced")
        #expect((response.effort?.resolvedWorkers ?? 0) >= 1)
        #expect((response.effort?.activeProcessors ?? 0) >= 1)
    }

    @Test
    func `Status reports true on-disk size from the store`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("index.db").path
        let store = DocIndexStore(dbPath: dbPath)
        // Persist one document so the database file exists on disk with
        // content the breakdown can attribute to text bytes.
        let seed = IndexedDocument(
            source: .files,
            externalID: "status-size-probe",
            displayName: "Status Size Probe",
            contentHash: "hash-status-size-probe"
        )
        let persisted = try await store.upsertDocument(seed)
        _ = try await store.upsertChunks(
            documentID: persisted.id,
            chunks: [IndexedChunk(documentID: persisted.id, ordinal: 0, text: "status size probe body")]
        )
        _ = try await store.stats()
        let breakdown = try await store.storageBreakdown()
        let attributes = try FileManager.default.attributesOfItem(atPath: dbPath)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        #expect(breakdown.dbFileBytes == fileSize)
        #expect(breakdown.dbFileBytes > 0)
        #expect(breakdown.walBytes >= 0)
        #expect(breakdown.contentBytes == breakdown.textBytes + breakdown.vectorBytes)

        let config = IndexConfig(enabled: true, files: true, dbPath: dbPath)
        let stats = try await store.stats()
        let response = makeIndexStatusResponse(
            config: config,
            stats: stats,
            running: false,
            lastErrors: [],
            storage: breakdown
        )
        #expect(response.dbFileBytes == fileSize)
        #expect(response.textBytes == stats.bytes)
    }

    @Test
    func `Status decodes payloads predating sizes and effort`() throws {
        // Older engines never wrote the size breakdown or the effort block,
        // so the status contract stays version-tolerant instead of failing.
        let payload = """
        {"enabled":true,"running":false,"documents":7,"chunks":21,"vectorChunks":14,"keywordChunks":7,"bytes":4096,"sources":[],"lastErrors":[],"bySource":[],"byExtractStatus":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IndexStatusResponse.self, from: payload)
        #expect(decoded.documents == 7)
        #expect(decoded.dbFileBytes == 0)
        #expect(decoded.walBytes == 0)
        #expect(decoded.textBytes == 0)
        #expect(decoded.vectorBytes == 0)
        #expect(decoded.ftsBytes == 0)
        #expect(decoded.freeBytes == 0)
        #expect(decoded.contentBytes == 0)
        #expect(decoded.effort == nil)
    }

    @Test
    func `Status defaults to an honest empty snapshot`() {
        let response = makeIndexStatusResponse(config: IndexConfig(), stats: nil, running: false, lastErrors: [])
        #expect(response.enabled == false)
        #expect(response.running == false)
        #expect(response.documents == 0)
        #expect(response.chunks == 0)
        #expect(response.bytes == 0)
        #expect(response.dbFileBytes == 0)
        #expect(response.walBytes == 0)
        #expect(response.textBytes == 0)
        #expect(response.vectorBytes == 0)
        #expect(response.ftsBytes == 0)
        #expect(response.freeBytes == 0)
        #expect(response.contentBytes == 0)
        #expect(response.indexAsOf == nil)
        // A globally disabled indexer gates every source, so the dashboard never
        // shows one as live while nothing can run.
        #expect(response.sources.allSatisfy { $0.enabled == false })
        #expect(response.lastErrors.isEmpty)
        // Effort still resolves so the dashboard renders workers on an empty store.
        #expect(response.effort?.preset == IndexConfig.defaultEffort)
    }
}

// MARK: - Settings patch

@Suite("Index Settings DTO")
struct IndexSettingsDTOTests {
    @Test
    func `Partial patch merges and preserves omitted fields`() throws {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(
            enabled: true,
            files: true,
            mail: false,
            messages: false,
            roots: ["~/Documents"],
            exclude: [".git"],
            maxFileMB: 20,
            mailVectorWindow: "2y",
            iCloudEvicted: "skip",
            describeImagesWithLLM: false,
            nightlyBudget: 0,
            dbPath: "~/.runeweaver/index.db",
            effort: "balanced",
            workers: 0,
            thermalBackoff: true,
            pauseOnBattery: false,
            maxVectorChunksPerDocument: 0
        )

        let update = UpdateSettingsRequest(index: IndexSettingsUpdate(
            enabled: false,
            mail: true,
            exclude: ["*.tmp"],
            maxFileMB: 50,
            effort: "light",
            thermalBackoff: false,
            pauseOnBattery: true,
            maxVectorChunksPerDocument: 120
        ))
        try update.apply(to: &config)

        #expect(config.index.enabled == false)
        #expect(config.index.mail == true)
        #expect(config.index.exclude == ["*.tmp"])
        #expect(config.index.maxFileMB == 50)
        #expect(config.index.effort == "light")
        #expect(config.index.thermalBackoff == false)
        #expect(config.index.pauseOnBattery == true)
        #expect(config.index.maxVectorChunksPerDocument == 120)
        // Every omitted field keeps its stored value.
        #expect(config.index.files == true)
        #expect(config.index.messages == false)
        #expect(config.index.roots == ["~/Documents"])
        #expect(config.index.mailVectorWindow == "2y")
        #expect(config.index.iCloudEvicted == "skip")
        #expect(config.index.describeImagesWithLLM == false)
        #expect(config.index.nightlyBudget == 0)
        #expect(config.index.dbPath == "~/.runeweaver/index.db")
        #expect(config.index.workers == 0)
    }

    @Test
    func `Custom effort patch carries its worker count`() throws {
        var config = RuneWeaverConfig.default
        config.index.effort = "balanced"
        config.index.workers = 0

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let update = UpdateSettingsRequest(index: IndexSettingsUpdate(
            effort: "custom",
            workers: cores
        ))
        try update.apply(to: &config)

        #expect(config.index.effort == "custom")
        #expect(config.index.workers == cores)
    }

    @Test
    func `Full snapshot round-trips through the same merge helper`() throws {
        var source = RuneWeaverConfig.default
        source.index = IndexConfig(
            enabled: true,
            files: false,
            mail: true,
            messages: true,
            roots: ["~/Notes", "~/Code"],
            exclude: [".git", "*.o"],
            maxFileMB: 64,
            mailVectorWindow: "1y",
            iCloudEvicted: "download",
            describeImagesWithLLM: true,
            nightlyBudget: 500,
            dbPath: "~/.runeweaver/index.db",
            effort: "performance",
            workers: 0,
            thermalBackoff: false,
            pauseOnBattery: true,
            maxVectorChunksPerDocument: 80
        )

        let update = UpdateSettingsRequest(index: IndexSettingsUpdate(source.index))
        var applied = RuneWeaverConfig.default
        try update.apply(to: &applied)

        #expect(applied.index == source.index)
    }

    @Test
    func `Settings response mirrors the index section`() {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(enabled: true, files: false, mail: true)
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.index == config.index)
    }

    @Test
    func `Index patch uses snake_case wire keys`() throws {
        let update = IndexSettingsUpdate(
            maxFileMB: 50,
            mailVectorWindow: "all",
            iCloudEvicted: "download",
            describeImagesWithLLM: true,
            effort: "custom",
            workers: 2,
            thermalBackoff: false,
            pauseOnBattery: true,
            maxVectorChunksPerDocument: 120
        )
        let data = try JSONEncoder().encode(update)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(object["max_file_mb"] as? Int == 50)
        #expect(object["mail_vector_window"] as? String == "all")
        #expect(object["icloud_evicted"] as? String == "download")
        #expect(object["describe_images_with_llm"] as? Bool == true)
        #expect(object["effort"] as? String == "custom")
        #expect(object["workers"] as? Int == 2)
        #expect(object["thermal_backoff"] as? Bool == false)
        #expect(object["pause_on_battery"] as? Bool == true)
        #expect(object["max_vector_chunks_per_document"] as? Int == 120)
    }

    @Test
    func `Index patch decodes the workers field`() throws {
        let payload = """
        {"effort":"custom","workers":5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IndexSettingsUpdate.self, from: payload)
        #expect(decoded.workers == 5)
    }

    @Test
    func `Settings response carries the walker always-skipped list`() throws {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(enabled: true, files: true, roots: ["~"])
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        // Single-sourced from the walker's prune list so the dashboard copy
        // cannot drift from what the next run actually skips.
        #expect(response.index.alwaysSkipped == FilesIndexer.alwaysSkippedPatterns)
        #expect(response.index.alwaysSkipped.contains("Music"))
        #expect(response.index.alwaysSkipped.contains(".git"))
        // The wire payload carries the read-only array under snake_case.
        let data = try JSONEncoder().encode(response.index)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let wire = object["always_skipped"] as? [String]
        #expect(wire == FilesIndexer.alwaysSkippedPatterns)
    }

    @Test
    func `Index patch ignores always-skipped on write`() throws {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(enabled: true, files: true, roots: ["~"], exclude: [".git"])
        let before = config.index.alwaysSkipped
        // A client echo carrying a stale list must not drift the stored policy.
        let update = UpdateSettingsRequest(index: IndexSettingsUpdate(
            enabled: false,
            alwaysSkipped: ["SentinelSkipAlpha", "SentinelSkipBeta"]
        ))
        try update.apply(to: &config)
        #expect(config.index.enabled == false)
        #expect(config.index.alwaysSkipped == before)
        #expect(config.index.alwaysSkipped == FilesIndexer.alwaysSkippedPatterns)
        #expect(!config.index.alwaysSkipped.contains("SentinelSkipAlpha"))
        // Decoding a payload that carries the key also discards it.
        let payload = """
        {"enabled":true,"always_skipped":["SentinelSkipAlpha"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IndexConfig.self, from: payload)
        #expect(decoded.alwaysSkipped == FilesIndexer.alwaysSkippedPatterns)
    }
}

// MARK: - Live construction on settings save

/// Covers the settings-save reconciliation that swaps the live store and
/// coordinator without a restart: enable-from-disabled, `db_path` moves,
/// disable-while-running teardown, and fail-closed construction.
@Suite("Index Live Construction")
struct IndexLiveConstructionTests {
    /// Makes an isolated directory for one test's index databases.
    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Builds a persisted config with the index policy applied.
    private func makeSavedConfig(enabled: Bool, dbPath: String) -> RuneWeaverConfig {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(enabled: enabled, files: true, mail: false, messages: false, roots: [], dbPath: dbPath)
        return config
    }

    /// Waits until the coordinator reports a run in flight.
    private func waitForRunning(_ coordinator: IndexCoordinator) async {
        for _ in 0 ..< 100 {
            if await coordinator.isRunning {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test
    func `Enable from disabled constructs live so run succeeds without restart`() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("index.db").path

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext()
            registerRuneWeaverRoutes(app)

            // No coordinator wired yet, so the control surface fails closed.
            let before = try await indexRequest(app: app, method: .POST, path: "/index/run")
            #expect(before.status == .serviceUnavailable)

            try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: true, dbPath: dbPath), context: app.runeWeaver)

            // The swap landed live: the same app now runs without a restart.
            let run = try await indexRequest(app: app, method: .POST, path: "/index/run")
            #expect(run.status == .ok)
            let summary = try run.content.decode(IndexRunResponse.self)
            #expect(summary.status == IndexRunStatus.ok.rawValue)
            let livePath = await app.runeWeaver.indexStore?.dbPath
            #expect(livePath == dbPath)
        }
    }

    @Test
    func `Db path change constructs against the new path and swaps`() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstPath = directory.appendingPathComponent("first.db").path
        let secondPath = directory.appendingPathComponent("second.db").path

        let context = makeIndexTestContext()
        try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: true, dbPath: firstPath), context: context)
        let firstCoordinator = context.indexCoordinator
        #expect(firstCoordinator != nil)
        #expect(await context.indexStore?.dbPath == firstPath)

        try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: true, dbPath: secondPath), context: context)
        #expect(await context.indexStore?.dbPath == secondPath)
        // A new generation serves the new path rather than reusing the old one.
        #expect(context.indexCoordinator !== firstCoordinator)

        let summary = await context.indexCoordinator?.run(trigger: .onDemand)
        #expect(summary?.status == .ok)
    }

    @Test
    func `Same db path refreshes policy without rebuilding`() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("index.db").path

        let context = makeIndexTestContext()
        try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: true, dbPath: dbPath), context: context)
        let coordinator = context.indexCoordinator
        #expect(coordinator != nil)

        var refreshed = makeSavedConfig(enabled: true, dbPath: dbPath)
        refreshed.index.mail = true
        try await reconcileLiveIndexPolicy(savedConfig: refreshed, context: context)
        #expect(context.indexCoordinator === coordinator)
        #expect(await context.indexStore?.dbPath == dbPath)
    }

    @Test
    func `Disable cancels the in-flight run then tears down`() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("index.db").path
        let store = DocIndexStore(dbPath: dbPath)
        let slowStage = IndexClosureStage(kind: .files, isEnabled: true) { _, isCancelled in
            for _ in 0 ..< 200 {
                if isCancelled() {
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return IndexSourceRunReport(kind: .files, scanned: 1, indexed: 0)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [slowStage],
            store: store
        )
        let context = makeIndexTestContext(coordinator: coordinator, store: store)

        let runTask = Task { await coordinator.run(trigger: .onDemand) }
        await waitForRunning(coordinator)
        #expect(await coordinator.isRunning)

        try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: false, dbPath: dbPath), context: context)

        let summary = await runTask.value
        #expect(summary.status == .cancelled)
        #expect(context.indexCoordinator == nil)
        #expect(context.indexStore == nil)
    }

    @Test
    func `Bad db path fails closed with the old index intact`() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goodPath = directory.appendingPathComponent("good.db").path
        // A directory is not a usable SQLite file, so probing it must fail.
        let badPath = directory.path

        let context = makeIndexTestContext()
        try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: true, dbPath: goodPath), context: context)
        #expect(await context.indexStore?.dbPath == goodPath)

        do {
            try await reconcileLiveIndexPolicy(savedConfig: makeSavedConfig(enabled: true, dbPath: badPath), context: context)
            #expect(Bool(false), "a bad db_path must throw before mutating the live context")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }
        // The previous generation keeps serving after the rejected swap.
        #expect(await context.indexStore?.dbPath == goodPath)
        #expect(context.indexCoordinator != nil)
        let summary = await context.indexCoordinator?.run(trigger: .onDemand)
        #expect(summary?.status == .ok)
    }
}

// MARK: - Live snapshot and kind-filtered latest run

/// Covers the additive live strip plus the durable latest-run lookup: live is
/// present while a run is in flight and null when idle, the newest index row
/// survives heavy chat interleaving, and a cancelled pass still leaves a strip
/// entry carrying its partial counts.
@Suite("Index Status Live and Latest Run")
struct IndexStatusLiveLatestTests {
    /// Waits until the coordinator reports a run in flight.
    private func waitForRunning(_ coordinator: IndexCoordinator) async {
        for _ in 0 ..< 100 {
            if await coordinator.isRunning {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Builds an isolated store plus a coordinator around the given stages.
    private func makeLiveComponents(stages: [IndexClosureStage]) throws -> (coordinator: IndexCoordinator, store: DocIndexStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DocIndexStore(dbPath: directory.appendingPathComponent("index.db").path)
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: stages,
            store: store,
            stateStore: IndexRunStateStore(path: directory.appendingPathComponent("state.json").path)
        )
        return (coordinator, store, directory)
    }

    @Test
    func `Live present during run and null when idle`() async throws {
        let slowStage = IndexClosureStage(kind: .files, isEnabled: true) { reporter, _ in
            await reporter(ToolProgress(
                message: "Indexing files",
                scanned: 3,
                matched: 1,
                current: "notes/report.md"
            ))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return IndexSourceRunReport(kind: .files, scanned: 3, indexed: 1, lastItem: "notes/report.md")
        }
        let (coordinator, store, directory) = try makeLiveComponents(stages: [slowStage])
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withIndexTestApp { app in
            app.runeWeaver = makeIndexTestContext(coordinator: coordinator, store: store)
            registerRuneWeaverRoutes(app)

            // Idle before the run reports no live strip.
            let idle = try await indexRequest(app: app, method: .GET, path: "/index/status")
            #expect(idle.status == .ok)
            #expect(try idle.content.decode(IndexStatusResponse.self).live == nil)

            let runTask = Task { await coordinator.run(trigger: .onDemand) }
            await waitForRunning(coordinator)
            #expect(await coordinator.isRunning)

            // In flight the probe carries the live counters plus phase, stage,
            // trigger, rate, elapsed, and the relative current file.
            let during = try await indexRequest(app: app, method: .GET, path: "/index/status")
            #expect(during.status == .ok)
            let live = try during.content.decode(IndexStatusResponse.self).live
            #expect(live != nil)
            #expect(live?.trigger == IndexRunTrigger.onDemand.rawValue)
            #expect(live?.phase == IndexPhase.extracting.rawValue)
            #expect(live?.stage == IndexSourceKind.files.rawValue)
            #expect((live?.scanned ?? 0) >= 1)
            #expect((live?.indexed ?? 0) >= 0)
            #expect((live?.elapsedMs ?? 0) >= 0)
            #expect((live?.rate ?? -1) >= 0)
            #expect(live?.current == "notes/report.md")

            let summary = await runTask.value
            #expect(summary.status == .ok)

            // Settled runs clear the snapshot so polling unmounts the strip.
            let after = try await indexRequest(app: app, method: .GET, path: "/index/status")
            #expect(after.status == .ok)
            let settled = try after.content.decode(IndexStatusResponse.self)
            #expect(settled.running == false)
            #expect(settled.live == nil)
        }
    }

    @Test
    func `Latest run survives heavy chat interleaving`() async throws {
        try await withIndexTestApp { app in
            let context = makeIndexTestContext()
            app.runeWeaver = context
            registerRuneWeaverRoutes(app)

            // One durable index row carrying counts plus its trigger line.
            let message = "Index run ok: 7 indexed, 1 vectors, 6 keyword-only, 10 scanned, 0 errors"
            let response = message + "\nTrigger: onDemand"
            _ = await context.runs.append(
                kind: ServerIndexRunReporter.kind,
                status: IndexRunStatus.ok.rawValue,
                message: message,
                response: response
            )

            // Enough chat traffic to push the index row far past the old
            // newest-N window: a kind-filtered lookup must still find it.
            for index in 0 ..< 150 {
                _ = await context.runs.append(
                    kind: "chat",
                    status: "ok",
                    message: "chat turn \(index)"
                )
            }

            let status = try await indexRequest(app: app, method: .GET, path: "/index/status")
            #expect(status.status == .ok)
            let lastRun = try status.content.decode(IndexStatusResponse.self).lastRun
            #expect(lastRun != nil)
            #expect(lastRun?.status == IndexRunStatus.ok.rawValue)
            #expect(lastRun?.indexed == 7)
            #expect(lastRun?.scanned == 10)
            #expect(lastRun?.errors == 0)
            #expect(lastRun?.trigger == IndexRunTrigger.onDemand.rawValue)
        }
    }

    @Test
    func `Cancelled run persists a strip entry with partial counts`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withIndexTestApp { app in
            let context = makeIndexTestContext()
            let store = DocIndexStore(dbPath: directory.appendingPathComponent("index.db").path)
            let reporter = ServerIndexRunReporter(runs: context.runs, hub: context.hub)
            let slowStage = IndexClosureStage(kind: .files, isEnabled: true) { _, isCancelled in
                for _ in 0 ..< 200 {
                    if isCancelled() {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return IndexSourceRunReport(kind: .files, scanned: 4, indexed: 2, skipped: 1)
            }
            let coordinator = IndexCoordinator(
                config: IndexConfig(enabled: true, files: true, roots: []),
                stages: [slowStage],
                store: store,
                reporter: reporter
            )
            context.setLiveIndex(store: store, coordinator: coordinator)
            app.runeWeaver = context
            registerRuneWeaverRoutes(app)

            let runTask = Task { await coordinator.run(trigger: .onDemand) }
            await waitForRunning(coordinator)
            #expect(await coordinator.isRunning)
            await coordinator.cancel()
            let summary = await runTask.value
            #expect(summary.status == .cancelled)

            // The terminal cancelled row keeps the partial counts so the strip
            // renders the work done so far instead of disappearing.
            let status = try await indexRequest(app: app, method: .GET, path: "/index/status")
            #expect(status.status == .ok)
            let lastRun = try status.content.decode(IndexStatusResponse.self).lastRun
            #expect(lastRun != nil)
            #expect(lastRun?.status == IndexRunStatus.cancelled.rawValue)
            #expect(lastRun?.indexed == summary.documentsIndexed)
            #expect(lastRun?.scanned == summary.scanned)
            #expect(lastRun?.trigger == IndexRunTrigger.onDemand.rawValue)
        }
    }

    @Test
    func `Skipped run surfaces its reason on the strip`() async throws {
        try await withIndexTestApp { app in
            let context = makeIndexTestContext()
            app.runeWeaver = context
            registerRuneWeaverRoutes(app)

            // A durable skipped row carries the `Skipped:` detail line the
            // coordinator writes, so the strip renders the same reason the
            // run notice shows.
            let message = "Index run skipped: 0 indexed, 0 vectors, 0 keyword-only, 0 scanned, 0 errors"
            let response = message + "\nTrigger: onDemand\nSkipped: Indexing is disabled in [index]."
            _ = await context.runs.append(
                kind: ServerIndexRunReporter.kind,
                status: IndexRunStatus.skipped.rawValue,
                message: message,
                response: response
            )

            let status = try await indexRequest(app: app, method: .GET, path: "/index/status")
            #expect(status.status == .ok)
            let lastRun = try status.content.decode(IndexStatusResponse.self).lastRun
            #expect(lastRun != nil)
            #expect(lastRun?.status == IndexRunStatus.skipped.rawValue)
            #expect(lastRun?.trigger == IndexRunTrigger.onDemand.rawValue)
            #expect(lastRun?.skippedReason == "Indexing is disabled in [index].")
        }
    }

    @Test
    func `Last-run strip decodes payloads predating the skip reason`() throws {
        // Older engines never wrote `skippedReason`, so the strip contract
        // stays version-tolerant and decodes to a nil reason instead of failing.
        let payload = """
        {"status":"ok","indexed":7,"scanned":10,"errors":0,"trigger":"onDemand"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IndexLastRunStatus.self, from: payload)
        #expect(decoded.status == IndexRunStatus.ok.rawValue)
        #expect(decoded.indexed == 7)
        #expect(decoded.trigger == IndexRunTrigger.onDemand.rawValue)
        #expect(decoded.skippedReason == nil)
    }
}
