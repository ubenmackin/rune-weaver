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
                (.POST, "/index/reset")
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

            for path in ["/index/run", "/index/cancel", "/index/prune", "/index/reset"] {
                let response = try await indexRequest(app: app, method: .POST, path: path)
                #expect(response.status == .serviceUnavailable, "\(path) must fail closed without a coordinator")
            }
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

        let response = makeIndexStatusResponse(
            config: config,
            stats: stats,
            running: true,
            lastErrors: ["mail: gateway timeout"]
        )

        #expect(response.enabled == true)
        #expect(response.running == true)
        #expect(response.documents == 7)
        #expect(response.chunks == 21)
        #expect(response.vectorChunks == 14)
        #expect(response.keywordChunks == 7)
        #expect(response.bytes == 4096)
        #expect(response.indexAsOf == snapshot)
        #expect(response.sources == [
            IndexSourceStatus(kind: "files", enabled: true),
            IndexSourceStatus(kind: "mail", enabled: false),
            IndexSourceStatus(kind: "messages", enabled: true)
        ])
        #expect(response.lastErrors == ["mail: gateway timeout"])
    }

    @Test
    func `Status defaults to an honest empty snapshot`() {
        let response = makeIndexStatusResponse(config: IndexConfig(), stats: nil, running: false, lastErrors: [])
        #expect(response.enabled == false)
        #expect(response.running == false)
        #expect(response.documents == 0)
        #expect(response.chunks == 0)
        #expect(response.bytes == 0)
        #expect(response.indexAsOf == nil)
        // A globally disabled indexer gates every source, so the dashboard never
        // shows one as live while nothing can run.
        #expect(response.sources.allSatisfy { $0.enabled == false })
        #expect(response.lastErrors.isEmpty)
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
            dbPath: "~/.runeweaver/index.db"
        )

        let update = UpdateSettingsRequest(index: IndexSettingsUpdate(
            enabled: false,
            mail: true,
            exclude: ["*.tmp"],
            maxFileMB: 50
        ))
        try update.apply(to: &config)

        #expect(config.index.enabled == false)
        #expect(config.index.mail == true)
        #expect(config.index.exclude == ["*.tmp"])
        #expect(config.index.maxFileMB == 50)
        // Every omitted field keeps its stored value.
        #expect(config.index.files == true)
        #expect(config.index.messages == false)
        #expect(config.index.roots == ["~/Documents"])
        #expect(config.index.mailVectorWindow == "2y")
        #expect(config.index.iCloudEvicted == "skip")
        #expect(config.index.describeImagesWithLLM == false)
        #expect(config.index.nightlyBudget == 0)
        #expect(config.index.dbPath == "~/.runeweaver/index.db")
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
            dbPath: "~/.runeweaver/index.db"
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
            describeImagesWithLLM: true
        )
        let data = try JSONEncoder().encode(update)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(object["max_file_mb"] as? Int == 50)
        #expect(object["mail_vector_window"] as? String == "all")
        #expect(object["icloud_evicted"] as? String == "download")
        #expect(object["describe_images_with_llm"] as? Bool == true)
    }
}
