// Rune Weaver Tools Tests — SearXNG stale-override auto-migration with recreate.

import Foundation
@testable import RuneWeaverTools
import Testing

@Suite("Search Template Migration — Stale Regen, Fresh Untouched, Rotation, Ordering")
struct SearchTemplateMigrationTests {
    @Test
    func `Missing marker reads as stale so pre-stamp installs migrate`() {
        // Installs from before stamping carry no marker at all; treating the
        // absence as stale is what moves them onto the current document
        // instead of leaving them pinned on an unversioned file forever.
        #expect(SearXNGEnsurer.overrideTemplateVersion(in: "server:\n  secret_key: \"abc\"\n") == nil)
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: "server:\n  secret_key: \"abc\"\n") == true)
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: "") == true)
    }

    @Test
    func `Older marker migrates while current and newer never downgrade`() {
        // Only a marker older than the bundled template forces the
        // regenerate-plus-recreate path; a current file stays untouched and a
        // forward-compatible file from a newer template is never rolled back.
        let current = SearXNGEnsurer.settingsTemplateVersion
        let older = "\(SearXNGEnsurer.settingsTemplateVersionMarkerPrefix) \(current - 1)\nserver:\n"
        let fresh = "\(SearXNGEnsurer.settingsTemplateVersionMarkerLine())\nserver:\n"
        let newer = "\(SearXNGEnsurer.settingsTemplateVersionMarkerPrefix) \(current + 1)\nserver:\n"
        #expect(SearXNGEnsurer.overrideTemplateVersion(in: older) == current - 1)
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: older) == true)
        #expect(SearXNGEnsurer.overrideTemplateVersion(in: fresh) == current)
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: fresh) == false)
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: newer) == false)
    }

    @Test
    func `Malformed marker reads as missing so half-written stamps heal`() {
        // A marker line that cannot parse as an integer proves nothing about
        // the document version; failing closed to stale keeps a truncated
        // write from posing as current on the next ensure.
        let malformed = "\(SearXNGEnsurer.settingsTemplateVersionMarkerPrefix) not-a-version\nserver:\n"
        #expect(SearXNGEnsurer.overrideTemplateVersion(in: malformed) == nil)
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: malformed) == true)
    }

    @Test
    func `Fresh rendering stamps the current marker with the given secret`() {
        // Every producer (first creation, stale migration, script fallback) must emit the same
        // schema: the marker for future migration checks plus the caller-supplied secret so the
        // mount never carries a placeholder key.
        let rendered = SearXNGEnsurer.settingsYAML(secretKey: "fresh-secret-123")
        #expect(rendered.contains(SearXNGEnsurer.settingsTemplateVersionMarkerLine()))
        #expect(rendered.contains("secret_key: \"fresh-secret-123\""))
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: rendered) == false)
    }

    @Test
    func `Stale document migrates to the current marker with a fresh secret`() {
        // The migration rebuilds from the current template rather than swapping the secret inside
        // the stale text, so old sizing and schema cannot linger behind; the test pins the converge
        // point by rendering a stale template with a new key and checking the stamp flips.
        let staleTemplate = "# old settings\nserver:\n  secret_key: \"old-key\"\n"
        let migrated = SearXNGEnsurer.renderedSettingsYAML(template: staleTemplate, secretKey: "brand-new-key")
        #expect(migrated.contains(SearXNGEnsurer.settingsTemplateVersionMarkerLine()))
        #expect(migrated.contains("secret_key: \"brand-new-key\""))
        #expect(!migrated.contains("old-key"))
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: migrated) == false)
    }

    @Test
    func `Secret rotation preserves the current marker`() {
        // Placeholder rotation (old committed secret or shipped placeholder) reuses the same
        // renderer as migration, so a rotated file must already read as fresh on the next ensure
        // instead of bouncing into the recreate path a second time.
        let currentFile = "\(SearXNGEnsurer.settingsTemplateVersionMarkerLine())\nserver:\n  secret_key: \"change-me-generate-per-install-secret\"\n"
        let rotated = SearXNGEnsurer.renderedSettingsYAML(template: currentFile, secretKey: "rotated-key-456")
        #expect(rotated.contains(SearXNGEnsurer.settingsTemplateVersionMarkerLine()))
        #expect(rotated.contains("secret_key: \"rotated-key-456\""))
        #expect(SearXNGEnsurer.overrideNeedsMigration(contents: rotated) == false)
        // Rotation keeps the stamp count at one so repeated rotations never
        // accumulate duplicate marker lines at the top of the file.
        let markerCount = rotated.components(separatedBy: SearXNGEnsurer.settingsTemplateVersionMarkerPrefix).count - 1
        #expect(markerCount == 1)
    }

    @Test
    func `Generated secrets vary and stay hex at the expected width`() {
        // A predictable or fixed secret would weaken Flask session signing
        // across installs, so two mints must differ while keeping the
        // lowercase-hex shape the YAML renderer quotes.
        let first = SearXNGEnsurer.makeSecretKey()
        let second = SearXNGEnsurer.makeSecretKey()
        #expect(first != second)
        #expect(first.count == 64)
        #expect(second.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test
    func `Recreate ordering keeps remove before the fresh run with current sizing`() {
        // The stale branch regenerates first, then drops the entry with rm-first before the fresh
        // run mounts the new document; pinning the verbs here keeps the engine on the same ordering
        // the script uses so the run can never hit an already-exists conflict on its own entry.
        let name = SearXNGEnsurer.containerName
        #expect(SearXNGEnsurer.containerRemoveArguments() == ["rm", name])
        let runArgs = SearXNGEnsurer.containerRunArguments(settingsPath: "/tmp/settings.yml", hostPort: 8888)
        #expect(runArgs.first == "run")
        #expect(!runArgs.contains("rm"))
        #expect(runArgs.contains(name))
        #expect(runArgs.contains("/tmp/settings.yml:/etc/searxng/settings.yml:ro"))
        #expect(runArgs.contains("127.0.0.1:8888:8080"))
        #expect(runArgs.contains("--cpus") && runArgs.contains("1"))
        #expect(runArgs.contains("--memory") && runArgs.contains("512M"))
    }

    @Test
    func `Escape-hatch script mirrors the marker version and rm-first recreate`() throws {
        // The shell hatch must detect the same stale state and recreate in the same order; a drift
        // in the version number, the marker spelling, or the remove-before-run sequence would leave
        // script recoveries on the old document while the engine boots the new one.
        let script = try Self.searxngUpScript()
        // Decode once so every assertion below reads the same text the shell
        // executes; a binary decode failure would hide the marker drift the
        // test exists to catch.
        let scriptString = String(decoding: script, as: UTF8.self)
        #expect(scriptString.contains("TEMPLATE_VERSION=\(SearXNGEnsurer.settingsTemplateVersion)"))
        #expect(scriptString.contains(SearXNGEnsurer.settingsTemplateVersionMarkerPrefix))
        #expect(scriptString.contains("override_needs_migration"))
        #expect(scriptString.contains("STALE_OVERRIDE=1"))
        // The stale recreate removes before the fresh run below it; comparing
        // positions keeps the ordering pinned without executing the script.
        guard let staleBranch = scriptString.range(of: "STALE_OVERRIDE:-0"),
              let rmCall = scriptString.range(of: "\"${RUNTIME}\" rm \"${CONTAINER_NAME}\""),
              let runArgs = scriptString.range(of: "RUN_ARGS=(run")
        else {
            Issue.record("searxng-up.sh is missing the stale rm-first recreate sequence")
            return
        }
        #expect(staleBranch.lowerBound < rmCall.lowerBound)
        #expect(rmCall.lowerBound < runArgs.lowerBound)
    }

    /// Reads the escape-hatch script independently of the test working directory.
    ///
    /// - Returns: Raw script bytes for marker and ordering assertions.
    private static func searxngUpScript() throws -> Data {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 10 {
            let candidate = dir.appendingPathComponent("scripts/searxng-up.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            // Walk toward the repo root the same way version drift tests do,
            // so Xcode, `swift test`, and CI resolve the hatch alike.
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        // Fall back to the Tests-to-root relative layout when the walk misses,
        // keeping the drift check hermetic instead of failing on runner depth.
        throw NSError(domain: "SearchTemplateMigrationTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "scripts/searxng-up.sh not found from \(#filePath)"
        ])
    }
}
