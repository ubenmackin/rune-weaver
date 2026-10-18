// Rune Weaver Core — Sovereign ledger re-verification with a signed checkpoint tiebreaker.

import CryptoKit
import Foundation

#if canImport(Security)
    import Security
#endif

// MARK: - Ceremony Verdict

/// Closed outcome of one sovereign verification ceremony.
public enum SovereignOutcome: String, Sendable, Codable, Equatable {
    /// The ledger held no episodes; the chain verified as explicitly empty.
    case empty
    /// The ledger re-verified and agrees with its sovereign material.
    case verified
    /// The ledger disagreed with its sovereign material; parked fail-closed.
    case mismatch
    /// Both sidecars are gone while a prior anchor survives; parked red
    /// until an explicit re-baseline. Never writes artifacts.
    case orphaned
}

/// How the signed checkpoint vote resolved a head disagreement.
public enum SovereignDecision: String, Sendable, Codable, Equatable {
    /// Heads agree; no tiebreak was required.
    case verified
    /// The signed vote attests the sovereign copy head.
    case backsSovereign
    /// The signed vote attests the primary ledger head.
    case backsPrimary
    /// The vote names neither head, so nothing adjudicated the disagreement.
    case backsNeither
}

/// Result of one sovereign verification ceremony.
public struct SovereignVerdict: Sendable, Equatable, Codable {
    /// Genesis head every chain derives from: the SHA-256 of zero bytes. An
    /// explicitly empty ledger verifies at this tip, which gives "empty" a
    /// concrete, comparable head instead of a nil hole.
    public static let emptyTip = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

    /// Closed outcome of the ceremony.
    public let outcome: SovereignOutcome
    /// Recomputed primary ledger head; `emptyTip` for an empty ledger.
    public let primaryTip: String
    /// Sovereign head under test: the copy head, or the last attested head
    /// when the copy itself is missing. Both heads are present exactly when
    /// the ceremony had material to compare.
    public let sovereignTip: String?
    /// Tip of the last signed checkpoint, nil when none had been recorded.
    public let checkpointTip: String?
    /// Episodes the recomputed chain covered.
    public let episodeCount: Int
    /// How the signed vote resolved a disagreement.
    public let decision: SovereignDecision

    /// Whether the primary head moved past the last checkpoint attestation.
    public var changedSinceCheckpoint: Bool {
        guard let checkpointTip else { return false }
        return checkpointTip != primaryTip
    }

    /// Creates a ceremony verdict. outcome: Closed outcome of the ceremony.
    public init(
        outcome: SovereignOutcome,
        primaryTip: String,
        sovereignTip: String?,
        checkpointTip: String?,
        episodeCount: Int,
        decision: SovereignDecision
    ) {
        self.outcome = outcome
        self.primaryTip = primaryTip
        self.sovereignTip = sovereignTip
        self.checkpointTip = checkpointTip
        self.episodeCount = episodeCount
        self.decision = decision
    }
}

// MARK: - Checkpoint

/// Enclave-signed checkpoint vote attesting a ledger head. The signature covers the canonical
/// payload below, so an edited tip or a backdated `signedAt` fails verification instead of reading
/// as a valid attestation.
public struct Checkpoint: Sendable, Equatable, Codable {
    /// Schema version this build writes and accepts.
    public static let currentVersion = 1
    /// Fields the strict decoder accepts; anything else is unknown.
    static let allowedFields: Set<String> = ["version", "tip", "episodeCount", "signedAt", "signature", "signer"]

    /// Schema version of the serialized document.
    public let version: Int
    /// Ledger head the vote attests.
    public let tip: String
    /// Episodes the attested chain covered.
    public let episodeCount: Int
    /// When the vote was signed.
    public let signedAt: Date
    /// Hex HMAC over the signed payload.
    public let signature: String
    /// Enclave signing key identity.
    public let signer: String

    /// Creates a checkpoint vote. version: Schema version, defaulting to
    /// ``currentVersion``.
    public init(
        version: Int = Checkpoint.currentVersion,
        tip: String,
        episodeCount: Int,
        signedAt: Date,
        signature: String,
        signer: String
    ) {
        self.version = version
        self.tip = tip
        self.episodeCount = episodeCount
        self.signedAt = signedAt
        self.signature = signature
        self.signer = signer
    }

    /// Canonical bytes the signature attests for this vote.
    func signaturePayload() -> String {
        Self.signaturePayload(
            version: version,
            tip: tip,
            episodeCount: episodeCount,
            signedAt: signedAt,
            signer: signer
        )
    }

    /// Canonical payload for a vote about to be signed. version: Schema version
    /// being written.
    static func signaturePayload(version: Int, tip: String, episodeCount: Int, signedAt: Date, signer: String) -> String {
        "\(version)|\(tip)|\(episodeCount)|\(signedAt.timeIntervalSince1970)|\(signer)"
    }
}

// MARK: - Enclave Signer

