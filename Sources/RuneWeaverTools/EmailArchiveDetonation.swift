// Rune Weaver Tools — Ephemeral zero-mount container detonation for email archives.

import Foundation
import RuneWeaverCore

/// Result of detonating one archive inside an isolated ephemeral container.
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

/// Isolates archive inspection inside an ephemeral zero-mount container with
/// no host mounts (stdin in, stdout out; read-only rootfs over a tmpfs tmp).
public protocol EmailArchiveDetonator: Sendable {
    /// Detonates archive bytes and optionally extracts one entry.
    func detonate(filename: String, contentType: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult
}

/// Ephemeral zero-mount detonator backed by the shared container builder.
public struct LiveEmailArchiveDetonator: EmailArchiveDetonator, Sendable {
    /// Pinned OCI image for detonation guests; never config-driven.
    public static let detonationImage = "alpine:3.22"

    /// Guest memory cap applied at creation, derived from the containers config.
    public let memory: String
    /// Host runtime behind the shared builder (live by default, stub in tests).
    private let runtime: any ContainerHostRuntime
    /// Shared ephemeral admission ledger checked before every spawn.
    private let ephemeralLedger: EphemeralContainerLedger

    /// Creates a live detonator on the containers policy.
    public init(
        memoryMB: Int = ContainersConfig.defaultMemoryMB,
        maxConcurrent: Int = ContainersConfig.defaultMaxConcurrent,
        runtime: (any ContainerHostRuntime)? = nil,
        ephemeralLedger: EphemeralContainerLedger? = nil
    ) {
        let resolvedRuntime = runtime ?? LiveContainerHostRuntime()
        let policy = ContainersConfig(memoryMB: memoryMB, maxConcurrent: maxConcurrent)
        let clampedMemory = StrictContainerRunner.clampedMemoryMB(for: policy)
        let clampedConcurrent = StrictContainerRunner.clampedMaxConcurrent(for: policy)
        self.memory = StrictContainerRunner.memoryCapString(forMB: clampedMemory)
        self.runtime = resolvedRuntime
        self.ephemeralLedger = ephemeralLedger ?? EphemeralContainerLedger(runtime: resolvedRuntime, maxConcurrent: clampedConcurrent)
    }

    /// Creates a detonator from the loaded policy sharing one ledger.
    public init(
        containersConfig: ContainersConfig,
        runtime: (any ContainerHostRuntime)? = nil,
        ephemeralLedger: EphemeralContainerLedger? = nil
    ) {
        self.init(
            memoryMB: containersConfig.memoryMB,
            maxConcurrent: containersConfig.maxConcurrent,
            runtime: runtime,
            ephemeralLedger: ephemeralLedger
        )
    }

    /// Detonates archive bytes in a fresh zero-mount container.
    public func detonate(filename: String, contentType _: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult {
        let runID = UUID()
        let sessionId = "runeweaver-session-\(runID.uuidString.lowercased())"
        let containerName = StrictContainerRunner.strictContainerName(for: runID)
        // Admission rides the shared ledger before any spawn so the cap denies
        // fail-closed past its limit and a census failure never spawns.
        try await ephemeralLedger.admit(timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds)
        try runtime.probe()
        do {
            let created = try await runtime.run(
                arguments: StrictContainerRunner.containerCreateArguments(
                    name: containerName,
                    image: Self.detonationImage,
                    workdir: Self.detonationWorkdir,
                    networkDenied: true,
                    memory: memory
                ),
                timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds
            )
            guard created.exitCode == 0 else {
                throw ContainerOperationError.operationFailed(
                    "Failed to create detonation container '\(containerName)': \(created.stderrString)"
                )
            }
            let started = try await runtime.run(
                arguments: StrictContainerRunner.containerStartArguments(name: containerName),
                timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds
            )
            guard started.exitCode == 0 else {
                throw ContainerOperationError.operationFailed(
                    "Failed to start detonation container '\(containerName)': \(started.stderrString)"
                )
            }
            await ephemeralLedger.register(name: containerName)
            let listing = try await runtime.run(
                arguments: Self.detonationExecArguments(name: containerName, script: Self.listScript),
                inputData: data,
                timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds
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
                guard parsed.contains(where: { $0.path == subpath }) else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                if let known = (parsed.first(where: { $0.path == subpath }))?.sizeBytes, known > EmailAttachmentTool.maxAttachmentBytes {
                    throw EmailIMAPError.bridgeFailed(EmailAttachmentTool.oversizeNote(sizeBytes: known))
                }
                let extracted = try await runtime.run(
                    arguments: Self.detonationExecArguments(name: containerName, script: Self.extractScript, entry: subpath),
                    inputData: data,
                    timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds
                )
                guard extracted.exitCode == 0 else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                guard extracted.stdout.count <= EmailAttachmentTool.maxAttachmentBytes else {
                    throw EmailIMAPError.bridgeFailed(EmailAttachmentTool.oversizeNote(sizeBytes: extracted.stdout.count))
                }
                entryData = extracted.stdout
            }
            await Self.bestEffortReap(name: containerName, runtime: runtime)
            await ephemeralLedger.unregister(name: containerName)
            return EmailArchiveDetonationResult(sessionId: sessionId, manifest: capped, manifestTruncated: truncated, entryData: entryData)
        } catch {
            await Self.bestEffortReap(name: containerName, runtime: runtime)
            await ephemeralLedger.unregister(name: containerName)
            throw error
        }
    }

    /// Guest workdir inside the zero-mount container; the tmpfs tmp is the only writable spot.
    private static let detonationWorkdir = "/tmp"

    /// Guest exec arguments piping stdin into the pinned image's shell.
    static func detonationExecArguments(name: String, script: String, entry: String? = nil) -> [String] {
        var args = ["exec", "-i", name, "/bin/sh", "-c", script]
        if let entry {
            args.append(contentsOf: ["sh", entry])
        }
        return args
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

    /// Stops and deletes the detonation container without masking the caller error.
    private static func bestEffortReap(name: String, runtime: any ContainerHostRuntime) async {
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerStopArguments(name: name),
                timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds
            )
        } catch is CancellationError {
            // allow deletion attempt even if stop was cancelled
        } catch {
            RuneWeaverLog.tools.debug("bestEffortReap: stop \(name) failed: \(error.localizedDescription)")
        }
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerDeleteArguments(name: name),
                timeoutSeconds: StrictContainerRunner.defaultProcessTimeoutSeconds
            )
        } catch is CancellationError {
            return
        } catch {
            RuneWeaverLog.tools.debug("bestEffortReap: delete \(name) failed: \(error.localizedDescription)")
        }
    }
}
