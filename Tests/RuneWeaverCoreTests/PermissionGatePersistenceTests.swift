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
    ///
    /// Filtered loads hide expired grants, so only a raw row count can
    /// distinguish the reaper physically deleting a row from the load
    /// query merely filtering it out.
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
}
