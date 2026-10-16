// Rune Weaver Core Tests — Engine version single-source drift guard.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Reasons version resolution can fail before any equality check runs.
private enum VersionDriftError: Error {
    /// No ancestor directory held a VERSION file within the search bound.
    case repoRootNotFound
    /// The located VERSION file held no usable release string.
    case emptyVersionFile
    /// The dashboard manifest held no usable version string.
    case missingPackageVersion
}

@Suite("Version Drift")
struct VersionDriftTests {
    @Test
    func `VERSION matches stamped constant and package manifest`() throws {
        let canonical = try Self.repoVersion()
        // The stamp is the build-time copy of VERSION; the computed current
        // must prefer it so /health, User-Agent, and the CLI agree.
        #expect(RuneWeaverGeneratedVersion.version == canonical)
        #expect(RuneWeaverVersion.current == canonical)
        #expect(try Self.packageVersion() == canonical)
        // User-Agent construction must track the canonical release as well.
        #expect(RuneWeaverVersion.userAgent == "rune-weaver/\(canonical)")
    }

    /// Reads the canonical release from the repo-root VERSION file.
    private static func repoVersion() throws -> String {
        let root = try repoRoot()
        let url = root.appendingPathComponent("VERSION")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let normalized = normalize(raw)
        guard !normalized.isEmpty else {
            throw VersionDriftError.emptyVersionFile
        }
        return normalized
    }

    /// Reads the dashboard release from the web package manifest. - Returns: Version string from
    /// `Web/package.json`, kept in sync by the version stamping step rather than hand edits.
    private static func packageVersion() throws -> String {
        let root = try repoRoot()
        let url = root.appendingPathComponent("Web/package.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["version"] as? String
        else {
            throw VersionDriftError.missingPackageVersion
        }
        let normalized = normalize(raw)
        guard !normalized.isEmpty else {
            throw VersionDriftError.missingPackageVersion
        }
        return normalized
    }

    /// Walks ancestors of this file until a VERSION marker appears.
    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 10 {
            let marker = dir.appendingPathComponent("VERSION").path
            if FileManager.default.fileExists(atPath: marker) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw VersionDriftError.repoRootNotFound
    }

    /// Trims whitespace and a single leading `v` so `v0.1.0` and `0.1.0`
    /// compare equal across hand edits, tags, and packaging scripts.
    private static func normalize(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
