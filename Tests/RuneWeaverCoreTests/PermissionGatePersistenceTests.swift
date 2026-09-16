// Rune Weaver Tests — PermissionGate SQLite persistence, startup cleanup, and periodic reaper.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("PermissionGate Persistence & Reaper Tests")
struct PermissionGatePersistenceTests {
    private func temporaryDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-trust-\(UUID().uuidString).db")
            .path
    }

    /// Counts every row in `trust_grants`, including expired rows.
    private func rawTrustGrantRowCount(dbPath: String) -> Int {
        #if canImport(SQLite3)
            let path = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            let status = path.withCString { sqlite3_open($0, &handle) }
            guard status == SQLITE_OK, let handle else { return -1 }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM trust_grants;", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return -1 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        #else
            return -1
        #endif
    }

    @Test
    func `SQLiteTrustStore saves and loads active grants`() async throws {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteTrustStore(dbPath: dbPath)
        let grantForever = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "alice@example.com"),
            grantedAt: Date(),
            expiresAt: nil,
            duration: .forever
        )
        let grantTimed = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "file.write", target: "/tmp/test.txt"),
            grantedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            duration: .oneHour
        )

        try await store.save([grantForever, grantTimed])

        let loaded = try await store.load()
        #expect(loaded.count == 2)
        #expect(loaded.contains { $0.actionDescriptor.toolName == "email.send" && $0.actionDescriptor.target == "alice@example.com" && $0.expiresAt == nil })
        #expect(loaded.contains { $0.actionDescriptor.toolName == "file.write" && $0.actionDescriptor.target == "/tmp/test.txt" && $0.expiresAt != nil })
    }

    @Test
    func `PermissionGate bootstrap prunes expired grants on startup`() async throws {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteTrustStore(dbPath: dbPath)

        // Seed 1 forever grant, 1 active grant, and 1 expired grant
        let now = Date()
        let grantForever = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "alice@example.com"),
            grantedAt: now,
            expiresAt: nil,
            duration: .forever
        )
        let grantActive = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "bob@example.com"),
            grantedAt: now,
            expiresAt: now.addingTimeInterval(600),
            duration: .fiveMinutes
        )
        let grantExpired = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "charlie@example.com"),
            grantedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(-10),
            duration: .fiveMinutes
        )

        try await store.save([grantForever, grantActive, grantExpired])

        // Boot a new PermissionGate instance against the same database
        let gate = await PermissionGate.load(store: store)

        let active = await gate.activeGrants()
        #expect(active.count == 2)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "alice@example.com")))
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "bob@example.com")))
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "charlie@example.com")) == false)

        // Confirm expired grant was physically removed from SQLite on startup
        let rawLoaded = try await store.load()
        #expect(rawLoaded.count == 2)
        #expect(rawLoaded.contains { $0.actionDescriptor.target == "charlie@example.com" } == false)
    }

    @Test
    func `PermissionGate periodic cleanup reaper purges expired grants`() async throws {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteTrustStore(dbPath: dbPath)
        let gate = await PermissionGate.load(store: store)

        // Add a forever grant and a very short-lived grant (expires in 0.05s)
        await gate.grantTrust(
            for: ActionDescriptor(toolName: "email.send", target: "safe@example.com"),
            duration: .forever
        )
        // Manually save an expired grant to simulate time passing while reaper runs
        let expiredGrant = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "file.delete", target: "/tmp/stale.txt"),
            grantedAt: Date().addingTimeInterval(-10),
            expiresAt: Date().addingTimeInterval(-1),
            duration: .fiveMinutes
        )
        var allGrants = await gate.activeGrants()
        allGrants.append(expiredGrant)
        try await store.save(allGrants)

        // The filtered load hides the expired row, so confirm it is
        // physically present before the reaper runs.
        #expect(rawTrustGrantRowCount(dbPath: dbPath) == 2)

        // Start reaper with 0.05s cadence
        await gate.startPeriodicCleanup(intervalSeconds: 0.05)

        // Wait slightly for reaper to tick
        try await Task.sleep(nanoseconds: 150_000_000) // 0.15s

        await gate.stopPeriodicCleanup()

        // Verify expired grant was purged by the reaper
        let activeAfter = await gate.activeGrants()
        #expect(activeAfter.count == 1)
        #expect(activeAfter[0].actionDescriptor.target == "safe@example.com")

        let storedGrants = try await store.load()
        #expect(storedGrants.count == 1)
        #expect(storedGrants[0].actionDescriptor.target == "safe@example.com")

        // A filtered load would pass even without the reaper, so assert
        // the raw row count to prove physical deletion happened.
        #expect(rawTrustGrantRowCount(dbPath: dbPath) == 1)
    }

    @Test
    func `PermissionGate grantTrust and revokeTrust update persistent storage`() async throws {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteTrustStore(dbPath: dbPath)
        let gate = await PermissionGate.load(store: store)

        await gate.grantTrust(
            for: ActionDescriptor(toolName: "email.send", target: "persist@example.com"),
            duration: .oneHour
        )

        // grantTrust awaits persistence, so storage already reflects the new grant.
        var stored = try await store.load()
        #expect(stored.count == 1)
        #expect(stored[0].actionDescriptor.target == "persist@example.com")

        // Revoke trust
        await gate.revokeTrust(for: ActionDescriptor(toolName: "email.send", target: "persist@example.com"))

        // revokeTrust awaits persistence, so storage already reflects the removal.
        stored = try await store.load()
        #expect(stored.isEmpty)
    }

    @Test
    func `Fresh grants start unused with zero count and nil stamp`() async throws {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteTrustStore(dbPath: dbPath)
        let gate = await PermissionGate.load(store: store)
        let descriptor = ActionDescriptor(toolName: "email.send", target: "fresh@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)

        // A replacement lifetime must not inherit prior counters, so fresh rows
        // prove the zero baseline instead of assuming it.
        let live = await gate.activeGrants()
        #expect(live.count == 1)
        #expect(live.first?.useCount == 0)
        #expect(live.first?.lastUsedAt == nil)

        // The zero baseline must survive the durable round-trip, not just memory.
        let stored = try await store.load()
        #expect(stored.count == 1)
        #expect(stored.first?.useCount == 0)
        #expect(stored.first?.lastUsedAt == nil)
    }

    @Test
    func `recordUse increments and stamps time and survives save plus load`() async {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteTrustStore(dbPath: dbPath)
        let gate = await PermissionGate.load(store: store)
        let descriptor = ActionDescriptor(toolName: "email.send", target: "used@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)

        // Each covered call bumps the counter and refreshes the stamp so the
        // dashboard can prove liveness instead of guessing from grant age.
        await gate.recordUse(for: descriptor)
        await gate.recordUse(for: descriptor)
        await gate.recordUse(for: descriptor)

        let live = await gate.activeGrants()
        #expect(live.count == 1)
        #expect(live.first?.useCount == 3)
        #expect(live.first?.lastUsedAt != nil)

        // Reload on the same file to prove the counters are durable, not just
        // resident in the granting gate instance.
        let reloaded = await PermissionGate.load(store: store)
        let restored = await reloaded.activeGrants()
        #expect(restored.count == 1)
        #expect(restored.first?.useCount == 3)
        #expect(restored.first?.lastUsedAt != nil)
        // SQLite REAL loses sub-millisecond precision, so compare with 1ms tolerance.
        if let liveStamp = live.first?.lastUsedAt, let restoredStamp = restored.first?.lastUsedAt {
            #expect(abs(liveStamp.timeIntervalSince(restoredStamp)) < 0.001)
        } else {
            Issue.record("Expected lastUsedAt on both live and restored grants")
        }
    }

    @Test
    func `Legacy SQLite rows without counter columns load as unused`() async throws {
        let dbPath = temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        #if canImport(SQLite3)
            // Hand-build a pre-counters database so the guarded migration path
            // is exercised: the loader must default counters instead of
            // failing the whole grant list.
            let expanded = (dbPath as NSString).expandingTildeInPath
            var rawHandle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &rawHandle) }) == SQLITE_OK,
                  let rawHandle
            else {
                Issue.record("Could not open legacy database")
                return
            }
            let createLegacy = """
            CREATE TABLE trust_grants (
                id TEXT PRIMARY KEY,
                tool_name TEXT NOT NULL,
                target TEXT NOT NULL,
                granted_at REAL NOT NULL,
                expires_at REAL,
                duration TEXT NOT NULL
            );
            """
            guard sqlite3_exec(rawHandle, createLegacy, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(rawHandle)
                Issue.record("Could not create legacy trust_grants table")
                return
            }
            let legacyID = UUID().uuidString
            let nowSeconds = Date().timeIntervalSince1970
            let insertLegacy = "INSERT INTO trust_grants (id, tool_name, target, granted_at, expires_at, duration) VALUES ('\(legacyID)', 'email.send', 'legacy@example.com', \(nowSeconds), NULL, 'forever');"
            guard sqlite3_exec(rawHandle, insertLegacy, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(rawHandle)
                Issue.record("Could not insert legacy trust row")
                return
            }
            sqlite3_close(rawHandle)

            let store = SQLiteTrustStore(dbPath: dbPath)
            let loaded = try await store.load()
            #expect(loaded.count == 1)
            #expect(loaded.first?.actionDescriptor.target == "legacy@example.com")
            // Missing columns mean the grant was never observed in use.
            #expect(loaded.first?.useCount == 0)
            #expect(loaded.first?.lastUsedAt == nil)
        #endif
    }

    @Test
    func `Legacy JSON without usage counters decodes as unused`() throws {
        // File rows written before tracking carry no counter keys; decoding
        // must treat the absence as untouched rather than corrupt.
        let full = TrustGrant(
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "legacy@example.com"),
            grantedAt: Date(),
            expiresAt: nil,
            duration: .forever,
            useCount: 3,
            lastUsedAt: Date()
        )
        let encoded = try JSONEncoder().encode(full)
        guard var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("Could not decode grant JSON for legacy shaping")
            return
        }
        dict.removeValue(forKey: "useCount")
        dict.removeValue(forKey: "lastUsedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(TrustGrant.self, from: legacyData)
        #expect(decoded.useCount == 0)
        #expect(decoded.lastUsedAt == nil)
    }

    @Test
    func `revokeGrant after use removes grant and future checks park again`() async {
        struct UsageProbeTool: Tool, Sendable {
            let name = "email.send"
            let description = "Send email."
            let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
            let permissionLevel = PermissionLevel.requiresApproval
            func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
                .success("probe-ok", callID: input.callID)
            }
        }

        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "bob@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)
        await gate.recordUse(for: descriptor)
        #expect(await gate.isTrusted(descriptor) == true)
        let before = await gate.activeGrants()
        #expect(before.first?.useCount == 1)
        #expect(before.first?.lastUsedAt != nil)
        guard let id = before.first(where: { $0.actionDescriptor == descriptor })?.id else {
            Issue.record("Expected granted row before revoke")
            return
        }

        // Stage a pending approval so the revoke can prove it touches only
        // future gate verdicts: the inbox entry must survive the revoke.
        let queue = ApprovalQueue(permissionGate: gate)
        let pending = await queue.enqueue(
            toolName: "email.send",
            description: "Send email.",
            input: ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"other@example.com"}"#)
        )
        #expect(await queue.count() == 1)

        // Revocation drops the row and returns gating to ask-every-time.
        #expect(await gate.revokeGrant(id: id) == true)
        #expect(await gate.isTrusted(descriptor) == false)
        #expect(await gate.activeGrants().contains { $0.id == id } == false)

        // The pending waiter is untouched: revoke is future-only with no
        // running-task or waiter cancellation path.
        #expect(await queue.count() == 1)
        #expect(await queue.request(id: pending.id)?.toolName == "email.send")

        // A future call for the revoked scope parks again instead of passing
        // or denying outright.
        let futureCall = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"bob@example.com"}"#)
        let verdict = await gate.checkPermission(toolCall: futureCall, tool: UsageProbeTool())
        guard case .requiresApproval = verdict else {
            Issue.record("Expected future check to park again after revoke, got \(verdict)")
            return
        }
    }

    @Test
    func `revokeGrant on already-expired grant reports no match`() async {
        let now = Date()
        let expired = TrustGrant(
            id: UUID(),
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "gone@example.com"),
            grantedAt: now.addingTimeInterval(-7200),
            expiresAt: now.addingTimeInterval(-60),
            duration: .fiveMinutes
        )
        // Bootstrap prunes the lapsed row, so the identifier is already gone
        // before revoke runs; the miss must report false so the route can stay 404.
        let store = InMemoryTrustStore(grants: [expired])
        let gate = await PermissionGate.load(store: store)
        #expect(await gate.activeGrants().isEmpty == true)
        #expect(await gate.revokeGrant(id: expired.id) == false)
    }
}
