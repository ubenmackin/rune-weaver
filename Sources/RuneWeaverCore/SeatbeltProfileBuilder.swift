// Rune Weaver Core — macOS Seatbelt (SBPL) profile generator for sandbox-exec.

import Foundation

/// Builder for macOS Seatbelt (SBPL) profiles used by `sandbox-exec`.
public struct SeatbeltProfileBuilder: Sendable, Equatable {
    /// Directories permitted for read-only access (in addition to system defaults).
    public var allowedReadPaths: Set<String>
    /// Directories permitted for read and write access.
    public var allowedWritePaths: Set<String>
    /// Seatbelt-confined temp dirs for staged document writes.
    public var allowedTempPaths: Set<String>
    /// Explicitly forbidden paths (overriding read/write allowances).
    public var deniedPaths: Set<String>
    /// Whether outbound and inbound network access is permitted.
    public var allowNetwork: Bool

    /// Default system read paths essential for standard binaries and runtimes.
    public static let defaultSystemReadPaths: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",
        "/opt/homebrew",
        "/Applications/Xcode.app",
        "/Library/Developer/CommandLineTools",
        "/private/var/folders",
        "/var/folders",
        "/private/etc",
        "/etc",
        "/dev",
        "/private/var/db/dyld"
    ]

    /// Default temporary write paths required by compilers, shells, and runtimes.
    public static let defaultSystemWritePaths: [String] = [
        "/private/tmp",
        "/tmp",
        "/private/var/folders",
        "/var/folders"
    ]

    /// High-risk user paths denied by default across all sandboxed executions.
    public static let defaultDeniedPaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/Library/Keychains",
        "~/.config/gcloud",
        "~/.netrc",
        "~/.runeweaver/memory",
        "~/.runeweaver/browser_profiles",
        "~/.runeweaver/config.toml",
        "~/.runeweaver/policy.toml",
        "~/.runeweaver/auth_token",
        "~/.runeweaver/searxng"
    ]

    /// Filename-level denies applied anywhere in the tree via SBPL regex.
    public static let defaultSensitiveFileRegexes: [String] = [
        #"/\.env[^/]*$"#,
        #"/\.netrc$"#,
        #"/secrets\.json$"#,
        #"/config\.toml$"#,
        #"/[^/]*\.pem$"#,
        #"/[^/]*\.key$"#,
        #"/[^/]*keychain[^/]*"#,
        #"/\.ssh/"#,
        #"/\.aws/"#,
        #"/\.gnupg/"#,
        #"/\.runeweaver/memory/"#,
        #"/\.runeweaver/browser_profiles/"#,
        // The bearer-token deny is filename-level so a `token_file` relocated
        // outside the default path still refuses; the SearXNG tree covers the
        // per-install Flask secret generated beside the app's config.
        #"/[^/]*auth_token$"#,
        #"/\.runeweaver/searxng/"#
    ]

    /// Creates a Seatbelt profile builder.
    public init(
        allowedReadPaths: [String] = [],
        allowedWritePaths: [String] = [],
        allowedTempPaths: [String] = [],
        deniedPaths: [String] = [],
        allowNetwork: Bool = false
    ) {
        self.allowedReadPaths = Set(allowedReadPaths)
        self.allowedWritePaths = Set(allowedWritePaths)
        self.allowedTempPaths = Set(allowedTempPaths)
        self.deniedPaths = Set(deniedPaths)
        self.allowNetwork = allowNetwork
    }

    /// Creates a Seatbelt-confined temp directory for staged document writes.
    public static func makeConfinedTempDirectory(prefix: String = "runeweaver-doc-") throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let name = "\(prefix)\(UUID().uuidString)"
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Resolves and expands tildes in path list.
    private static func expandPaths(_ paths: [String]) -> [String] {
        paths.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed as NSString).expandingTildeInPath
        }
    }

    /// Allowlisted roots safe to interpolate into SBPL subpaths.
    private static func sanitizedAllowPaths(_ paths: Set<String>) -> [String] {
        expandPaths(Array(paths)).compactMap { expanded in
            guard expanded.hasPrefix("/") else { return nil }
            guard expanded != "/" else { return nil }
            guard !expanded.contains("\n"), !expanded.contains("\r"), !expanded.contains("\0") else { return nil }
            return expanded
        }
    }

    /// Deny roots safe to interpolate; malformed entries are dropped fail-closed.
    private static func sanitizedDenyPaths(_ paths: Set<String>) -> [String] {
        expandPaths(Array(paths)).compactMap { expanded in
            guard expanded.hasPrefix("/") else { return nil }
            guard !expanded.contains("\n"), !expanded.contains("\r"), !expanded.contains("\0") else { return nil }
            return expanded
        }
    }

    /// Bootstrap traversal rules keeping dyld launchable under deny-default.
    private func bootstrapLiterals() -> [String] {
        [
            ";; Bootstrap traversal for dyld and path resolution",
            "(allow file-read* file-test-existence",
            "    (literal \"/\")",
            "    (literal \"/.CFUserTextEncoding\")",
            ")",
            "(allow file-read-metadata file-test-existence",
            "    (literal \"/etc\")",
            "    (literal \"/tmp\")",
            "    (literal \"/var\")",
            "    (literal \"/private/etc/localtime\")",
            ")",
            "(allow file-read* file-test-existence",
            "    (subpath \"/private/var/db/timezone\")",
            "    (subpath \"/var/db/timezone\")",
            ")",
            ""
        ]
    }

    /// Appends deny-default write isolation plus narrow device sinks.
    private func appendWriteIsolation(to lines: inout [String], sanitizedTemp: Set<String>) {
        lines.append(";; Filesystem write isolation: block all writes by default")
        lines.append("(deny file-write* (subpath \"/\"))")
        var allWrite = Set(Self.defaultSystemWritePaths)
        allWrite.formUnion(Self.sanitizedAllowPaths(allowedWritePaths))
        allWrite.formUnion(sanitizedTemp)
        let sortedWrite = allWrite.sorted()
        if !sortedWrite.isEmpty {
            lines.append("(allow file-write*")
            for path in sortedWrite {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }
        lines.append("(allow file-write*")
        lines.append("    (literal \"/dev/null\")")
        lines.append("    (literal \"/dev/zero\")")
        lines.append("    (literal \"/dev/dtracehelper\")")
        lines.append(")")
        lines.append("")
    }

    /// Synthesizes the complete SBPL Scheme string for `/usr/bin/sandbox-exec -p`.
    public func buildProfile() -> String {
        var lines: [String] = []
        lines.append("(version 1)")
        lines.append("(deny default)")
        lines.append("")

        // Network policy
        lines.append(";; Network access policy")
        if allowNetwork {
            lines.append("(allow network*)")
        } else {
            lines.append("(deny network*)")
        }
        lines.append("")

        // Process and system-service compat: a deny-default sandbox cannot launch the dynamic
        // linker or query kernel state without these, so they reopen only execution and discovery
        // while file and network confinement below still holds.
        lines.append(";; Process and system-service compat for macOS 14+ dyld")
        lines.append("(allow process-fork)")
        lines.append("(allow process-exec*)")
        // Process introspection stays open for self only in spirit: libSystem
        // queries its own pid and process list during startup, and denying
        // these aborts before main runs even though no other process is touched.
        lines.append("(allow process-info*)")
        lines.append("(allow sysctl-read)")
        lines.append("(allow mach-lookup)")
        lines.append("(allow signal)")
        // Execution prerequisites that stay denied by default but are required for libSystem and
        // dyld to finish launching: shared-memory setup for dispatch, system-domain sockets for
        // service discovery, and ioctls for inherited stdio.
        lines.append("(allow ipc-posix-shm*)")
        // Dispatch may back semaphores with posix semaphores on some OS
        // releases, so both shared-memory flavors stay open while filesystem
        // and network confinement below still holds.
        lines.append("(allow ipc-posix-sem*)")
        lines.append("(allow system-socket)")
        lines.append("(allow file-ioctl)")
        lines.append("")
        lines.append(contentsOf: bootstrapLiterals())
        // Binary launch stays covered by the process exec/fork allows above combined with the file-
        // read and executable-mapping allows below: the kernel reads binaries through file-read
        // rights and maps them through file-map-executable rights, so both stay scoped to the same...

        let sanitizedTemp = Set(Self.sanitizedAllowPaths(allowedTempPaths))
        appendWriteIsolation(to: &lines, sanitizedTemp: sanitizedTemp)

        // Filesystem read policy: deny-default already blocks reads, so reopen only minimal system
        // roots plus caller workspace roots.
        lines.append(";; Filesystem read isolation: allow only system and workspace roots")
        var allRead = Set(Self.defaultSystemReadPaths)
        allRead.formUnion(Self.defaultSystemWritePaths)
        allRead.formUnion(Self.sanitizedAllowPaths(allowedReadPaths))
        allRead.formUnion(Self.sanitizedAllowPaths(allowedWritePaths))
        allRead.formUnion(sanitizedTemp)
        let sortedRead = allRead.sorted()
        if !sortedRead.isEmpty {
            lines.append("(allow file-read* file-test-existence")
            for path in sortedRead {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }

        // Executable mapping stays confined to the same roots as reads minus temp: dyld maps system
        // libraries and the target binary via file-map-executable rather than file-read, so deny-
        // default would otherwise abort before main runs.
        let executablePaths = sortedRead.filter { !sanitizedTemp.contains($0) }
        if !executablePaths.isEmpty {
            lines.append("(allow file-map-executable")
            for path in executablePaths {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }
        if !sanitizedTemp.isEmpty {
            lines.append(";; Temp staging is never executable: staged bytes move on approval, never run in place")
            lines.append("(deny file-map-executable")
            for path in sanitizedTemp.sorted() {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }

        // Denied sensitive paths (highest priority overrides)
        lines.append(";; Explicit credential and sensitive directory denials")
        var allDeny = Set(Self.expandPaths(Self.defaultDeniedPaths))
        allDeny.formUnion(Self.sanitizedDenyPaths(deniedPaths))
        let sortedDeny = allDeny.sorted()
        if !sortedDeny.isEmpty {
            lines.append("(deny file-read* file-write* file-map-executable file-test-existence")
            for path in sortedDeny {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }

        // Filename-level secret denies: catch bare names wherever they sit,
        // including inside an allowed workspace where subpath allows would
        // otherwise reopen them.
        lines.append(";; Sensitive filename denials applied anywhere in the tree")
        let sortedRegexes = Self.defaultSensitiveFileRegexes.sorted()
        if !sortedRegexes.isEmpty {
            lines.append("(deny file-read* file-write* file-map-executable file-test-existence")
            for pattern in sortedRegexes {
                lines.append("    (regex #\"\(pattern)\")")
            }
            lines.append(")")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Escapes a path for interpolation inside an SBPL quoted string.
    private func escapeScheme(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for character in path {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "(":
                escaped += "\\("
            case ")":
                escaped += "\\)"
            case ";":
                escaped += "\\;"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                // Drop remaining C0 controls that could split directives;
                // legitimate macOS paths never rely on them, and dropping
                // fails closed to a non-matching subpath.
                if character.isASCII, let ascii = character.asciiValue, ascii < 0x20 || ascii == 0x7F {
                    continue
                }
                escaped.append(character)
            }
        }
        return escaped
    }
}
