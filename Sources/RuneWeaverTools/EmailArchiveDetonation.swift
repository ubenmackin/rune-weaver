// Rune Weaver Tools — Ephemeral microVM detonation for email archives.
//
// Isolates untrusted ZIP/TAR bytes in zero-host-mounts container machines
// with manifest-only returns, so archive inspection never stages payloads
// to the host while approved exports still pass the workspace guard.

import Foundation
import RuneWeaverCore

/// Result of detonating one archive inside an isolated microVM.
///
/// Carries only the session correlation id, the entry manifest, and the
/// raw bytes of a single inspected entry when requested. Archive bytes
/// themselves never cross back except through the single inspected entry
/// or an explicit approval-gated export handled by the tool.
public struct EmailArchiveDetonationResult: Sendable, Equatable {
    /// Ephemeral detonation correlation id (`runeweaver-session-<uuid>`).
    public let sessionId: String
    /// Entries listed inside the archive, truncated to the manifest cap.
    public let manifest: [EmailArchiveEntry]
    /// Whether the manifest was truncated at the entry cap.
    public let manifestTruncated: Bool
    /// Raw bytes of the inspected subpath entry, when requested.
    public let entryData: Data?

    /// Creates a detonation result.
    public init(sessionId: String, manifest: [EmailArchiveEntry], manifestTruncated: Bool = false, entryData: Data? = nil) {
        self.sessionId = sessionId
        self.manifest = manifest
        self.manifestTruncated = manifestTruncated
        self.entryData = entryData
    }
}

/// Isolates archive inspection inside a zero-host-mounts microVM.
///
/// Production spawns an ephemeral container machine per archive with no
/// filesystem mounts, unpacks and lists inside via `run`, and reaps the
/// machine immediately; the TTL sweeper remains the safety net for
/// crashes. Tests inject a stub so no container runtime is required.
public protocol EmailArchiveDetonator: Sendable {
    /// Detonates archive bytes and optionally extracts one entry.
    /// - Parameters:
    ///   - filename: Original attachment filename for format hints.
    ///   - contentType: Raw MIME type for format hints.
    ///   - data: Raw archive bytes (already capped at the attachment limit).
    ///   - subpath: Validated relative entry path to extract, if any.
    /// - Returns: Session id, manifest, and optional entry bytes.
    func detonate(filename: String, contentType: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult
}

/// Ephemeral microVM detonator backed by the container machine manager.
///
/// Each call owns its machine lifetime: create with the configured base
/// image and runtime (the manager exposes no mount options, so guests
/// start with zero host mounts on an internal virtual disk), stream the
/// archive bytes over stdin for listing and optional extraction, then
/// best-effort stop and delete. Sessions are never reused across calls:
/// every detonation is ephemeral and reaped immediately, with the TTL prune
/// as the safety net only for machines orphaned by crashes. Concurrency is
/// capped before spawn so a burst of archives fails closed instead of
/// oversubscribing the host. Failures fail closed without staging
/// anything to the host; cleanup errors are swallowed so the original
/// detonation failure (never archive bytes or secrets) is what surfaces.
public struct LiveEmailArchiveDetonator: EmailArchiveDetonator, Sendable {
    /// Container CLI runtime name or path.
    public let containerRuntime: String
    /// OCI base image for detonation guests.
    public let containerBaseImage: String
    /// Maximum concurrent detonation machines, enforced before spawn.
    public let maxConcurrentMachines: Int

    /// Creates a live detonator.
    /// - Parameters:
    ///   - containerRuntime: Container CLI runtime name or path.
    ///   - containerBaseImage: OCI base image for detonation guests.
    ///   - maxConcurrentMachines: Cap on concurrent detonation machines, enforced before spawn.
    public init(
        containerRuntime: String = SandboxConfig.defaultContainerRuntime,
        containerBaseImage: String = SandboxConfig.defaultContainerBaseImage,
        maxConcurrentMachines: Int = SandboxConfig.defaultMaxConcurrentMachines
    ) {
        self.containerRuntime = containerRuntime
        self.containerBaseImage = containerBaseImage
        self.maxConcurrentMachines = maxConcurrentMachines
    }

