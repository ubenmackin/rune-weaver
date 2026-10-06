// Rune Weaver Core — macOS Seatbelt (SBPL) profile generator for sandbox-exec.

import Foundation

/// Builder for macOS Seatbelt (SBPL) profiles used by `sandbox-exec`.
///
/// Network confinement is blanket-allow whenever `allowNetwork` is true:
/// per-host `remote tcp` filters are not expressible on current macOS (the
/// kernel only accepts `localhost` or `*` as IP, so hostnames reject as
/// kleene star), so the profile carries `(allow network*)` and per-host
/// enforcement lives in the supervisor's string screening instead. That
/// screening is best-effort: it sees explicit URLs, schemeless host text,
/// and typed URLs, but misses dials that never surface as recognizable host
/// strings (non-URL spellings, raw IP forms outside the screened text, and
/// encoded or obfuscated forms), so a screened pass is not a proof of
/// no-egress — defense in depth, not a boundary.
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
    /// Declared egress hosts constraining sandboxed network dials.
    ///
    /// Retained for approval surfacing and supervisor screening: the sandbox
    /// stays blanket-allow (`allow network*` when `allowNetwork` is true)
    /// whether this set is empty or not, because per-host SBPL is not
    /// expressible on current macOS (the kernel only accepts `localhost` or
    /// `*` as IP, so hostnames reject as kleene star). The supervisor remains
    /// the per-host enforcement point through best-effort string screening
    /// (undeclared deny, declared-plus-policy-allowed allow), which sees
    /// explicit URLs, schemeless host text, and typed URLs but misses dials
    /// that never surface as recognizable host strings (non-URL spellings
    /// and encoded or obfuscated forms).
    public var allowedEgressHosts: [String]

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
        "~/.runeweaver/memory/vectors",
        "~/.runeweaver/browser_profiles",
        "~/.runeweaver/config.toml",
        "~/.runeweaver/policy.toml",
        "~/.runeweaver/auth_token",
        "~/.runeweaver/searxng",
        "~/.git-credentials",
        "~/.gitcookies",
        "~/.rclone.conf",
        "~/.npmrc",
        "~/.pypirc",
        "~/.Xauthority",
        "~/.emulator_console_auth_token",
        "~/.kube",
        "~/.docker",
        "~/.chia_keys",
        "~/.zshrc",
        "~/.zprofile",
        "~/.zshenv",
        "~/.zlogin",
        "~/.bashrc",
        "~/.bash_profile",
        "~/.profile",
        "~/.bash_login",
        "~/.bash_logout",
        "~/Library/LaunchAgents",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons"
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
        #"/\.runeweaver/memory/vectors/"#,
        #"/\.runeweaver/browser_profiles/"#,
        // The bearer-token deny is filename-level so a `token_file` relocated
        // outside the default path still refuses; the SearXNG tree covers the
        // per-install Flask secret generated beside the app's config.
        #"/[^/]*auth_token$"#,
        #"/\.runeweaver/searxng/"#,
        #"/\.zshrc$"#,
        #"/\.zprofile$"#,
        #"/\.zshenv$"#,
        #"/\.zlogin$"#,
        #"/\.bashrc$"#,
        #"/\.bash_profile$"#,
        #"/\.profile$"#,
        #"/\.bash_login$"#,
        #"/\.bash_logout$"#,
        #"/[^/]*\.bashrc$"#,
        #"/[^/]*\.zshrc$"#,
        #"/[^/]*\.profile$"#,
        #"/[^/]*\.bash_profile$"#,
        #"/[^/]*\.zshenv$"#,
        #"/[^/]*\.zprofile$"#,
        #"/[^/]*\.zlogin$"#,
        #"/[^/]*\.bash_login$"#,
        #"/[^/]*\.bash_logout$"#,
        #"/[^/]*_history$"#,
        #"/\.zsh_sessions/"#,
        #"/Library/LaunchAgents/"#,
        #"/Library/LaunchDaemons/"#
    ]

    /// Maximum declared egress hosts honored per profile.
    ///
    /// Bounds SBPL size and keeps the approval surface reviewable: beyond ten
    /// the owner cannot meaningfully authorize destinations, so callers must
    /// split the work rather than widening silently.
    public static let maxEgressHosts = 10

    /// Creates a Seatbelt profile builder.
    public init(
        allowedReadPaths: [String] = [],
        allowedWritePaths: [String] = [],
        allowedTempPaths: [String] = [],
        deniedPaths: [String] = [],
        allowNetwork: Bool = false,
        allowedEgressHosts: [String] = []
    ) {
        self.allowedReadPaths = Set(allowedReadPaths)
        self.allowedWritePaths = Set(allowedWritePaths)
        self.allowedTempPaths = Set(allowedTempPaths)
        self.deniedPaths = Set(deniedPaths)
        self.allowNetwork = allowNetwork
        self.allowedEgressHosts = allowedEgressHosts
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
        appendNetworkPolicy(to: &lines)
        lines.append("")
        appendProcessCompat(to: &lines)
        lines.append(contentsOf: bootstrapLiterals())
        // Binary launch stays covered by the process exec/fork allows above combined with the file-
        // read and executable-mapping allows below: the kernel reads binaries through file-read
        // rights and maps them through file-map-executable rights, so both stay scoped to the same...
        let sanitizedTemp = Set(Self.sanitizedAllowPaths(allowedTempPaths))
        appendWriteIsolation(to: &lines, sanitizedTemp: sanitizedTemp)
        appendReadPolicy(to: &lines, sanitizedTemp: sanitizedTemp)
        appendExecPolicy(to: &lines, sanitizedTemp: sanitizedTemp)
        appendDenyPolicy(to: &lines)
        return lines.joined(separator: "\n")
    }

    /// Appends the network access policy with blanket-allow plus supervisor screening.
    ///
    /// The sandbox stays blanket-allow whenever `allowNetwork` is true,
    /// whether or not hosts are declared: per-host `remote tcp` with hostnames
    /// is not expressible on current macOS (the kernel only accepts
    /// `localhost` or `*` as IP, so hostnames reject as kleene star), so
    /// narrowing declared hosts to deny-all would grant less capability than
    /// declaring nothing and leave `network_hosts` unusable. The supervisor
    /// remains the per-host enforcement point through best-effort string
    /// screening (undeclared deny, declared-plus-policy-allowed allow), which
    /// sees explicit URLs, schemeless host text, and typed URLs but misses
    /// dials that never surface as recognizable host strings (non-URL
    /// spellings and encoded or obfuscated forms) — a screened pass narrows
    /// the dial surface without proving no-egress.
    /// - Parameter lines: Profile lines to append to.
    private func appendNetworkPolicy(to lines: inout [String]) {
        lines.append(";; Network access policy")
        guard allowNetwork else {
            lines.append("(deny network*)")
            return
        }
        let scopedHosts = Self.sanitizedEgressHosts(allowedEgressHosts)
        if !scopedHosts.isEmpty {
            let declaredHostCount = allowedEgressHosts.count
            let validHostCount = scopedHosts.count
            RuneWeaverLog.sandbox.info(
                "SeatbeltProfileBuilder: blanket-allow network with supervisor screening (validHosts=\(validHostCount) declared=\(declaredHostCount))."
            )
        }
        lines.append("(allow network*)")
    }

    /// Appends process and system-service compat for deny-default launch.
    ///
    /// - Parameter lines: Profile lines to append to.
    private func appendProcessCompat(to lines: inout [String]) {
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
    }

    /// Appends filesystem read isolation for system and workspace roots.
    ///
    /// - Parameters:
    ///   - lines: Profile lines to append to.
    ///   - sanitizedTemp: Confined temp dirs already sanitized for interpolation.
    private func appendReadPolicy(to lines: inout [String], sanitizedTemp: Set<String>) {
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
    }

    /// Appends executable-mapping confinement excluding temp staging.
    ///
    /// - Parameters:
    ///   - lines: Profile lines to append to.
    ///   - sanitizedTemp: Confined temp dirs excluded from execution.
    private func appendExecPolicy(to lines: inout [String], sanitizedTemp: Set<String>) {
        // Executable mapping stays confined to the same roots as reads minus temp: dyld maps system
        // libraries and the target binary via file-map-executable rather than file-read, so deny-
        // default would otherwise abort before main runs.
        var allRead = Set(Self.defaultSystemReadPaths)
        allRead.formUnion(Self.defaultSystemWritePaths)
        allRead.formUnion(Self.sanitizedAllowPaths(allowedReadPaths))
        allRead.formUnion(Self.sanitizedAllowPaths(allowedWritePaths))
        allRead.formUnion(sanitizedTemp)
        let executablePaths = allRead.sorted().filter { !sanitizedTemp.contains($0) }
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
    }

    /// Appends explicit credential denies plus filename-level secret denies.
    ///
    /// - Parameter lines: Profile lines to append to.
    private func appendDenyPolicy(to lines: inout [String]) {
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

extension SeatbeltProfileBuilder {
    /// Declared-host validation failures for `network_hosts`.
    ///
    /// Carries only the offending value so shell and desktop surfaces keep
    /// their own output idiom while sharing one validity rule: both tools
    /// map the error to `ToolOutput.failure` without duplicating the
    /// max-count or per-host checks.
    public enum DeclaredHostValidationError: Error, Sendable, Equatable {
        /// More hosts declared than `maxEgressHosts` allows.
        case tooMany(count: Int)
        /// One raw entry that is not a plain hostname or address literal.
        case invalidHost(String)

        /// Human-readable reason, safe to surface to the owner.
        public var message: String {
            switch self {
            case let .tooMany(count):
                "Invalid argument 'network_hosts': must contain at most"
                    + " \(SeatbeltProfileBuilder.maxEgressHosts)"
                    + " hosts (got \(count))."
            case let .invalidHost(rawHost):
                "Invalid argument 'network_hosts': '\(rawHost)'"
                    + " is not a valid hostname or IP address."
            }
        }
    }

    /// Validates raw `network_hosts` without touching sandbox or supervisor.
    ///
    /// Over-limit or malformed entries throw before any confinement contact
    /// so a misspelled destination never widens silently. Single-sources the
    /// rule previously duplicated across shell and desktop tools: max-count
    /// plus per-host `sanitizedEgressHosts([raw]).isEmpty` plus sanitize.
    /// - Parameter hosts: Raw declared hosts from the caller.
    /// - Returns: Canonical hosts in first-seen order, at most `maxEgressHosts`.
    public static func validatedDeclaredHosts(_ hosts: [String]) throws -> [String] {
        if hosts.count > maxEgressHosts {
            throw DeclaredHostValidationError.tooMany(count: hosts.count)
        }
        for rawHost in hosts
            where sanitizedEgressHosts([rawHost]).isEmpty
        {
            throw DeclaredHostValidationError.invalidHost(rawHost)
        }
        return sanitizedEgressHosts(hosts)
    }

    /// Validated egress hosts safe to interpolate into SBPL remote filters.
    ///
    /// Accepts single-label names (`localhost`), dotted hostnames, IPv4 quads,
    /// and bracketed or bare IPv6 literals; rejects wildcards, port-qualified
    /// entries, URLs, and SBPL-breaking scalars so a crafted host cannot split
    /// the profile. Comparison canonicalizes through the shared host
    /// normalizer, dedupes case-insensitively, and caps at `maxEgressHosts` in
    /// first-seen order so the sandbox and the supervisor agree on identity.
    /// - Parameter hosts: Raw declared hosts from the caller.
    /// - Returns: Canonical hosts in first-seen order, at most `maxEgressHosts`.
    public static func sanitizedEgressHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in hosts {
            guard out.count < maxEgressHosts else { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard isValidEgressHost(trimmed) else { continue }
            let canonical = SensitiveAddressNormalization.normalizedHost(trimmed)
            guard !canonical.isEmpty else { continue }
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            out.append(canonical)
        }
        return out
    }

    /// Whether one raw host is a plain hostname or address literal.
    ///
    /// Hostnames allow ASCII letters, digits, hyphens, and dots with no empty
    /// label and no leading or trailing hyphen, mirroring the dashboard
    /// `^[A-Za-z0-9._-]+$` slug/host contract so Unicode homographs (`café`,
    /// Cyrillic) never pass as declared hosts; address literals defer to the
    /// shared IPv4/IPv6 parsers so `127.0.0.1` and `::1` pass while `999.1.1.1`
    /// and `host:443` refuse. The check is syntactic only — reachability still
    /// flows through the policy allowlist and the SSRF guard.
    private static func isValidEgressHost(_ host: String) -> Bool {
        if host.contains("\n") || host.contains("\r") || host.contains("\0") {
            return false
        }
        if host.contains(" ") || host.contains("\t") {
            return false
        }
        if host.contains("\"") || host.contains("(") || host.contains(")") || host.contains(";") {
            return false
        }
        // "/" already rejects "://" spellings, so no separate scheme check.
        if host.contains("/") || host.contains("*") || host.contains("\\") {
            return false
        }
        if host.contains("@") || host.contains("?") || host.contains("#") {
            return false
        }
        var bare = host
        if bare.hasPrefix("["), bare.hasSuffix("]"), bare.count >= 2 {
            bare = String(bare.dropFirst().dropLast())
        }
        if bare.isEmpty {
            return false
        }
        if bare.lowercased() == "localhost" {
            return true
        }
        // Port-qualified spellings never count as hosts: a colon means an
        // IPv6 literal or nothing, so IPv4 resolution must not see the raw
        // `host:port` text and launder its numeric tail into an address.
        if bare.contains(":") {
            return SensitiveAddressParsing.ipv6Hextets(bare) != nil
        }
        if SensitiveAddressParsing.canonicalIPv4Octets(bare) != nil {
            return true
        }
        let labels = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.count <= 253 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        if labels.count == 1 {
            let single = String(labels[0])
            guard let first = single.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        }
        return true
    }
}

extension SeatbeltProfileBuilder.DeclaredHostValidationError: LocalizedError {
    public var errorDescription: String? {
        message
    }
}
