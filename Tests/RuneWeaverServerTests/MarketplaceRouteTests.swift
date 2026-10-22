// Rune Weaver Server Tests — Marketplace catalog and plugin installation routes.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

@Suite("Marketplace Routes")
struct MarketplaceRouteTests {
    private struct MarketplaceStubLLM: LLMProvider, Sendable {
        let modelInfo = ModelInfo(name: "marketplace-stub", provider: "stub", contextLength: 2048)
        func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
            AsyncStream { $0.finish() }
        }

        func embeddings(text _: [String]) async throws -> [[Float]] {
            []
        }
    }

    private static func sendRequest(
        app: Application,
        method: HTTPMethod,
        path: String
    ) async throws -> Response {
        let request = Request(
            application: app,
            method: method,
            url: URI(string: path),
            on: app.eventLoopGroup.next()
        )
        return try await app.responder.respond(to: request).get()
    }

    private static func sendRequest(
        app: Application,
        method: HTTPMethod,
        path: String,
        body: some Content
    ) async throws -> Response {
        let request = Request(
            application: app,
            method: method,
            url: URI(string: path),
            on: app.eventLoopGroup.next()
        )
        try request.content.encode(body)
        return try await app.responder.respond(to: request).get()
    }

    private func withMarketplaceApp<T>(
        pluginsDir: URL,
        dbPath: String,
        marketplaceIndexURL: String,
        _ body: (Application, ServerContext) async throws -> T
    ) async throws -> T {
        let app = try await Application.make(.testing)
        do {
            let conversations = ConversationManager()
            let gate = PermissionGate()
            let approvals = ApprovalQueue(permissionGate: gate)
            let memory = MemoryEngine(
                episodesDBPath: dbPath,
                vectorDBPath: pluginsDir.appendingPathComponent("vectors.db").path
            )
            let orchestrator = Orchestrator(
                conversations: conversations,
                toolBus: ToolBus(permissionGate: gate),
                llm: MarketplaceStubLLM(),
                memoryEngine: memory
            )
            let pStore = ToolRegistryStore(dbPath: dbPath)
            let pDiscovery = PluginDiscoveryService(pluginsDirectory: pluginsDir, store: pStore)
            let context = ServerContext(
                conversations: conversations,
                toolBus: ToolBus(permissionGate: gate),
                orchestrator: orchestrator,
                memoryEngine: memory,
                permissionGate: gate,
                approvals: approvals,
                pluginStore: pStore,
                pluginDiscovery: pDiscovery,
                pluginConfig: PluginConfig(pluginsDir: pluginsDir.path, marketplaceIndexURL: marketplaceIndexURL),
                toolStates: ToolStateStore(dbPath: dbPath)
            )
            try configureRuneWeaver(app, context: context)
            let value = try await body(app, context)
            try await app.asyncShutdown()
            return value
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func `GET /marketplace/plugins includes community.monarch-money from local index`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("test-marketplace-get-\(UUID().uuidString)")
        let pluginsDir = base.appendingPathComponent("plugins")
        let dbPath = base.appendingPathComponent("episodes.db").path
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Resolve index relative to the test source so CWD never decides the result.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let indexURL = repoRoot.appendingPathComponent("Plugins/index.json")

        try await withMarketplaceApp(pluginsDir: pluginsDir, dbPath: dbPath, marketplaceIndexURL: indexURL.path) { app, _ in
            let res = try await Self.sendRequest(app: app, method: .GET, path: "/marketplace/plugins")
            #expect(res.status == .ok)
            let decoded = try res.content.decode(MarketplaceResponse.self)
            let ids = Set(decoded.items.map(\.id))
            #expect(ids.contains("community.monarch-money"))
            #expect(decoded.items.count == 1)
            #expect(!ids.contains("community.playwright-browser"))
            #expect(!ids.contains("community.homeassistant-control"))
            #expect(!ids.contains("community.github-explorer"))
            #expect(!ids.contains("community.clock-timer"))
            let monarch = decoded.items.first { $0.id == "community.monarch-money" }
            #expect(monarch != nil)
            #expect(monarch?.name == "Monarch Money")
            #expect(monarch?.runtime == "python")
            #expect(monarch?.declaredTools.contains("monarch.accounts") == true)
            #expect(monarch?.isInstalled == false)
        }
    }

    @Test
    func `POST /marketplace/install installs community.monarch-money files into plugins directory`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("test-marketplace-post-\(UUID().uuidString)")
        let pluginsDir = base.appendingPathComponent("plugins")
        let dbPath = base.appendingPathComponent("episodes.db").path
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Resolve index relative to the test source so CWD never decides the result.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let indexURL = repoRoot.appendingPathComponent("Plugins/index.json")

        try await withMarketplaceApp(pluginsDir: pluginsDir, dbPath: dbPath, marketplaceIndexURL: indexURL.path) { app, _ in
            let installReq = InstallMarketplacePluginRequest(id: "community.monarch-money")
            let res = try await Self.sendRequest(app: app, method: .POST, path: "/marketplace/install", body: installReq)
            #expect(res.status == .ok)
            let summary = try res.content.decode(PluginSummary.self)
            #expect(summary.id == "community.monarch-money")
            #expect(summary.status == "discovered")
            #expect(summary.isEnabled == false)
            #expect(summary.tools.count == 4)

            // Verify files exist in plugins directory
            let targetMonarchDir = pluginsDir.appendingPathComponent("community.monarch-money")
            #expect(FileManager.default.fileExists(atPath: targetMonarchDir.appendingPathComponent("rune.json").path))
            #expect(FileManager.default.fileExists(atPath: targetMonarchDir.appendingPathComponent("main.py").path))
            #expect(FileManager.default.fileExists(atPath: targetMonarchDir.appendingPathComponent("requirements.txt").path))
            #expect(FileManager.default.fileExists(atPath: targetMonarchDir.appendingPathComponent("README.md").path))

            // Check GET /marketplace/plugins now reports isInstalled == true
            let listRes = try await Self.sendRequest(app: app, method: .GET, path: "/marketplace/plugins")
            let listDecoded = try listRes.content.decode(MarketplaceResponse.self)
            let monarch = listDecoded.items.first { $0.id == "community.monarch-money" }
            #expect(monarch?.isInstalled == true)
        }
    }
}