    /// Detonates archive bytes in a fresh ephemeral machine.
    /// - Parameters:
    ///   - filename: Original attachment filename for format hints.
    ///   - contentType: Raw MIME type (unused beyond hints; listing probes formats inside the guest).
    ///   - data: Raw archive bytes.
    ///   - subpath: Validated relative entry path to extract, if any.
    /// - Returns: Session id, manifest, and optional entry bytes.
    public func detonate(filename: String, contentType _: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult {
        let sessionId = "runeweaver-session-\(UUID().uuidString.lowercased())"
        try await enforceConcurrencyLimit()
        try await ContainerMachineManager.createMachine(name: sessionId, image: containerBaseImage, runtime: containerRuntime)
        do {
            let listing = try await ContainerMachineManager.run(
                machineName: sessionId,
                command: ["sh", "-c", Self.listScript],
                runtime: containerRuntime,
                inputData: data
            )
            guard listing.exitCode == 0 else {
                throw EmailIMAPError.bridgeFailed("Could not inspect archive '\(filename)': unsupported or corrupt archive")
            }
            let parsed = EmailArchiveListingParser.parseListOutput(listing.stdoutString, filename: filename)
            guard !parsed.isEmpty else {
                throw EmailIMAPError.bridgeFailed("Could not inspect archive '\(filename)': unsupported or corrupt archive")
            }
            let capped = Array(parsed.prefix(EmailAttachmentLifecycle.maxArchiveManifestEntries))
            let truncated = parsed.count > capped.count
            var entryData: Data?
            if let subpath {
                guard capped.contains(where: { $0.path == subpath }) || parsed.contains(where: { $0.path == subpath }) else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                if let known = (parsed.first(where: { $0.path == subpath }))?.sizeBytes, known > EmailAttachmentTool.maxAttachmentBytes {
                    throw EmailIMAPError.bridgeFailed(EmailAttachmentTool.oversizeNote(sizeBytes: known))
                }
                let extracted = try await ContainerMachineManager.run(
                    machineName: sessionId,
                    command: ["sh", "-c", Self.extractScript, "sh", subpath],
                    runtime: containerRuntime,
                    inputData: data
                )
                guard extracted.exitCode == 0 else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                guard extracted.stdout.count <= EmailAttachmentTool.maxAttachmentBytes else {
                    throw EmailIMAPError.bridgeFailed(EmailAttachmentTool.oversizeNote(sizeBytes: extracted.stdout.count))
                }
                entryData = extracted.stdout
            }
            await Self.bestEffortReap(name: sessionId, runtime: containerRuntime)
            return EmailArchiveDetonationResult(sessionId: sessionId, manifest: capped, manifestTruncated: truncated, entryData: entryData)
        } catch {
            await Self.bestEffortReap(name: sessionId, runtime: containerRuntime)
            throw error
        }
    }

    /// Guest script listing archive entries from stdin bytes.
    ///
    /// Streams stdin to a scratch file, then probes ZIP before TAR so a
    /// mislabeled archive still lists; every probe is quiet so only the
    /// successful listing reaches stdout. No caller input is interpolated:
    /// the script is fixed text, keeping subpath payloads out of shell parsing.
    private static var listScript: String {
        "cat > /tmp/payload.bin; "
            + "if command -v unzip >/dev/null 2>&1; then "
            + "if unzip -l /tmp/payload.bin 2>/dev/null; then exit 0; fi; fi; "
            + "if tar -tzvf /tmp/payload.bin 2>/dev/null; then exit 0; fi; "
            + "if tar -tvf /tmp/payload.bin 2>/dev/null; then exit 0; fi; "
            + "echo UNSUPPORTED_ARCHIVE >&2; exit 1"
    }

    /// Guest script extracting one argv-passed entry from stdin bytes.
    ///
    /// The entry arrives as `$1` (never interpolated into shell text) and is
    /// always referenced behind `--` so leading dashes cannot parse as flags.
    /// ZIP is probed before TAR for the same mislabeling reason as listing.
    private static var extractScript: String {
        "cat > /tmp/payload.bin; entry=\"$1\"; "
            + "if command -v unzip >/dev/null 2>&1; then "
            + "if unzip -p /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; fi; "
            + "if tar -xzOf /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; "
            + "if tar -xOf /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; "
            + "exit 1"
    }

    /// Stops and deletes a detonation machine without masking the caller error.
    ///
    /// Ephemeral machines are reaped immediately after listing/extraction so
    /// no detonation VM outlives its call; the periodic TTL prune stays
    /// the safety net only for crashes between create and reap. There is no
    /// warm-session reuse across calls.
    /// - Parameters:
    ///   - name: Machine to reap.
    ///   - runtime: Container CLI runtime.
    private static func bestEffortReap(name: String, runtime: String) async {
        try? await ContainerMachineManager.stopMachine(name: name, runtime: runtime)
        try? await ContainerMachineManager.deleteMachine(name: name, runtime: runtime)
    }

    /// Fails closed when the concurrent detonation cap is already reached.
    ///
    /// Counts live `runeweaver-`-prefixed machines before spawn so a burst of
    /// archives cannot oversubscribe the host; listing failures fall through
    /// to `createMachine` so a missing runtime still surfaces its own error.
    private func enforceConcurrencyLimit() async throws {
        let cap = max(1, maxConcurrentMachines)
        do {
            let live = try await ContainerMachineManager.listMachines(
                prefix: ContainerMachineManager.machinePrefix,
                runtime: containerRuntime
            )
            guard live.count < cap else {
                throw EmailIMAPError.bridgeFailed(
                    "Archive detonation limit reached (\(cap) concurrent sessions); try again after idle sessions are reclaimed."
                )
            }
        } catch let bridge as EmailIMAPError {
            throw bridge
        } catch {
            // Listing failed (for example runtime missing): let create surface it.
        }
    }
}