/// Signs and verifies the attestation a ``Checkpoint`` carries. The ceremony owns all cryptographic
/// decisions; the health recorder only checks structure, so this seam is where signature truth
/// lives.
public protocol SovereignSigner: Sendable {
    /// Stable identity of the signing key, recorded on every vote.
    var identity: String { get }
    /// Signs a challenge payload.
    /// - Parameter challenge: Canonical bytes to sign.
    /// - Returns: Hex-encoded signature.
    func sign(challenge: String) async throws -> String
    /// Whether a signature matches the challenge under this signer's key.
    func verify(challenge: String, signature: String) async -> Bool
    /// Loads or mints the key without signing, so boot fails fast on lock.
    func preloadIfNeeded() async throws
}

extension SovereignSigner {
    /// Default no-op for throwaway signers that hold no durable key.
    public func preloadIfNeeded() async throws {}
}

/// Keychain-backed Enclave signer: HMAC-SHA256 under a 256-bit Keychain key.
public struct EnclaveHMACSigner: SovereignSigner {
    /// Legacy file holding the signing key, migrated once into the Keychain
    /// then removed. `~` is expanded on use.
    public static let defaultKeyPath = "~/.runeweaver/sovereign-signing.key"
    /// Keychain account holding the base64 signing key.
    public static let signingKeyAccount = "sovereign.signing.key"
    /// Key length in bytes: a 256-bit HMAC-SHA256 key.
    public static let keyLength = 32

    /// Stable identity recorded on every vote.
    public let identity: String
    /// Legacy file path migrated once into the Keychain then removed.
    public let legacyKeyPath: String
    /// Keychain backing the signing key; never consulted via environment.
    public let secrets: SecretsManager

    /// Creates a signer. identity: Signing key identity recorded on votes.
    /// legacyKeyPath: Legacy file migrated into the Keychain on first use.
    public init(
        identity: String = "runeweaver-enclave-hmac-sha256",
        legacyKeyPath: String? = nil,
        secrets: SecretsManager? = nil
    ) {
        self.identity = identity
        self.legacyKeyPath = legacyKeyPath ?? EnclaveHMACSigner.defaultKeyPath
        self.secrets = secrets ?? SecretsManager()
    }

    public func preloadIfNeeded() async throws {
        _ = try await loadKey()
    }

    public func sign(challenge: String) async throws -> String {
        let key = try await loadKey()
        let code = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key)
        return Self.hex(Data(code))
    }

    public func verify(challenge: String, signature: String) async -> Bool {
        guard let key = try? await loadKey() else { return false }
        let candidate = signature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key)
        return Self.constantTimeEquals(Self.hex(Data(code)), candidate)
    }

    /// Loads the Keychain key, migrating once from the legacy file or
    /// minting on a genuine fresh install. A locked Keychain fails closed
    /// with an unlock remedy; a stale file fails with a delete remedy.
    private func loadKey() async throws -> SymmetricKey {
        let stored: String?
        do {
            stored = try await secrets.retrieveKeychain(key: Self.signingKeyAccount)
        } catch {
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key is locked in the Keychain; unlock the Keychain and retry"
            )
        }
        let legacyURL = URL(fileURLWithPath: (legacyKeyPath as NSString).expandingTildeInPath)
        if let stored {
            // A legacy file beside a live Keychain key means a migration left
            // a stale copy behind (failed removal or a restored backup); the
            // stale file is never silently preferred or ignored.
            guard !FileManager.default.fileExists(atPath: legacyURL.path) else {
                throw SovereignLedgerError.signingKeyUnavailable(
                    reason: "a stale sovereign signing key file still exists at \(legacyURL.path) beside the Keychain key; delete the stale file and retry"
                )
            }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: trimmed), data.count == Self.keyLength else {
                throw SovereignLedgerError.signingKeyUnavailable(
                    reason: "sovereign signing key in the Keychain is corrupt; delete the stale Keychain item to mint a fresh key"
                )
            }
            return SymmetricKey(data: data)
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return try await migrateLegacyKey(at: legacyURL)
        }
        let fresh = try Self.randomBytes()
        do {
            // Add-only mint: a concurrent creator's item is never clobbered,
            // so the stored winner stays stable and every writer below adopts
            // one identity key instead of diverging mid-ceremony.
            _ = try await secrets.storeKeychainIfAbsent(key: Self.signingKeyAccount, secret: fresh.base64EncodedString())
        } catch {
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key could not be stored; unlock the Keychain and retry"
            )
        }
        return try await readStoredSigningKey()
    }

    /// Reads the signing key back and validates its shape, so mint and
    /// migration both converge on the stored winner. A missing or corrupt
    /// item fails closed with the matching remedy.
    private func readStoredSigningKey() async throws -> SymmetricKey {
        let adopted: String?
        do {
            adopted = try await secrets.retrieveKeychain(key: Self.signingKeyAccount)
        } catch {
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key was stored but could not be read back; unlock the Keychain and retry"
            )
        }
        guard let adopted,
              let data = Data(base64Encoded: adopted.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == Self.keyLength
        else {
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key in the Keychain is corrupt; delete the stale Keychain item to mint a fresh key"
            )
        }
        return SymmetricKey(data: data)
    }

    /// Imports the legacy file into the Keychain then removes it, so the
    /// file exists for exactly one migration.
    private func migrateLegacyKey(at url: URL) async throws -> SymmetricKey {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        guard let permissions, permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              data.count == Self.keyLength
        else {
            // A concurrent migration can import and remove the file between
            // this check and the read; when the Keychain already holds a
            // valid key the invariant holds and the winner is adopted.
            if let winner = try? await readStoredSigningKey() {
                return winner
            }
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key at \(url.path) is loose, unreadable, or not \(Self.keyLength) bytes; delete the stale file to mint a fresh key"
            )
        }
        do {
            // Add-only import: a concurrent mint's key is never clobbered by
            // the file bytes, so both writers adopt the same stored winner.
            _ = try await secrets.storeKeychainIfAbsent(key: Self.signingKeyAccount, secret: data.base64EncodedString())
        } catch {
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key could not be stored; unlock the Keychain and retry"
            )
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A concurrent migration can remove the file first, so a failed
            // removal only blocks while the stale copy is actually on disk.
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw SovereignLedgerError.signingKeyUnavailable(
                    reason: "the imported sovereign signing key could not be removed from \(url.path); delete the stale file and retry"
                )
            }
        }
        return try await readStoredSigningKey()
    }

    /// Mints key bytes from the system CSPRNG.
    /// - Returns: Fresh key bytes.
    private static func randomBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        #if canImport(Security)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw SovereignLedgerError.signingKeyUnavailable(
                    reason: "system CSPRNG refused to mint the sovereign signing key"
                )
            }
        #else
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        #endif
        return Data(bytes)
    }

    /// Lowercase hex of an authentication code, following the repo-wide
    /// CryptoKit idiom so sovereign digests read the same as policy hashes.
    /// Shared with the probe signer so both verifiers attest one idiom.
    static func hex(_ code: Data) -> String {
        code.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two hex digests without an early exit on first difference.
    /// Shared with the probe signer so both verifiers attest one idiom.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for (lhsByte, rhsByte) in zip(lhsBytes, rhsBytes) {
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}

