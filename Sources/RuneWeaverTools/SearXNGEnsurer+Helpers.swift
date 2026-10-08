// Rune Weaver Tools — SearXNGEnsurer configuration helpers.
//
// Holds the pure configuration surface for the local SearXNG lifecycle:
// loopback management checks, Apple Container runtime resolution, daemon
// probe plus system-start recovery, failure-detail formatting, host-port
// mapping, bundled template lookup, and the per-install settings document
// carrying a random Flask secret plus a template-version marker so stale
// installs migrate forward with a fresh secret and a container recreate.
// This keeps the `SearXNGEnsurer` actor body
// within the type-length budget while the lifecycle entry points in
// `WebSearchTool.swift` retain single-flight ensure, honest start reporting,
// cooperative cancellation, loopback-only publishing, fail-closed settings,
// secret file permissions, port parity between probe and publish, and the
// Bundle plus executable-adjacent plus repo-checkout fallback chain.

import Foundation
import RuneWeaverCore

extension SearXNGEnsurer {
    /// Whether a base URL is locally managed (loopback) rather than external.
    /// Only loopback bases can be healed by starting the local container; an
    /// external SearXNG needs no local start, so callers report started:false
    /// instead of claiming an irrelevant container launch. Unspecified
    /// addresses (`0.0.0.0`, `::`) are never managed: a container published
    /// there would never converge the loopback probe, so only `127/8`,
    /// `::1`, and `localhost` qualify.
    public static func isManagedBaseURL(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return false
        }
        if isUnspecifiedHost(host) {
            return false
        }
        return ApiSSRFGuard.isLoopbackHost(host)
    }

    /// Whether a host is the unspecified address (`0.0.0.0` or `::`).
    /// Covers resolver-accepted spellings (decimal, hex, octal, short forms
    /// plus compressed IPv6) so `0`, `0x0`, and `::` fail closed like the
    /// dotted quad.
    private static func isUnspecifiedHost(_ host: String) -> Bool {
        if let octets = ApiSSRFGuard.canonicalIPv4Octets(host),
           octets.firstOctet == 0, octets.secondOctet == 0, octets.thirdOctet == 0, octets.fourthOctet == 0
        {
            return true
        }
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.contains(":"), !cleaned.contains("."), let groups = ApiSSRFGuard.ipv6Hextets(cleaned),
           groups.allSatisfy({ $0 == 0 })
        {
            return true
        }
        return false
    }

    /// Known install locations always probed after PATH entries.
    /// A minimal or GUI-launched PATH often omits Homebrew, so the fallback
    /// keeps a standard install discoverable without trusting PATH alone.
    public static let fallbackRuntimeDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Ordered directories probed for the container runtime.
    /// PATH order wins so an operator override shadows the fallback, while the
    /// appended fallbacks keep a Homebrew install visible when PATH is minimal.
    /// Duplicates collapse so a PATH that already carries a fallback probes it
    /// once; blanks are skipped so empty segments never become relative probes.
    /// - Parameter pathValue: Raw `PATH` value, or nil when unset.
    /// - Returns: Deduplicated directories, PATH entries first.
    public static func runtimeSearchDirectories(pathValue: String?) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ dir: String) {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }
        if let pathValue {
            for part in pathValue.split(separator: ":") {
                append(String(part))
            }
        }
        for fallback in fallbackRuntimeDirectories {
            append(fallback)
        }
        return ordered
    }

    /// Ordered directories probed for the container runtime in this process.
    /// Reads the live `PATH` so production and diagnostics share one ordering
    /// instead of drifting between call sites.
    /// - Returns: Deduplicated directories, PATH entries first.
    public static func runtimeSearchDirectories() -> [String] {
        runtimeSearchDirectories(pathValue: ProcessInfo.processInfo.environment["PATH"])
    }

    /// Resolves the Apple Container runtime with no Docker fallback.
    /// Docker is intentionally unsupported: the soul reuses the Tier-3
    /// dependency instead of adding a second container runtime, so hosts
    /// without `container` fail closed with the escape-hatch guidance.
    /// Probes the shared search ordering so a minimal PATH never hides a
    /// Homebrew install; nil preserves the missing-runtime contract for the
    /// cascade to fail closed with guidance.
    /// - Parameters:
    ///   - searchDirectories: Ordered directories to probe.
    ///   - isExecutable: Filesystem probe, injectable so tests can stub an install.
    /// - Returns: Executable URL, or nil when the Apple Container CLI is missing.
    public static func resolveRuntimeURL(
        searchDirectories: [String],
        isExecutable: (String) -> Bool
    ) -> URL? {
        let runtime = "container"
        for dir in searchDirectories {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(runtime)
            if isExecutable(candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Resolves the runtime against an explicit PATH value for testing.
    /// Keeps the production lookup honest by routing the same fallback
    /// ordering through a stubbed filesystem probe.
    /// - Parameters:
    ///   - pathValue: Raw `PATH` value driving the search ordering.
    ///   - isExecutable: Filesystem probe, injectable so tests can stub an install.
    /// - Returns: Executable URL, or nil when missing everywhere searched.
    public static func resolveRuntimeURL(pathValue: String?, isExecutable: (String) -> Bool) -> URL? {
        resolveRuntimeURL(searchDirectories: runtimeSearchDirectories(pathValue: pathValue), isExecutable: isExecutable)
    }

    /// Resolves the Apple Container runtime with no Docker fallback.
    /// Docker is intentionally unsupported: the soul reuses the Tier-3
    /// dependency instead of adding a second container runtime, so hosts
    /// without `container` fail closed with the escape-hatch guidance.
    /// - Returns: Executable URL, or nil when the Apple Container CLI is missing.
    public static func resolveRuntimeURL() -> URL? {
        resolveRuntimeURL(
            searchDirectories: runtimeSearchDirectories(),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Fast probe budget for the container system daemon check.
    /// Short so a down daemon fails fast instead of burning the ensure budget.
    public static let daemonProbeTimeoutSeconds: Double = 5
    /// Bounded budget for healing the container system service.
    /// Short enough that the cached-image heals stay responsive ahead of the
    /// minutes-scale readiness watch; the watch backstop does not cover these heals.
    public static let containerSystemStartTimeoutSeconds: Double = 8
    /// Cap for the stderr tail carried in failure detail.
    /// Keeps dashboard messages readable while preserving the actionable line.
    public static let maxFailureTailChars = 500
    /// Install location for the Apple Container CLI backing search and detonation.
    public static let appleContainerInstallURL = "https://github.com/apple/container"

    /// Guidance returned when the container runtime cannot be resolved.
    /// Points at the Apple Container install and rules out Docker, so a bare
    /// host fails with a next step instead of a bare exit code. Names the
    /// searched directories so the banner alone explains the miss without
    /// re-running the lookup; the list mirrors the resolver ordering.
    /// - Parameter searchedDirectories: Directories probed, defaulting to the live search ordering.
    /// - Returns: Human-readable install guidance naming where it looked.
    public static func installGuidanceMessage(searchedDirectories: [String]? = nil) -> String {
        let searched = (searchedDirectories ?? runtimeSearchDirectories()).joined(separator: ", ")
        return "Container runtime 'container' not found. Install the Apple Container CLI "
            + "(\(appleContainerInstallURL)), then retry. Docker is not supported. "
            + "After installing, start the system with `container system start` and verify with `container list`. "
            + "Searched: \(searched)."
    }

    /// Single-cause error for a missing container runtime.
    /// Carries only the install guidance (with the searched directories) so
    /// callers surface one cause plus one command instead of nesting the
    /// unreachable-engine text around the install text.
    /// - Parameter searchedDirectories: Directories probed, defaulting to the live search ordering.
    /// - Returns: Error carrying the install next step.
    public static func runtimeNotFoundError(searchedDirectories: [String]? = nil) -> Error {
        let directories = searchedDirectories ?? runtimeSearchDirectories()
        let message = installGuidanceMessage(searchedDirectories: directories)
        return NSError(domain: "RuneWeaverSearXNG", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Arguments probing the container system daemon without side effects.
    /// `list` needs the daemon yet changes nothing, so it doubles as the
    /// health probe and the README verify step.
    /// - Returns: Arguments for the daemon probe.
    public static func daemonProbeArguments() -> [String] {
        ["list"]
    }

    /// Arguments healing a down container system service.
    /// Matches the documented `container system start` recovery so the engine,
    /// the escape-hatch script, and the README never diverge.
    /// - Returns: Arguments starting the system service.
    public static func containerSystemStartArguments() -> [String] {
        ["system", "start"]
    }

    /// Whether container output indicates a down system service.
    /// Matches only specific down-state phrases (`XPC connection` with word
    /// boundaries plus the `system service` hint), so a fresh boot or a
    /// stopped service heals via `system start` while unrelated output that
    /// merely mentions `xpc` never triggers the heal.
    /// - Parameter output: Combined stdout plus stderr from the probe.
    /// - Returns: True when the service needs a start.
    public static func isDaemonDown(output: String) -> Bool {
        let lowered = output.lowercased()
        if lowered.range(of: #"\bxpc\W+connection\b"#, options: .regularExpression) != nil {
            return true
        }
        if lowered.contains("system-service") || lowered.contains("system service") || lowered.contains("system_service") {
            return true
        }
        return false
    }

    /// Keeps only the actionable tail of process output for failure detail.
    /// Collapses internal whitespace (including newlines) to single spaces so
    /// the fragment stays single-line for log lines and dashboard banners,
    /// then keeps the trailing slice so the final error line survives while
    /// long progress logs cannot flood the dashboard.
    /// - Parameters:
    ///   - text: Raw combined output.
    ///   - limit: Maximum characters to keep.
    /// - Returns: Trimmed single-line tail, or empty when input is blank.
    public static func cappedTail(_ text: String, limit: Int = maxFailureTailChars) -> String {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        let cap = max(1, limit)
        guard collapsed.count > cap else { return collapsed }
        return String(collapsed.suffix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Timeout hint appended when a stage exhausts its budget.
    /// - Parameter timeoutSeconds: Budget that was exceeded.
    /// - Returns: Parenthesized timeout note.
    public static func timeoutNote(timeoutSeconds: Double) -> String {
        "(timed out after \(Int(timeoutSeconds))s)"
    }

    /// Formats one stage failure for the ensure message thread.
    /// Carries stage plus exit plus capped tail plus an optional timeout note,
    /// so the dashboard can show why the cascade stopped without re-running.
    /// Collapses internal whitespace to single spaces so the fragment stays
    /// single-line for log lines and dashboard banners even when process
    /// output carries newlines.
    /// - Parameters:
    ///   - stage: Cascade stage (`runtime`, `daemon`, `start`, `run`, `poll`).
    ///   - exitCode: Process exit status when a process ran.
    ///   - output: Combined output to tail-cap.
    ///   - timedOut: Whether the stage hit its timeout.
    ///   - timeoutSeconds: Budget for the timeout note when timed out.
    /// - Returns: Single-line failure fragment.
    public static func failureMessage(
        stage: String,
        exitCode: Int32?,
        output: String?,
        timedOut: Bool,
        timeoutSeconds: Double? = nil
    ) -> String {
        var parts = ["stage: \(stage)"]
        if let exitCode {
            parts.append("exit: \(exitCode)")
        }
        let tail = cappedTail(output ?? "")
        if !tail.isEmpty {
            parts.append("detail: \(tail)")
        }
        if timedOut, let timeoutSeconds {
            parts.append(timeoutNote(timeoutSeconds: timeoutSeconds))
        } else if timedOut {
            parts.append("(timed out)")
        }
        let joined = parts.joined(separator: ", ")
        return joined.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Extracts the host port from the configured base URL for `-p` mapping.
    /// An explicit port wins; otherwise the scheme default applies
    /// (`https` implies 443, `http` implies 80) so the loopback publish
    /// matches the probe. A bare `http://127.0.0.1` no longer silently maps
    /// to 8888 while the probe dials 80, which never converged; 8888 is the
    /// default configured URL's port, not the fallback for a missing port.
    public static func hostPort(from baseURL: String) -> Int {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return 8888
        }
        if let port = url.port, (1 ... 65535).contains(port) {
            return port
        }
        if url.scheme?.lowercased() == "https" {
            return 443
        }
        return 80
    }

    /// Resolves the bundled SearXNG settings template without relying on the
    /// process working directory, so installed serve/app runs outside the
    /// repo root still mount the template carrying the guaranteed JSON format.
    /// Order: SwiftPM bundle resources, app bundle resources,
    /// executable-adjacent locations, then the repo checkout as a dev fallback
    /// for `swift run` from the source root.
    /// - Returns: Template file URL when found, nil otherwise.
    public static func bundledTemplateURL() -> URL? {
        var candidates: [URL] = []
        #if SWIFT_PACKAGE && !SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE
            if let resourceURL = Bundle.module.resourceURL {
                candidates += [
                    resourceURL.appendingPathComponent("Config/searxng/settings.yml"),
                    resourceURL.appendingPathComponent("searxng/settings.yml"),
                    resourceURL.appendingPathComponent("settings.yml")
                ]
            }
        #endif
        if let resourceURL = Bundle.main.resourceURL {
            candidates += [
                resourceURL.appendingPathComponent("Config/searxng/settings.yml"),
                resourceURL.appendingPathComponent("searxng/settings.yml"),
                resourceURL.appendingPathComponent("settings.yml")
            ]
        }
        // Executable-adjacent layouts cover installed CLIs and app bundles
        // where resources sit beside or above the binary.
        let executableDirs: [URL] = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent()
        ].compactMap(\.self)
        for dir in executableDirs {
            candidates += [
                dir.appendingPathComponent("Config/searxng/settings.yml"),
                dir.appendingPathComponent("Resources/Config/searxng/settings.yml"),
                dir.appendingPathComponent("../Resources/Config/searxng/settings.yml")
            ]
        }
        // Dev fallback: repo-root checkout when running from source.
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Config/searxng/settings.yml")
        )
        for url in candidates where FileManager.default.fileExists(atPath: url.standardized.path) {
            return url
        }
        return nil
    }

    /// Locates the bundled SearXNG settings for the container mount.
    /// Prefers the per-install override, then the bundled template resolved
    /// without the working directory so installed runs mount real settings.
    public static func bundledSettingsPath() -> String? {
        let override = overrideSettingsPath()
        if FileManager.default.fileExists(atPath: override) {
            return override
        }
        return bundledTemplateURL()?.path
    }

    /// Per-install override path carrying the generated Flask secret.
    /// - Returns: `~/.runeweaver/searxng/settings.yml` absolute path.
    public static func overrideSettingsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".runeweaver/searxng/settings.yml")
    }

    /// Current template version stamped into per-install overrides.
    /// Bumped whenever the generated settings document or the container
    /// sizing it boots must roll forward together; an override missing the
    /// marker or carrying an older value is regenerated with a fresh secret
    /// and the container is recreated so the new document actually boots
    /// instead of lingering behind a `start` of the old entry.
    public static let settingsTemplateVersion = 2

    /// YAML comment prefix carrying the template version in overrides.
    /// A comment keeps SearXNG parsing untouched while letting both the
    /// engine and the escape-hatch script detect stale installs with a
    /// plain text search instead of parsing YAML.
    public static let settingsTemplateVersionMarkerPrefix = "# rune-weaver-template-version:"

    /// Full marker line stamped into freshly generated overrides.
    /// - Parameter version: Template version to stamp, defaulting to current.
    /// - Returns: Comment line carrying the version.
    public static func settingsTemplateVersionMarkerLine(version: Int = settingsTemplateVersion) -> String {
        "\(settingsTemplateVersionMarkerPrefix) \(version)"
    }

    /// Whitespace-tolerant marker shape shared with the escape-hatch script.
    /// The shell matches `^[[:space:]]*#[[:space:]]*rune-weaver-template-version:`
    /// so `#rune-…` and `#  rune-…` read as stamped; the engine must accept the
    /// same spellings or a variant file reads stale in one and fresh in the other.
    public static let templateVersionMarkerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[\\s]*#[\\s]*rune-weaver-template-version:",
        options: []
    )

    /// Version digits after the marker, tolerating surrounding whitespace.
    /// Mirrors the shell `sed` extraction so both sides agree on the stamped number.
    public static let templateVersionNumberRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "rune-weaver-template-version:[\\s]*([0-9]+)",
        options: []
    )

    /// Whether a line carries the template-version marker under shell-tolerant spacing.
    /// - Parameter line: Single override line to test.
    /// - Returns: True when the line matches the tolerant marker shape.
    public static func isTemplateVersionMarkerLine(_ line: String) -> Bool {
        guard let regex = templateVersionMarkerRegex else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }

    /// Extracts the stamped template version from override text.
    /// Only the first marker line counts; a malformed value reads as missing
    /// so the caller regenerates instead of trusting a half-written stamp.
    /// Whitespace around `#` and the marker name tolerates the shell spellings
    /// so engine and script never disagree on staleness or duplicate the stamp.
    /// - Parameter contents: Override file text.
    /// - Returns: Stamped version, or nil when absent or unparseable.
    public static func overrideTemplateVersion(in contents: String) -> Int? {
        // Shared fold keeps marker detection identical for CRLF/CR overrides
        // instead of leaving a stray return on the version line.
        for line in NormalizedText.splitLines(contents) {
            guard isTemplateVersionMarkerLine(line) else { continue }
            guard let regex = templateVersionNumberRegex else { return nil }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges > 1,
                  let codeRange = Range(match.range(at: 1), in: line),
                  let parsed = Int(line[codeRange])
            else { return nil }
            return parsed
        }
        return nil
    }

    /// Whether override text predates the current template.
    /// Missing or unparseable markers count as stale so installs from before
    /// stamping still migrate; newer values never migrate so a
    /// forward-compatible install is never downgraded.
    /// - Parameter contents: Override file text.
    /// - Returns: True when the marker is missing or older than current.
    public static func overrideNeedsMigration(contents: String) -> Bool {
        guard let stamped = overrideTemplateVersion(in: contents) else { return true }
        return stamped < settingsTemplateVersion
    }

    /// Whether the on-disk override (if any) is stale.
    /// A missing file reads as fresh here: creation already mints the current
    /// marker, so only an existing file with a missing or older marker forces
    /// the remove-first recreate path. Deletion-based rotation keeps working
    /// because the recreated file carries the current marker. An existing but
    /// unreadable file never reads as fresh: it logs and reports stale so a
    /// permission failure fails closed instead of skipping migration.
    /// - Returns: True when an existing override needs migration.
    public static func isStaleOverridePresent() -> Bool {
        let path = overrideSettingsPath()
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            return overrideNeedsMigration(contents: contents)
        } catch {
            RuneWeaverLog.tools.error(
                "SearXNGEnsurer: failed reading override at \(path): \(error.localizedDescription)"
            )
            return true
        }
    }

    /// Generates a random Flask secret key as lowercase hex.
    /// - Parameter byteCount: Random bytes before hex encoding (clamped 16-64).
    /// - Returns: Hex string twice `byteCount` chars.
    public static func makeSecretKey(byteCount: Int = 32) -> String {
        let count = min(max(byteCount, 16), 64)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0 ..< count {
            bytes.append(UInt8.random(in: 0 ... 255))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Renders a standalone settings document with the given secret.
    /// Inherits upstream defaults via `use_default_settings` so unspecified
    /// options track SearXNG releases; only the local overrides below diverge
    /// and the engine fan-out stays at three general-purpose entries. Mirrors
    /// the bundled `Config/searxng/settings.yml` template and the script
    /// fallback so every producer emits the same schema. The marker line pins
    /// the template version so later ensures can tell a stale override from a
    /// current one without parsing YAML.
    /// - Parameter secretKey: Per-install Flask secret.
    /// - Returns: YAML document mountable at `/etc/searxng/settings.yml`.
    public static func settingsYAML(secretKey: String) -> String {
        """
        # Rune Weaver — Per-install SearXNG settings (generated).
        \(settingsTemplateVersionMarkerLine())
        #
        # Created on first ensure into `~/.runeweaver/searxng/settings.yml`.
        # Holds a random per-install Flask `secret_key`. Delete this file and
        # re-run ensure (or `scripts/searxng-up.sh`) to rotate to a fresh key,
        # then recreate the `runeweaver-searxng` container to pick it up.
        # Inherits upstream defaults; only the overrides below diverge.
        use_default_settings:
          engines:
            keep_only:
              - duckduckgo
              - brave
              - wikipedia
        general:
          instance_name: "Rune Weaver SearXNG"
        server:
          port: 8080
          bind_address: "0.0.0.0"
          secret_key: "\(secretKey)"
          limiter: false
          image_proxy: false
        search:
          formats:
            - html
            - json
        outgoing:
          request_timeout: 10.0
          max_request_timeout: 15.0
          pool_connections: 20
        """
            + "\n"
    }

    /// Replaces the `secret_key` line in a template with a fresh secret.
    /// Preserves any existing template-version marker when current and stamps
    /// the current marker when missing or older, so both the placeholder
    /// rotation and the stale-override migration converge on the same
    /// document without a second write.
    /// - Parameters:
    ///   - template: Bundled `settings.yml` text.
    ///   - secretKey: Per-install Flask secret.
    /// - Returns: Template with the secret line replaced, or fallback rendering.
    public static func renderedSettingsYAML(template: String, secretKey: String) -> String {
        let secretReplacement = "  secret_key: \"\(secretKey)\""
        let markerReplacement = settingsTemplateVersionMarkerLine()
        // Single normalization feeds both the trailing-newline check and the
        // line mapping so secret and marker replacements see the same lines
        // on every platform without folding twice.
        let normalizedTemplate = NormalizedText.normalizedLineEndings(template)
        let hadTrailingNewline = normalizedTemplate.hasSuffix("\n")
        let lines = NormalizedText.splitLines(normalizedTemplate)
        var replacedSecret = false
        var replacedMarker = false
        let mapped = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("secret_key:") {
                replacedSecret = true
                return secretReplacement
            }
            // Tolerant marker match mirrors the shell so `#rune-…` and
            // `#  rune-…` variants replace in place instead of duplicating.
            if isTemplateVersionMarkerLine(line) {
                replacedMarker = true
                return markerReplacement
            }
            return line
        }
        var stamped = mapped
        if !replacedMarker {
            // Keep the stamp near the top so it stays visible without
            // disturbing the YAML body: after the first header line when the
            // template opens with one, otherwise at the very top.
            if stamped.isEmpty {
                stamped = [markerReplacement]
            } else {
                stamped.insert(markerReplacement, at: min(1, stamped.count))
            }
        }
        if replacedSecret {
            var rendered = stamped.joined(separator: "\n")
            // The shared split treats a trailing newline as a terminator, so
            // restore it to keep template round-trips byte-identical otherwise.
            if hadTrailingNewline, !rendered.hasSuffix("\n") {
                rendered += "\n"
            }
            return rendered
        }
        return settingsYAML(secretKey: secretKey)
    }

    /// Writes secret bytes through an owner-only temp before the move.
    /// A direct atomic write inherits the process umask (022 → 0644), leaving
    /// the key briefly world-readable before the trailing chmod; staging
    /// through a 0600 temp keeps the secret owner-only at every instant, then
    /// the replace-or-move commits it without a readable window.
    /// - Parameters:
    ///   - data: Encoded settings document to persist.
    ///   - path: Destination override path.
    public static func writeSecretFileAtomically(data: Data, toPath path: String) throws {
        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        let tmpName = ".searxng-settings.\(UUID().uuidString).tmp"
        let tmpPath = (directory as NSString).appendingPathComponent(tmpName)
        let tmpURL = URL(fileURLWithPath: tmpPath)
        let destinationURL = URL(fileURLWithPath: path)
        guard fileManager.createFile(atPath: tmpPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(
                domain: "RuneWeaverSearXNG",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not stage secret temp file"]
            )
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath)
            if fileManager.fileExists(atPath: path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tmpURL)
            } else {
                try fileManager.moveItem(at: tmpURL, to: destinationURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            throw error
        }
    }

    /// Ensures the per-install override exists with a random secret.
    /// Enforces `0700` on the containing directory and `0600` on the file on
    /// every path (not just creation) so pre-existing installs keep the
    /// per-install secret invariant. An existing file missing the current
    /// template marker (or carrying an older one) is rebuilt from the current
    /// template with a fresh secret so the next fresh run boots the new
    /// document plus current sizing; the placeholder rotation below stays for
    /// files already on the current marker. Permission failures fail closed
    /// with nil instead of reporting success while the secret stays
    /// world-readable. Deleting the override still rotates: recreation mints
    /// a fresh secret carrying the current marker.
    /// - Returns: Override path when present or created, nil otherwise.
    @discardableResult
    public static func ensureOverrideSettingsFile() -> String? {
        let fileManager = FileManager.default
        let overridePath = overrideSettingsPath()
        let directory = (overridePath as NSString).deletingLastPathComponent
        if fileManager.fileExists(atPath: overridePath) {
            // Harden pre-existing installs: the secret invariant holds for
            // old files too, not just freshly minted ones.
            do {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overridePath)
            } catch {
                RuneWeaverLog.tools.error(
                    "SearXNGEnsurer: failed enforcing secret permissions at \(overridePath): \(error.localizedDescription)"
                )
                return nil
            }
            let existing: String?
            do {
                existing = try String(contentsOfFile: overridePath, encoding: .utf8)
            } catch {
                RuneWeaverLog.tools.warning("SearXNGEnsurer: failed to read override file at \(overridePath): \(error.localizedDescription)")
                existing = nil
            }
            if let existing {
                // Stale installs predate the marker entirely, so rebuild from
                // the current template (not a secret swap in the stale
                // document) with a fresh secret at 0600. The caller recreates
                // the container afterwards so the new settings actually boot.
                if overrideNeedsMigration(contents: existing) {
                    let fresh = makeSecretKey()
                    let template: String?
                    if let bundledURL = bundledTemplateURL() {
                        do {
                            template = try String(contentsOf: bundledURL, encoding: .utf8)
                        } catch {
                            RuneWeaverLog.tools.warning("SearXNGEnsurer: failed reading bundled template at \(bundledURL.path): \(error.localizedDescription)")
                            template = nil
                        }
                    } else {
                        template = nil
                    }
                    let regenerated: String = if let template {
                        renderedSettingsYAML(template: template, secretKey: fresh)
                    } else {
                        settingsYAML(secretKey: fresh)
                    }
                    if let data = regenerated.data(using: .utf8) {
                        do {
                            try writeSecretFileAtomically(data: data, toPath: overridePath)
                        } catch {
                            RuneWeaverLog.tools.error(
                                "SearXNGEnsurer: failed migrating stale override at \(overridePath): \(error.localizedDescription)"
                            )
                            return nil
                        }
                    }
                    return overridePath
                }
                // Rotate installs still carrying the old committed secret or the
                // shipped placeholder to a fresh random key (best-effort). The
                // render also stamps the current marker, so rotated files never
                // read as stale on the next ensure.
                if existing.contains("rune-weaver-local-search") || existing.contains("change-me-generate-per-install-secret") {
                    let fresh = makeSecretKey()
                    let rotated = renderedSettingsYAML(template: existing, secretKey: fresh)
                    if let data = rotated.data(using: .utf8) {
                        do {
                            try writeSecretFileAtomically(data: data, toPath: overridePath)
                        } catch {
                            RuneWeaverLog.tools.error(
                                "SearXNGEnsurer: failed rotating secret at \(overridePath): \(error.localizedDescription)"
                            )
                            return nil
                        }
                    }
                }
            }
            return overridePath
        }
        let secret = makeSecretKey()
        let template: String?
        if let bundledURL = bundledTemplateURL() {
            do {
                template = try String(contentsOf: bundledURL, encoding: .utf8)
            } catch {
                RuneWeaverLog.tools.warning("SearXNGEnsurer: failed reading bundled template at \(bundledURL.path): \(error.localizedDescription)")
                template = nil
            }
        } else {
            template = nil
        }
        let content: String = if let template {
            renderedSettingsYAML(template: template, secretKey: secret)
        } else {
            settingsYAML(secretKey: secret)
        }
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: directory),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let data = content.data(using: .utf8) else { return nil }
            try writeSecretFileAtomically(data: data, toPath: overridePath)
            return overridePath
        } catch {
            RuneWeaverLog.tools.error(
                "SearXNGEnsurer: failed creating secret at \(overridePath): \(error.localizedDescription)"
            )
            return nil
        }
    }
}

