// Rune Weaver Core Tests — Sovereign identity: Keychain key lifecycle, anchor refresh, and orphaned-attestation pulse.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Scratch tree for one sovereign ceremony test; every path is unique per test.
private struct SovereignScratch: Sendable {
    let root: URL
    let copyPath: String
    let checkpointPath: String
    let dbPath: String

    /// Creates the scratch tree under the system temporary directory.
    static func make() throws -> SovereignScratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-sovereign-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SovereignScratch(
            root: root,
            copyPath: root.appendingPathComponent("ledger.sovereign.jsonl").path,
            checkpointPath: root.appendingPathComponent("sovereign-checkpoint.json").path,
            dbPath: root.appendingPathComponent("episodes.db").path
        )
    }

    /// Removes the scratch tree, best-effort.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Isolated in-memory secret vault so tests never touch the system Keychain.
private func freshTestSecrets() -> SecretsManager {
    SecretsManager(service: "com.runeweaver.test.sovereign.\(UUID().uuidString)", inMemory: true)
}

/// Builds a ledger over one scratch tree with an injectable clock so anchor
/// attestation instants stay deterministic.
private func makeLedger(
    scratch: SovereignScratch,
    secrets: SecretsManager,
    signer: any SovereignSigner? = nil,
    now: @escaping @Sendable () -> Date
) -> SovereignLedger {
    SovereignLedger(
        episodeStore: EpisodeStore(dbPath: scratch.dbPath),
        sovereignCopyPath: scratch.copyPath,
        checkpointPath: scratch.checkpointPath,
        signer: signer,
        secrets: secrets,
        now: now
    )
}

/// Parked-red state the orphan and re-baseline tests start from.
private struct OrphanFixture {
    let scratch: SovereignScratch
    let secrets: SecretsManager
    let pulse: SystemHealthSnapshot
    let attestedTip: String
}

/// Reads the stored anchor from the primary episode store.
private func readStoredAnchor(dbPath: String) async throws -> SovereignAnchor? {
    let store = EpisodeStore(dbPath: dbPath)
    return try await store.readSovereignAnchor()
}

/// Signed instant recorded on the checkpoint file.
private func checkpointSignedAt(path: String) throws -> Date {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let seconds = object["signedAt"] as? Double
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return Date(timeIntervalSince1970: seconds)
}

/// Drives a fresh install to its baseline, deletes both sidecars, and records
/// the orphaned ceremony, arriving at the parked-red state the orphan and
/// re-baseline tests start from.
private func makeOrphanedFixture() async throws -> OrphanFixture {
    let scratch = try SovereignScratch.make()
    let secrets = freshTestSecrets()
    let store = EpisodeStore(dbPath: scratch.dbPath)
    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    let baseline = makeLedger(scratch: scratch, secrets: secrets, now: { t1 })
    try await store.store(sessionID: UUID(), role: .user, content: "history the orphan erased")
    let first = try await baseline.verifyChain()
    try FileManager.default.removeItem(atPath: scratch.copyPath)
    try FileManager.default.removeItem(atPath: scratch.checkpointPath)
    let t2 = t1.addingTimeInterval(120)
    let orphanCeremony = makeLedger(scratch: scratch, secrets: secrets, now: { t2 })
    let orphaned = try await orphanCeremony.verifyChain()
    #expect(orphaned.outcome == .orphaned)
    let pulse = SystemHealthSnapshot()
    await pulse.recordSovereign(orphaned)
    return OrphanFixture(scratch: scratch, secrets: secrets, pulse: pulse, attestedTip: first.primaryTip)
}

/// Signer standing in for a locked Keychain: loading fails closed with the
/// unlock remedy instead of falling back to any other key material.
private struct LockedKeychainSigner: SovereignSigner {
    let identity = "runeweaver-test-locked-keychain"

    /// Remedy text mirroring the production locked-Keychain failure class.
    private static let lockedRemedy =
        "sovereign signing key is locked in the Keychain; unlock the Keychain and retry"

    func preloadIfNeeded() async throws {
        throw SovereignLedgerError.signingKeyUnavailable(reason: Self.lockedRemedy)
    }

    func sign(challenge _: String) async throws -> String {
        throw SovereignLedgerError.signingKeyUnavailable(reason: Self.lockedRemedy)
    }

    func verify(challenge _: String, signature _: String) async -> Bool {
        false
    }
}

