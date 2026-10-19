// Rune Weaver Tests — PermissionGate rule persistence and lifecycle administration.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

/// Raw SQLite fixtures for the rule-persistence suites. The store opens and closes per call exactly
/// as production does, so the helpers mirror its busy timeout instead of surfacing a transient write
/// lock as a failed fixture.
private enum RulePersistenceTestSupport {
    /// Builds an isolated database path under the temporary directory.
    static func temporaryDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rules-\(UUID().uuidString).db")
            .path
    }

    /// Executes one raw statement so fixture tables predate the store.
    @discardableResult
    static func execRaw(dbPath: String, sql: String) -> Bool {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return false }
            defer { sqlite3_close(handle) }
            _ = sqlite3_busy_timeout(handle, 5000)
            return sql.withCString { sqlite3_exec(handle, $0, nil, nil, nil) } == SQLITE_OK
        #else
            return false
        #endif
    }

    /// Counts rows in a fixture table so a prune proves physical deletion.
    static func rawRowCount(dbPath: String, table: String) -> Int {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return -1 }
            defer { sqlite3_close(handle) }
            _ = sqlite3_busy_timeout(handle, 5000)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return -1 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        #else
            return -1
        #endif
    }

    /// Backdates one rule's expiry so a row lapses while the gate is live.
    @discardableResult
    static func backdateExpiry(dbPath: String, id: UUID, expiresAt: Date) -> Bool {
        let sql = "UPDATE access_rules SET expires_at = \(expiresAt.timeIntervalSince1970) WHERE id = '\(id.uuidString)';"
        return execRaw(dbPath: dbPath, sql: sql)
    }
}

/// Probe tool standing in for a gated tool on the decision path.
private struct GateProbeTool: Tool, Sendable {
    /// Tool name the gate branches and scopes on.
    let name: String
    /// Trust level the probe declares; approval-gated by default.
    let permissionLevel: PermissionLevel = .requiresApproval

    /// Summary shown in approval prompts.
    var description: String {
        "Probe for \(name)."
    }

    /// Accepts any object; the gate reads only the fields it names.
    var inputSchema: JSONSchema {
        .emptyObject
    }

    /// The probe never executes; the verdict is the assertion target.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("probe-ok", callID: input.callID)
    }
}

@Suite("PermissionGate Persistence & Reaper Tests")
struct PermissionGatePersistenceTests {
    // MARK: - Save and load