/// Rune Weaver Tools — SearXNG cascade outcomes plus daemon healing.
///
/// Holds the cascade outcome structs and the daemon probe plus start helpers
/// so the main `SearXNGEnsurer` actor body stays within the type-length
/// budget. Behavior is unchanged; the lifecycle entry points keep calling
/// these helpers through the same `SearXNGEnsurer` namespace.
extension SearXNGEnsurer {
    /// Outcome of healing the container system daemon.
    /// Keeps the started flag beside the failure fragment so the cascade can
    /// record which heal actually moved the daemon without extra plumbing.
    public struct DaemonOutcome: Sendable {
        public let daemonStarted: Bool
        public let failure: String?
        public init(daemonStarted: Bool, failure: String? = nil) {
            self.daemonStarted = daemonStarted
            self.failure = failure
        }
    }

    /// Outcome of the container start-or-run step.
    /// Mirrors the daemon outcome shape so the cascade merges both heals into
    /// one started flag plus the last failure detail.
    public struct ContainerOutcome: Sendable {
        public let didStart: Bool
        public let failure: String?
        public init(didStart: Bool, failure: String? = nil) {
            self.didStart = didStart
            self.failure = failure
        }
    }

    /// Non-throwing ensure outcome for HTTP lifecycle routes.
    /// `message` carries the trimmed banner (terminal cause plus one
    /// `scripts/searxng-up.sh` remediation) for inline error slots, while
    /// `diagnostics` carries the full per-stage detail (stage, exit, capped
    /// tail, timeout) for server warn logs plus the collapsed Settings
    /// diagnostics element. Both normalize blanks to nil so callers never
    /// render whitespace as detail.
    public struct EnsureReport: Sendable {
        public let reachable: Bool
        public let started: Bool
        public let message: String?
        public let diagnostics: String?
        public init(reachable: Bool, started: Bool, message: String? = nil, diagnostics: String? = nil) {
            self.reachable = reachable
            self.started = started
            let trimmedMessage = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.message = trimmedMessage.isEmpty ? nil : trimmedMessage
            let trimmedDiagnostics = (diagnostics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.diagnostics = trimmedDiagnostics.isEmpty ? nil : trimmedDiagnostics
        }
    }

