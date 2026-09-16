// Rune Weaver Tools — Ephemeral microVM detonation for email archives.

import Foundation
import RuneWeaverCore

/// Result of detonating one archive inside an isolated microVM.
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
public protocol EmailArchiveDetonator: Sendable {
    /// Detonates archive bytes and optionally extracts one entry.
    func detonate(filename: String, contentType: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult
}

/// Ephemeral microVM detonator backed by the container machine manager.
public struct LiveEmailArchiveDetonator: EmailArchiveDetonator, Sendable {
    /// Container CLI runtime name or path.
    public let containerRuntime: String
    /// OCI base image for detonation guests.
    public let containerBaseImage: String
    /// Maximum concurrent detonation machines, enforced before spawn.
    public let maxConcurrentMachines: Int

    /// Creates a live detonator.
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
    private static var listScript: String {
        "cat > /tmp/payload.bin; "
            + "if command -v unzip >/dev/null 2>&1; then "
            + "if unzip -l /tmp/payload.bin 2>/dev/null; then exit 0; fi; fi; "
            + "if tar -tzvf /tmp/payload.bin 2>/dev/null; then exit 0; fi; "
            + "if tar -tvf /tmp/payload.bin 2>/dev/null; then exit 0; fi; "
            + "echo UNSUPPORTED_ARCHIVE >&2; exit 1"
    }

    /// Guest script extracting one argv-passed entry from stdin bytes.
    private static var extractScript: String {
        "cat > /tmp/payload.bin; entry=\"$1\"; "
            + "if command -v unzip >/dev/null 2>&1; then "
            + "if unzip -p /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; fi; "
            + "if tar -xzOf /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; "
            + "if tar -xOf /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; "
            + "exit 1"
    }

    /// Stops and deletes a detonation machine without masking the caller error.
    private static func bestEffortReap(name: String, runtime: String) async {
        try? await ContainerMachineManager.stopMachine(name: name, runtime: runtime)
        try? await ContainerMachineManager.deleteMachine(name: name, runtime: runtime)
    }

    /// Fails closed when the concurrent detonation cap is already reached.
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
            RuneWeaverLog.tools.debug("EmailArchiveDetonation: Container pre-check listing skipped: \(error.localizedDescription); deferring to creation.")
        }
    }
}
