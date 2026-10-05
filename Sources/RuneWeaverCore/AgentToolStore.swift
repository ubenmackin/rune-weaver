// Rune Weaver Core — Hash-pinned registry for owner-promoted agent scripts.
//
// Purpose: owns the `agent_tools` table in the shared `episodes.db` so a script
// the owner promotes from `workspace/tools/` becomes a named, verifiable
// capability instead of an ad-hoc shell string. Every promotion pins the exact
// file bytes as a SHA-256 hex digest; every later execution re-hashes and
// compares before dispatching, so a modified script fails closed instead of
// running silently changed bytes.
// Scope: name validation, workspace containment, file hashing, SQLite
// persistence, tamper-driven disablement, and the needs-attention sink only;
// execution, permission gating, and HTTP routing live with the tools and
// server layers.
// Architectural role: durable trust anchor beside the goal and plugin stores,
// following the shared Core store idiom (actor isolation plus serialized
// SQLite access) so the CLI and the service observe one registry.

import CryptoKit
import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// Lifecycle state for one promoted agent script.
///
/// Raw values are the stable SQLite strings, so renaming a case never silently
/// rewrites persisted rows. A tampered script always lands in `disabled`, and
/// only an explicit owner enable (or a fresh re-promotion followed by an
/// explicit enable) returns it to service — re-promotion alone never
/// re-enables, so a quiet file change cannot self-heal into execution.
public enum AgentToolStatus: String, Sendable, Codable, CaseIterable, Equatable {
    /// Eligible for verified execution.
    case enabled
    /// Refused for execution until the owner re-enables explicitly.
    case disabled
}

/// One pinned agent script: its registry identity plus its integrity pin.
///
/// The pin is the SHA-256 hex of the exact file bytes at promotion time, not
/// a timestamp or size, so any byte change — even a whitespace edit — fails
/// verification. The path is stored absolute so later boots resolve the same
/// file without depending on the process working directory.
public struct AgentToolRecord: Sendable, Codable, Equatable, Identifiable {
    /// Stable row identifier shared with the service routes.
    public let id: UUID
    /// Registry name supplied at promotion (for example `"summarize"`).
    public let name: String
    /// Absolute script path inside `workspace/tools/`.
    public let scriptPath: String
    /// Pinned SHA-256 hex of the file bytes at promotion time.
    public let sha256: String
    /// Whether verified execution is currently allowed.
    public var status: AgentToolStatus
    /// When the row was first persisted.
    public let createdAt: Date
    /// When the row last changed (promotion, verification failure, or status edit).
    public var updatedAt: Date

    /// Creates a record snapshot.
    public init(
        id: UUID = UUID(),
        name: String,
        scriptPath: String,
        sha256: String,
        status: AgentToolStatus = .enabled,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.scriptPath = scriptPath
        self.sha256 = sha256
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Typed failures for agent-tool promotion and verification.
///
/// Every case carries owner-actionable copy: the caller surfaces
/// `localizedDescription` directly instead of inventing a second message, so
/// the tool, CLI, and REST layers refuse identically.
public enum AgentToolStoreError: Error, Sendable, Equatable {
    /// The registry name was empty or used characters outside the slug set.
    case invalidName(String)
    /// The script path resolved outside `workspace/tools/`.
    case outsideWorkspace(String)
    /// No file exists at the resolved script path.
    case fileMissing(String)
    /// The file could not be read (permissions, directory, or I/O failure).
    case unreadable(String)
    /// No registry row exists for the requested name or identifier.
    case notFound(String)
    /// The live bytes no longer match the pin; the row has been disabled.
    case tampered(String)
    /// The row is parked disabled and must be re-enabled after review.
    case disabled(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
}

extension AgentToolStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidName(detail):
            detail.isEmpty ? "Invalid agent tool name." : detail
        case let .outsideWorkspace(detail):
            detail.isEmpty ? "Only scripts inside workspace/tools/ can be promoted." : detail
        case let .fileMissing(detail):
            detail.isEmpty ? "Script file not found." : detail
        case let .unreadable(detail):
            detail.isEmpty ? "Script file could not be read." : detail
        case let .notFound(detail):
            detail.isEmpty ? "Unknown agent tool." : detail
        case let .tampered(detail):
            detail.isEmpty ? "Agent tool failed verification and is disabled." : detail
        case let .disabled(detail):
            detail.isEmpty ? "Agent tool is disabled. Re-enable it after review before running." : detail
        case let .persistenceFailed(detail):
            detail.isEmpty ? "Agent tool store write failed." : detail
        case let .storeUnavailable(detail):
            detail.isEmpty ? "Agent tool store unavailable." : detail
        }
    }
}

