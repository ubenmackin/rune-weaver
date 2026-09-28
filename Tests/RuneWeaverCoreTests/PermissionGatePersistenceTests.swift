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
            // Mirror the production busy_timeout so a transient reaper/store
            // write lock waits instead of surfacing as a false -1.
            _ = sqlite3_busy_timeout(handle, 5000)
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

    @Test
    func `widenGrant promotes target-specific grant to tool-wide grant`() async {
        let gate = PermissionGate()
        let targetDescriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        await gate.grantTrust(for: targetDescriptor, duration: .oneHour)
        await gate.recordUse(for: targetDescriptor)

        guard let grant = await gate.activeGrants().first(where: { $0.actionDescriptor == targetDescriptor }) else {
            Issue.record("Expected active grant")
            return
        }
        #expect(grant.actionDescriptor.target == "alice@example.com")
        #expect(grant.useCount == 1)

        // Widening promotes target to empty while preserving ID and useCount
        let widened = await gate.widenGrant(id: grant.id)
        #expect(widened == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        let widenedGrant = active[0]
        #expect(widenedGrant.id == grant.id)
        #expect(widenedGrant.actionDescriptor.target.isEmpty == true)
        #expect(widenedGrant.duration == .oneHour)
        #expect(widenedGrant.useCount == 1)

        // Tool-wide grant now matches other targets for email.send
        let bobDescriptor = ActionDescriptor(toolName: "email.send", target: "bob@example.com")
        #expect(await gate.isTrusted(bobDescriptor) == true)

        // Repeat widen on already empty target returns true (idempotent)
        #expect(await gate.widenGrant(id: grant.id) == true)

        // Widening non-existent ID returns false
        #expect(await gate.widenGrant(id: UUID()) == false)
    }

    @Test
    func `widenGrant after a prior widen re-resolves the target and preserves other grants`() async {
        let gate = PermissionGate()
        let first = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        let second = ActionDescriptor(toolName: "email.send", target: "bob@example.com")
        let unrelated = ActionDescriptor(toolName: "file.write", target: "/tmp/report.txt")
        // The first grant is deliberately short-lived and the second forever, so
        // the second promotion strictly outlives the first and takes the
        // promote path rather than the keep-covering early return.
        await gate.grantTrust(for: first, duration: .fiveMinutes)
        await gate.grantTrust(for: second, duration: .forever)
        await gate.grantTrust(for: unrelated, duration: .forever)
        await gate.recordUse(for: first)
        await gate.recordUse(for: second)
        await gate.recordUse(for: second)

        let staged = await gate.activeGrants()
        guard let firstID = staged.first(where: { $0.actionDescriptor == first })?.id,
              let secondID = staged.first(where: { $0.actionDescriptor == second })?.id
        else {
            Issue.record("Expected both narrow grants before widening")
            return
        }

        // Widening the first grant drops a tool-wide row that sits ahead of the
        // second grant, so the second widen must find its slot again by
        // identity. Reusing the stale index would overwrite the unrelated grant
        // that follows instead of the intended one.
        #expect(await gate.widenGrant(id: firstID) == true)
        #expect(await gate.widenGrant(id: secondID) == true)

        let active = await gate.activeGrants()
        let emailGrants = active.filter { $0.actionDescriptor.toolName == "email.send" }
        #expect(emailGrants.count == 1)
        #expect(emailGrants[0].id == secondID)
        #expect(emailGrants[0].actionDescriptor.target.isEmpty == true)
        #expect(emailGrants[0].useCount == 2)

        guard let fileGrant = active.first(where: { $0.actionDescriptor.toolName == "file.write" }) else {
            Issue.record("Unrelated grant was corrupted or dropped")
            return
        }
        #expect(fileGrant.actionDescriptor == unrelated)
        #expect(fileGrant.useCount == 0)
    }

    @Test
    func `widenGrant with the target last does not read past the end`() async {
        let gate = PermissionGate()
        let first = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        let second = ActionDescriptor(toolName: "email.send", target: "bob@example.com")
        await gate.grantTrust(for: first, duration: .oneHour)
        await gate.grantTrust(for: second, duration: .oneHour)

        let staged = await gate.activeGrants()
        guard let firstID = staged.first(where: { $0.actionDescriptor == first })?.id,
              let secondID = staged.first(where: { $0.actionDescriptor == second })?.id
        else {
            Issue.record("Expected both narrow grants before widening")
            return
        }

        #expect(await gate.widenGrant(id: firstID) == true)
        // The target now sits last, and the dedupe removes the widened grant
        // ahead of it; resolving by identity keeps the write in range rather
        // than trapping on the stale slot.
        #expect(await gate.widenGrant(id: secondID) == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].id == secondID)
        #expect(active[0].actionDescriptor.toolName == "email.send")
        #expect(active[0].actionDescriptor.target.isEmpty == true)
        #expect(await gate.isTrusted(first) == true)
    }

    @Test
    func `widenGrant dedupes a pre-existing tool-wide grant for the same tool`() async {
        let gate = PermissionGate()
        let narrow = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        let toolWide = ActionDescriptor(toolName: "email.send", target: "")
        // The narrow grant is granted last with a longer tier, so it strictly
        // outlives the tool-wide row. Dedupe must keep the promoted row's
        // identity and counters instead of collapsing them into the shorter
        // tool-wide grant, which would enshrine a trust reduction.
        await gate.grantTrust(for: toolWide, duration: .fiveMinutes)
        await gate.grantTrust(for: narrow, duration: .oneHour)
        await gate.recordUse(for: narrow)

        let staged = await gate.activeGrants()
        guard let narrowID = staged.first(where: { $0.actionDescriptor == narrow })?.id else {
            Issue.record("Expected the narrow grant")
            return
        }
        #expect(staged.contains { $0.actionDescriptor == toolWide } == true)

        // Promoting the narrow grant must collapse the overlapping tool-wide
        // row rather than leave two rows covering the same tool, while keeping
        // the narrow grant's identity and usage counters.
        #expect(await gate.widenGrant(id: narrowID) == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].id == narrowID)
        #expect(active[0].actionDescriptor.target.isEmpty == true)
        #expect(active[0].useCount == 1)
    }

    @Test
    func `widenGrant never shortens a longer-lived tool-wide grant`() async {
        let gate = PermissionGate()
        let toolWide = ActionDescriptor(toolName: "email.send", target: "")
        let narrow = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        // The durable forever grant must survive a widen of the short-lived
        // narrow grant: promoting the narrow row would replace forever with
        // five minutes and re-prompt every email after the window, dropping
        // trust the user already granted.
        await gate.grantTrust(for: toolWide, duration: .forever)
        await gate.recordUse(for: toolWide)
        await gate.grantTrust(for: narrow, duration: .fiveMinutes)

        let staged = await gate.activeGrants()
        guard let narrowID = staged.first(where: { $0.actionDescriptor == narrow })?.id,
              let toolWideGrant = staged.first(where: { $0.actionDescriptor == toolWide })
        else {
            Issue.record("Expected both the narrow and tool-wide grants")
            return
        }

        #expect(await gate.widenGrant(id: narrowID) == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].id == toolWideGrant.id)
        #expect(active[0].actionDescriptor.target.isEmpty == true)
        #expect(active[0].duration == .forever)
        #expect(active[0].expiresAt == nil)
        #expect(active[0].useCount == 1)
        #expect(active.contains { $0.id == narrowID } == false)
    }

    @Test
    func `widenGrant keeps an equal-tier tool-wide grant that expires later`() async {
        let now = Date()
        // Equal nominal tiers still diverge on effective expiry when the
        // tool-wide grant was installed later. The longer-lived tool-wide grant
        // must survive so the promote does not truncate trust to the narrow
        // grant's earlier expiry.
        let narrow = TrustGrant(
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "alice@example.com"),
            grantedAt: now.addingTimeInterval(-240),
            expiresAt: now.addingTimeInterval(120),
            duration: .oneHour
        )
        let toolWide = TrustGrant(
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: ""),
            grantedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(300),
            duration: .oneHour
        )
        let store = InMemoryTrustStore(grants: [narrow, toolWide])
        let gate = await PermissionGate.load(store: store)

        #expect(await gate.widenGrant(id: narrow.id) == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].id == toolWide.id)
        #expect(active[0].actionDescriptor.target.isEmpty == true)
        #expect(active[0].expiresAt == toolWide.expiresAt)
        #expect(active.contains { $0.id == narrow.id } == false)
    }

    @Test
    func `widenGrant keeps a lower-tier tool-wide grant that expires later`() async {
        let now = Date()
        // The covering tool-wide grant carries a lower nominal tier yet expires
        // later because the narrow grant sits near the end of its longer tier.
        // Effective expiry alone must decide the survivor so the wider grant is
        // not truncated to the narrow grant's earlier expiry.
        let narrow = TrustGrant(
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: "alice@example.com"),
            grantedAt: now.addingTimeInterval(-86280),
            expiresAt: now.addingTimeInterval(120),
            duration: .oneDay
        )
        let toolWide = TrustGrant(
            actionDescriptor: ActionDescriptor(toolName: "email.send", target: ""),
            grantedAt: now,
            expiresAt: now.addingTimeInterval(300),
            duration: .fiveMinutes
        )
        let store = InMemoryTrustStore(grants: [narrow, toolWide])
        let gate = await PermissionGate.load(store: store)

        #expect(await gate.widenGrant(id: narrow.id) == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].id == toolWide.id)
        #expect(active[0].actionDescriptor.target.isEmpty == true)
        #expect(active[0].expiresAt == toolWide.expiresAt)
    }

    @Test
    func `ApprovalQueue widen decision never replaces a longer-lived tool-wide grant`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let toolWide = ActionDescriptor(toolName: "api.request", target: "")
        // A durable forever grant must survive a widen decision that asks for a
        // shorter tier: the decision path shares the gate's never-shorten
        // invariant, so choosing "allow for all targets" for five minutes
        // cannot collapse the tool-wide forever trust to a five-minute window.
        await gate.grantTrust(for: toolWide, duration: .forever)
        await gate.recordUse(for: toolWide)
        guard let foreverID = await gate.activeGrants().first(where: { $0.actionDescriptor == toolWide })?.id else {
            Issue.record("Expected a tool-wide forever grant")
            return
        }

        let request = await queue.enqueue(
            toolName: "api.request",
            description: "API call",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.example.com/data"}"#)
        )
        #expect(await queue.decide(id: request.id, approved: true, duration: .fiveMinutes, widen: true) == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].id == foreverID)
        #expect(active[0].duration == .forever)
        #expect(active[0].expiresAt == nil)
        #expect(active[0].useCount == 1)
    }

    @Test
    func `ApprovalQueue decide with widen creates tool-wide grant`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "API call",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.example.com/data"}"#)
        )

        let decided = await queue.decide(id: request.id, approved: true, duration: .oneHour, widen: true)
        #expect(decided == true)

        let active = await gate.activeGrants()
        #expect(active.count == 1)
        #expect(active[0].actionDescriptor.toolName == "api.request")
        #expect(active[0].actionDescriptor.target.isEmpty == true)

        // Another URL for api.request is now trusted
        let otherDescriptor = ActionDescriptor(toolName: "api.request", target: "https://other.com/api")
        #expect(await gate.isTrusted(otherDescriptor) == true)
    }

    @Test
    func `ApprovalQueue this-time widen never persists a grant`() async {
        // A this-time decision is one-shot by definition: even a caller that
        // mistakenly passes widen must not convert it into a tool-wide durable
        // grant, or a single approval would silently widen trust forever.
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "API call",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.example.com/data"}"#)
        )

        let decided = await queue.decide(id: request.id, approved: true, duration: .thisTime, widen: true)
        #expect(decided == true)

        #expect(await gate.activeGrants().isEmpty == true)
        let otherDescriptor = ActionDescriptor(toolName: "api.request", target: "https://other.com/api")
        #expect(await gate.isTrusted(otherDescriptor) == false)
    }
}