    /// User-info key carrying the full per-stage detail alongside the trimmed banner.
    /// The banner (`NSLocalizedDescriptionKey`) stays to terminal cause plus one
    /// remediation so it renders once; this key holds the chained stage fragments
    /// for warn logs plus collapsed diagnostics without nesting a second guidance
    /// message inside the banner.
    public static let diagnosticsUserInfoKey = "RuneWeaverSearXNGDiagnostics"

    /// Extracts the per-stage diagnostics chained for an ensure failure.
    /// - Parameter error: Failure from `unreachableError`.
    /// - Returns: Full cascade detail when present, nil for install-only or cancelled paths.
    public static func diagnostics(from error: Error) -> String? {
        let raw = (error as NSError).userInfo[diagnosticsUserInfoKey] as? String
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed banner for a daemon heal that stayed down.
    /// Single cause plus one hatch command; raw stage tail lives in diagnostics only.
    public static func daemonBanner() -> String {
        "Container system service failed to start. Run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for a container run heal that failed.
    /// Covers fresh-run failures (exit plus capped tail stays in diagnostics
    /// plus warn logs) so the banner renders once without leaking raw
    /// registry or runtime output.
    public static func runBanner() -> String {
        "SearXNG container failed to start (run failed). Run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for an image pull that exhausted its minutes budget.
    /// A timed-out pull is safe to retry because downloaded layers stay
    /// cached, so the next attempt resumes instead of restarting.
    /// - Parameter timeoutSeconds: Pull budget that was exceeded.
    /// - Returns: Retry-with-cached-layers cause plus the single hatch command.
    public static func pullTimeoutBanner(timeoutSeconds: Double = containerImagePullTimeoutSeconds) -> String {
        "SearXNG image pull timed out after \(Int(timeoutSeconds))s. Retry — downloaded layers are cached. Run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for an image pull that failed without timing out.
    /// Points at Hub reachability (auth, network, or registry outage) rather
    /// than the run step, so a registry miss never renders as a run failure.
    /// - Returns: Hub-reachability cause plus the single hatch command.
    public static func pullFailedBanner() -> String {
        "SearXNG image pull failed. Check Docker Hub reachability, then run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for a poll timeout with no heal failure to name.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Not-reachable cause plus the single hatch command.
    public static func timeoutBanner(baseURL: String) -> String {
        "SearXNG is not reachable at \(baseURL). Start it with `scripts/searxng-up.sh`, then retry."
    }

    /// Trimmed banner for a container that crashed while the watch waited.
    /// Names the crash plus captured logs instead of a timeout note, so the
    /// headline points at the exit rather than the elapsed backstop. Raw exit
    /// plus logs tail stays in diagnostics plus warn logs.
    /// - Returns: Crash cause plus the single hatch command.
    public static func readinessCrashBanner() -> String {
        "SearXNG container crashed during startup (exit with logs captured). Run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for a container that vanished mid-wait.
    /// A missing entry after a successful start means another actor removed it
    /// or the create never committed, so the headline names the disappearance
    /// instead of a timeout note. The last probe plus logs tail stays in diagnostics.
    /// - Returns: Missing cause plus the single hatch command.
    public static func readinessMissingBanner() -> String {
        "SearXNG container went missing during startup. Run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for a watch backstop with no terminal crash to name.
    /// Carries the waiting stage plus the last observed state instead of a bare
    /// timeout note, so the headline still names what the watch last saw. Full
    /// last state plus logs tail stays in diagnostics plus warn logs.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Waiting cause with last-state hint plus the single hatch command.
    public static func readinessBackstopBanner(baseURL: String) -> String {
        "SearXNG did not become reachable at \(baseURL) while waiting (last state captured with logs). Run `scripts/searxng-up.sh` to retry."
    }

    /// Trimmed banner for a watch that kept answering HTTP 5xx while waiting.
    /// Names sickness (the engine answers but never gets healthy) instead of a
    /// crash (the container exited or vanished) or a stuck wait (nothing ever
    /// answered), so each cause renders once. The capped body tail stays in
    /// diagnostics plus warn logs, never in the banner, mirroring the crash path.
    /// - Parameter statusCode: Failing HTTP status when known, nil for a generic 5xx line.
    /// - Returns: Sick cause plus the single hatch command.
    public static func readinessServerErrorBanner(statusCode: Int? = nil) -> String {
        if let statusCode, (500 ..< 600).contains(statusCode) {
            return "SearXNG is responding with repeated server errors (HTTP \(statusCode) with body captured). Run `scripts/searxng-up.sh` to retry."
        }
        return "SearXNG is responding with repeated server errors (HTTP 5xx with body captured). Run `scripts/searxng-up.sh` to retry."
    }

    /// Whether an HTTP status proves the engine answered healthy.
    /// Mirrors the reachability probe range so the counting loop and the boolean
    /// probe agree on what counts as success; 4xx stays non-success because the
    /// engine answered but not with a usable page.
    /// - Parameter statusCode: Observed HTTP status.
    /// - Returns: True for 2xx/3xx.
    public static func isReadinessSuccessStatusCode(_ statusCode: Int) -> Bool {
        (200 ..< 400).contains(statusCode)
    }

    /// Whether an HTTP status is a countable server-error candidate.
    /// Only 5xx can prove sickness; 4xx, redirects handled elsewhere, and
    /// connection gaps keep waiting instead of extending the streak.
    /// - Parameter statusCode: Observed HTTP status.
    /// - Returns: True for 5xx.
    public static func isReadinessServerErrorStatusCode(_ statusCode: Int) -> Bool {
        (500 ..< 600).contains(statusCode)
    }

    /// Whether a 5xx body carries enough signal to count toward sickness.
    /// Empty or whitespace-only bodies keep waiting: a bare 500 without a
    /// readable tail is indistinguishable from a load transient, so it must not
    /// trip the fail-fast on its own.
    /// - Parameter bodyTail: Capped, decoded body tail for the probe.
    /// - Returns: True when the tail holds non-blank text.
    public static func isCountableServerErrorBody(_ bodyTail: String) -> Bool {
        !bodyTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Decodes one HTTP body into a countable tail, if it carries signal.
    /// Non-UTF8 bytes read as unparseable and keep waiting rather than posing
    /// as sickness; blank text after trimming does the same. The surviving tail
    /// is capped so the headline cause stays readable in diagnostics.
    /// - Parameter data: Raw HTTP body bytes from the probe.
    /// - Returns: Capped single-line tail, or nil when empty or unparseable.
    public static func countableServerErrorBodyTail(from data: Data) -> String? {
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        let tail = cappedTail(decoded)
        return isCountableServerErrorBody(tail) ? tail : nil
    }

    /// Whether one probe response extends the consecutive 5xx streak.
    /// Requires both the 5xx status and a readable tail so empty or unparseable
    /// 500s keep waiting instead of tripping the threshold on noise.
    /// - Parameters:
    ///   - statusCode: Observed HTTP status, nil when no response arrived.
    ///   - bodyTail: Capped, decoded body tail, possibly empty.
    /// - Returns: True only for a countable 5xx.
    public static func shouldCountServerError(statusCode: Int?, bodyTail: String) -> Bool {
        guard let statusCode, isReadinessServerErrorStatusCode(statusCode) else { return false }
        return isCountableServerErrorBody(bodyTail)
    }

    /// Advances the consecutive 5xx streak for one probe response.
    /// Success proves health and clears the streak; a countable 5xx extends it;
    /// a definitive non-5xx answer (such as 4xx) breaks consecutiveness and
    /// clears it, so an interleaved 404 never counts toward the trip. Connection
    /// gaps (nil status) and 5xx without a readable body preserve the streak and
    /// keep waiting: they prove neither health nor sickness, so the watch holds
    /// its prior count until the backstop instead of tripping on noise.
    /// - Parameters:
    ///   - current: Streak entering this probe.
    ///   - statusCode: Observed HTTP status, nil when no response arrived.
    ///   - bodyTail: Capped, decoded body tail, possibly empty.
    /// - Returns: Streak leaving this probe.
    public static func nextConsecutiveServerErrorCount(current: Int, statusCode: Int?, bodyTail: String) -> Int {
        if let statusCode, isReadinessSuccessStatusCode(statusCode) {
            return 0
        }
        if shouldCountServerError(statusCode: statusCode, bodyTail: bodyTail) {
            return max(0, current) + 1
        }
        if let statusCode {
            // A 5xx without a readable body is a gap, not proof of recovery:
            // preserve the streak and keep waiting for a countable answer.
            if isReadinessServerErrorStatusCode(statusCode) {
                return max(0, current)
            }
            // Any other answered status definitively breaks the run of 5xx.
            return 0
        }
        return max(0, current)
    }

    /// Whether the consecutive streak trips the sick fail-fast.
    /// Kept beside the counter so the tick and the unit tests share one gate
    /// instead of duplicating the threshold comparison.
    /// - Parameter count: Consecutive countable 5xx responses so far.
    /// - Returns: True once the streak reaches the threshold.
    public static func shouldFailFastOnConsecutiveServerErrors(_ count: Int) -> Bool {
        count >= SearXNGEnsurer.consecutiveServerErrorThreshold
    }

    /// One HTTP probe snapshot for the readiness watch.
    /// Carries the status plus the capped body tail so the tick can tell healthy
    /// (2xx/3xx, resets), sick (countable 5xx, advances), broken (definitive
    /// non-5xx such as 4xx, resets), and patience (gaps or empty 5xx, preserves)
    /// apart without a second fetch per tick.
    public struct HTTPProbeSnapshot: Sendable, Equatable {
        /// Observed HTTP status, nil when no response arrived or parsing failed.
        public let statusCode: Int?
        /// Capped single-line body tail, empty when none arrived or it was blank.
        public let bodyTail: String

        /// Creates a snapshot.
        public init(statusCode: Int?, bodyTail: String = "") {
            self.statusCode = statusCode
            self.bodyTail = bodyTail
        }

        /// No-response snapshot for connection gaps and unparseable replies.
        /// Keeps waiting with the streak preserved until the backstop.
        static var noResponse: Self {
            Self(statusCode: nil, bodyTail: "")
        }

        /// Whether this probe proves the engine answered healthy.
        /// Mirrors the boolean reachability range so both probes agree.
        public var isSuccess: Bool {
            guard let statusCode else { return false }
            return SearXNGEnsurer.isReadinessSuccessStatusCode(statusCode)
        }

        /// Whether this probe extends the consecutive 5xx streak.
        /// Requires both the 5xx status and a readable tail.
        public var isCountableServerError: Bool {
            SearXNGEnsurer.shouldCountServerError(statusCode: statusCode, bodyTail: bodyTail)
        }
    }

    /// State text naming the sick HTTP status inside waiting detail.
    /// Kept as `http <code>` so the banner router can tell sickness from crash
    /// (`exited`/`error`) and disappearance (`missing`) while the body tail after
    /// `logs:` never leaks crash words into the hint.
    /// - Parameter statusCode: Failing HTTP status.
    /// - Returns: Hint such as `http 500`.
    public static func readinessServerErrorStateText(statusCode: Int) -> String {
        "http \(statusCode)"
    }

    /// Builds one sick failure fragment carrying the capped body tail.
    /// Uses the shared waiting shape without a timeout note so the backstop
    /// (which always carries one) keeps rendering as stuck while sickness renders
    /// as sick; the hint stays before `logs:` so body prose never poses as state.
    /// - Parameters:
    ///   - statusCode: Failing HTTP status at the threshold trip.
    ///   - bodyTail: Capped body tail to headline, re-capped for safety.
    /// - Returns: Single-line waiting fragment for the diagnostics chain.
    public static func readinessServerErrorDetail(statusCode: Int, bodyTail: String) -> String {
        let tail = cappedTail(bodyTail)
        let combined = if tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "container \(readinessServerErrorStateText(statusCode: statusCode))"
        } else {
            "container \(readinessServerErrorStateText(statusCode: statusCode)) logs: \(tail)"
        }
        return failureMessage(
            stage: EnsureStage.waiting.rawValue,
            exitCode: nil,
            output: combined,
            timedOut: false
        )
    }

    /// Extracts the sick HTTP status from chained waiting detail, if present.
    /// Reads only the state hint before `logs:` so body prose containing error or
    /// missing never poses as sickness the way the crash router already avoids.
    /// - Parameter detail: Chained per-stage fragments from the cascade.
    /// - Returns: First `http 5xx` status found in a waiting hint, nil otherwise.
    public static func serverErrorStatusCode(in detail: String) -> Int? {
        let hint = waitingStateHint(in: detail)
        let pattern = #"\bhttp\s+(5\d\d)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(hint.startIndex..., in: hint)
        guard let match = regex.firstMatch(in: hint, options: [], range: range),
              match.numberOfRanges > 1,
              let codeRange = Range(match.range(at: 1), in: hint),
              let code = Int(hint[codeRange])
        else { return nil }
        return code
    }

    /// Raw daemon probe outcome.
    /// Small struct replacing the 4-tuple so the large-tuple gate stays
    /// green while the cascade keeps the same down plus exit plus output
    /// plus timeout shape.
    public struct DaemonProbeOutcome: Sendable {
        public let isDown: Bool
        public let exitCode: Int32?
        public let output: String
        public let timedOut: Bool
        public init(isDown: Bool, exitCode: Int32?, output: String, timedOut: Bool) {
            self.isDown = isDown
            self.exitCode = exitCode
            self.output = output
            self.timedOut = timedOut
        }

        /// Whether the probe failed without down-state wording.
        /// Distinct from healthy (exit 0, answered) and down (wording
        /// matched): preserves exit plus output so callers surface it without
        /// paying a `system start` heal for a bad binary or permissions error.
        public var isProbeFailure: Bool {
            if isDown {
                return false
            }
            if timedOut {
                return true
            }
            if let exitCode {
                return exitCode != 0
            }
            return !output.isEmpty
        }
    }

    /// Raw system-start outcome.
    /// Small struct replacing the 4-tuple so the large-tuple gate stays
    /// green while the cascade keeps the same started plus exit plus
    /// output plus timeout shape.
    public struct SystemStartOutcome: Sendable {
        public let started: Bool
        public let exitCode: Int32?
        public let output: String
        public let timedOut: Bool
        public init(started: Bool, exitCode: Int32?, output: String, timedOut: Bool) {
            self.started = started
            self.exitCode = exitCode
            self.output = output
            self.timedOut = timedOut
        }
    }

    /// Probes the container system daemon with a fast side-effect-free call.
    /// Only down-state wording counts as down; a nonzero exit without that
    /// wording is a distinct probe failure preserving exit plus output, so
    /// callers surface it instead of paying a `system start` heal for a bad
    /// binary or permissions error.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: Whether the daemon looks down plus raw exit, output, and timeout flag.
    public static func daemonProbeResult(runtime: URL) async -> DaemonProbeOutcome {
        if Task.isCancelled {
            return DaemonProbeOutcome(isDown: false, exitCode: nil, output: "", timedOut: false)
        }
        do {
            let (code, output) = try await runProcess(
                executableURL: runtime,
                arguments: daemonProbeArguments(),
                timeoutSeconds: daemonProbeTimeoutSeconds
            )
            if Task.isCancelled {
                return DaemonProbeOutcome(isDown: false, exitCode: code, output: output, timedOut: false)
            }
            // Only the wording counts as down. Any other exit returns
            // isDown:false with exit plus output preserved, so the caller can
            // tell healthy (exit 0) from probe failure (nonzero) via
            // `isProbeFailure` instead of healing blindly.
            let down = isDaemonDown(output: output)
            return DaemonProbeOutcome(isDown: down, exitCode: code, output: output, timedOut: false)
        } catch is CancellationError {
            return DaemonProbeOutcome(isDown: false, exitCode: nil, output: "", timedOut: false)
        } catch let error as BoundedProcessError {
            if case .timedOut = error {
                return DaemonProbeOutcome(
                    isDown: isDaemonDown(output: error.localizedDescription),
                    exitCode: nil,
                    output: error.localizedDescription,
                    timedOut: true
                )
            }
            return DaemonProbeOutcome(
                isDown: isDaemonDown(output: error.localizedDescription),
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        } catch {
            return DaemonProbeOutcome(
                isDown: isDaemonDown(output: error.localizedDescription),
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        }
    }

    /// Starts the container system service when the probe says it is down.
    /// Bounded so a hung launchd registration cannot burn the whole ensure
    /// budget; the caller re-probes afterwards to confirm the heal.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: Whether the start exited 0 plus raw exit, output, and timeout flag.
    public static func systemStartResult(runtime: URL) async -> SystemStartOutcome {
        if Task.isCancelled {
            return SystemStartOutcome(started: false, exitCode: nil, output: "", timedOut: false)
        }
        do {
            let (code, output) = try await runProcess(
                executableURL: runtime,
                arguments: containerSystemStartArguments(),
                timeoutSeconds: containerSystemStartTimeoutSeconds
            )
            if Task.isCancelled {
                return SystemStartOutcome(started: false, exitCode: code, output: output, timedOut: false)
            }
            return SystemStartOutcome(started: code == 0, exitCode: code, output: output, timedOut: false)
        } catch is CancellationError {
            return SystemStartOutcome(started: false, exitCode: nil, output: "", timedOut: false)
        } catch let error as BoundedProcessError {
            if case .timedOut = error {
                return SystemStartOutcome(
                    started: false,
                    exitCode: nil,
                    output: error.localizedDescription,
                    timedOut: true
                )
            }
            return SystemStartOutcome(
                started: false,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        } catch {
            return SystemStartOutcome(
                started: false,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        }
    }

    /// Ensures the container system daemon answers, healing it when down.
    /// Probes fast, best-effort starts the system on down-state text, then
    /// re-probes so a transient start still counts as healed. A probe failure
    /// without the wording surfaces immediately without paying the start, and
    /// a start that leaves the socket down never claims started. Records the
    /// daemon failure detail (stage, exit, capped tail, timeout) for the
    /// ensure message thread.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: Whether this call started the daemon plus failure detail when still down.
    public static func ensureDaemonStarted(runtime: URL) async -> DaemonOutcome {
        if Task.isCancelled {
            return DaemonOutcome(daemonStarted: false, failure: nil)
        }
        let probe = await daemonProbeResult(runtime: runtime)
        if Task.isCancelled {
            return DaemonOutcome(daemonStarted: false, failure: nil)
        }
        if !probe.isDown {
            // Unknown probe failure (nonzero exit or timeout without the
            // wording) surfaces here so a bad binary or permissions error
            // never pays a `system start` plus re-probe before surfacing.
            if probe.isProbeFailure {
                let failure = failureMessage(
                    stage: EnsureStage.daemon.rawValue,
                    exitCode: probe.exitCode,
                    output: probe.output,
                    timedOut: probe.timedOut,
                    timeoutSeconds: probe.timedOut ? daemonProbeTimeoutSeconds : nil
                )
                return DaemonOutcome(daemonStarted: false, failure: failure)
            }
            return DaemonOutcome(daemonStarted: false, failure: nil)
        }
        let start = await systemStartResult(runtime: runtime)
        if Task.isCancelled {
            return DaemonOutcome(daemonStarted: false, failure: nil)
        }
        // Recheck after the heal: a start that exited 0 but left the socket
        // down still counts as unhealed, so the cascade keeps the failure.
        let recheck = await daemonProbeResult(runtime: runtime)
        if Task.isCancelled {
            return DaemonOutcome(daemonStarted: false, failure: nil)
        }
        if !recheck.isDown {
            // A recheck that fails without the wording proves nothing about
            // the heal, so it must not claim the start either.
            if recheck.isProbeFailure {
                let detailOutput = recheck.output.isEmpty ? start.output : recheck.output
                let timedOut = start.timedOut || recheck.timedOut
                let timeoutSeconds: Double? = if start.timedOut {
                    containerSystemStartTimeoutSeconds
                } else if recheck.timedOut {
                    daemonProbeTimeoutSeconds
                } else {
                    nil
                }
                let failure = failureMessage(
                    stage: EnsureStage.daemon.rawValue,
                    exitCode: recheck.exitCode ?? start.exitCode,
                    output: detailOutput,
                    timedOut: timedOut,
                    timeoutSeconds: timeoutSeconds
                )
                return DaemonOutcome(daemonStarted: false, failure: failure)
            }
            return DaemonOutcome(daemonStarted: start.started, failure: nil)
        }
        // Prefer the recheck output (closest to the final state), falling back
        // to the start output when the recheck carried no text.
        let detailOutput = recheck.output.isEmpty ? start.output : recheck.output
        let timedOut = start.timedOut || recheck.timedOut
        let timeoutSeconds: Double? = timedOut ? containerSystemStartTimeoutSeconds : nil
        let failure = failureMessage(
            stage: EnsureStage.daemon.rawValue,
            exitCode: recheck.exitCode ?? start.exitCode,
            output: detailOutput,
            timedOut: timedOut,
            timeoutSeconds: timeoutSeconds
        )
        // Never claim started while the socket stays down: a `system start`
        // exiting 0 without the daemon answering leaves the engine dark.
        return DaemonOutcome(daemonStarted: false, failure: failure)
    }
}

/// Rune Weaver Tools — SearXNG decoded-inspect classification.
///
/// Holds the pure JSON inspection helpers for the readiness watch: strict
/// pure-JSON decoding, case-insensitive key lookup, exact-key error detection,
/// state-candidate collection, flag interpretation, and exact-state
/// classification. Pure and synchronous so the ticking watch and unit tests
/// share one gate; terminal states fail fast with the logs tail while
/// unparseable shapes stay unknown until the 165s backstop.
extension SearXNGEnsurer {
    /// Decodes an inspect dump only when it is pure JSON.
    /// Mixed prose plus JSON stays unparseable so the caller keeps waiting
    /// instead of trusting a fragment that never proved container state.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: Decoded array or object, nil when the dump is not pure JSON.
    public static func decodedInspectJSON(from output: String) -> Any? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    /// Case-insensitive lookup inside one decoded object.
    /// Container runtimes vary the casing of state keys, so `Error` and
    /// `error` must read identically without duplicating every branch.
    /// - Parameters:
    ///   - key: Logical key such as status or error.
    ///   - dict: Decoded object to search.
    /// - Returns: Value under the logical key, nil when absent.
    public static func inspectValue(forKey key: String, in dict: [String: Any]) -> Any? {
        let wanted = key.lowercased()
        for (candidate, value) in dict where candidate.lowercased() == wanted {
            return value
        }
        return nil
    }

    /// Whether a decoded `Error` value names a real failure.
    /// Only a non-blank string counts; null, missing, blank, and the literal
    /// `"null"` read as healthy so an empty error key never fails the watch.
    /// - Parameter value: Decoded value under an error key.
    /// - Returns: True when the value proves a failure.
    public static func isNonEmptyInspectErrorValue(_ value: Any) -> Bool {
        if value is NSNull {
            return false
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return trimmed.lowercased() != "null"
        }
        return false
    }

    /// Whether decoded JSON carries a non-empty `Error` under any object.
    /// Exact-key matching keeps `ErrorLogPath`, `LogPath` values, and
    /// `errorMessage` from posing as failures the way substring search did.
    /// - Parameter value: Decoded inspect array or object.
    /// - Returns: True when an exact error key holds a failure.
    public static func nonEmptyErrorInDecodedJSON(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, entry) in dict {
                if key.lowercased() == "error", isNonEmptyInspectErrorValue(entry) {
                    return true
                }
            }
            for (_, entry) in dict where nonEmptyErrorInDecodedJSON(entry) {
                return true
            }
            return false
        }
        if let array = value as? [Any] {
            for entry in array where nonEmptyErrorInDecodedJSON(entry) {
                return true
            }
            return false
        }
        return false
    }

    /// Collects decoded objects that look like container state.
    /// A state candidate carries at least one lifecycle key, so image names,
    /// mounts, and log paths never enter the terminal decision on their own.
    /// - Parameters:
    ///   - value: Decoded inspect array or object.
    ///   - candidates: Accumulated state-like objects.
    public static func collectInspectStateCandidates(from value: Any, into candidates: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            var normalized = Set<String>()
            for key in dict.keys {
                let flat = key.lowercased()
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: " ", with: "")
                normalized.insert(flat)
            }
            if normalized.contains("status") || normalized.contains("running") || normalized.contains("dead")
                || normalized.contains("oomkilled") || normalized.contains("error") || normalized.contains("exitcode")
                || normalized.contains("paused") || normalized.contains("restarting")
            {
                candidates.append(dict)
            }
            for (_, entry) in dict {
                collectInspectStateCandidates(from: entry, into: &candidates)
            }
            return
        }
        if let array = value as? [Any] {
            for entry in array {
                collectInspectStateCandidates(from: entry, into: &candidates)
            }
        }
    }

    /// Whether a decoded flag reads as set.
    /// Covers JSON booleans plus forgiving string and numeric shapes so runtime
    /// casing or encoding drift still waits unless the flag is unambiguously set.
    /// - Parameter value: Decoded value under a boolean lifecycle key.
    /// - Returns: True only when the flag is unambiguously set.
    public static func isSetInspectFlag(_ value: Any) -> Bool {
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered == "true" || lowered == "1" || lowered == "yes"
        }
        return false
    }

    /// Classifies decoded JSON from exact state fields only.
    /// Terminal checks precede liveness so a contradictory dump still fails
    /// fast, while an unrecognized status degrades to unknown instead of
    /// guessing from unrelated fields such as image names or deadlines.
    /// - Parameter value: Decoded inspect array or object.
    /// - Returns: Classified state, nil when no legible state exists.
    public static func stateClassificationFromDecodedJSON(_ value: Any) -> ContainerReadinessState? {
        var candidates: [[String: Any]] = []
        collectInspectStateCandidates(from: value, into: &candidates)
        guard !candidates.isEmpty else { return nil }
        var sawRunning = false
        var sawWaiting = false
        for candidate in candidates {
            if let statusValue = inspectValue(forKey: "status", in: candidate) as? String {
                let status = statusValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch status {
                case "exited":
                    return .exited
                case "dead", "failed":
                    return .errored
                case "running", "up":
                    sawRunning = true
                case "created", "starting", "restarting", "paused", "removing", "waiting":
                    sawWaiting = true
                default:
                    break
                }
            }
            if let deadValue = inspectValue(forKey: "dead", in: candidate), isSetInspectFlag(deadValue) {
                return .errored
            }
            var oomValue: Any?
            for (key, entry) in candidate {
                let flat = key.lowercased()
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: " ", with: "")
                if flat == "oomkilled" {
                    oomValue = entry
                    break
                }
            }
            if let oomValue, isSetInspectFlag(oomValue) {
                return .errored
            }
            if let errorValue = inspectValue(forKey: "error", in: candidate),
               isNonEmptyInspectErrorValue(errorValue)
            {
                return .errored
            }
            if let runningValue = inspectValue(forKey: "running", in: candidate),
               isSetInspectFlag(runningValue)
            {
                sawRunning = true
            } else if let pausedValue = inspectValue(forKey: "paused", in: candidate),
                      isSetInspectFlag(pausedValue)
            {
                sawWaiting = true
            } else if let restartingValue = inspectValue(forKey: "restarting", in: candidate),
                      isSetInspectFlag(restartingValue)
            {
                sawWaiting = true
            }
        }
        if sawRunning {
            return .running
        }
        if sawWaiting {
            return .waiting
        }
        return nil
    }
}