/// Needs-attention sink invoked when verification fails closed.
///
/// The store owns detection (hash mismatch) while the host owns surfacing: the
/// service logs and badges, tests capture, and direct-core callers stay silent
/// with nil. The message is already owner-readable, so sinks forward it
/// verbatim instead of rewording.
public typealias AgentToolAttentionSink = @Sendable (String) async -> Void

/// Verified script plus its immutable staged copy for execution.
///
/// The staged file carries the exact bytes that passed the hash check, written
/// to a random workspace/tmp path with owner-execute-only bits. Callers execute
/// the staged copy, never the workspace original, so a concurrent `bash.exec`
/// write to `workspace/tools/` after verification cannot swap bytes under the
/// running shell. The caller removes the copy after the run.
public struct StagedAgentTool: Sendable {
    /// Registry row whose pin the staged bytes matched.
    public let record: AgentToolRecord
    /// Random workspace/tmp file carrying the verified bytes.
    public let stagedURL: URL

    /// Creates a staged pair.
    public init(record: AgentToolRecord, stagedURL: URL) {
        self.record = record
        self.stagedURL = stagedURL
    }
}

/// Single-flight lock serializing agent-tool runs within one process.
///
/// An actor alone still interleaves when the operation awaits: a second caller
/// can enter while the first is suspended on hashing or shell spawn, so the
/// set carries ownership across those awaits. The service maps a refused
/// acquire to HTTP 409, mirroring the goal-advance contention path instead of
/// inventing a second status.
public actor AgentToolRunLock {
    /// Identifiers with an in-flight run.
    private var runningIDs: Set<UUID> = []

    /// Creates an empty run lock.
    public init() {}

    /// Acquires the slot for one tool row.
    /// - Parameter id: Tool row identifier.
    /// - Returns: True when the slot was acquired.
    @discardableResult
    public func tryAcquire(id: UUID) -> Bool {
        if runningIDs.contains(id) {
            return false
        }
        runningIDs.insert(id)
        return true
    }

    /// Releases the slot. Unknown identifiers are a no-op.
    /// - Parameter id: Tool row identifier.
    public func release(id: UUID) {
        runningIDs.remove(id)
    }

    /// Whether the tool has an in-flight run.
    /// - Parameter id: Tool row identifier.
    /// - Returns: True while the tool is running.
    public func isRunning(id: UUID) -> Bool {
        runningIDs.contains(id)
    }
}

