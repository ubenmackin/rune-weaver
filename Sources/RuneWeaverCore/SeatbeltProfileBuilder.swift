// Rune Weaver Core — macOS Seatbelt (SBPL) profile generator for sandbox-exec.
//
// Synthesizes Scheme-based Sandbox Profile Language (SBPL) profiles for
// execution under `/usr/bin/sandbox-exec -p`. Enforces principle of least
// privilege at the macOS XNU kernel layer: using a deny-default baseline
// with explicit allows for dyld and system service discovery on macOS 14+,
// while strictly denying network access by default, confining filesystem
// reads and writes to explicit workspace boundaries plus minimal system and
// runtime temp paths, and completely blocking access to user credentials,
// keys, and sensitive project secrets.

import Foundation

/// Builder for macOS Seatbelt (SBPL) profiles used by `sandbox-exec`.
public struct SeatbeltProfileBuilder: Sendable, Equatable {
    /// Directories permitted for read-only access (in addition to system defaults).
    public var allowedReadPaths: Set<String>
    /// Directories permitted for read and write access.
    public var allowedWritePaths: Set<String>
    /// Explicitly forbidden paths (overriding read/write allowances).
    public var deniedPaths: Set<String>
    /// Whether outbound and inbound network access is permitted.
    public var allowNetwork: Bool

