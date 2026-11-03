// Rune Weaver Server — Marketplace catalog core helpers and shared bounds.

import Foundation
import RuneWeaverCore
import RuneWeaverTools

struct MarketplaceIndexDocument: Codable, Sendable {
    let version: Int?
    let items: [MarketplaceIndexEntry]
}

struct MarketplaceIndexEntry: Codable, Sendable {
    let id: String
    let name: String
    let version: String
    let author: String?
    let description: String
    let downloadURL: String?
    let tags: [String]
    let runtime: String
    let declaredTools: [String]
    let path: String?
    let files: [String]?
}

/// Catalog and install helpers share one namespace so generic names never leak globally.
enum MarketplaceCatalog {
    /// Shared payload cap keeps installer copies plus hash reads bounded.
    static let pluginFileMaxBytes = 5_242_880

    /// Index cap shared with validation plus loading so bounds stay single-sourced.
    static let indexMaxBytes = 1_048_576

    static func isVersionNewer(_ candidate: String, than current: String) -> Bool {
        let candidateClean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentClean = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidateClean != currentClean else { return false }

        let candidateParts = candidateClean.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) }
        let currentParts = currentClean.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) }

        let maxCount = max(candidateParts.count, currentParts.count)
        if maxCount > 0, !candidateParts.isEmpty || !currentParts.isEmpty {
            for componentIndex in 0 ..< maxCount {
                let candidateComponent = componentIndex < candidateParts.count ? candidateParts[componentIndex] : 0
                let currentComponent = componentIndex < currentParts.count ? currentParts[componentIndex] : 0
                if candidateComponent > currentComponent {
                    return true
                }
                if candidateComponent < currentComponent {
                    return false
                }
            }
        }
        return candidateClean.compare(currentClean, options: .numeric) == .orderedDescending
    }

    /// Hashes requirements bytes so identical lockfiles reuse the provisioned venv.
    private static func secureRequirementsHexDigest(at reqURL: URL, maxBytes: Int) -> String? {
        guard let data = PluginSecurity.secureCappedFileData(at: reqURL, maxBytes: maxBytes) else {
            return nil
        }
        return PluginSecurity.hexDigest(for: data)
    }

    static func requirementsSHA256(at directory: URL) -> String? {
        // Identical requirements reuse the venv, so hash raw bytes deterministically.
        // Size cap keeps hashing bounded like installer copies.
        let reqURL = directory.appendingPathComponent("requirements.txt")
        guard let values = try? reqURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return secureRequirementsHexDigest(at: reqURL, maxBytes: pluginFileMaxBytes)
    }

    static func catalogRequirementsSHA(for pluginID: String, entry: MarketplaceIndexEntry?) async -> String? {
        // New payload hash comes from the same local source the installer copies.
        let filesToCopy = entry?.files ?? ["rune.json", "main.py", "requirements.txt", "README.md"]
        guard filesToCopy.contains("requirements.txt") else { return nil }
        var candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins/\(pluginID)")
        ]
        if let rawPath = entry?.path, let validated = MarketplaceCatalog.validatedMarketplaceSourceDir(rawPath) {
            candidates.append(validated)
        }
        for localDir in candidates where FileManager.default.fileExists(atPath: localDir.path) {
            // Same symlink plus size bounds as installer so hashing never reads unsafe bytes.
            let reqURL = localDir.appendingPathComponent("requirements.txt")
            guard MarketplaceCatalog.isSafeLocalSourceFile(at: reqURL, within: localDir) else { continue }
            if let digest = secureRequirementsHexDigest(at: reqURL, maxBytes: pluginFileMaxBytes) {
                return digest
            }
        }
        // Remote-only entries hash the fetched lockfile so unchanged requirements still reuse.
        guard let entry, let rawURL = entry.downloadURL, let baseDownloadURL = URL(string: rawURL),
              baseDownloadURL.scheme?.lowercased() == "https", baseDownloadURL.host?.isEmpty == false
        else {
            return nil
        }
        let remoteReqURL = baseDownloadURL.deletingLastPathComponent().appendingPathComponent("requirements.txt")
        guard let data = await MarketplaceCatalog.fetchValidatedMarketplaceBytes(from: remoteReqURL, maxBytes: pluginFileMaxBytes, timeout: 10.0),
              data.count <= pluginFileMaxBytes
        else {
            return nil
        }
        return PluginSecurity.hexDigest(for: data)
    }

    static func isValidMarketplaceCatalogID(_ id: String) -> Bool {
        // Catalog IDs become directory names, so enforce the install allowlist early.
        guard !id.isEmpty, id != ".", id != "..",
              id.range(of: "^[a-zA-Z0-9_.-]+$", options: .regularExpression) != nil,
              !id.contains("/"), !id.contains("\\"), !id.contains("..") else { return false }
        return true
    }

    /// Single-component allowlist shared by validation plus install containment.
    static func isSafeMarketplaceFileName(_ fileName: String) -> Bool {
        // Single-component allowlist so catalog entries cannot escape the pen.
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains(".."),
              !fileName.hasPrefix("/"), !fileName.hasPrefix("\\") else { return false }
        for scalar in fileName.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
            return false
        }
        return true
    }

    /// Catalog sources stay under Plugins so workspace files never enter the pen.
    static func validatedMarketplaceSourceDir(_ rawPath: String) -> URL? {
        // Catalog sources stay under Plugins/ so workspace files never enter the pen.
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\"), !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"), !trimmed.contains(".."),
              trimmed == "Plugins" || trimmed.hasPrefix("Plugins/") else { return nil }
        for scalar in trimmed.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
            return nil
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        let candidate = workspaceRoot.appendingPathComponent(trimmed).standardizedFileURL
        let resolvedRoot = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    /// Symlink plus containment check shared by hashing and install copying.
    static func isSafeLocalSourceFile(at src: URL, within localDir: URL) -> Bool {
        // lstat-style check rejects symlinks plus directories before any copy.
        guard let values = try? src.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              values.isDirectory != true
        else {
            return false
        }
        let resolvedDir = localDir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSrc = src.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedDir.path.hasSuffix("/") ? resolvedDir.path : resolvedDir.path + "/"
        return resolvedSrc.path.hasPrefix(prefix)
    }

    /// Capped https fetch shared by index loading plus install plus hashing.
    static func fetchValidatedMarketplaceBytes(from initialURL: URL, maxBytes: Int, timeout: TimeInterval) async -> Data? {
        // Hermetic suites stay off the network so catalog fetches fail fast.
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else { return nil }
        // Manual redirect chain re-validates https plus SSRF plus size cap per hop.
        var current = initialURL
        for _ in 0 ..< HTTPRedirectFollower.maxRedirects {
            // Cancelled runs fail fast instead of draining redirect budgets.
            guard !Task.isCancelled,
                  current.scheme?.lowercased() == "https", current.host?.isEmpty == false,
                  await ApiSSRFGuard.denyReasonAsync(for: current.absoluteString, allowlistedOrigins: []) == nil
            else { return nil }
            var request = URLRequest(url: current)
            request.timeoutInterval = timeout
            // Streaming cap enforces per-byte during download so oversized bodies never buffer.
            let capped = try? await CappedNoRedirectDelegate.downloadCapped(
                request: request,
                maxBytes: maxBytes,
                timeoutSeconds: timeout
            )
            guard let (data, response) = capped, let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 200 {
                guard data.count <= maxBytes else { return nil }
                return data
            }
            guard (300 ..< 400).contains(http.statusCode),
                  let next = HTTPRedirectFollower.redirectTarget(http: http, currentURL: current),
                  next.scheme?.lowercased() == "https", next.host?.isEmpty == false
            else { return nil }
            current = next
        }
        return nil
    }
}