// MARK: - Errors

/// Failures raised by a sovereign verification ceremony.
public enum SovereignLedgerError: Error, Sendable, Equatable {
    /// The signing key is unreadable, wrong-length, or cannot be minted.
    case signingKeyUnavailable(reason: String)
    /// The sovereign copy could not be read, or is not owner-only.
    case sovereignCopyUnreadable(path: String)
    /// The sovereign copy exceeds the ceiling. Truncation is refused, so an
    /// explicit prune task must shrink the ledger first.
    case sovereignCopyTooLarge(path: String, limitBytes: Int)
    /// An artifact carried a field outside its schema.
    case unknownField(path: String, field: String)
    /// A copy line could not be decoded against the copy schema.
    case malformedCopyLine(path: String, seq: Int)
    /// Copy sequence numbers are not contiguous from zero.
    case sequenceDiscontinuity(path: String, expected: Int, found: Int)
    /// A copy line's hash does not follow from its declared previous tip.
    case chainBreak(path: String, seq: Int)
    /// A copy line's HMAC does not verify under the enclave key.
    case hmacMismatch(path: String, seq: Int)
    /// The sovereign copy could not be written.
    case sovereignCopyWriteFailed(path: String)
    /// The checkpoint could not be read.
    case checkpointUnreadable(path: String)
    /// The checkpoint carried an unknown field or an unwritten schema version.
    case malformedCheckpoint(path: String)
    /// The checkpoint signature does not verify under the enclave key.
    case checkpointSignatureInvalid(path: String)
    /// The checkpoint is past the staleness bound and cannot arbitrate.
    case checkpointStale(path: String, ageSeconds: Int)
    /// The checkpoint could not be written.
    case checkpointWriteFailed(path: String)
    /// The anchor could not be read from the Keychain. Carries the remedy so
    /// fail-closed ceremonies name the unlock step.
    case anchorUnreadable(account: String, reason: String)
    /// The anchor could not be written to the Keychain. Carries the remedy so
    /// fail-closed ceremonies name the unlock step.
    case anchorWriteFailed(account: String, reason: String)
}

/// Surfaces the authored reason as `localizedDescription`, so boot refusals
/// and ceremony logs name the remedy matching the actual failure class.
extension SovereignLedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .signingKeyUnavailable(reason):
            reason
        case let .anchorUnreadable(_, reason):
            reason
        case let .anchorWriteFailed(_, reason):
            reason
        case let .sovereignCopyUnreadable(path):
            "Sovereign copy at \(path) could not be read or is not owner-only."
        case let .sovereignCopyTooLarge(path, limitBytes):
            "Sovereign copy at \(path) exceeds \(limitBytes) bytes; prune the ledger to shrink the copy and retry."
        case let .unknownField(path, field):
            "Sovereign artifact at \(path) carries unknown field \(field)."
        case let .malformedCopyLine(path, seq):
            "Sovereign copy line \(seq) at \(path) is malformed."
        case let .sequenceDiscontinuity(path, expected, found):
            "Sovereign copy at \(path) is not contiguous from zero: expected sequence \(expected), found \(found)."
        case let .chainBreak(path, seq):
            "Sovereign copy line \(seq) at \(path) breaks the hash chain."
        case let .hmacMismatch(path, seq):
            "Sovereign copy line \(seq) at \(path) fails HMAC verification."
        case let .sovereignCopyWriteFailed(path):
            "Sovereign copy at \(path) could not be written."
        case let .checkpointUnreadable(path):
            "Sovereign checkpoint at \(path) could not be read."
        case let .malformedCheckpoint(path):
            "Sovereign checkpoint at \(path) is malformed or carries an unknown field."
        case let .checkpointSignatureInvalid(path):
            "Sovereign checkpoint at \(path) fails signature verification."
        case let .checkpointStale(path, ageSeconds):
            "Sovereign checkpoint at \(path) is \(ageSeconds)s old, past the staleness bound, and cannot arbitrate."
        case let .checkpointWriteFailed(path):
            "Sovereign checkpoint at \(path) could not be written."
        }
    }
}