    /// Default system read paths essential for standard binaries and runtimes.
    ///
    /// Kept to OS and toolchain locations only: a denied-by-default sandbox
    /// cannot start the dynamic linker or interpreters without these, so they
    /// reopen just enough for `/bin/cat` and `/usr/bin/python3` to launch
    /// without exposing any user data.
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
    ///
    /// Covers credential directories plus the local memory store so a
    /// compromised rune cannot exfiltrate episodes or configuration even when
    /// the broader home tree stays reachable for legitimate work.
    public static let defaultDeniedPaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/Library/Keychains",
        "~/.config/gcloud",
        "~/.netrc",
        "~/.runeweaver/memory",
        "~/.runeweaver/config.toml"
    ]

    /// Filename-level denies applied anywhere in the tree via SBPL regex.
    ///
    /// Subpath denies only match directory prefixes, so bare secret names
    /// (`secrets.json`, `.env*`, `*.pem`) hiding inside an allowed workspace
    /// would otherwise slip through the allowlist. These patterns mirror the
    /// shared file-policy deny list so the kernel sandbox and the file tools
    /// agree on which names are never readable.
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
        #"/\.runeweaver/memory/"#
    ]

    /// Creates a Seatbelt profile builder.
    /// - Parameters:
    ///   - allowedReadPaths: Additional read-only paths.
    ///   - allowedWritePaths: Read-write paths (typically the workspace).
    ///   - deniedPaths: Explicitly denied paths.
    ///   - allowNetwork: Whether network sockets are permitted (defaults to false).
    public init(
        allowedReadPaths: [String] = [],
        allowedWritePaths: [String] = [],
        deniedPaths: [String] = [],
        allowNetwork: Bool = false
    ) {
        self.allowedReadPaths = Set(allowedReadPaths)
        self.allowedWritePaths = Set(allowedWritePaths)
        self.deniedPaths = Set(deniedPaths)
        self.allowNetwork = allowNetwork
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
    ///
    /// Rejects anything that would silently reopen the whole filesystem
    /// (`/`), non-absolute entries that resolve ambiguously under the sandbox
    /// working directory, and line-splitting controls that could smuggle extra
    /// directives past the quoted string. Rejection fails closed: a dropped
    /// workspace simply stays unreadable instead of weakening confinement.
    private static func sanitizedAllowPaths(_ paths: Set<String>) -> [String] {
        expandPaths(Array(paths)).compactMap { expanded in
            guard expanded.hasPrefix("/") else { return nil }
            guard expanded != "/" else { return nil }
            guard !expanded.contains("\n"), !expanded.contains("\r"), !expanded.contains("\0") else { return nil }
            return expanded
        }
    }

    /// Deny roots safe to interpolate; malformed entries are dropped fail-closed.
    ///
    /// A broken filter must never break profile parsing: dropping keeps the
    /// profile valid so `sandbox-exec` stays enforced, with the deny-default
    /// baseline still covering the omitted path.
    private static func sanitizedDenyPaths(_ paths: Set<String>) -> [String] {
        expandPaths(Array(paths)).compactMap { expanded in
            guard expanded.hasPrefix("/") else { return nil }
            guard !expanded.contains("\n"), !expanded.contains("\r"), !expanded.contains("\0") else { return nil }
            return expanded
        }
    }

    /// Bootstrap traversal rules keeping dyld launchable under deny-default.
    ///
    /// The dynamic linker resolves its launch base through the filesystem
    /// root and consults timezone data on macOS 14+, so these narrow
    /// literals and the single system-data subtree stay open while
    /// deny-default still holds everywhere else.
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

    /// Synthesizes the complete SBPL Scheme string for `/usr/bin/sandbox-exec -p`.
    ///
    /// Uses a deny-default baseline so every operation is blocked unless
    /// explicitly allowed, then reopens just enough for macOS dyld, libSystem,
    /// and IPC runtimes to initialize on macOS 14+ via minimal process,
    /// executable-mapping, sysctl, Mach, and system-path read allows:
    /// - Network egress and ingress are blocked by default.
    /// - Filesystem reads and writes are confined to explicit workspace roots
    ///   plus minimal system and temporary directories.
    /// - High-risk user directories (SSH, AWS, Keychains, etc.) are explicitly
    ///   denied for reads, writes, and executable mapping.
    /// - Sensitive filenames (.env, secrets.json, *.pem, etc.) are denied tree-wide.
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

        // Process and system-service compat: a deny-default sandbox cannot
        // launch the dynamic linker or query kernel state without these, so
        // they reopen only execution and discovery while file and network
        // confinement below still holds.
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
        // Execution prerequisites that stay denied by default but are required
        // for libSystem and dyld to finish launching: shared-memory setup for
        // dispatch, system-domain sockets for service discovery, and ioctls
        // for inherited stdio. None of these reopens filesystem or network
        // access on its own; inherited pipes stay usable without an explicit
        // rule since they are open before confinement and carry no path.
        lines.append("(allow ipc-posix-shm*)")
        // Dispatch may back semaphores with posix semaphores on some OS
        // releases, so both shared-memory flavors stay open while filesystem
        // and network confinement below still holds.
        lines.append("(allow ipc-posix-sem*)")
        lines.append("(allow system-socket)")
        lines.append("(allow file-ioctl)")
        lines.append("")
        lines.append(contentsOf: bootstrapLiterals())
        // Binary launch stays covered by the process exec/fork allows above
        // combined with the file-read and executable-mapping allows below: the
        // kernel reads binaries through file-read rights and maps them through
        // file-map-executable rights, so both stay scoped to the same roots.

        // Filesystem write policy: deny all writes by default, then allow designated directories
        lines.append(";; Filesystem write isolation: block all writes by default")
        lines.append("(deny file-write* (subpath \"/\"))")
        var allWrite = Set(Self.defaultSystemWritePaths)
        allWrite.formUnion(Self.sanitizedAllowPaths(allowedWritePaths))
        let sortedWrite = allWrite.sorted()
        if !sortedWrite.isEmpty {
            lines.append("(allow file-write*")
            for path in sortedWrite {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }
        // Runtime device sinks: null and tracing helpers stay writable without
        // reopening general writes. Placed after the write deny so the narrow
        // literals override the broad deny while all other writes stay confined.
        // Inherited stdout/stderr pipes need no explicit rule: they are open
        // before confinement and carry no filesystem path, so confinement
        // still holds.
        lines.append("(allow file-write*")
        lines.append("    (literal \"/dev/null\")")
        lines.append("    (literal \"/dev/zero\")")
        lines.append("    (literal \"/dev/dtracehelper\")")
        lines.append(")")
        lines.append("")

        // Filesystem read policy: deny-default already blocks reads, so reopen
        // only minimal system roots plus caller workspace roots. Write roots
        // are included here as well since listing or reading back a just-written
        // file requires read rights; credential denies below still override.
        // Existence checks travel with reads so allowed roots stay statable:
        // dyld and standard tools probe before mapping, and a denied probe
        // fails the launch even when the content itself would be permitted.
        lines.append(";; Filesystem read isolation: allow only system and workspace roots")
        var allRead = Set(Self.defaultSystemReadPaths)
        allRead.formUnion(Self.defaultSystemWritePaths)
        allRead.formUnion(Self.sanitizedAllowPaths(allowedReadPaths))
        allRead.formUnion(Self.sanitizedAllowPaths(allowedWritePaths))
        let sortedRead = allRead.sorted()
        if !sortedRead.isEmpty {
            lines.append("(allow file-read* file-test-existence")
            for path in sortedRead {
                lines.append("    (subpath \"\(escapeScheme(path))\")")
            }
            lines.append(")")
            lines.append("")
        }

        // Executable mapping stays confined to the same roots as reads: dyld
        // maps system libraries and the target binary via file-map-executable
        // rather than file-read, so deny-default would otherwise abort before
        // main runs. Scoping matches reads so no new filesystem reach is added.
        if !sortedRead.isEmpty {
            lines.append("(allow file-map-executable")
            for path in sortedRead {
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
    ///
    /// Quoted SBPL strings still honor backslash escapes, so an unescaped
    /// quote or backslash from a marketplace-controlled directory name could
    /// terminate the string and smuggle extra directives. Parentheses,
    /// semicolons, and line breaks are neutralized as well so a crafted name
    /// cannot comment out the closing quote or split the profile across lines
    /// even if the parser's quoting rules tighten or loosen.
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
