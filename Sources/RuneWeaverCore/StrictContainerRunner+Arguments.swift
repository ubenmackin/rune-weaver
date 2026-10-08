// Rune Weaver Core — Strict container argument builders.
//
// Purpose: own per-turn container naming plus create and exec shapes so the
// strict runner keeps one builder for every runtime invocation.
// Scope: naming, create with labels, exec, and lifecycle argument vectors
// only; resolution, inspection parsing, and live execution stay elsewhere.
// Architectural role: focused extension backing `StrictContainerRunner`
// keeping the enum body within the type-length budget.

import Foundation

// MARK: - StrictContainerRunner Argument Builders

extension StrictContainerRunner {
    /// Derives the per-session container name from the session identifier.
    /// - Parameter sessionID: Owning turn session.
    /// - Returns: Prefix plus the first 8 lowercase hex chars.
    public static func strictContainerName(for sessionID: UUID) -> String {
        let hex = sessionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return strictNamePrefix + hex
    }

    /// Builds `container create` arguments for one strict container.
    /// - Parameters:
    ///   - name: Container name.
    ///   - hostPath: Fresh scratch leaf on the host.
    ///   - guestPath: Mount point inside the guest.
    ///   - workdir: Working directory inside the guest.
    ///   - networkDenied: When true the container gets no DNS.
    ///   - memory: Guest memory cap.
    /// - Returns: Exact argument sequence for the runtime.
    public static func containerCreateArguments(
        name: String,
        hostPath: String,
        guestPath: String,
        workdir: String,
        networkDenied: Bool,
        memory: String = defaultMemory
    ) -> [String] {
        containerCreateArguments(
            name: name,
            hostPath: hostPath,
            guestPath: guestPath,
            workdir: workdir,
            networkDenied: networkDenied,
            memory: memory,
            labels: [:]
        )
    }

    /// Builds `container create` arguments with labels placed before the image.
    /// - Parameters:
    ///   - name: Container name.
    ///   - hostPath: Fresh scratch leaf on the host.
    ///   - guestPath: Mount point inside the guest.
    ///   - workdir: Working directory inside the guest.
    ///   - networkDenied: When true the container gets no DNS.
    ///   - memory: Guest memory cap.
    ///   - labels: Label pairs stored as `--label key=value` before the image.
    /// - Returns: Exact argument sequence with labels preceding the image.
    public static func containerCreateArguments(
        name: String,
        hostPath: String,
        guestPath: String,
        workdir: String,
        networkDenied: Bool,
        memory: String = defaultMemory,
        labels: [String: String]
    ) -> [String] {
        var args = [
            "create",
            "--name", name,
            "--volume", "\(hostPath):\(guestPath)",
            "--workdir", workdir,
            "--read-only",
            "--tmpfs", "/tmp",
            "--memory", memory
        ]
        if networkDenied {
            args.append("--no-dns")
        }
        for key in labels.keys.sorted() {
            guard let value = labels[key] else { continue }
            args.append("--label")
            args.append("\(key)=\(value)")
        }
        args.append(contentsOf: ["--entrypoint", "/bin/sleep", defaultImage, "infinity"])
        return args
    }

    /// Builds `container create` arguments for one zero-mount ephemeral container.
    ///
    /// Forced zero-volume runs mount nothing, so an untrusted payload never
    /// touches a host path; the guest keeps only its tmpfs `tmp` for scratch.
    /// - Parameters:
    ///   - name: Container name.
    ///   - image: Pinned OCI image for the guest.
    ///   - workdir: Working directory inside the guest.
    ///   - networkDenied: When true the container gets no DNS.
    ///   - memory: Guest memory cap.
    ///   - labels: Label pairs stored as `--label key=value` before the image.
    /// - Returns: Exact argument sequence with labels preceding the image.
    public static func containerCreateArguments(
        name: String,
        image: String,
        workdir: String,
        networkDenied: Bool,
        memory: String = defaultMemory,
        labels: [String: String] = [:]
    ) -> [String] {
        var args = [
            "create",
            "--name", name,
            "--workdir", workdir,
            "--read-only",
            "--tmpfs", "/tmp",
            "--memory", memory
        ]
        if networkDenied {
            args.append("--no-dns")
        }
        for key in labels.keys.sorted() {
            guard let value = labels[key] else { continue }
            args.append("--label")
            args.append("\(key)=\(value)")
        }
        args.append(contentsOf: ["--entrypoint", "/bin/sleep", image, "infinity"])
        return args
    }

    /// Builds `container exec` arguments for one strict container.
    /// - Parameters:
    ///   - name: Container name.
    ///   - workdir: Working directory inside the guest.
    ///   - command: Already resource-limited shell command.
    /// - Returns: Exact argument sequence for the runtime.
    public static func containerExecArguments(name: String, workdir: String, command: String) -> [String] {
        ["exec", "-w", workdir, name, "/bin/bash", "-c", command]
    }

    /// Arguments starting one strict container.
    public static func containerStartArguments(name: String) -> [String] {
        ["start", name]
    }

    /// Arguments stopping one strict container.
    public static func containerStopArguments(name: String) -> [String] {
        ["stop", name]
    }

    /// Arguments deleting one strict container.
    public static func containerDeleteArguments(name: String) -> [String] {
        ["delete", name]
    }

    /// Arguments listing every container including stopped ones.
    public static func containerListAllArguments() -> [String] {
        ["list", "--all"]
    }

    /// Arguments inspecting one ephemeral container by name.
    /// - Parameter name: Container to inspect.
    /// - Returns: Exact argument sequence for the runtime.
    public static func containerInspectArguments(name: String) -> [String] {
        ["inspect", name]
    }
}
