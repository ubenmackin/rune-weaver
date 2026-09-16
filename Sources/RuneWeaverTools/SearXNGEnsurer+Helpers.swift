// Rune Weaver Tools — SearXNGEnsurer configuration helpers.
//
// Holds the pure configuration surface for the local SearXNG lifecycle:
// loopback management checks, Apple Container runtime resolution, daemon
// probe plus system-start recovery, failure-detail formatting, host-port
// mapping, bundled template lookup, and the per-install settings document
// carrying a random Flask secret. This keeps the `SearXNGEnsurer` actor body
// within the type-length budget while the lifecycle entry points in
// `WebSearchTool.swift` retain single-flight ensure, honest start reporting,
// cooperative cancellation, loopback-only publishing, fail-closed settings,
// secret file permissions, port parity between probe and publish, and the
// Bundle plus executable-adjacent plus repo-checkout fallback chain.

import Foundation
import RuneWeaverCore

public extension SearXNGEnsurer {
    /// Whether a base URL is locally managed (loopback) rather than external.
    /// Only loopback bases can be healed by starting the local container; an
    /// external SearXNG needs no local start, so callers report started:false
    /// instead of claiming an irrelevant container launch. Unspecified
    /// addresses (`0.0.0.0`, `::`) are never managed: a container published
    /// there would never converge the loopback probe, so only `127/8`,
    /// `::1`, and `localhost` qualify.
    static func isManagedBaseURL(_ baseURL: String) -> Bool {
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

    /// Resolves the Apple Container runtime with no Docker fallback.
    /// Docker is intentionally unsupported: the soul reuses the Tier-3
    /// dependency instead of adding a second container runtime, so hosts
    /// without `container` fail closed with the escape-hatch guidance.
    /// - Returns: Executable URL, or nil when the Apple Container CLI is missing.
    static func resolveRuntimeURL() -> URL? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        let runtime = "container"
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(runtime)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Fast probe budget for the container system daemon check.
    /// Short so a down daemon fails fast instead of burning the ensure budget.
    static let daemonProbeTimeoutSeconds: Double = 5
    /// Bounded budget for healing the container system service.
    /// Short enough that the full cascade (probe 5s, system start 8s,
    /// recheck 5s, start 5s, run 8s, final poll 10s — about 41s worst case)
    /// stays responsive; the final poll budget does not cover these heals.
    static let containerSystemStartTimeoutSeconds: Double = 8
    /// Cap for the stderr tail carried in failure detail.
    /// Keeps dashboard messages readable while preserving the actionable line.
    static let maxFailureTailChars = 500
    /// Install location for the Apple Container CLI backing search and detonation.
    static let appleContainerInstallURL = "https://github.com/apple/container"

    /// Guidance returned when the container runtime cannot be resolved.
    /// Points at the Apple Container install and rules out Docker, so a bare
    /// host fails with a next step instead of a bare exit code.
    /// - Returns: Human-readable install guidance.
    static func installGuidanceMessage() -> String {
        "Container runtime 'container' not found. Install the Apple Container CLI "
            + "(\(appleContainerInstallURL)), then retry. Docker is not supported. "
            + "After installing, start the system with `container system start` and verify with `container list`."
    }

    /// Arguments probing the container system daemon without side effects.
    /// `list` needs the daemon yet changes nothing, so it doubles as the
    /// health probe and the README verify step.
    /// - Returns: Arguments for the daemon probe.
    static func daemonProbeArguments() -> [String] {
        ["list"]
    }

    /// Arguments healing a down container system service.
    /// Matches the documented `container system start` recovery so the engine,
    /// the escape-hatch script, and the README never diverge.
    /// - Returns: Arguments starting the system service.
    static func containerSystemStartArguments() -> [String] {
        ["system", "start"]
    }

    /// Whether container output indicates a down system service.
    /// Matches only specific down-state phrases (`XPC connection` with word
    /// boundaries plus the `system service` hint), so a fresh boot or a
    /// stopped service heals via `system start` while unrelated output that
    /// merely mentions `xpc` never triggers the heal.
    /// - Parameter output: Combined stdout plus stderr from the probe.
    /// - Returns: True when the service needs a start.
    static func isDaemonDown(output: String) -> Bool {
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
    static func cappedTail(_ text: String, limit: Int = maxFailureTailChars) -> String {
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
    static func timeoutNote(timeoutSeconds: Double) -> String {
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
    static func failureMessage(
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
    static func hostPort(from baseURL: String) -> Int {
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
    static func bundledTemplateURL() -> URL? {
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
    static func bundledSettingsPath() -> String? {
        let override = overrideSettingsPath()
        if FileManager.default.fileExists(atPath: override) {
            return override
        }
        return bundledTemplateURL()?.path
    }

    /// Per-install override path carrying the generated Flask secret.
    /// - Returns: `~/.runeweaver/searxng/settings.yml` absolute path.
    static func overrideSettingsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".runeweaver/searxng/settings.yml")
    }

    /// Generates a random Flask secret key as lowercase hex.
    /// - Parameter byteCount: Random bytes before hex encoding (clamped 16-64).
    /// - Returns: Hex string twice `byteCount` chars.
    static func makeSecretKey(byteCount: Int = 32) -> String {
        let count = min(max(byteCount, 16), 64)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0 ..< count {
            bytes.append(UInt8.random(in: 0 ... 255))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Renders a standalone settings document with the given secret.
    /// - Parameter secretKey: Per-install Flask secret.
    /// - Returns: YAML document mountable at `/etc/searxng/settings.yml`.
    static func settingsYAML(secretKey: String) -> String {
        """
        # Rune Weaver — Per-install SearXNG settings (generated).
        #
        # Created on first ensure into `~/.runeweaver/searxng/settings.yml`.
        # Holds a random per-install Flask `secret_key`. Delete this file and
        # re-run ensure (or `scripts/searxng-up.sh`) to rotate to a fresh key,
        # then recreate the `runeweaver-searxng` container to pick it up.
        general:
          debug: false
          instance_name: "Rune Weaver SearXNG"
        server:
          port: 8080
          bind_address: "0.0.0.0"
          secret_key: "\(secretKey)"
          limiter: false
          image_proxy: false
        search:
          safe_search: 0
          autocomplete: ""
          formats:
            - html
            - json
        engines:
          - name: duckduckgo
            engine: duckduckgo
            shortcut: ddg
          - name: brave
            engine: brave
            shortcut: br
          - name: wikipedia
            engine: wikipedia
            shortcut: wp
        outgoing:
          request_timeout: 10.0
          max_request_timeout: 15.0
          pool_connections: 20
        """
            + "\n"
    }

    /// Replaces the `secret_key` line in a template with a fresh secret.
    /// - Parameters:
    ///   - template: Bundled `settings.yml` text.
    ///   - secretKey: Per-install Flask secret.
    /// - Returns: Template with the secret line replaced, or fallback rendering.
    static func renderedSettingsYAML(template: String, secretKey: String) -> String {
        let replacement = "  secret_key: \"\(secretKey)\""
        let lines = template.components(separatedBy: "\n")
        var replaced = false
        let mapped = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("secret_key:") {
                replaced = true
                return replacement
            }
            return line
        }
        if replaced {
            return mapped.joined(separator: "\n")
        }
        return settingsYAML(secretKey: secretKey)
    }

    /// Ensures the per-install override exists with a random secret.
    /// Enforces `0700` on the containing directory and `0600` on the file on
    /// every path (not just creation) so pre-existing installs keep the
    /// per-install secret invariant. Permission failures fail closed with nil
    /// instead of reporting success while the secret stays world-readable.
    /// - Returns: Override path when present or created, nil otherwise.
    @discardableResult
    static func ensureOverrideSettingsFile() -> String? {
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
            // Rotate installs still carrying the old committed secret or the
            // shipped placeholder to a fresh random key (best-effort).
            if let existing = try? String(contentsOfFile: overridePath, encoding: .utf8),
               existing.contains("rune-weaver-local-search") || existing.contains("change-me-generate-per-install-secret")
            {
                let fresh = makeSecretKey()
                let rotated = renderedSettingsYAML(template: existing, secretKey: fresh)
                if let data = rotated.data(using: .utf8) {
                    do {
                        try data.write(to: URL(fileURLWithPath: overridePath), options: .atomic)
                        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overridePath)
                    } catch {
                        RuneWeaverLog.tools.error(
                            "SearXNGEnsurer: failed rotating secret at \(overridePath): \(error.localizedDescription)"
                        )
                        return nil
                    }
                }
            }
            return overridePath
        }
        let secret = makeSecretKey()
        let content: String = if let bundledURL = bundledTemplateURL(),
                                 let template = try? String(contentsOf: bundledURL, encoding: .utf8)
        {
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
            try data.write(to: URL(fileURLWithPath: overridePath), options: .atomic)
            do {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overridePath)
            } catch {
                RuneWeaverLog.tools.error(
                    "SearXNGEnsurer: failed enforcing secret permissions at \(overridePath): \(error.localizedDescription)"
                )
                return nil
            }
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
public extension SearXNGEnsurer {
    /// Outcome of healing the container system daemon.
    /// Keeps the started flag beside the failure fragment so the cascade can
    /// record which heal actually moved the daemon without extra plumbing.
    struct DaemonOutcome: Sendable {
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
    struct ContainerOutcome: Sendable {
        public let didStart: Bool
        public let failure: String?
        public init(didStart: Bool, failure: String? = nil) {
            self.didStart = didStart
            self.failure = failure
        }
    }

    /// Non-throwing ensure outcome for HTTP lifecycle routes.
    /// Small struct replacing the 3-tuple so the large-tuple gate stays
    /// green while callers keep the same reachable plus started plus
    /// message shape.
    struct EnsureReport: Sendable {
        public let reachable: Bool
        public let started: Bool
        public let message: String?
        public init(reachable: Bool, started: Bool, message: String? = nil) {
            self.reachable = reachable
            self.started = started
            self.message = message
        }
    }

    /// Raw daemon probe outcome.
    /// Small struct replacing the 4-tuple so the large-tuple gate stays
    /// green while the cascade keeps the same down plus exit plus output
    /// plus timeout shape.
    struct DaemonProbeOutcome: Sendable {
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
    struct SystemStartOutcome: Sendable {
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
    static func daemonProbeResult(runtime: URL) async -> DaemonProbeOutcome {
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
    static func systemStartResult(runtime: URL) async -> SystemStartOutcome {
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
    static func ensureDaemonStarted(runtime: URL) async -> DaemonOutcome {
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

/// Rune Weaver Tools — SearXNG container lifecycle plus reachability.
///
/// Holds the container start-or-run cascade, the fresh-run helper, failure
/// guidance, reachability probing, and bounded process execution so the main
/// `SearXNGEnsurer` actor body stays within the type-length budget. Behavior
/// is unchanged; callers keep using the same `SearXNGEnsurer` namespace.
public extension SearXNGEnsurer {
    /// Starts or recreates the SearXNG container with failure detail.
    /// Tries the existing stopped container first, then a fresh run with the
    /// per-install settings mount. Only an exit-0 spawn claims a start so
    /// cross-process races never double-claim; failures carry stage, exit,
    /// capped tail, and timeout for the ensure message.
    /// - Parameters:
    ///   - browser: `[browser]` policy carrying the base URL.
    ///   - runtime: Resolved Apple Container CLI.
    /// - Returns: Whether this call started a container plus failure detail.
    static func startExistingOrRun(browser: BrowserConfig, runtime: URL) async -> ContainerOutcome {
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        // An existing stopped container starts fastest; when none exists
        // the start fails and the run below creates it. Only an exit-0 start
        // claims the outcome, so a container revived by another process
        // reports false here instead of double-claiming.
        var lastFailure: String?
        do {
            let (code, output) = try await runProcess(
                executableURL: runtime,
                arguments: ["start", containerName],
                timeoutSeconds: 5
            )
            if Task.isCancelled {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            if await isReachable(baseURL: browser.searxngURL) {
                return ContainerOutcome(didStart: code == 0, failure: nil)
            }
            if code != 0 {
                lastFailure = failureMessage(
                    stage: EnsureStage.start.rawValue,
                    exitCode: code,
                    output: output,
                    timedOut: false
                )
            }
        } catch is CancellationError {
            return ContainerOutcome(didStart: false, failure: nil)
        } catch let error as BoundedProcessError {
            lastFailure = runFailureMessage(error: error, stage: EnsureStage.start.rawValue, timeout: 5)
        } catch {
            lastFailure = failureMessage(
                stage: EnsureStage.start.rawValue,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        }
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        if await isReachable(baseURL: browser.searxngURL) {
            // Reachable now supersedes the earlier start failure, so clear it
            // instead of carrying a stale stage detail into a success.
            return ContainerOutcome(didStart: false, failure: nil)
        }
        return await runFreshContainer(browser: browser, runtime: runtime, lastFailure: lastFailure)
    }

    /// Runs a fresh SearXNG container with the per-install settings mount.
    /// Extracted from `startExistingOrRun` so the starter stays within the
    /// function body budget; behavior is unchanged.
    /// - Parameters:
    ///   - browser: `[browser]` policy carrying the base URL.
    ///   - runtime: Resolved Apple Container CLI.
    ///   - lastFailure: Failure detail from the start attempt, if any.
    /// - Returns: Whether this call started a container plus failure detail.
    static func runFreshContainer(
        browser: BrowserConfig,
        runtime: URL,
        lastFailure: String?
    ) async -> ContainerOutcome {
        // Ensure the per-install override exists with a random secret before
        // resolving the mount, so the shipped placeholder is never mounted.
        // Fail closed when secret permissions cannot be enforced: a hardening
        // failure must never fall through to mounting a world-readable file.
        guard ensureOverrideSettingsFile() != nil else {
            let secretFailure = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: nil,
                output: "secret permissions",
                timedOut: false
            )
            return ContainerOutcome(
                didStart: false,
                failure: lastFailure.map { "\($0); \(secretFailure)" } ?? secretFailure
            )
        }
        guard let settings = bundledSettingsPath() else {
            // Fail closed: never start with image defaults, which lack the
            // guaranteed formats:[html,json]. The caller falls through to
            // polling and then to the guidance error naming the manual hatch.
            let missing = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: nil,
                output: "no SearXNG settings found for mount",
                timedOut: false
            )
            return ContainerOutcome(didStart: false, failure: lastFailure.map { "\($0); \(missing)" } ?? missing)
        }
        let port = hostPort(from: browser.searxngURL)
        let runArgs = [
            "run", "-d",
            "--name", containerName,
            // Loopback-only publish: the engine has no auth, so LAN exposure
            // would open unauthenticated search to the local network.
            "-p", "127.0.0.1:\(port):8080",
            "-v", "\(settings):/etc/searxng/settings.yml:ro",
            containerImage
        ]
        do {
            let (code, output) = try await runProcess(executableURL: runtime, arguments: runArgs, timeoutSeconds: 8)
            if Task.isCancelled {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            if code == 0 {
                // Exit 0 supersedes the earlier start failure, so success
                // clears the stale stage detail instead of carrying it forward.
                return ContainerOutcome(didStart: true, failure: nil)
            }
            let runFailure = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: code,
                output: output,
                timedOut: false
            )
            return ContainerOutcome(
                didStart: false,
                failure: lastFailure.map { "\($0); \(runFailure)" } ?? runFailure
            )
        } catch is CancellationError {
            return ContainerOutcome(didStart: false, failure: nil)
        } catch let error as BoundedProcessError {
            let runFailure = runFailureMessage(
                error: error,
                stage: EnsureStage.run.rawValue,
                timeout: 8
            )
            return ContainerOutcome(
                didStart: false,
                failure: lastFailure.map { "\($0); \(runFailure)" } ?? runFailure
            )
        } catch {
            let runFailure = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
            return ContainerOutcome(
                didStart: false,
                failure: lastFailure.map { "\($0); \(runFailure)" } ?? runFailure
            )
        }
    }

    /// Builds the run-stage failure fragment for a bounded-process error.
    /// Shared by the start and run phases so timeout mapping stays single
    /// sourced between the container heal steps.
    /// - Parameters:
    ///   - error: Bounded-process failure from the container spawn.
    ///   - stage: Cascade stage name for the failure message.
    ///   - timeout: Budget for the timeout note when the spawn timed out.
    /// - Returns: Single-line failure fragment.
    static func runFailureMessage(error: BoundedProcessError, stage: String, timeout: Double) -> String {
        let timedOut = if case .timedOut = error {
            true
        } else {
            false
        }
        return failureMessage(
            stage: stage,
            exitCode: nil,
            output: error.localizedDescription,
            timedOut: timedOut,
            timeoutSeconds: timedOut ? timeout : nil
        )
    }

    /// Best-effort container stop shared by the server stop route.
    /// A missing runtime or absent container still reports stopped so the
    /// settings toggle never sticks on a 500; later searches re-ensure.
    static func bestEffortStop() async {
        guard let runtime = resolveRuntimeURL() else { return }
        _ = try? await runProcess(
            executableURL: runtime,
            arguments: ["stop", containerName],
            timeoutSeconds: 8
        )
    }

    /// Probes the SearXNG base URL with a short timeout.
    /// Surfaces 3xx instead of auto-following so the probe shares the manual
    /// redirect policy with `web.fetch`/`api.request` (`NoRedirectDelegate`
    /// plus per-hop re-validation there); a safe start can never launder an
    /// unsafe redirect through the session follower.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: True when the engine answers with 2xx/3xx.
    static func isReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: probeTimeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(WebFetchTool.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200 ..< 400).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Fail-closed guidance naming the manual escape hatch.
    /// Appends the last cascade detail (stage, exit, capped tail, timeout) so
    /// callers and the dashboard surface why the heal stopped, not just that
    /// the probe stayed dark.
    /// - Parameters:
    ///   - baseURL: Configured `searxng_url`.
    ///   - detail: Last failure fragment from the cascade, if any.
    /// - Returns: Error carrying remediation steps plus failure detail.
    static func unreachableError(baseURL: String, detail: String?) -> Error {
        var message =
            "SearXNG is not reachable at \(baseURL). Start it with `scripts/searxng-up.sh` "
                + "or `container start \(containerName)`, then retry the search. "
                + "The container is left running after quit by design."
        let trimmed = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            message += " (\(trimmed))"
        }
        return NSError(domain: "RuneWeaverSearXNG", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Fail-closed guidance naming the manual escape hatch.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Error carrying remediation steps.
    static func unreachableError(baseURL: String) -> Error {
        unreachableError(baseURL: baseURL, detail: nil)
    }

    /// Runs one container process without blocking the cooperative pool.
    static func runProcess(executableURL: URL, arguments: [String], timeoutSeconds: Double) async throws -> (Int32, String) {
        try Task.checkCancellation()
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: executableURL,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
            try Task.checkCancellation()
            return (result.exitCode, result.stdoutString + result.stderrString)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }
}