// MARK: - Sovereign Anchor

/// Keychain anchor remembering the last attested head. Survives sidecar
/// deletes, so a missing copy plus checkpoint with a live anchor reads as
/// a loud orphan instead of a fresh install.
public struct SovereignAnchor: Sendable, Equatable, Codable {
    /// Allowed JSON fields; anything else is rejected as unknown.
    static let allowedFields: Set<String> = ["tip", "episodeCount", "attestedAt"]

    /// Attested ledger head.
    public let tip: String
    /// Episodes the attested chain covered.
    public let episodeCount: Int
    /// When the anchor was written.
    public let attestedAt: Date

    /// Creates an anchor record.
    public init(tip: String, episodeCount: Int, attestedAt: Date) {
        self.tip = tip
        self.episodeCount = episodeCount
        self.attestedAt = attestedAt
    }
}

// MARK: - Sovereign Copy Line

/// One decoded line of the sovereign copy.
private struct CopyLine {
    /// Copied episode.
    let episode: Episode
    /// Tip the line follows: `emptyTip` for the first line.
    let previousTip: String
    /// Hash of this line's canonical episode bytes over `previousTip`.
    let hash: String
    /// Hex HMAC over `hash`.
    let hmac: String
}

// MARK: - Ledger

/// Actor-backed sovereign ledger verifier.
public actor SovereignLedger {
    /// Default sovereign copy path beside the other durable memory state.
    public static let defaultSovereignCopyPath = "~/.runeweaver/memory/ledger.sovereign.jsonl"
    /// Default checkpoint path beside the other durable engine state.
    public static let defaultCheckpointPath = "~/.runeweaver/sovereign-checkpoint.json"
    /// Keychain account holding the anchor JSON.
    public static let anchorAccount = "sovereign.anchor"
    /// Anchor JSON ceiling; longer payloads are refused, never truncated.
    public static let maxAnchorJSONChars = 512
    /// A checkpoint older than this cannot arbitrate; the ceremony fails closed.
    public static let maxCheckpointAge: TimeInterval = 36 * 60 * 60
    /// Sovereign copy ceiling. A larger copy is refused, never truncated.
    public static let maxSovereignCopyBytes = 50 * 1024 * 1024
    /// Fields the strict copy-line decoder accepts; anything else is unknown.
    private static let copyLineFields: Set<String> = ["seq", "episode", "prev", "hash", "hmac"]
    /// Fields the strict episode decoder accepts; anything else is unknown.
    private static let episodeFields: Set<String> = ["id", "session_id", "role", "content", "timestamp", "metadata"]

    /// Primary episode store the chain is recomputed from.
    private let episodeStore: EpisodeStore
    /// Filesystem path of the sovereign copy. `~` is expanded on use.
    private let sovereignCopyPath: String
    /// Filesystem path of the signed checkpoint. `~` is expanded on use.
    private let checkpointPath: String
    /// Enclave signer backing checkpoint votes and copy-line HMACs.
    private let signer: SovereignSigner
    /// Keychain backing the anchor; nil coalesces to the default manager.
    private let secrets: SecretsManager
    /// Clock source, injectable so staleness is exercised without sleeping.
    private let now: @Sendable () -> Date

    /// Creates a sovereign ledger verifier. episodeStore: Primary store the chain
    /// is recomputed from.
    public init(
        episodeStore: EpisodeStore,
        sovereignCopyPath: String = SovereignLedger.defaultSovereignCopyPath,
        checkpointPath: String = SovereignLedger.defaultCheckpointPath,
        signer: SovereignSigner? = nil,
        secrets: SecretsManager? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.episodeStore = episodeStore
        self.sovereignCopyPath = sovereignCopyPath
        self.checkpointPath = checkpointPath
        let resolvedSecrets = secrets ?? SecretsManager()
        self.secrets = resolvedSecrets
        if let signer {
            self.signer = signer
        } else {
            self.signer = EnclaveHMACSigner(secrets: resolvedSecrets)
        }
        self.now = now
    }

    // MARK: - Ceremony

    /// Loads the signing key without verifying, so serve boot fails fast
    /// on a locked Keychain with an unlock remedy.
    public func preloadSigningKey() async throws {
        try await signer.preloadIfNeeded()
    }

    /// Runs one verification ceremony over the primary ledger.
    public func verifyChain() async throws -> SovereignVerdict {
        try await signer.preloadIfNeeded()
        let episodes = try await episodeStore.orderedEpisodesForVerification()
        let chain = Self.recomputeChain(episodes)
        let primaryTip = chain.last?.hash ?? SovereignVerdict.emptyTip

        let copy = try await readSovereignCopy()
        let checkpoint = try await readCheckpoint()
        let checkpointTip = checkpoint?.tip
        let anchor = try await readAnchor()

        if let copy {
            let sovereignTip = copy.last?.hash ?? SovereignVerdict.emptyTip
            let prefixVerified = copy.count <= chain.count
                && zip(copy, chain).allSatisfy { $0.hash == $1.hash }
            guard prefixVerified else {
                // The store no longer corroborates recorded history: the copy
                // carries an episode the chain cannot reproduce, or the
                // ledger shrank beneath the copy. Park, never repair.
                return mismatchVerdict(
                    primaryTip: primaryTip,
                    sovereignTip: sovereignTip,
                    checkpointTip: checkpointTip,
                    episodeCount: episodes.count
                )
            }
            if copy.count != chain.count {
                // Ledger growth: the copy is a verified prefix, so extending
                // it and re-attesting is the ceremony's normal outcome rather
                // than a disagreement.
                try await writeSovereignCopy(chain)
            }
            try await writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
            try await writeAnchor(tip: primaryTip, episodeCount: episodes.count)
            return SovereignVerdict(
                outcome: episodes.isEmpty ? .empty : .verified,
                primaryTip: primaryTip,
                // The copy head after this ceremony: identical to the primary
                // head on agreement, and the freshly extended head on growth,
                // so a growing ledger never reads as a disagreement.
                sovereignTip: primaryTip,
                checkpointTip: checkpointTip,
                episodeCount: episodes.count,
                decision: .verified
            )
        }

        guard let checkpoint else {
            if let anchor {
                // Sidecars gone while an anchor survives: prior attestation
                // lost. Park loud without writing artifacts.
                return SovereignVerdict(
                    outcome: .orphaned,
                    primaryTip: primaryTip,
                    sovereignTip: anchor.tip,
                    checkpointTip: nil,
                    episodeCount: episodes.count,
                    decision: .backsNeither
                )
            }
            // First ceremony: the recomputed chain becomes the baseline the
            // copy and the signed vote attests.
            try await writeSovereignCopy(chain)
            try await writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
            try await writeAnchor(tip: primaryTip, episodeCount: episodes.count)
            return SovereignVerdict(
                outcome: episodes.isEmpty ? .empty : .verified,
                primaryTip: primaryTip,
                sovereignTip: primaryTip,
                // Attesting the baseline head means the verdict never reads as
                // changed against the vote this very ceremony just wrote.
                checkpointTip: primaryTip,
                episodeCount: episodes.count,
                decision: .verified
            )
        }
        guard checkpoint.tip == primaryTip else {
            // A signed vote exists but its copy is gone.
            return mismatchVerdict(
                primaryTip: primaryTip,
                sovereignTip: checkpoint.tip,
                checkpointTip: checkpointTip,
                episodeCount: episodes.count
            )
        }
        // The signed vote attests exactly this head, so restoring the copy
        // from verified material is corroborated, not silent repair.
        try await writeSovereignCopy(chain)
        try await writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
        try await writeAnchor(tip: primaryTip, episodeCount: episodes.count)
        return SovereignVerdict(
            outcome: episodes.isEmpty ? .empty : .verified,
            primaryTip: primaryTip,
            sovereignTip: primaryTip,
            checkpointTip: checkpointTip,
            episodeCount: episodes.count,
            decision: .verified
        )
    }

    /// Re-attests the current primary head with a fresh signed vote. The explicit counterpart to a
    /// failed ceremony: it signs and persists a new checkpoint at the current head without
    /// adjudicating anything.
    public func writeCheckpoint() async throws -> Checkpoint {
        let episodes = try await episodeStore.orderedEpisodesForVerification()
        let chain = Self.recomputeChain(episodes)
        let checkpoint = try await makeCheckpoint(
            tip: chain.last?.hash ?? SovereignVerdict.emptyTip,
            episodeCount: episodes.count
        )
        try persistCheckpoint(checkpoint)
        return checkpoint
    }

    /// Rewrites the copy plus checkpoint from the current chain. Owner-approved deletes
    /// shrink the ledger, so this is the single path that re-baselines to a smaller head.
    public func rebaselineToCurrentChain() async throws -> SovereignVerdict {
        try await signer.preloadIfNeeded()
        let episodes = try await episodeStore.orderedEpisodesForVerification()
        let chain = Self.recomputeChain(episodes)
        let primaryTip = chain.last?.hash ?? SovereignVerdict.emptyTip
        try await writeSovereignCopy(chain)
        try await writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
        try await writeAnchor(tip: primaryTip, episodeCount: episodes.count)
        return SovereignVerdict(
            outcome: episodes.isEmpty ? .empty : .verified,
            primaryTip: primaryTip,
            sovereignTip: primaryTip,
            checkpointTip: primaryTip,
            episodeCount: episodes.count,
            decision: .verified
        )
    }

    /// Pure tiebreaker for a head disagreement.
    public func adjudicate(primaryTip: String, sovereignTip: String, checkpointTip: String) -> SovereignDecision {
        guard let primary = HealthSnapshotValue.normalizedTip(primaryTip),
              let sovereign = HealthSnapshotValue.normalizedTip(sovereignTip)
        else {
            return .backsNeither
        }
        if primary == sovereign {
            return .verified
        }
        guard let checkpoint = HealthSnapshotValue.normalizedTip(checkpointTip) else {
            return .backsNeither
        }
        if checkpoint == primary {
            return .backsPrimary
        }
        if checkpoint == sovereign {
            return .backsSovereign
        }
        return .backsNeither
    }
}