@Suite("Sovereign Keychain Identity")
struct SovereignKeychainIdentityTests {
    @Test
    func `Concurrent fresh mints converge on one identity key`() async throws {
        let secrets = freshTestSecrets()

        let signatures = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0 ..< 8 {
                group.addTask {
                    let signer = EnclaveHMACSigner(secrets: secrets)
                    return try await signer.sign(challenge: "fresh-install-challenge")
                }
            }
            var collected: [String] = []
            for try await signature in group {
                collected.append(signature)
            }
            return collected
        }
        // One stored winner: every minter adopted it, none diverged mid-race.
        #expect(signatures.count == 8)
        #expect(Set(signatures).count == 1)
    }

    @Test
    func `Add-only mint never clobbers a stored key`() async throws {
        let secrets = freshTestSecrets()
        let account = EnclaveHMACSigner.signingKeyAccount
        try await secrets.storeKeychain(key: account, secret: "stored-winner")

        let raced = try await secrets.storeKeychainIfAbsent(key: account, secret: "racing-mint")
        #expect(raced == false)
        #expect(try await secrets.retrieveKeychain(key: account) == "stored-winner")

        let freshKey = account + ".fresh"
        let created = try await secrets.storeKeychainIfAbsent(key: freshKey, secret: "first-writer")
        #expect(created == true)
        let second = try await secrets.storeKeychainIfAbsent(key: freshKey, secret: "second-writer")
        #expect(second == false)
        #expect(try await secrets.retrieveKeychain(key: freshKey) == "first-writer")
    }

    @Test
    func `A corrupt Keychain key fails the ceremony closed`() async throws {
        let scratch = try SovereignScratch.make()
        defer { scratch.remove() }
        let secrets = freshTestSecrets()
        try await secrets.storeKeychain(
            key: EnclaveHMACSigner.signingKeyAccount,
            secret: Data(repeating: 0x07, count: 10).base64EncodedString()
        )
        let ledger = makeLedger(scratch: scratch, secrets: secrets, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        do {
            _ = try await ledger.verifyChain()
            Issue.record("Expected the corrupt key to fail the ceremony closed")
        } catch let error as SovereignLedgerError {
            guard case let .signingKeyUnavailable(reason) = error else {
                Issue.record("Expected signingKeyUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("corrupt"))
        }
        // No ceremony artifacts were written under a refused key.
        #expect(!FileManager.default.fileExists(atPath: scratch.copyPath))
        #expect(!FileManager.default.fileExists(atPath: scratch.checkpointPath))
    }

    @Test
    func `A locked Keychain fails boot and the ceremony closed with an unlock remedy`() async throws {
        let scratch = try SovereignScratch.make()
        defer { scratch.remove() }
        let secrets = freshTestSecrets()
        let ledger = makeLedger(
            scratch: scratch,
            secrets: secrets,
            signer: LockedKeychainSigner(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        // Boot preload refuses with the named unlock remedy.
        do {
            try await ledger.preloadSigningKey()
            Issue.record("Expected the locked Keychain to refuse boot preload")
        } catch let error as SovereignLedgerError {
            guard case let .signingKeyUnavailable(reason) = error else {
                Issue.record("Expected signingKeyUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("unlock"))
            // The authored reason surfaces as the localized description so
            // boot logs name the remedy.
            #expect(error.localizedDescription == reason)
        }
        // The ceremony refuses closed and writes no artifacts.
        do {
            _ = try await ledger.verifyChain()
            Issue.record("Expected the locked Keychain to fail the ceremony closed")
        } catch is SovereignLedgerError {}
        #expect(!FileManager.default.fileExists(atPath: scratch.copyPath))
        #expect(!FileManager.default.fileExists(atPath: scratch.checkpointPath))
        // The refused ceremony parks the pulse red until a fresh passing one.
        let pulse = SystemHealthSnapshot()
        await pulse.recordSovereignFailure()
        let value = await pulse.snapshot()
        #expect(value.status == .red)
        #expect(value.remediation == .rebaseline)
    }
}

@Suite("Sovereign Anchor And Orphan")
struct SovereignAnchorOrphanTests {
    @Test
    func `Genuine fresh install writes its baseline green`() async throws {
        let scratch = try SovereignScratch.make()
        defer { scratch.remove() }
        let secrets = freshTestSecrets()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = makeLedger(scratch: scratch, secrets: secrets, now: { t1 })

        // An empty chain anchors to the explicit empty verdict, not a nil hole.
        let first = try await ledger.verifyChain()
        #expect(first.outcome == .empty)
        #expect(first.primaryTip == SovereignVerdict.emptyTip)
        let anchor = try #require(await readStoredAnchor(dbPath: scratch.dbPath))
        #expect(anchor.tip == SovereignVerdict.emptyTip)

        let pulse = SystemHealthSnapshot()
        await pulse.recordSovereign(first)
        let value = await pulse.snapshot()
        #expect(value.status == .green)
        #expect(value.remediation == .none)

        // A repeat ceremony on the untouched install stays green with no orphan.
        let second = try await ledger.verifyChain()
        #expect(second.outcome == .empty)
        await pulse.recordSovereign(second)
        #expect(await pulse.snapshot().status == .green)
    }

    @Test
    func `Passing ceremonies refresh the anchor head and attestation`() async throws {
        let scratch = try SovereignScratch.make()
        defer { scratch.remove() }
        let secrets = freshTestSecrets()
        let store = EpisodeStore(dbPath: scratch.dbPath)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeLedger(scratch: scratch, secrets: secrets, now: { t1 })

        try await store.store(sessionID: UUID(), role: .user, content: "episode one")
        let verdictOne = try await first.verifyChain()
        #expect(verdictOne.outcome == .verified)
        let anchorOne = try #require(await readStoredAnchor(dbPath: scratch.dbPath))
        #expect(anchorOne.tip == verdictOne.primaryTip)
        #expect(anchorOne.episodeCount == 1)
        #expect(abs(anchorOne.attestedAt.timeIntervalSince1970 - t1.timeIntervalSince1970) < 0.5)

        try await store.store(sessionID: UUID(), role: .assistant, content: "episode two")
        let t2 = t1.addingTimeInterval(120)
        let second = makeLedger(scratch: scratch, secrets: secrets, now: { t2 })
        let verdictTwo = try await second.verifyChain()
        #expect(verdictTwo.outcome == .verified)
        #expect(verdictTwo.primaryTip != verdictOne.primaryTip)
        let anchorTwo = try #require(await readStoredAnchor(dbPath: scratch.dbPath))
        #expect(anchorTwo.tip == verdictTwo.primaryTip)
        #expect(anchorTwo.episodeCount == 2)
        #expect(abs(anchorTwo.attestedAt.timeIntervalSince1970 - t2.timeIntervalSince1970) < 0.5)
    }

    @Test
    func `Unchanged head still refreshes the checkpoint past the staleness bound`() async throws {
        let scratch = try SovereignScratch.make()
        defer { scratch.remove() }
        let secrets = freshTestSecrets()
        let store = EpisodeStore(dbPath: scratch.dbPath)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.store(sessionID: UUID(), role: .user, content: "steady history")
        let first = makeLedger(scratch: scratch, secrets: secrets, now: { t1 })
        let verdictOne = try await first.verifyChain()
        #expect(verdictOne.outcome == .verified)
        let firstSignedAt = try checkpointSignedAt(path: scratch.checkpointPath)
        #expect(abs(firstSignedAt.timeIntervalSince(t1)) < 1)

        // Heads still agree 37h later, so the ceremony re-attests
        // instead of failing closed on the aged vote.
        let t2 = t1.addingTimeInterval(37 * 60 * 60)
        let second = makeLedger(scratch: scratch, secrets: secrets, now: { t2 })
        let verdictTwo = try await second.verifyChain()
        #expect(verdictTwo.outcome == .verified)
        #expect(verdictTwo.primaryTip == verdictOne.primaryTip)
        let secondSignedAt = try checkpointSignedAt(path: scratch.checkpointPath)
        #expect(abs(secondSignedAt.timeIntervalSince(t2)) < 1)
    }

    @Test
    func `Orphaned anchor parks the pulse red naming both missing files`() async throws {
        let fixture = try await makeOrphanedFixture()
        defer { fixture.scratch.remove() }
        let value = await fixture.pulse.snapshot()
        #expect(value.status == .red)
        #expect(value.remediation == .rebaseline)
        #expect(value.degradedReasons.contains { reason in
            reason.contains("ledger.sovereign.jsonl") && reason.contains("sovereign-checkpoint.json")
        })
        // The orphaned ceremony wrote no artifacts, and the anchor still
        // attests the last head prior attestation reached.
        #expect(!FileManager.default.fileExists(atPath: fixture.scratch.copyPath))
        #expect(!FileManager.default.fileExists(atPath: fixture.scratch.checkpointPath))
        let anchor = try #require(await readStoredAnchor(dbPath: fixture.scratch.dbPath))
        #expect(anchor.tip == fixture.attestedTip)
    }

    @Test
    func `Re-baseline clears the parked red and refreshes the anchor`() async throws {
        let fixture = try await makeOrphanedFixture()
        defer { fixture.scratch.remove() }
        let before = await fixture.pulse.snapshot()
        #expect(before.status == .red)

        let t3 = Date(timeIntervalSince1970: 1_700_000_240)
        let rebaseline = makeLedger(scratch: fixture.scratch, secrets: fixture.secrets, now: { t3 })
        let verdict = try await rebaseline.rebaselineToCurrentChain()
        #expect(verdict.outcome == .verified)
        await fixture.pulse.recordSovereign(verdict)
        let after = await fixture.pulse.snapshot()
        #expect(after.status == .green)
        #expect(after.remediation == .none)
        #expect(after.ledgerVerifiedAt != nil)

        // Re-baseline refreshes the anchor alongside the copy and checkpoint.
        #expect(FileManager.default.fileExists(atPath: fixture.scratch.copyPath))
        #expect(FileManager.default.fileExists(atPath: fixture.scratch.checkpointPath))
        let anchor = try #require(await readStoredAnchor(dbPath: fixture.scratch.dbPath))
        #expect(anchor.tip == verdict.primaryTip)
        #expect(abs(anchor.attestedAt.timeIntervalSince1970 - t3.timeIntervalSince1970) < 0.5)
    }
}