/// Actor-isolated SQLite store for hash-pinned agent scripts.
///
/// One store owns the `agent_tools` table so boot promotion, shell dispatch,
/// and dashboard CRUD observe the same pins: the table is created additively
/// (`CREATE TABLE IF NOT EXISTS`) so opening a database that already carries
/// conversations never disturbs existing rows. Blocking SQLite work runs off
/// the actor executor through the shared serial store queue, mirroring the
/// goal store, and every multi-row mutation commits in one statement so a
/// crash can never leave a half-pinned row.
public actor AgentToolStore {
    /// Subdirectory of the workspace root that alone may host promoted scripts.
    public static let toolsDirectoryName = "tools"
    /// Longest registry name the store accepts, bounding row and prompt growth.
    public static let maxNameLength = 64

    /// Filesystem path of the shared SQLite database.
    ///
    /// Held `nonisolated` so paired stores over the same file can be built
    /// synchronously without an actor hop for an immutable path; the value
    /// never mutates after initialization, so no isolation protects it.
    public nonisolated let dbPath: String
    /// Scratch workspace owning the eligible `tools/` directory.
    private let workspaceStore: WorkspaceStore
    /// Needs-attention sink invoked on every fail-closed verification.
    private let eventSink: AgentToolAttentionSink?

    /// Creates a store over the shared database file.
    /// - Parameters:
    ///   - dbPath: SQLite file path (the same `episodes.db` used by sessions and goals).
    ///   - workspaceStore: Workspace owning the eligible directory; nil derives the real-home store.
    ///   - eventSink: Needs-attention sink for tamper transitions; nil keeps detection silent.
    public init(dbPath: String, workspaceStore: WorkspaceStore? = nil, eventSink: AgentToolAttentionSink? = nil) {
        self.dbPath = dbPath
        self.workspaceStore = workspaceStore ?? WorkspaceStore()
        self.eventSink = eventSink
    }

    /// Resolves the eligible tools directory without touching disk.
    ///
    /// Derived per call from the live workspace root so a test-injected store
    /// with an isolated root and the production home store never disagree on
    /// eligibility; the `tools` leaf is appended, never configured, so only
    /// that one directory ever qualifies.
    /// - Returns: Canonical eligible directory.
    public func toolsDirectory() async -> URL {
        await workspaceStore.root().appendingPathComponent(Self.toolsDirectoryName)
    }

    /// Promotes a script into the registry, pinning its current bytes.
    ///
    /// Re-promotion updates the pin (path plus hash plus stamp) while
    /// preserving identity and lifecycle state: a disabled row stays disabled
    /// until the owner explicitly re-enables it, so a quiet file change can
    /// never self-heal into execution by re-promoting alone. The file must
    /// already exist as a regular file; promotion never creates it.
    /// - Parameters:
    ///   - name: Registry name for later runs.
    ///   - scriptPath: Caller-supplied script path (absolute, tilde, or workspace-relative).
    /// - Returns: The pinned row.
    @discardableResult
    public func promote(name: String, scriptPath: String) async throws -> AgentToolRecord {
        let trimmedName = try Self.validatedName(name)
        let resolved = try await resolvedScriptURL(for: scriptPath)
        let bytes = try Self.fileBytes(at: resolved, scriptPath: scriptPath)
        let digest = Self.sha256Hex(of: bytes)
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.promote(
                name: trimmedName,
                scriptPath: resolved.path,
                sha256: digest,
                dbPath: dbPath
            )
        }
    }

    /// Re-hashes the pinned file and compares it against the stored pin.
    ///
    /// A match returns the row untouched so steady runs stay cheap; a
    /// mismatch flips the row to `disabled`, emits the needs-attention note
    /// through the injected sink, and throws the typed tamper error so the
    /// caller fails closed instead of executing changed bytes. A missing or
    /// unreadable file is treated as tampering for the same reason: the pin
    /// can no longer be proven, so execution must not proceed.
    /// - Parameter name: Registry name to verify.
    /// - Returns: The verified row when the bytes still match.
    @discardableResult
    public func verify(name: String) async throws -> AgentToolRecord {
        let (record, _) = try await verifiedRecordAndBytes(name: name)
        return record
    }

    /// Verifies the pin and stages the exact verified bytes for execution.
    ///
    /// The bytes are the ones that matched the pin, written to a random
    /// workspace/tmp file. Callers execute the staged copy, never the workspace
    /// original, so a concurrent `bash.exec` write to `workspace/tools/`
    /// after verification cannot swap bytes under the running shell. The
    /// staging directory resolves before verification so no await sits between
    /// the final hash and the immutable write, preserving TOCTOU atomicity.
    /// A row parked disabled fails without writing a temp copy, so disabled rows
    /// never pay the stage plus immediate cleanup; a hash mismatch still
    /// disables even an already-disabled row so tampering never goes silent.
    /// Hold `AgentToolRunLock` across this call and the spawn it enables so
    /// concurrent runs serialize instead of interleaving verify and spawn.
    /// The caller removes the copy via `removeStagedCopy(at:)` after the run
    /// settles.
    /// - Parameter name: Registry name to verify and stage.
    /// - Returns: Verified row plus the staged copy carrying the verified bytes.
    public func verifyAndStage(name: String) async throws -> StagedAgentTool {
        let stagingDir = await workspaceStore.root().appendingPathComponent(WorkspaceStore.tmpDirectoryName)
        let (stored, bytes) = try await verifiedRecordAndBytes(name: name)
        guard stored.status == .enabled else {
            throw AgentToolStoreError.disabled("Agent tool '\(stored.name)' is disabled. Re-enable it after review before running.")
        }
        let stagedURL = try Self.stageVerifiedBytes(bytes, originalPath: stored.scriptPath, toolName: stored.name, stagingDirectory: stagingDir)
        return StagedAgentTool(record: stored, stagedURL: stagedURL)
    }

    /// Single verification path for `verify` plus `verifyAndStage`.
    ///
    /// Both entry points must agree byte-for-byte on what counts as verified:
    /// one fetch, one read, one hash compare with the same fail-closed
    /// disablement, so a later edit to the tamper handling cannot fix one
    /// path while leaving the other behind.
    /// - Parameter name: Registry name to verify.
    /// - Returns: Verified row plus the exact bytes that matched the pin.
    private func verifiedRecordAndBytes(name: String) async throws -> (record: AgentToolRecord, bytes: Data) {
        let trimmedName = try Self.validatedName(name)
        let dbPath = self.dbPath
        let stored: AgentToolRecord? = try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.record(named: trimmedName, dbPath: dbPath)
        }
        guard let stored else {
            throw AgentToolStoreError.notFound("Unknown agent tool '\(trimmedName)'. Promote it from workspace/tools/ first.")
        }
        let fileURL = URL(fileURLWithPath: stored.scriptPath)
        let bytes: Data
        do {
            bytes = try Self.fileBytes(at: fileURL, scriptPath: stored.scriptPath)
        } catch {
            // An unreadable pin proves nothing, so the row is disabled like a
            // mismatch rather than left enabled behind an I/O error.
            _ = try await SQLiteSerialIO.run {
                try SQLiteAgentToolStore.setStatusByName(name: trimmedName, status: .disabled, dbPath: dbPath)
            }
            await emitAttention(note: Self.tamperNote(name: trimmedName, reason: "the pinned script could not be read and the tool was disabled"))
            throw AgentToolStoreError.tampered(
                "Agent tool '\(trimmedName)' failed verification (script unreadable)"
                    + " and is now disabled. Re-promote after review."
            )
        }
        let currentDigest = Self.sha256Hex(of: bytes)
        guard currentDigest.lowercased() == stored.sha256.lowercased() else {
            _ = try await SQLiteSerialIO.run {
                try SQLiteAgentToolStore.setStatusByName(name: trimmedName, status: .disabled, dbPath: dbPath)
            }
            await emitAttention(note: Self.tamperNote(name: trimmedName, reason: "the script changed since promotion and the tool was disabled"))
            throw AgentToolStoreError.tampered("Agent tool '\(trimmedName)' failed verification (hash mismatch) and is now disabled. Re-promote after review.")
        }
        return (stored, bytes)
    }

    /// Removes a staged copy best-effort after the run settles.
    ///
    /// Missing files are a no-op so double-cleanup and crash-recovered temps
    /// never fail a run that already succeeded; failures are swallowed because
    /// cleanup must never mask the execution outcome.
    /// - Parameter url: Staged file to remove.
    public static func removeStagedCopy(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes verified bytes to a random workspace/tmp file for execution.
    ///
    /// The filename carries a UUID plus the original extension so shebang
    /// dispatch survives without leaking the registry name; `0500` keeps the
    /// copy owner-readable plus executable while refusing further writes, and
    /// the random name keeps a concurrent workspace writer from targeting the
    /// copy it cannot enumerate in the short stage-to-spawn window. The copy
    /// lives under workspace/tmp (owner-only `0700`, quota-bounded) so the
    /// shell maps a workspace-controlled immutable copy with the cwd guard
    /// plus sandbox read roots covering it. The staging directory is resolved
    /// before the hash and created synchronously here, so no await sits
    /// between the final hash and the immutable write.
    ///
    /// A symlinked staging directory or workspace root refuses fail-closed
    /// before any create or write follows the link outside the workspace,
    /// single-sourced via `WorkspaceContainment` with the scratch store, so a
    /// swapped `workspace -> /` or `tmp -> /` never chmods or writes outside
    /// the workspace. The payload reserves exclusively at `0500` before a
    /// single byte lands, so verified bytes are never writable.
    /// - Parameters:
    ///   - bytes: Exact bytes that matched the pin.
    ///   - originalPath: Pinned path supplying the extension hint.
    ///   - toolName: Registry name for the failure message.
    ///   - stagingDirectory: Workspace/tmp directory holding the staged copy.
    /// - Returns: Staged file URL carrying the verified bytes.
    private static func stageVerifiedBytes(_ bytes: Data, originalPath: String, toolName: String, stagingDirectory: URL) throws -> URL {
        try refuseSymlinkedStagingDirectory(stagingDirectory, toolName: toolName)
        let ext = (originalPath as NSString).pathExtension
        let filename = "runeweaver-tool-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
        } catch {
            throw AgentToolStoreError.persistenceFailed("Agent tool '\(toolName)' could not be staged for execution: \(error.localizedDescription)")
        }
        let url = stagingDirectory.appendingPathComponent(filename)
        // The random filename carries no separator, but the canonical staged
        // path must still sit under the canonical staging directory so a
        // raced swap between the pre-create refusal above and this write
        // cannot steer the copy outside the workspace.
        let canonicalStaging = WorkspaceContainment.canonical(stagingDirectory)
        let canonicalStaged = WorkspaceContainment.canonical(url)
        guard !WorkspaceContainment.escapesRoot(canonical: canonicalStaged, expectedRoot: canonicalStaging) else {
            try? FileManager.default.removeItem(at: url)
            throw AgentToolStoreError.persistenceFailed(
                "Agent tool '\(toolName)' could not be staged for execution: workspace unavailable at \(stagingDirectory.path):"
                    + " resolved path escapes workspace boundary (\(canonicalStaged.path))"
            )
        }
        do {
            try WorkspaceContainment.writeImmutableBytes(bytes, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AgentToolStoreError.persistenceFailed("Agent tool '\(toolName)' could not be staged for execution: \(error.localizedDescription)")
        }
        return url
    }

    /// Refuses when the staging directory escapes the workspace boundary.
    ///
    /// Covers only the final components via `lstat` plus the canonical
    /// prefix check, single-sourced via `WorkspaceContainment` with the
    /// scratch store: the workspace root (the staging directory's parent)
    /// and the staging directory itself must both be non-links, and the
    /// symlink-resolved staging path must stay under the symlink-resolved
    /// workspace root. Both sides resolve together so benign system links
    /// (`/var` -> `/private/var` under test temp roots) stay usable while a
    /// swapped `tmp` link diverges outside the root and refuses. Runs
    /// synchronously with no await so the `verifyAndStage` hash-to-write
    /// window stays atomic. Fails closed with `persistenceFailed`.
    /// - Parameters:
    ///   - stagingDirectory: Workspace/tmp directory holding the staged copy.
    ///   - toolName: Registry name for the failure message.
    private static func refuseSymlinkedStagingDirectory(_ stagingDirectory: URL, toolName: String) throws {
        let workspaceRoot = stagingDirectory.deletingLastPathComponent()
        if let bad = WorkspaceContainment.firstSymlink(in: [stagingDirectory, workspaceRoot]) {
            if bad.path == stagingDirectory.path {
                throw AgentToolStoreError.persistenceFailed(
                    "Agent tool '\(toolName)' could not be staged for execution: workspace tmp unavailable at \(stagingDirectory.path):"
                        + " tmp directory is a symlink and will not be followed"
                )
            }
            throw AgentToolStoreError.persistenceFailed(
                "Agent tool '\(toolName)' could not be staged for execution: workspace unavailable at \(workspaceRoot.path):"
                    + " workspace root is a symlink and will not be followed"
            )
        }
        let canonicalStaging = WorkspaceContainment.canonical(stagingDirectory)
        let canonicalRoot = WorkspaceContainment.canonical(workspaceRoot)
        guard !WorkspaceContainment.escapesRoot(canonical: canonicalStaging, expectedRoot: canonicalRoot) else {
            throw AgentToolStoreError.persistenceFailed(
                "Agent tool '\(toolName)' could not be staged for execution: workspace unavailable at \(stagingDirectory.path):"
                    + " resolved path escapes workspace boundary (\(canonicalStaging.path))"
            )
        }
    }

    /// Reads one row by registry name, or nil when absent.
    /// - Parameter name: Registry name.
    /// - Returns: The row, or nil.
    public func get(name: String) async throws -> AgentToolRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.record(named: trimmed, dbPath: dbPath)
        }
    }

    /// Reads one row by identifier, or nil when absent.
    /// - Parameter id: Row identifier.
    /// - Returns: The row, or nil.
    public func get(id: UUID) async throws -> AgentToolRecord? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.record(id: id, dbPath: dbPath)
        }
    }

    /// Lists every pinned row ordered by name for stable dashboard rendering.
    /// - Returns: All rows, empty when none are promoted.
    public func list() async throws -> [AgentToolRecord] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.list(dbPath: dbPath)
        }
    }

    /// Moves one row to a new lifecycle state by name.
    /// - Parameters:
    ///   - name: Registry name.
    ///   - status: New state.
    /// - Returns: The updated row.
    @discardableResult
    public func setStatus(name: String, status: AgentToolStatus) async throws -> AgentToolRecord {
        let trimmedName = try Self.validatedName(name)
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.setStatusByName(name: trimmedName, status: status, dbPath: dbPath)
        }
    }

    /// Moves one row to a new lifecycle state by identifier.
    /// - Parameters:
    ///   - id: Row identifier.
    ///   - status: New state.
    /// - Returns: The updated row.
    @discardableResult
    public func setStatus(id: UUID, status: AgentToolStatus) async throws -> AgentToolRecord {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.setStatusByID(id: id, status: status, dbPath: dbPath)
        }
    }

    /// Removes one row by registry name. Unknown names are a no-op returning false.
    /// - Parameter name: Registry name.
    /// - Returns: True when a row was removed.
    @discardableResult
    public func remove(name: String) async throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.removeByName(name: trimmed, dbPath: dbPath)
        }
    }

    /// Removes one row by identifier. Unknown identifiers are a no-op returning false.
    /// - Parameter id: Row identifier.
    /// - Returns: True when a row was removed.
    @discardableResult
    public func remove(id: UUID) async throws -> Bool {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteAgentToolStore.removeByID(id: id, dbPath: dbPath)
        }
    }

    // MARK: - Validation and hashing

    /// Checks whether a script path resolves inside the eligible tools directory.
    ///
    /// Both sides resolve symlinks before the prefix check, so a symlinked
    /// parent (`tools/evil -> /tmp` plus `tools/evil/pwn.sh`) cannot hide an
    /// outside target behind an inside spelling, and a moved or symlinked
    /// workspace root still refuses at dispatch. The trailing-slash form keeps
    /// `tools-evil/` from prefix-matching `tools/`. Single-sourced for
    /// promotion, `tool.run` dispatch, and the service run route so all three
    /// agree byte-for-byte. Boundary math lives in `WorkspaceContainment`.
    /// - Parameters:
    ///   - scriptPath: Absolute script path to test (promotion candidate or pinned row).
    ///   - toolsDir: Eligible `tools/` directory (unresolved is fine; it is resolved here).
    /// - Returns: True when the resolved script sits inside the resolved tools directory.
    public static func isContainedInTools(scriptPath: String, toolsDir: URL) -> Bool {
        WorkspaceContainment.isContained(path: scriptPath, inside: toolsDir)
    }

    /// Validates a registry name to the owner-visible slug set.
    ///
    /// Names are the prompt-visible handle for a script, so they stay short,
    /// printable, and free of path separators: slashes or whitespace would let
    /// a name masquerade as a path in logs and dashboards. The set is ASCII
    /// only (`A-Za-z0-9-_.`, at most 64 chars), mirroring the dashboard
    /// `^[A-Za-z0-9._-]+$` check so Unicode homographs never enter the
    /// registry from either surface.
    /// - Parameter raw: Caller-supplied name.
    /// - Returns: Trimmed valid name.
    public static func validatedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolStoreError.invalidName("Agent tool name must not be empty.")
        }
        guard trimmed.count <= maxNameLength else {
            throw AgentToolStoreError.invalidName("Agent tool name must be \(maxNameLength) characters or fewer (got \(trimmed.count)).")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw AgentToolStoreError.invalidName("Agent tool name '\(trimmed)' may use only letters, numbers, '-', '_', and '.'.")
        }
        return trimmed
    }

    /// Resolves a caller-supplied script path into the eligible directory.
    ///
    /// Tilde expands, relative spellings resolve against the workspace root
    /// with a canonical `tools/` base so `tools/cleanup.sh` and its absolute
    /// form agree, and `..` collapses via standardization before the prefix
    /// check so `tools/../outside` cannot escape. A legacy `workspace/`
    /// lead strips first, so `workspace/tools/cleanup.sh` maps to the same
    /// `tools/cleanup.sh` file instead of nesting under `<root>/workspace/`
    /// outside the eligible directory. The full candidate resolves symlinks
    /// before the prefix check (single-sourced with the run-time gate via
    /// `isContainedInTools`), so a symlinked parent inside `tools/` pointing
    /// outside still refuses instead of pinning foreign bytes.
    /// - Parameter scriptPath: Caller-supplied path.
    /// - Returns: Canonical absolute file URL inside `tools/`.
    private func resolvedScriptURL(for scriptPath: String) async throws -> URL {
        let trimmed = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolStoreError.invalidName("Script path must not be empty. Only scripts inside workspace/tools/ can be promoted.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let root = await workspaceStore.root()
        let toolsDir = root.appendingPathComponent(Self.toolsDirectoryName).standardizedFileURL
        let candidate: URL = if expanded.hasPrefix("/") {
            URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            root.appendingPathComponent(WorkspaceContainment.stripWorkspacePrefix(expanded)).standardizedFileURL
        }
        guard candidate.path != toolsDir.path else {
            throw AgentToolStoreError.invalidName("Script path must name a file inside workspace/tools/, not the directory itself.")
        }
        // The full candidate resolves symlinks before the prefix check, so a
        // parent-directory symlink escape (`tools/evil -> /tmp` plus
        // `tools/evil/pwn.sh`) refuses even though the unresolved spelling
        // standardizes inside `tools/`.
        guard Self.isContainedInTools(scriptPath: candidate.path, toolsDir: toolsDir) else {
            let resolved = WorkspaceContainment.canonical(candidate)
            if resolved.path != candidate.path {
                throw AgentToolStoreError.outsideWorkspace("Only scripts inside workspace/tools/ can be promoted (link escapes to '\(resolved.path)').")
            }
            throw AgentToolStoreError.outsideWorkspace(
                "Only scripts inside workspace/tools/ can be promoted (got '\(trimmed)')."
                    + " Move the script under \(toolsDir.path) first."
            )
        }
        // A symlink to the tools directory itself resolves to the directory,
        // which names no file; refuse like the direct directory spelling.
        let resolved = WorkspaceContainment.canonical(candidate)
        let resolvedTools = WorkspaceContainment.canonical(toolsDir)
        guard resolved.path != resolvedTools.path else {
            throw AgentToolStoreError.invalidName("Script path must name a file inside workspace/tools/, not the directory itself.")
        }
        return candidate
    }

    /// Reads file bytes, refusing directories and missing entries with typed copy.
    ///
    /// Directories read as data would otherwise pin an unstable listing, so
    /// they refuse before hashing; the honest reason names the path so the
    /// owner can fix it without guessing.
    private static func fileBytes(at url: URL, scriptPath: String) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentToolStoreError.fileMissing("Script not found at '\(scriptPath)'. Only existing files inside workspace/tools/ can be promoted.")
        }
        guard !isDirectory.boolValue else {
            throw AgentToolStoreError.unreadable("Script at '\(scriptPath)' is a directory; promote a regular file instead.")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AgentToolStoreError.unreadable("Script at '\(scriptPath)' could not be read: \(error.localizedDescription)")
        }
    }

    /// Hashes file bytes to lowercase SHA-256 hex for pinning.
    /// - Parameter data: Exact file bytes.
    /// - Returns: Hex digest.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the needs-attention note emitted on every fail-closed verification.
    ///
    /// The note names the tool and the cause in one line so dashboards can
    /// badge it without parsing: the row is already disabled, and the owner
    /// re-promotes after review.
    private static func tamperNote(name: String, reason: String) -> String {
        "Agent tool '\(name)' needs attention: \(reason)."
    }

    /// Emits the needs-attention note best-effort through the injected sink.
    ///
    /// A missing sink is a silent detection (direct-core callers), never a
    /// failure: verification still flips the row and throws, so the sink can
    /// never gate the fail-closed transition.
    private func emitAttention(note: String) async {
        guard let eventSink else { return }
        await eventSink(note)
    }
}

