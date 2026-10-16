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
    func sign(challenge: String) throws -> String
    /// Whether a signature matches the challenge under this signer's key.
    func verify(challenge: String, signature: String) -> Bool
}

/// File-backed Enclave signer: HMAC-SHA256 under an owner-only 256-bit key.
public struct EnclaveHMACSigner: SovereignSigner {
    /// Conventional key path beside the other durable engine state.
    public static let defaultKeyPath = "~/.runeweaver/sovereign-signing.key"
    /// Key length in bytes: a 256-bit HMAC-SHA256 key.
    public static let keyLength = 32

    /// Stable identity recorded on every vote.
    public let identity: String
    /// Filesystem path of the signing key. `~` is expanded on use.
    public let keyPath: String

    /// Creates a signer. identity: Signing key identity recorded on votes.
    public init(
        identity: String = "runeweaver-enclave-hmac-sha256",
        keyPath: String = EnclaveHMACSigner.defaultKeyPath
    ) {
        self.identity = identity
        self.keyPath = keyPath
    }

    public func sign(challenge: String) throws -> String {
        try withKey { key in
            let code = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key)
            return Self.hex(Data(code))
        }
    }

    public func verify(challenge: String, signature: String) -> Bool {
        guard let key = try? loadKey() else { return false }
        let candidate = signature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key)
        return Self.constantTimeEquals(Self.hex(Data(code)), candidate)
    }

    /// Runs work under the signing key, minting the key on first use.
    /// - Parameter body: Work receiving the loaded key.
    /// - Returns: The body's result.
    private func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        let url = URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            return try body(loadKey(at: url))
        }
        let data = try Self.randomBytes()
        do {
            try writeExclusive(data, to: url)
        } catch SovereignLedgerError.keyAlreadyPresent {
            // A concurrent minter won the race; adopt the key now on disk so
            // both writers verify each other's votes.
            return try body(loadKey(at: url))
        }
        return try body(SymmetricKey(data: data))
    }

    /// Loads the key, failing closed on a loose, unreadable, or wrong-length file.
    private func loadKey() throws -> SymmetricKey {
        try loadKey(at: URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath))
    }

    /// Loads the key at a resolved path.
    private func loadKey(at url: URL) throws -> SymmetricKey {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        guard let permissions, permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              data.count == Self.keyLength
        else {
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "sovereign signing key at \(url.path) is loose, unreadable, or not \(Self.keyLength) bytes"
            )
        }
        return SymmetricKey(data: data)
    }

    /// Creates the key file exclusively at `0600` inside a `0700` directory.
    private func writeExclusive(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd: Int32 = url.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else {
            if errno == EEXIST {
                throw SovereignLedgerError.keyAlreadyPresent
            }
            throw SovereignLedgerError.signingKeyUnavailable(
                reason: "could not create the sovereign signing key at \(url.path)"
            )
        }
        defer { _ = close(fd) }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw SovereignLedgerError.signingKeyUnavailable(
                            reason: "could not write the sovereign signing key"
                        )
                    }
                    if written == 0 {
                        throw SovereignLedgerError.signingKeyUnavailable(
                            reason: "short write for the sovereign signing key"
                        )
                    }
                    offset += Int(written)
                }
            }
        } catch {
            // A partial key on disk would fail every later load closed for the
            // wrong reason, so remove it and let the next ceremony re-mint.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        _ = fchmod(fd, mode_t(0o600))
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
    /// Another process minted the signing key first; internal to the signer.
    case keyAlreadyPresent
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
    /// Clock source, injectable so staleness is exercised without sleeping.
    private let now: @Sendable () -> Date

    /// Creates a sovereign ledger verifier. episodeStore: Primary store the chain
    /// is recomputed from.
    public init(
        episodeStore: EpisodeStore,
        sovereignCopyPath: String = SovereignLedger.defaultSovereignCopyPath,
        checkpointPath: String = SovereignLedger.defaultCheckpointPath,
        signer: SovereignSigner? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.episodeStore = episodeStore
        self.sovereignCopyPath = sovereignCopyPath
        self.checkpointPath = checkpointPath
        self.signer = signer ?? EnclaveHMACSigner()
        self.now = now
    }

    // MARK: - Ceremony

    /// Runs one verification ceremony over the primary ledger.
    public func verifyChain() async throws -> SovereignVerdict {
        let episodes = try await episodeStore.orderedEpisodesForVerification()
        let chain = Self.recomputeChain(episodes)
        let primaryTip = chain.last?.hash ?? SovereignVerdict.emptyTip

        let copy = try readSovereignCopy()
        let checkpoint = try readCheckpoint()
        let checkpointTip = checkpoint?.tip

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
                try writeSovereignCopy(chain)
            }
            try writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
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
            // First ceremony: the recomputed chain becomes the baseline the
            // copy and the signed vote attests.
            try writeSovereignCopy(chain)
            try writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
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
        try writeSovereignCopy(chain)
        try writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
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
        let checkpoint = try makeCheckpoint(
            tip: chain.last?.hash ?? SovereignVerdict.emptyTip,
            episodeCount: episodes.count
        )
        try persistCheckpoint(checkpoint)
        return checkpoint
    }

    /// Rewrites the copy plus checkpoint from the current chain. Owner-approved deletes
    /// shrink the ledger, so this is the single path that re-baselines to a smaller head.
    public func rebaselineToCurrentChain() async throws -> SovereignVerdict {
        let episodes = try await episodeStore.orderedEpisodesForVerification()
        let chain = Self.recomputeChain(episodes)
        let primaryTip = chain.last?.hash ?? SovereignVerdict.emptyTip
        try writeSovereignCopy(chain)
        try writeCheckpoint(tip: primaryTip, episodeCount: episodes.count)
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
    private func readSovereignCopy() throws -> [CopyLine]? {
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
            guard signer.verify(challenge: line.hash, signature: line.hmac) else {
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
    private func writeSovereignCopy(_ chain: [(episode: Episode, hash: String)]) throws {
        let path = expanded(sovereignCopyPath)
        var previous = SovereignVerdict.emptyTip
        var payload = Data()
        for (seq, entry) in chain.enumerated() {
            let hmac = try signer.sign(challenge: entry.hash)
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
    /// Reads, verifies, and age-checks the signed checkpoint.
    private func readCheckpoint() throws -> Checkpoint? {
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
        guard signer.verify(challenge: checkpoint.signaturePayload(), signature: signature) else {
            throw SovereignLedgerError.checkpointSignatureInvalid(path: path)
        }
        let age = now().timeIntervalSince(checkpoint.signedAt)
        guard age <= Self.maxCheckpointAge else {
            throw SovereignLedgerError.checkpointStale(path: path, ageSeconds: Int(age))
        }
        return checkpoint
    }

    /// Signs a fresh checkpoint for a head. tip: Ledger head to attest.
    private func makeCheckpoint(tip: String, episodeCount: Int) throws -> Checkpoint {
        let signedAt = now()
        let identity = signer.identity
        let payload = Checkpoint.signaturePayload(
            version: Checkpoint.currentVersion,
            tip: tip,
            episodeCount: episodeCount,
            signedAt: signedAt,
            signer: identity
        )
        return try Checkpoint(
            version: Checkpoint.currentVersion,
            tip: tip,
            episodeCount: episodeCount,
            signedAt: signedAt,
            signature: signer.sign(challenge: payload),
            signer: identity
        )
    }

    /// Signs and persists a checkpoint for a head. tip: Ledger head to attest.
    private func writeCheckpoint(tip: String, episodeCount: Int) throws {
        try persistCheckpoint(makeCheckpoint(tip: tip, episodeCount: episodeCount))
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