// MARK: - Chain Recomputation

extension SovereignLedger {
    /// Recomputes the canonical chain over ordered episodes.
    private static func recomputeChain(_ episodes: [Episode]) -> [(episode: Episode, hash: String)] {
        var chain: [(episode: Episode, hash: String)] = []
        chain.reserveCapacity(episodes.count)
        var previous = SovereignVerdict.emptyTip
        for episode in episodes {
            let hash = chainHash(previous: previous, canonical: canonicalEpisodeData(episode))
            chain.append((episode, hash))
            previous = hash
        }
        return chain
    }

    /// Hashes one entry over the previous tip and its canonical bytes. previous:
    /// Tip the entry follows.
    private static func chainHash(previous: String, canonical: Data) -> String {
        var bytes = Data(previous.utf8)
        bytes.append(0x1F)
        bytes.append(canonical)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical episode bytes: the exact payload the chain hashes.
    private static func canonicalEpisodeData(_ episode: Episode) -> Data {
        var buffer = Data()
        func frame(_ field: String) {
            var length = UInt32(field.utf8.count).littleEndian
            buffer.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            buffer.append(Data(field.utf8))
        }
        frame(episode.id.uuidString)
        frame(episode.sessionID.uuidString)
        frame(episode.role.rawValue)
        frame(String(format: "%.6f", episode.timestamp.timeIntervalSince1970))
        for key in episode.metadata.keys.sorted() {
            frame(key)
            frame(episode.metadata[key] ?? "")
        }
        // Content goes last: it is the only unbounded, delimiter-bearing field.
        frame(episode.content)
        return buffer
    }
}

// MARK: - Sovereign Copy

extension SovereignLedger {
    /// Reads and strictly verifies the sovereign copy.
    private func readSovereignCopy() async throws -> [CopyLine]? {
        let path = expanded(sovereignCopyPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // The copy carries conversation content, so a file the owner cannot
        // prove is owner-only is refused instead of read.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        guard let permissions, permissions.intValue & 0o077 == 0 else {
            throw SovereignLedgerError.sovereignCopyUnreadable(path: path)
        }
        try assertWithinCopyLimit(path: path)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SovereignLedgerError.sovereignCopyUnreadable(path: path)
        }
        if data.count > Self.maxSovereignCopyBytes {
            throw SovereignLedgerError.sovereignCopyTooLarge(path: path, limitBytes: Self.maxSovereignCopyBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SovereignLedgerError.sovereignCopyUnreadable(path: path)
        }
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [CopyLine] = []
        lines.reserveCapacity(rawLines.count)
        for (offset, raw) in rawLines.enumerated() {
            if offset == rawLines.count - 1, raw.isEmpty {
                // A single trailing newline closes the last line.
                continue
            }
            guard !raw.isEmpty else {
                throw SovereignLedgerError.malformedCopyLine(path: path, seq: offset)
            }
            try lines.append(decodeCopyLine(Data(raw.utf8), path: path, seq: offset))
        }
        for (offset, line) in lines.enumerated() {
            let expectedPrevious = offset == 0 ? SovereignVerdict.emptyTip : lines[offset - 1].hash
            guard line.previousTip == expectedPrevious,
                  line.hash == Self.chainHash(previous: line.previousTip, canonical: Self.canonicalEpisodeData(line.episode))
            else {
                throw SovereignLedgerError.chainBreak(path: path, seq: offset)
            }
            guard await signer.verify(challenge: line.hash, signature: line.hmac) else {
                throw SovereignLedgerError.hmacMismatch(path: path, seq: offset)
            }
        }
        return lines
    }