#if canImport(SQLite3)
    /// Blocking SQLite implementation behind ``AgentToolStore``.
    enum SQLiteAgentToolStore {
        /// Opens (creating parent directories) and migrates the database.
        ///
        /// The table is additive only: existing session, message, episode,
        /// goal, and run-log tables are never altered or dropped, so a shared
        /// `episodes.db` keeps its history intact.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        static func open(dbPath: String) throws -> OpaquePointer? {
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: AgentToolStoreError.storeUnavailable)
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS agent_tools(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    script_path TEXT NOT NULL,
                    sha256 TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
                failure: AgentToolStoreError.persistenceFailed
            )
            return handle
        }

        /// Executes a multi-statement SQL string.
        static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: AgentToolStoreError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Column-text helper returning nil for NULL columns.
        static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            SQLiteHelpers.columnText(statement, index: index)
        }

        /// Reads the record at the statement's current row.
        static func readRecord(_ statement: OpaquePointer?) -> AgentToolRecord? {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let name = columnText(statement, index: 1),
                  let scriptPath = columnText(statement, index: 2),
                  let sha256 = columnText(statement, index: 3),
                  let statusRaw = columnText(statement, index: 4)
            else { return nil }
            // Unknown statuses fail closed to disabled so a hand-edited row
            // can never execute while claiming an unrecognized state.
            let status = AgentToolStatus(rawValue: statusRaw) ?? .disabled
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            return AgentToolRecord(
                id: id,
                name: name,
                scriptPath: scriptPath,
                sha256: sha256,
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        /// Promotes a script, updating the pin while preserving identity and state.
        ///
        /// A fresh name inserts an enabled row; a known name updates only the
        /// path, hash, and stamp so a disabled row stays disabled until the
        /// owner explicitly re-enables it instead of self-healing silently.
        static func promote(name: String, scriptPath: String, sha256: String, dbPath: String) throws -> AgentToolRecord {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            if let existing = try record(named: name, handle: handle) {
                var update: OpaquePointer?
                guard sqlite3_prepare_v2(
                    handle,
                    "UPDATE agent_tools SET script_path = ?, sha256 = ?, updated_at = ? WHERE name = ?;",
                    -1,
                    &update,
                    nil
                ) == SQLITE_OK else {
                    throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool re-promotion")
                }
                defer { sqlite3_finalize(update) }
                let now = Date()
                bindText(update, index: 1, value: scriptPath)
                bindText(update, index: 2, value: sha256.lowercased())
                sqlite3_bind_double(update, 3, now.timeIntervalSince1970)
                bindText(update, index: 4, value: name)
                guard sqlite3_step(update) == SQLITE_DONE else {
                    throw AgentToolStoreError.persistenceFailed("Could not re-promote agent tool '\(name)'")
                }
                var refreshed = existing
                refreshed = AgentToolRecord(
                    id: existing.id,
                    name: existing.name,
                    scriptPath: scriptPath,
                    sha256: sha256.lowercased(),
                    status: existing.status,
                    createdAt: existing.createdAt,
                    updatedAt: now
                )
                return refreshed
            }
            let now = Date()
            let record = AgentToolRecord(
                name: name,
                scriptPath: scriptPath,
                sha256: sha256.lowercased(),
                status: .enabled,
                createdAt: now,
                updatedAt: now
            )
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "INSERT INTO agent_tools(id, name, script_path, sha256, status, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?);",
                -1,
                &insert,
                nil
            ) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool promotion")
            }
            defer { sqlite3_finalize(insert) }
            bindText(insert, index: 1, value: record.id.uuidString)
            bindText(insert, index: 2, value: record.name)
            bindText(insert, index: 3, value: record.scriptPath)
            bindText(insert, index: 4, value: record.sha256)
            bindText(insert, index: 5, value: record.status.rawValue)
            sqlite3_bind_double(insert, 6, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(insert, 7, record.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw AgentToolStoreError.persistenceFailed("Could not promote agent tool '\(name)'")
            }
            return record
        }

        /// Reads one row by name on an open handle.
        static func record(named name: String, handle: OpaquePointer?) throws -> AgentToolRecord? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT id, name, script_path, sha256, status, created_at, updated_at FROM agent_tools WHERE name = ?;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: name)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readRecord(statement)
        }

        /// Reads one row by name, opening the database.
        static func record(named name: String, dbPath: String) throws -> AgentToolRecord? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            return try record(named: name, handle: handle)
        }

        /// Reads one row by identifier.
        static func record(id: UUID, dbPath: String) throws -> AgentToolRecord? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT id, name, script_path, sha256, status, created_at, updated_at FROM agent_tools WHERE id = ?;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readRecord(statement)
        }

        /// Lists every row ordered by name for stable rendering.
        static func list(dbPath: String) throws -> [AgentToolRecord] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT id, name, script_path, sha256, status, created_at, updated_at FROM agent_tools ORDER BY name ASC;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool list")
            }
            defer { sqlite3_finalize(statement) }
            var results: [AgentToolRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = readRecord(statement) {
                    results.append(record)
                }
            }
            return results
        }

        /// Moves one row to a new state by name.
        static func setStatusByName(name: String, status: AgentToolStatus, dbPath: String) throws -> AgentToolRecord {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE agent_tools SET status = ?, updated_at = ? WHERE name = ?;", -1, &update, nil) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool status update")
            }
            defer { sqlite3_finalize(update) }
            let now = Date()
            bindText(update, index: 1, value: status.rawValue)
            sqlite3_bind_double(update, 2, now.timeIntervalSince1970)
            bindText(update, index: 3, value: name)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw AgentToolStoreError.persistenceFailed("Could not update agent tool '\(name)'")
            }
            guard sqlite3_changes(handle) > 0 else {
                throw AgentToolStoreError.notFound("Unknown agent tool '\(name)'.")
            }
            guard let refreshed = try record(named: name, handle: handle) else {
                throw AgentToolStoreError.notFound("Unknown agent tool '\(name)'.")
            }
            return refreshed
        }

        /// Moves one row to a new state by identifier.
        static func setStatusByID(id: UUID, status: AgentToolStatus, dbPath: String) throws -> AgentToolRecord {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE agent_tools SET status = ?, updated_at = ? WHERE id = ?;", -1, &update, nil) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool status update")
            }
            defer { sqlite3_finalize(update) }
            let now = Date()
            bindText(update, index: 1, value: status.rawValue)
            sqlite3_bind_double(update, 2, now.timeIntervalSince1970)
            bindText(update, index: 3, value: id.uuidString)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw AgentToolStoreError.persistenceFailed("Could not update agent tool \(id)")
            }
            guard sqlite3_changes(handle) > 0 else {
                throw AgentToolStoreError.notFound("Unknown agent tool \(id.uuidString).")
            }
            var read: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT id, name, script_path, sha256, status, created_at, updated_at FROM agent_tools WHERE id = ?;",
                -1,
                &read,
                nil
            ) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool read")
            }
            defer { sqlite3_finalize(read) }
            bindText(read, index: 1, value: id.uuidString)
            guard sqlite3_step(read) == SQLITE_ROW, let refreshed = readRecord(read) else {
                throw AgentToolStoreError.notFound("Unknown agent tool \(id.uuidString).")
            }
            return refreshed
        }

        /// Removes one row by name.
        static func removeByName(name: String, dbPath: String) throws -> Bool {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return false }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM agent_tools WHERE name = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: name)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AgentToolStoreError.persistenceFailed("Could not delete agent tool '\(name)'")
            }
            return sqlite3_changes(handle) > 0
        }

        /// Removes one row by identifier.
        static func removeByID(id: UUID, dbPath: String) throws -> Bool {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return false }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM agent_tools WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw AgentToolStoreError.persistenceFailed("Could not prepare agent tool delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AgentToolStoreError.persistenceFailed("Could not delete agent tool \(id)")
            }
            return sqlite3_changes(handle) > 0
        }
    }
#endif
