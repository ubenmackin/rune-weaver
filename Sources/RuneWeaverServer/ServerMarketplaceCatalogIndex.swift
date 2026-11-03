// Rune Weaver Server — Marketplace catalog index loading and merging.

import Foundation
import RuneWeaverCore
import RuneWeaverTools

/// Index validation plus loading split from the catalog core.
extension MarketplaceCatalog {
    /// Curated fallback stays empty so the remote index decides the merge.
    static func getCuratedMarketplaceItems(installedIDs _: Set<String>) -> [MarketplacePluginItem] {
        // Catalog mirrors the remote index, so the curated set stays empty.
        []
    }

    private static func isValidMarketplaceIndex(_ doc: MarketplaceIndexDocument) -> Bool {
        // Version plus per-entry identity keep malformed catalogs from entering the merge.
        guard let version = doc.version, version >= 1 else { return false }
        // Duplicate IDs would collide on merge, so fail closed before any read.
        var seenIDs = Set<String>()
        for entry in doc.items {
            guard seenIDs.insert(entry.id).inserted,
                  !entry.id.isEmpty, !entry.name.isEmpty, !entry.version.isEmpty,
                  entry.runtime == "python" || entry.runtime == "executable",
                  !entry.declaredTools.isEmpty,
                  MarketplaceCatalog.isValidMarketplaceCatalogID(entry.id) else { return false }
            if let files = entry.files {
                guard !files.isEmpty, files.allSatisfy(MarketplaceCatalog.isSafeMarketplaceFileName) else { return false }
            }
            if let rawPath = entry.path, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               MarketplaceCatalog.validatedMarketplaceSourceDir(rawPath) == nil
            {
                return false
            }
            if let rawURL = entry.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawURL.isEmpty
            {
                guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return false }
            }
        }
        return true
    }

    private static func loadValidatedMarketplaceIndexFile(at url: URL) -> MarketplaceIndexDocument? {
        // Size cap plus validation keep oversized or malformed catalogs out.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = PluginSecurity.secureCappedFileData(at: url, maxBytes: indexMaxBytes),
              data.count <= indexMaxBytes,
              let doc = try? JSONDecoder().decode(MarketplaceIndexDocument.self, from: data),
              isValidMarketplaceIndex(doc)
        else {
            return nil
        }
        return doc
    }

    private static func loadValidatedMarketplaceIndexFile(atExpandedPath rawPath: String) -> MarketplaceIndexDocument? {
        // Expand tilde plus reject traversal so configured paths cannot escape via "..".
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for scalar in trimmed.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let fileURL: URL
        if expanded.hasPrefix("/") {
            // Absolute catalog paths stay inside the workspace or the owner data dir.
            let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
            let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
            let ownerDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".runeweaver").standardizedFileURL
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            let resolvedWorkspace = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
            let resolvedOwner = ownerDir.resolvingSymlinksInPath().standardizedFileURL
            let workspacePrefix = resolvedWorkspace.path.hasSuffix("/") ? resolvedWorkspace.path : resolvedWorkspace.path + "/"
            let ownerPrefix = resolvedOwner.path.hasSuffix("/") ? resolvedOwner.path : resolvedOwner.path + "/"
            guard resolvedCandidate.path.hasPrefix(workspacePrefix) || resolvedCandidate.path.hasPrefix(ownerPrefix) else { return nil }
            fileURL = candidate
        } else {
            let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
            fileURL = workspaceRoot.appendingPathComponent(expanded).standardizedFileURL
        }
        return loadValidatedMarketplaceIndexFile(at: fileURL)
    }

    static func loadMarketplaceIndex(context: ServerContext) async -> MarketplaceIndexDocument? {
        // Cancelled runs skip catalog work so hung suites settle promptly.
        guard !Task.isCancelled else { return nil }
        let urlString = context.pluginConfig.marketplaceIndexURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = urlString.lowercased()

        // Remote catalog requires https only so plain http cannot tamper the merge.
        // Hermetic suites skip remote so file and bundled catalogs decide the merge.
        let allowsRemote = ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1"
        if allowsRemote, lower.hasPrefix("https://") {
            if let url = URL(string: urlString),
               url.scheme?.lowercased() == "https",
               url.host?.isEmpty == false,
               let data = await MarketplaceCatalog.fetchValidatedMarketplaceBytes(from: url, maxBytes: indexMaxBytes, timeout: 5.0),
               let doc = try? JSONDecoder().decode(MarketplaceIndexDocument.self, from: data),
               isValidMarketplaceIndex(doc)
            {
                return doc
            }
        } else if !lower.hasPrefix("http://"),
                  !lower.hasPrefix("https://"),
                  !urlString.isEmpty,
                  let doc = loadValidatedMarketplaceIndexFile(atExpandedPath: urlString)
        {
            // Configured file path honors tilde, containment, size cap, plus validation.
            return doc
        }

        // File path from environment with the same size and validation bounds.
        if let envPath = ProcessInfo.processInfo.environment["RUNEWEAVER_MARKETPLACE_INDEX_PATH"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let doc = loadValidatedMarketplaceIndexFile(atExpandedPath: envPath)
        {
            return doc
        }

        // Fallback to local Plugins/index.json relative to current directory, plugins pen, or home.
        // Hermetic suites skip home so developer state never decides test merges.
        var candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins/index.json"),
            context.pluginDiscovery.pluginsDirectory.deletingLastPathComponent().appendingPathComponent("Plugins/index.json")
        ]
        if allowsRemote {
            candidates.append(
                URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
                    .appendingPathComponent(".runeweaver/Plugins/index.json")
            )
        }
        for candidate in candidates {
            if let doc = loadValidatedMarketplaceIndexFile(at: candidate) {
                return doc
            }
        }

        return nil
    }

    static func fetchMarketplaceCatalog(context: ServerContext, installedRecordsByID: [String: PluginRecord]) async -> [MarketplacePluginItem] {
        // Cancelled runs return empty so hung suites settle promptly.
        guard !Task.isCancelled else { return [] }
        // Duplicates fail catalog validation; map is defensive last-wins.
        var itemsByID: [String: MarketplacePluginItem] = [:]

        for item in MarketplaceCatalog.getCuratedMarketplaceItems(installedIDs: Set(installedRecordsByID.keys)) {
            itemsByID[item.id] = item
        }

        if let doc = await MarketplaceCatalog.loadMarketplaceIndex(context: context) {
            for entry in doc.items {
                let installedRecord = installedRecordsByID[entry.id]
                let isInstalled = installedRecord != nil
                let installedVersion = installedRecord?.version
                let hasUpdate = isInstalled && installedVersion != nil && MarketplaceCatalog.isVersionNewer(entry.version, than: installedVersion!)

                let item = MarketplacePluginItem(
                    id: entry.id,
                    name: entry.name,
                    version: entry.version,
                    author: entry.author ?? "Community",
                    description: entry.description,
                    downloadURL: entry.downloadURL ?? "",
                    tags: entry.tags,
                    runtime: entry.runtime,
                    declaredTools: entry.declaredTools,
                    isInstalled: isInstalled,
                    installedVersion: installedVersion,
                    hasUpdate: hasUpdate
                )
                itemsByID[entry.id] = item
            }
        }

        return Array(itemsByID.values)
    }
}