    /// Decodes one copy line strictly against the copy schema. data: Raw line
    /// bytes.
    private func decodeCopyLine(_ data: Data, path: String, seq: Int) throws -> CopyLine {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            throw SovereignLedgerError.malformedCopyLine(path: path, seq: seq)
        }
        if let unknown = dict.keys.first(where: { !Self.copyLineFields.contains($0) }) {
            throw SovereignLedgerError.unknownField(path: path, field: unknown)
        }
        guard let declaredSeq = dict["seq"] as? Int,
              let previousTip = dict["prev"] as? String,
              let hash = dict["hash"] as? String,
              let hmac = dict["hmac"] as? String,
              let episodeObject = dict["episode"] as? [String: Any]
        else {
            throw SovereignLedgerError.malformedCopyLine(path: path, seq: seq)
        }
        if declaredSeq != seq {
            throw SovereignLedgerError.sequenceDiscontinuity(path: path, expected: seq, found: declaredSeq)
        }
        guard let previous = HealthSnapshotValue.normalizedTip(previousTip),
              let lineHash = HealthSnapshotValue.normalizedTip(hash),
              !hmac.isEmpty
        else {
            throw SovereignLedgerError.malformedCopyLine(path: path, seq: seq)
        }
        return try CopyLine(
            episode: decodeEpisode(episodeObject, path: path, seq: seq),
            previousTip: previous,
            hash: lineHash,
            hmac: hmac
        )
    }

