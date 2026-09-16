// Rune Weaver Tools — SearXNGEnsurer configuration helpers.
//
// Holds the pure configuration surface for the local SearXNG lifecycle:
// loopback management checks, Apple Container runtime resolution, host-port
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
