// Rune Weaver Server Tests — Session archiving and filtering routes.

import Foundation
import NIOCore
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

private final class SessionTestStubLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "stub", provider: "stub", contextLength: 8192)
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "ok", isFinished: true, totalTokens: 5))
            continuation.finish()
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

@Suite("Server Session Archiving Routes")
struct ServerSessionArchivingRouteTests {
    private struct SessionRouteHarness {
        let app: Application
        let context: ServerContext
        let conversations: ConversationManager
    }

    private func withSessionHarness<T>(
        _ body: (SessionRouteHarness) async throws -> T
    ) async throws -> T {
        let app = try await Application.make(.testing)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: SessionTestStubLLM(),
            memoryEngine: memory
        )
        let runs = RunLogStore()
        let hub = WSHub()
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            scheduler: SchedulerStore(),
            runs: runs,
            hub: hub,
            pluginStore: ToolRegistryStore(dbPath: dbPath),
            toolStates: ToolStateStore(dbPath: dbPath),
            stagedFiles: StagedFilesStore(dbPath: dbPath)
        )
        try configureRuneWeaver(app, context: context)
        let harness = SessionRouteHarness(app: app, context: context, conversations: conversations)
        do {
            let result = try await body(harness)
            try await app.asyncShutdown()
            try? FileManager.default.removeItem(at: base)
            return result
        } catch {
            try? await app.asyncShutdown()
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    private func sendRequest(app: Application, method: HTTPMethod, path: String) async throws -> Response {
        let request = Request(
            application: app,
            method: method,
            url: URI(string: path),
            on: app.eventLoopGroup.next()
        )
        return try await app.responder.respond(to: request).get()
    }

    @Test
    func `GET /sessions filters archived and query parameter includes them`() async throws {
        try await withSessionHarness { harness in
            let activeID = UUID()
            let archivedID = UUID()

            await harness.conversations.ensureSession(id: activeID, title: "Active Session")
            _ = await harness.conversations.append(Message(role: .user, content: "Active hello"), to: activeID)

            await harness.conversations.ensureSession(id: archivedID, title: "Archived Session")
            _ = await harness.conversations.append(Message(role: .user, content: "Archived hello"), to: archivedID)
            await harness.conversations.setSessionArchived(id: archivedID, isArchived: true)

            // Default GET /sessions: should only contain active
            let defaultResponse = try await sendRequest(app: harness.app, method: .GET, path: "/sessions")
            #expect(defaultResponse.status == .ok)
            let defaultData = try defaultResponse.content.decode(SessionsResponse.self)
            #expect(defaultData.sessions.contains(where: { $0.id == activeID }))
            #expect(!defaultData.sessions.contains(where: { $0.id == archivedID }))

            // GET /sessions?include_archived=true: should contain both
            let includeResponse = try await sendRequest(app: harness.app, method: .GET, path: "/sessions?include_archived=true")
            #expect(includeResponse.status == .ok)
            let includeData = try includeResponse.content.decode(SessionsResponse.self)
            #expect(includeData.sessions.contains(where: { $0.id == activeID }))
            #expect(includeData.sessions.contains(where: { $0.id == archivedID }))
            let archivedSummary = includeData.sessions.first(where: { $0.id == archivedID })
            #expect(archivedSummary?.isArchived == true)
        }
    }

    @Test
    func `POST /sessions/:id/archive and unarchive toggles session archived state`() async throws {
        try await withSessionHarness { harness in
            let sessionID = UUID()
            await harness.conversations.ensureSession(id: sessionID, title: "Toggle Archive Session")
            _ = await harness.conversations.append(Message(role: .user, content: "Hello"), to: sessionID)

            // Archive the session
            let archiveResponse = try await sendRequest(app: harness.app, method: .POST, path: "/sessions/\(sessionID)/archive")
            #expect(archiveResponse.status == .noContent)

            let afterArchive = await harness.conversations.session(id: sessionID)
            #expect(afterArchive?.isArchived == true)

            // Unarchive the session
            let unarchiveResponse = try await sendRequest(app: harness.app, method: .POST, path: "/sessions/\(sessionID)/unarchive")
            #expect(unarchiveResponse.status == .noContent)

            let afterUnarchive = await harness.conversations.session(id: sessionID)
            #expect(afterUnarchive?.isArchived == false)

            // 404 for unknown session
            let unknownID = UUID()
            let notFoundArchive = try await sendRequest(app: harness.app, method: .POST, path: "/sessions/\(unknownID)/archive")
            #expect(notFoundArchive.status == .notFound)
        }
    }
}