    /// Decodes a line's embedded episode, rejecting unknown fields there too.
    private func decodeEpisode(_ object: [String: Any], path: String, seq: Int) throws -> Episode {
        if let unknown = object.keys.first(where: { !Self.episodeFields.contains($0) }) {
            throw SovereignLedgerError.unknownField(path: path, field: "episode.\(unknown)")
        }
        guard let idText = object["id"] as? String,
              let sessionText = object["session_id"] as? String,
              let roleText = object["role"] as? String,
              let content = object["content"] as? String,
              let timestampText = object["timestamp"] as? String,
              let id = UUID(uuidString: idText),
              let sessionID = UUID(uuidString: sessionText),
              let role = Message.Role(rawValue: roleText)
        else {
            throw SovereignLedgerError.malformedCopyLine(path: path, seq: seq)
        }
        let metadata = object["metadata"] as? [String: String] ?? [:]
        return Episode(
            id: id,
            sessionID: sessionID,
            role: role,
            content: content,
            timestamp: Date(timeIntervalSince1970: Double(timestampText) ?? 0),
            metadata: metadata
        )
    }

    /// Writes the sovereign copy atomically under the size ceiling.
    private func writeSovereignCopy(_ chain: [(episode: Episode, hash: String)]) async throws {
        let path = expanded(sovereignCopyPath)
        var previous = SovereignVerdict.emptyTip
        var payload = Data()
        for (seq, entry) in chain.enumerated() {
            let hmac = try await signer.sign(challenge: entry.hash)
            let line = try Self.copyLineData(
                seq: seq,
                episode: entry.episode,
                previousTip: previous,
                hash: entry.hash,
                hmac: hmac
            )
            payload.append(line)
            payload.append(0x0A)
            previous = entry.hash
        }
        guard payload.count <= Self.maxSovereignCopyBytes else {
            throw SovereignLedgerError.sovereignCopyTooLarge(path: path, limitBytes: Self.maxSovereignCopyBytes)
        }
        do {
            try writeRestricted(payload, to: path)
        } catch {
            throw SovereignLedgerError.sovereignCopyWriteFailed(path: path)
        }
    }

    /// Renders one copy line as canonical JSON. seq: Zero-based position.
    private static func copyLineData(
        seq: Int,
        episode: Episode,
        previousTip: String,
        hash: String,
        hmac: String
    ) throws -> Data {
        let line: [String: Any] = [
            "seq": seq,
            "episode": Self.episodeObject(episode),
            "prev": previousTip,
            "hash": hash,
            "hmac": hmac
        ]
        return try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    }

    /// Projects an episode into the copy's explicit JSON shape.
    private static func episodeObject(_ episode: Episode) -> [String: Any] {
        [
            "id": episode.id.uuidString,
            "session_id": episode.sessionID.uuidString,
            "role": episode.role.rawValue,
            "content": episode.content,
            "timestamp": String(format: "%.6f", episode.timestamp.timeIntervalSince1970),
            "metadata": episode.metadata
        ]
    }

    /// Early-out size gate ahead of the byte-accurate read.
    private func assertWithinCopyLimit(path: String) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxSovereignCopyBytes else {
            throw SovereignLedgerError.sovereignCopyTooLarge(path: path, limitBytes: Self.maxSovereignCopyBytes)
        }
    }
}

// MARK: - Checkpoint

extension SovereignLedger {
    /// Reads the Keychain anchor fresh per ceremony. Corrupt payloads read
    /// as absent; a locked Keychain fails closed with an unlock remedy.
    private func readAnchor() async throws -> SovereignAnchor? {
        let raw: String?
        do {
            raw = try await secrets.retrieveKeychain(key: Self.anchorAccount)
        } catch {
            throw SovereignLedgerError.anchorUnreadable(
                account: Self.anchorAccount,
                reason: "sovereign anchor is locked in the Keychain; unlock the Keychain and retry"
            )
        }
        guard let raw, raw.count <= Self.maxAnchorJSONChars,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              dict.keys.allSatisfy({ SovereignAnchor.allowedFields.contains($0) }),
              let tipRaw = dict["tip"] as? String,
              let tip = HealthSnapshotValue.normalizedTip(tipRaw),
              let episodeCount = dict["episodeCount"] as? Int,
              episodeCount >= 0,
              let attestedAtSeconds = dict["attestedAt"] as? Double
        else {
            return nil
        }
        return SovereignAnchor(tip: tip, episodeCount: episodeCount, attestedAt: Date(timeIntervalSince1970: attestedAtSeconds))
    }