    @Test
    func `a second gate sees the durable rules the first saved, deny rows included`() async throws {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let gate = await PermissionGate.load(ruleStore: store)
        // A path scope stores its canonical spelling, so assert against what the
        // canonicalizer resolves rather than the raw input.
        let notesPrefix = try #require(AccessScope.canonicalPathPrefix("/tmp/notes"))
        #expect(await gate.grant(.toolWide, toolName: "email.send", duration: .forever))
        #expect(await gate.grant(.recipientSet(["a@x.com", "b@x.com"]), toolName: "email.send", duration: .oneDay))
        #expect(await gate.grant(.exactTarget("dr.smith@clinic.com"), toolName: "email.send", duration: .oneHour))
        #expect(await gate.grant(.pathPrefix(notesPrefix), toolName: "files.write", duration: .oneHour))
        await gate.denyRule(.domain(host: "example.com", subdomains: false), toolName: "api.request", reason: "owner refused this host")

        let stored = try await store.load()
        #expect(stored.count == 5)
        #expect(stored.contains {
            $0.action == .deny && $0.toolName == "api.request"
                && $0.scope == .domain(host: "example.com", subdomains: false)
                && $0.expiresAt == nil && $0.reason == "owner refused this host"
        })

        // A second gate over the same file reads exactly the same rule set, so a
        // durable decision survives a restart instead of re-prompting.
        let reloaded = await PermissionGate.load(ruleStore: store)
        let reloadedRules = await reloaded.activeRules()
        #expect(reloadedRules.count == 5)
        let reloadedIDs = reloadedRules.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let storedIDs = stored.map(\.id).sorted { $0.uuidString < $1.uuidString }
        #expect(reloadedIDs == storedIDs)
        #expect(reloadedRules.contains { $0.scope == .recipientSet(["a@x.com", "b@x.com"]) })
        #expect(reloadedRules.contains { $0.scope == .pathPrefix(notesPrefix) })
        #expect(reloadedRules.contains { $0.action == .deny })

        // The gate's live view keeps both the tool-wide and exact-target
        // allows beside the richer scopes and the deny row.
        let liveRules = await gate.activeRules()
        #expect(liveRules.count == 5)
        #expect(liveRules.contains { $0.toolName == "email.send" && $0.scope == .toolWide })
        #expect(liveRules.contains { $0.toolName == "email.send" && $0.scope == .exactTarget("dr.smith@clinic.com") })
        #expect(liveRules.contains { $0.action == .deny && $0.toolName == "api.request" })
    }

    // MARK: - Prune on startup

    @Test
    func `bootstrap prunes expired allows from memory and never lets them allow`() async throws {
        let now = Date()
        let expired = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("gone@example.com"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .oneHour
        ))
        // A `messages.send` tool-wide row is the pre-invariant spelling: it can
        // never cover a real send, so bootstrap drops it instead of lingering as
        // trust nobody can exercise.
        let legacyWideSend = try #require(AccessRule(
            toolName: "messages.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: now,
            duration: .forever
        ))
        let standingDeny = try #require(AccessRule(
            toolName: "stub.write",
            scope: .toolWide,
            action: .deny,
            grantedAt: now,
            reason: "owner refused writes"
        ))
        let live = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("a@x.com"),
            action: .allow,
            grantedAt: now,
            duration: .forever
        ))

        let store = InMemoryAccessRuleStore(rules: [expired, legacyWideSend, standingDeny, live])
        let gate = await PermissionGate.load(ruleStore: store)

        let rules = await gate.activeRules()
        #expect(rules.count == 2)
        #expect(rules.contains { $0.id == standingDeny.id })
        #expect(rules.contains { $0.id == live.id })
        #expect(rules.contains { $0.id == expired.id } == false)
        #expect(rules.contains { $0.id == legacyWideSend.id } == false)

        // The lapsed rule never allows, even the exact call it once covered.
        let covered = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#)
        #expect(await gate.checkPermission(toolCall: covered, tool: GateProbeTool(name: "email.send")) == .allowed)
        let lapsed = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"gone@example.com"}"#)
        guard case .requiresApproval = await gate.checkPermission(toolCall: lapsed, tool: GateProbeTool(name: "email.send")) else {
            Issue.record("Expected the pruned rule to park again instead of allowing")
            return
        }
        // The dropped send row cannot cover the handle the owner would approve.
        let send = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"hi"}"#)
        guard case .requiresApproval = await gate.checkPermission(toolCall: send, tool: GateProbeTool(name: "messages.send")) else {
            Issue.record("Expected the unusable tool-wide send row to park again")
            return
        }
    }

    @Test
    func `bootstrap prunes expired rows from storage while deny rows survive`() async throws {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let now = Date()
        let expiredAllow = try #require(AccessRule(
            toolName: "email.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .oneHour
        ))
        let standingDeny = try #require(AccessRule(
            toolName: "stub.write",
            scope: .toolWide,
            action: .deny,
            grantedAt: now,
            reason: "owner refused writes"
        ))
        let durableAllow = try #require(AccessRule(
            toolName: "email.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: now,
            duration: .oneDay
        ))
        try await store.save([expiredAllow, standingDeny, durableAllow])
        #expect(RulePersistenceTestSupport.rawRowCount(dbPath: dbPath, table: "access_rules") == 3)

        _ = await PermissionGate.load(ruleStore: store)

        // Startup prunes the store itself, not just the in-memory mirror, while a
        // standing refusal has no expiry to lapse.
        let stored = try await store.load()
        #expect(stored.count == 2)
        #expect(stored.contains { $0.id == standingDeny.id })
        #expect(stored.contains { $0.id == durableAllow.id })
        #expect(RulePersistenceTestSupport.rawRowCount(dbPath: dbPath, table: "access_rules") == 2)
    }

    // MARK: - Periodic reaper

    @Test
    func `the periodic reaper sweeps a row that lapses while the gate is live`() async throws {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let now = Date()
        let standing = try #require(AccessRule(
            toolName: "email.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: now,
            duration: .forever
        ))
        let lapsing = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("stale@example.com"),
            action: .allow,
            grantedAt: now,
            duration: .oneHour
        ))
        try await store.save([standing, lapsing])
        let gate = await PermissionGate.load(ruleStore: store)
        #expect(await gate.activeRules().count == 2)

        // A row can lapse while the process runs, so backdate the stored expiry
        // and prove the reaper removes it from the database rather than leaving
        // it to resurrect on the next boot.
        #expect(RulePersistenceTestSupport.backdateExpiry(dbPath: dbPath, id: lapsing.id, expiresAt: now.addingTimeInterval(-60)))
        #expect(RulePersistenceTestSupport.rawRowCount(dbPath: dbPath, table: "access_rules") == 2)

        await gate.startPeriodicCleanup(intervalSeconds: 0.05)
        try await Task.sleep(nanoseconds: 250_000_000)
        await gate.stopPeriodicCleanup()

        let stored = try await store.load()
        #expect(stored.map(\.id) == [standing.id])
        #expect(RulePersistenceTestSupport.rawRowCount(dbPath: dbPath, table: "access_rules") == 1)
    }

    // MARK: - Grant, revoke, usage

    @Test
    func `grant plus revoke rewrite the stored rule set`() async throws {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let gate = await PermissionGate.load(ruleStore: store)
        let descriptor = ActionDescriptor(toolName: "email.send", target: "persist@example.com")
        #expect(await gate.grantTrust(for: descriptor, duration: .oneHour))

        // `grantTrust` awaits persistence, so storage already carries the rule.
        let stored = try await store.load()
        let saved = try #require(stored.first)
        #expect(stored.count == 1)
        #expect(saved.toolName == "email.send")
        #expect(saved.scope == .exactTarget("persist@example.com"))
        #expect(saved.action == .allow)
        #expect(saved.duration == .oneHour)
        #expect(saved.expiresAt != nil)

        // Revoking removes exactly one rule and reports the miss next time so a
        // route can stay 404 instead of rewriting anything.
        #expect(await gate.revokeRule(id: saved.id))
        #expect(try await store.load().isEmpty)
        #expect(await gate.revokeRule(id: saved.id) == false)
        #expect(await gate.isTrusted(descriptor) == false)

        // Future calls park again rather than reading as trusted.
        let call = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"persist@example.com"}"#)
        guard case .requiresApproval = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "email.send")) else {
            Issue.record("Expected a revoked rule to park again")
            return
        }
    }

    @Test
    func `fresh rules start unused and the zero baseline survives the round trip`() async {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let gate = await PermissionGate.load(ruleStore: store)
        #expect(await gate.grantTrust(for: ActionDescriptor(toolName: "email.send", target: "fresh@example.com"), duration: .oneHour))

        // A replacement lifetime must not inherit prior counters, so fresh rows
        // prove the zero baseline instead of assuming it.
        let live = await gate.activeRules()
        #expect(live.count == 1)
        #expect(live.first?.useCount == 0)
        #expect(live.first?.lastUsedAt == nil)

        let reloaded = await PermissionGate.load(ruleStore: store)
        let restored = await reloaded.activeRules()
        #expect(restored.count == 1)
        #expect(restored.first?.useCount == 0)
        #expect(restored.first?.lastUsedAt == nil)
    }

    @Test
    func `recordUse attributes to the covering rule and survives a reload`() async throws {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let gate = await PermissionGate.load(ruleStore: store)
        let descriptor = ActionDescriptor(toolName: "email.send", target: "used@example.com")
        #expect(await gate.grantTrust(for: descriptor, duration: .forever))
        #expect(await gate.grant(.toolWide, toolName: "bash.exec", duration: .forever))

        // Each covered call bumps the counter on the rule that allowed it: the
        // exact rule when one exists, the tool-wide fallback otherwise, so the
        // dashboard can prove liveness instead of guessing from rule age.
        let narrowScope = PermissionGate.scope(for: descriptor)
        await gate.recordUse(scope: narrowScope, toolName: "email.send")
        await gate.recordUse(scope: narrowScope, toolName: "email.send")
        await gate.recordUse(scope: .exactTarget("ls ~/notes"), toolName: "bash.exec")

        let live = await gate.activeRules()
        let usedNarrow = try #require(live.first { $0.toolName == "email.send" })
        let usedWide = try #require(live.first { $0.toolName == "bash.exec" })
        #expect(usedNarrow.useCount == 2)
        #expect(usedNarrow.lastUsedAt != nil)
        #expect(usedWide.useCount == 1)
        #expect(usedWide.lastUsedAt != nil)

        // The counters are durable, not just resident in the granting instance.
        let reloaded = await PermissionGate.load(ruleStore: store)
        let restored = await reloaded.activeRules()
        let restoredNarrow = try #require(restored.first { $0.toolName == "email.send" })
        let restoredWide = try #require(restored.first { $0.toolName == "bash.exec" })
        #expect(restoredNarrow.useCount == 2)
        #expect(restoredWide.useCount == 1)
        // SQLite REAL loses sub-millisecond precision, so compare with a tolerance.
        guard let liveStamp = usedNarrow.lastUsedAt, let restoredStamp = restoredNarrow.lastUsedAt else {
            Issue.record("Expected lastUsedAt on both live and restored rules")
            return
        }
        #expect(abs(liveStamp.timeIntervalSince(restoredStamp)) < 0.001)
    }

    // MARK: - Widen

    @Test
    func `widenGrant promotes an exact-target rule and keeps identity and counters`() async throws {
        let store = InMemoryAccessRuleStore()
        let gate = await PermissionGate.load(ruleStore: store)
        let descriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        #expect(await gate.grantTrust(for: descriptor, duration: .oneHour))
        await gate.recordUse(scope: PermissionGate.scope(for: descriptor), toolName: descriptor.toolName)

        let staged = await gate.activeRules()
        let narrow = try #require(staged.first)
        #expect(narrow.scope == .exactTarget("alice@example.com"))
        #expect(narrow.useCount == 1)

        #expect(await gate.widenGrant(id: narrow.id) == .widened)

        // Identity, creation time, and counters survive the promotion, and the
        // widened row is the only row the store now holds.
        let active = await gate.activeRules()
        #expect(active.count == 1)
        let widened = try #require(active.first)
        #expect(widened.id == narrow.id)
        #expect(widened.scope == .toolWide)
        #expect(widened.duration == .oneHour)
        #expect(widened.grantedAt == narrow.grantedAt)
        #expect(widened.useCount == 1)
        #expect(try await store.load() == active)

        // Tool-wide coverage now reaches a recipient the narrow rule never matched.
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "bob@example.com")))

        // A second widen is idempotent success rather than a second row.
        #expect(await gate.widenGrant(id: narrow.id) == .widened)
        #expect(await gate.activeRules().count == 1)
    }

    @Test
    func `widenGrant distinguishes notFound from notWidenable and never promotes a deny`() async throws {
        let gate = await PermissionGate.load(ruleStore: InMemoryAccessRuleStore())
        let widenable = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        let send = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        #expect(await gate.grantTrust(for: widenable, duration: .oneHour))
        #expect(await gate.grantTrust(for: send, duration: .oneHour))
        await gate.denyRule(.exactTarget("blocked@example.com"), toolName: "email.send", reason: "owner refused this recipient")

        let staged = await gate.activeRules()
        let widenableID = staged.first { $0.toolName == "email.send" && $0.scope == .exactTarget("alice@example.com") }?.id
        let sendID = staged.first { $0.toolName == "messages.send" && $0.scope == .exactTarget("+15551234567") }?.id
        let denyID = staged.first { $0.toolName == "email.send" && $0.action == .deny }?.id

        // The three outcomes stay distinct: a missing id is notFound, a live send
        // grant is notWidenable with the honest reason, and a refusal is not
        // trust to promote so it reports notFound rather than losing its scope.
        #expect(await gate.widenGrant(id: UUID()) == .notFound)
        #expect(
            try await gate.widenGrant(id: #require(sendID))
                == .notWidenable(reason: GrantWidenOutcome.messagesSendRefusal)
        )
        #expect(try await gate.widenGrant(id: #require(denyID)) == .notFound)
        #expect(try await gate.widenGrant(id: #require(widenableID)) == .widened)

        let active = await gate.activeRules()
        #expect(active.contains { $0.id == sendID && $0.scope == .exactTarget("+15551234567") })
        #expect(active.contains { $0.id == denyID && $0.action == .deny })
        #expect(active.contains { $0.id == widenableID && $0.scope == .toolWide })
    }

    @Test
    func `widenGrant never shortens a longer-lived tool-wide rule`() async throws {
        let now = Date()
        let toolWide = try #require(AccessRule(
            toolName: "email.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: now,
            duration: .forever
        ))
        let narrow = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("alice@example.com"),
            action: .allow,
            grantedAt: now,
            duration: .fiveMinutes
        ))
        let store = InMemoryAccessRuleStore(rules: [toolWide, narrow])
        let gate = await PermissionGate.load(ruleStore: store)

        // Promoting the short-lived narrow row would replace forever trust with
        // five minutes, so the covering tool-wide rule is kept instead.
        #expect(await gate.widenGrant(id: narrow.id) == .widened)

        let active = await gate.activeRules()
        #expect(active.count == 1)
        #expect(active[0].id == toolWide.id)
        #expect(active[0].scope == .toolWide)
        #expect(active[0].duration == .forever)
        #expect(active[0].expiresAt == nil)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "bob@example.com")))
    }

    @Test
    func `widenGrant keeps a covering tool-wide rule that expires later`() async throws {
        let now = Date()
        // Equal nominal tiers still diverge on effective expiry, so the
        // longer-lived tool-wide rule must survive rather than be truncated to
        // the narrow rule's earlier expiry.
        let toolWide = try #require(AccessRule(
            toolName: "email.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: now,
            duration: .fiveMinutes
        ))
        let narrow = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("alice@example.com"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-3300),
            duration: .oneHour
        ))
        let store = InMemoryAccessRuleStore(rules: [toolWide, narrow])
        let gate = await PermissionGate.load(ruleStore: store)

        #expect(await gate.widenGrant(id: narrow.id) == .widened)

        let active = await gate.activeRules()
        #expect(active.count == 1)
        #expect(active[0].id == toolWide.id)
        #expect(active[0].expiresAt == toolWide.expiresAt)
        #expect(active.contains { $0.id == narrow.id } == false)
    }

    // MARK: - Re-arm

    @Test
    func `rearmGrant preserves identity and counters while recomputing expiry`() async throws {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        #expect(await gate.grantTrust(for: descriptor, duration: .oneHour))
        await gate.recordUse(scope: PermissionGate.scope(for: descriptor), toolName: descriptor.toolName)
        await gate.recordUse(scope: PermissionGate.scope(for: descriptor), toolName: descriptor.toolName)

        let before = try #require(await gate.activeRules().first)
        #expect(before.useCount == 2)
        let grantedAt = before.grantedAt
        let lastUsedAt = before.lastUsedAt

        // Re-arming rewrites only the tier and its expiry from confirmation
        // time: identity, scope, creation time, and liveness counters survive so
        // the dashboard keeps proving exercised trust across the change.
        #expect(await gate.rearmGrant(id: before.id, duration: .oneDay) == .rearmed)

        let active = await gate.activeRules()
        #expect(active.count == 1)
        let rearmed = try #require(active.first)
        #expect(rearmed.id == before.id)
        #expect(rearmed.toolName == descriptor.toolName)
        #expect(rearmed.scope == PermissionGate.scope(for: descriptor))
        #expect(rearmed.grantedAt == grantedAt)
        #expect(rearmed.useCount == 2)
        #expect(rearmed.lastUsedAt == lastUsedAt)
        #expect(rearmed.duration == .oneDay)
        if let expiresAt = rearmed.expiresAt {
            // Expiry is recomputed from now rather than carried from the
            // original grant date, so a longer tier extends trust.
            #expect(expiresAt > Date())
        } else {
            Issue.record("Expected a dated tier to carry an expiry")
        }

        // The never-expiring tier clears expiry on the same row.
        #expect(await gate.rearmGrant(id: before.id, duration: .forever) == .rearmed)
        let standing = await gate.activeRules()
        #expect(standing.count == 1)
        #expect(standing[0].duration == .forever)
        #expect(standing[0].expiresAt == nil)
        #expect(standing[0].useCount == 2)
    }

    @Test
    func `rearmGrant reports notFound for an expired rule and invalidDuration for a one-shot tier`() async throws {
        let now = Date()
        let expired = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("gone@example.com"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .oneHour
        ))
        // Bootstrap prunes the lapsed row, so the identifier is already gone
        // before re-arm runs and the miss must read as unknown, not a tier error.
        let store = InMemoryAccessRuleStore(rules: [expired])
        let gate = await PermissionGate.load(ruleStore: store)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.rearmGrant(id: expired.id, duration: .oneHour) == .notFound)
        #expect(await gate.rearmGrant(id: UUID(), duration: .oneHour) == .notFound)

        // One-shot and ephemeral tiers have no lifetime to recompute: the
        // refusal names the tier and leaves the live rule untouched.
        let descriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        #expect(await gate.grantTrust(for: descriptor, duration: .oneHour))
        let liveID = try #require(await gate.activeRules().first?.id)
        for tier in [TrustDuration.thisTime, .forTask, .forSession] {
            #expect(await gate.rearmGrant(id: liveID, duration: tier) == .invalidDuration(reason: GrantRearmOutcome.thisTimeRefusal))
        }
        let active = await gate.activeRules()
        #expect(active.count == 1)
        #expect(active[0].duration == .oneHour)
        #expect(await gate.isTrusted(descriptor) == true)
    }

    // MARK: - Deny lifecycle

    @Test
    func `deny rules never age out and are removed only by an explicit revoke`() async throws {
        let dbPath = RulePersistenceTestSupport.temporaryDBPath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = SQLiteAccessRuleStore(dbPath: dbPath)
        let gate = await PermissionGate.load(ruleStore: store)
        await gate.denyRule(.toolWide, toolName: "stub.write", reason: "owner refused writes")

        let deny = try #require(await gate.activeRules().first)
        #expect(deny.action == .deny)
        #expect(deny.duration == nil)
        #expect(deny.expiresAt == nil)
        #expect(deny.reason == "owner refused writes")

        // A durable allow minted afterwards cannot evict the refusal that already
        // covers the scope, and the refusal still wins the check.
        #expect(await gate.grant(.toolWide, toolName: "stub.write", duration: .oneHour))
        #expect(await gate.activeRules().count == 2)
        let call = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        guard case let .denied(reason) = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "stub.write")) else {
            Issue.record("Expected the deny rule to outrank the allow rule")
            return
        }
        #expect(reason.contains("Denied by rule"))

        // Neither an explicit prune nor the periodic reaper can lapse a refusal
        // into the allow decision underneath it.
        await gate.pruneExpiredAndPersist()
        await gate.startPeriodicCleanup(intervalSeconds: 0.05)
        try await Task.sleep(nanoseconds: 200_000_000)
        await gate.stopPeriodicCleanup()
        #expect(await gate.activeRules().contains { $0.id == deny.id })

        // Only an explicit revoke removes it; the allow row survives it.
        #expect(await gate.revokeRule(id: deny.id))
        #expect(await gate.activeRules().count == 1)
        #expect(await gate.revokeRule(id: deny.id) == false)
        #expect(RulePersistenceTestSupport.rawRowCount(dbPath: dbPath, table: "access_rules") == 1)

        // With the refusal gone the surviving allow covers the call, which is
        // what proves the revoke removed the denial rather than the trust.
        #expect(await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "stub.write")) == .allowed)
    }

    // MARK: - Ephemeral grants

    @Test
    func `forTask and forSession grants stay in memory, never persist, and clear on lifecycle`() async throws {
        let store = InMemoryAccessRuleStore()
        let gate = await PermissionGate.load(ruleStore: store)
        let sessionA = UUID()
        let sessionB = UUID()
        let taskDescriptor = ActionDescriptor(toolName: "files.write", target: "/tmp/scoped.txt")
        let sessionDescriptor = ActionDescriptor(toolName: "bash.exec")

        #expect(await gate.isTrusted(taskDescriptor, sessionID: sessionA) == false)
        #expect(await gate.isTrusted(taskDescriptor, sessionID: sessionB) == false)

        #expect(await gate.grantTrust(for: taskDescriptor, duration: .forTask, sessionID: sessionA))
        #expect(await gate.grantTrust(for: sessionDescriptor, duration: .forSession, sessionID: sessionA))

        // Ephemeral trust never persists and never reads as a durable rule.
        #expect(try await store.load().isEmpty)
        #expect(await gate.activeRules().isEmpty)

        // Trust isolates by session and is unscoped without one.
        #expect(await gate.isTrusted(taskDescriptor, sessionID: sessionA) == true)
        #expect(await gate.isTrusted(taskDescriptor, sessionID: sessionB) == false)
        #expect(await gate.isTrusted(taskDescriptor) == false)
        #expect(await gate.isTrusted(sessionDescriptor, sessionID: sessionA) == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "bash.exec", target: "ls"), sessionID: sessionA) == true)
        #expect(await gate.isTrusted(sessionDescriptor, sessionID: sessionB) == false)

        // The task tier ends at the turn boundary; the session tier survives it.
        await gate.clearTaskGrants(for: sessionA)
        #expect(await gate.isTrusted(taskDescriptor, sessionID: sessionA) == false)
        #expect(await gate.isTrusted(sessionDescriptor, sessionID: sessionA) == true)

        // The session tier dies with the conversation that approved it.
        await gate.clearSessionGrants(for: sessionA)
        #expect(await gate.isTrusted(sessionDescriptor, sessionID: sessionA) == false)
        #expect(await gate.ephemeralGrants(sessionID: sessionA).isEmpty)
    }
}