/// Smoke-test contract for the permission gate consulting shell rules before parking.
@Suite("Bash Smoke Gate Contract")
struct BashSmokeGateContractTests {
    /// Probe tool standing in for `bash.exec` on the gate path.
    private struct SmokeBashTool: Tool, Sendable {
        /// Canonical shell tool name the gate branches on.
        let name = "bash.exec"
        /// Human-readable summary shown in approval prompts.
        let description = "Smoke-test shell probe."
        /// Accepts any object; the gate reads only the command field.
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        /// Shell execution always parks unless a rule allows or denies first.
        let permissionLevel = PermissionLevel.requiresApproval
        /// Probe never executes; the gate verdict is the assertion target.
        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("smoke-ok", callID: input.callID)
        }
    }

    /// Gate wired to the smoke-test shell policy.
    private func makeSmokeGate() async -> PermissionGate {
        let gate = PermissionGate()
        await gate.updateBashConfig(BashGateTestSupport.smokeBashConfig())
        return gate
    }

    /// Allowed echo runs with no prompt.
    @Test
    func `echo Hello World is allowed without prompting`() async {
        let gate = await makeSmokeGate()
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"echo Hello World"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: SmokeBashTool())
        guard case .allowed = verdict else {
            Issue.record("Expected echo Hello World to be allowed, got \(verdict)")
            return
        }
    }

    /// Unlisted touch parks for approval.
    @Test
    func `touch parks for approval`() async {
        let gate = await makeSmokeGate()
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"touch ~/helloWorld.txt"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: SmokeBashTool())
        guard case .requiresApproval = verdict else {
            Issue.record("Expected touch ~/helloWorld.txt to require approval, got \(verdict)")
            return
        }
    }

    /// Denied rm refuses without prompting.
    @Test
    func `rm is denied without prompting`() async {
        let gate = await makeSmokeGate()
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"rm ~/helloWorld.txt"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: SmokeBashTool())
        guard case let .denied(reason) = verdict else {
            Issue.record("Expected rm ~/helloWorld.txt to be denied, got \(verdict)")
            return
        }
        #expect(!reason.isEmpty)
    }
}