    /// Persists the anchor for a passing head. Never called for orphan or
    /// mismatch, so only attested heads survive sidecar deletes.
    private func writeAnchor(tip: String, episodeCount: Int) async throws {
        guard let normalized = HealthSnapshotValue.normalizedTip(tip) else { return }
        let anchor = SovereignAnchor(tip: normalized, episodeCount: episodeCount, attestedAt: now())
        let payload: [String: Any] = [
            "tip": anchor.tip,
            "episodeCount": anchor.episodeCount,
            "attestedAt": anchor.attestedAt.timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8),
              raw.count <= Self.maxAnchorJSONChars
        else {
            throw SovereignLedgerError.anchorWriteFailed(
                account: Self.anchorAccount,
                reason: "sovereign anchor could not be serialized within the JSON ceiling; refused, never truncated"
            )
        }
        do {
            try await secrets.storeKeychain(key: Self.anchorAccount, secret: raw)
        } catch {
            throw SovereignLedgerError.anchorWriteFailed(
                account: Self.anchorAccount,
                reason: "sovereign anchor could not be stored; unlock the Keychain and retry"
            )
        }
    }

    /// Reads, verifies, and age-checks the signed checkpoint.
    private func readCheckpoint() async throws -> Checkpoint? {
        let path = expanded(checkpointPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SovereignLedgerError.checkpointUnreadable(path: path)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            throw SovereignLedgerError.malformedCheckpoint(path: path)
        }
        if let unknown = dict.keys.first(where: { !Checkpoint.allowedFields.contains($0) }) {
            throw SovereignLedgerError.unknownField(path: path, field: unknown)
        }
        guard let version = dict["version"] as? Int,
              let tip = dict["tip"] as? String,
              let episodeCount = dict["episodeCount"] as? Int,
              let signedAtSeconds = dict["signedAt"] as? Double,
              let signature = dict["signature"] as? String,
              let signerIdentity = dict["signer"] as? String,
              version == Checkpoint.currentVersion,
              let normalizedTip = HealthSnapshotValue.normalizedTip(tip),
              !signature.isEmpty,
              !signerIdentity.isEmpty
        else {
            throw SovereignLedgerError.malformedCheckpoint(path: path)
        }
        let checkpoint = Checkpoint(
            version: version,
            tip: normalizedTip,
            episodeCount: episodeCount,
            signedAt: Date(timeIntervalSince1970: signedAtSeconds),
            signature: signature,
            signer: signerIdentity
        )
        guard await signer.verify(challenge: checkpoint.signaturePayload(), signature: signature) else {
            throw SovereignLedgerError.checkpointSignatureInvalid(path: path)
        }
        let age = now().timeIntervalSince(checkpoint.signedAt)
        guard age <= Self.maxCheckpointAge else {
            throw SovereignLedgerError.checkpointStale(path: path, ageSeconds: Int(age))
        }
        return checkpoint
    }

    /// Signs a fresh checkpoint for a head. tip: Ledger head to attest.
    private func makeCheckpoint(tip: String, episodeCount: Int) async throws -> Checkpoint {
        let signedAt = now()
        let identity = signer.identity
        let payload = Checkpoint.signaturePayload(
            version: Checkpoint.currentVersion,
            tip: tip,
            episodeCount: episodeCount,
            signedAt: signedAt,
            signer: identity
        )
        let signature = try await signer.sign(challenge: payload)
        return Checkpoint(
            version: Checkpoint.currentVersion,
            tip: tip,
            episodeCount: episodeCount,
            signedAt: signedAt,
            signature: signature,
            signer: identity
        )
    }

    /// Signs and persists a checkpoint for a head. tip: Ledger head to attest.
    private func writeCheckpoint(tip: String, episodeCount: Int) async throws {
        let checkpoint = try await makeCheckpoint(tip: tip, episodeCount: episodeCount)
        try persistCheckpoint(checkpoint)
    }

    /// Persists a checkpoint as canonical sorted-key JSON.
    /// - Parameter checkpoint: Vote to persist.
    private func persistCheckpoint(_ checkpoint: Checkpoint) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(checkpoint)
        } catch {
            throw SovereignLedgerError.checkpointWriteFailed(path: expanded(checkpointPath))
        }
        do {
            try writeRestricted(data, to: expanded(checkpointPath))
        } catch {
            throw SovereignLedgerError.checkpointWriteFailed(path: expanded(checkpointPath))
        }
    }
}

// MARK: - Verdict and Restricted Files

extension SovereignLedger {
    /// Builds a parked-mismatch verdict, labeling which side the vote backs.
    /// primaryTip: Recomputed primary ledger head.
    private func mismatchVerdict(
        primaryTip: String,
        sovereignTip: String,
        checkpointTip: String?,
        episodeCount: Int
    ) -> SovereignVerdict {
        let decision = checkpointTip.map {
            adjudicate(primaryTip: primaryTip, sovereignTip: sovereignTip, checkpointTip: $0)
        } ?? .backsNeither
        return SovereignVerdict(
            outcome: .mismatch,
            primaryTip: primaryTip,
            sovereignTip: sovereignTip,
            checkpointTip: checkpointTip,
            episodeCount: episodeCount,
            decision: decision
        )
    }

    /// Writes bytes to a `0600` file inside `0700` directories via a same-directory temp plus an
    /// atomic replace, so a crash never leaves a half-written artifact and no window exposes it
    /// under a looser mode.
    private func writeRestricted(_ data: Data, to path: String) throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Re-assert the directory mode: a directory created by an older build
        // or a restore could be wider, and restricted bytes must never sit in one.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Expands a `~`-prefixed path to an absolute filesystem path.
    /// - Parameter path: Raw path.
    /// - Returns: Expanded path.
    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
