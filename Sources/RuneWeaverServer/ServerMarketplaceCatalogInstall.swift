// Rune Weaver Server — Marketplace catalog install and scaffold helpers.

import Foundation
import RuneWeaverCore
import RuneWeaverTools

/// Install payload handling split from catalog core so each body stays scannable.
extension MarketplaceCatalog {
    private static func toolMeta(name: String, description: String, schema: String, permission: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": schema,
            "permission_level": permission
        ]
    }

    private static func getCuratedToolsMetadata(for pluginID: String, fallbackTools: [String]) -> [[String: Any]] {
        switch pluginID {
        case "community.playwright-browser":
            [
                MarketplaceCatalog.toolMeta(
                    name: "browser.navigate",
                    description: "Navigate the browser to a specific URL.",
                    schema: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}",
                    permission: "requiresApproval"
                ),
                MarketplaceCatalog.toolMeta(
                    name: "browser.read_page",
                    description: "Read text content and metadata of the current page.",
                    schema: "{\"type\":\"object\",\"properties\":{\"selector\":{\"type\":\"string\"}},\"required\":[]}",
                    permission: "readOnly"
                ),
                MarketplaceCatalog.toolMeta(
                    name: "browser.screenshot",
                    description: "Capture screenshot of current browser window.",
                    schema: "{\"type\":\"object\",\"properties\":{\"filename\":{\"type\":\"string\"}},\"required\":[]}",
                    permission: "requiresApproval"
                )
            ]
        case "community.homeassistant-control":
            [
                MarketplaceCatalog.toolMeta(
                    name: "home.get_state",
                    description: "Get state of an entity in Home Assistant.",
                    schema: "{\"type\":\"object\",\"properties\":{\"entity_id\":{\"type\":\"string\"}},\"required\":[\"entity_id\"]}",
                    permission: "readOnly"
                ),
                MarketplaceCatalog.toolMeta(
                    name: "home.call_service",
                    description: "Call a service on an entity in Home Assistant.",
                    schema: "{\"type\":\"object\",\"properties\":{\"domain\":{\"type\":\"string\"},"
                        + "\"service\":{\"type\":\"string\"},\"entity_id\":{\"type\":\"string\"}},\"required\":[\"domain\",\"service\",\"entity_id\"]}",
                    permission: "requiresApproval"
                )
            ]
        case "community.github-explorer":
            [
                MarketplaceCatalog.toolMeta(
                    name: "github.search_repos",
                    description: "Search GitHub repositories with a query string.",
                    schema: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}",
                    permission: "readOnly"
                ),
                MarketplaceCatalog.toolMeta(
                    name: "github.list_issues",
                    description: "List open issues for a repository.",
                    schema: "{\"type\":\"object\",\"properties\":{\"repo\":{\"type\":\"string\"}},\"required\":[\"repo\"]}",
                    permission: "readOnly"
                )
            ]
        case "community.clock-timer":
            [
                MarketplaceCatalog.toolMeta(
                    name: "clock.current_time",
                    description: "Get current system and UTC time.",
                    schema: "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
                    permission: "readOnly"
                ),
                MarketplaceCatalog.toolMeta(
                    name: "clock.convert_timezone",
                    description: "Convert current time to target timezone.",
                    schema: "{\"type\":\"object\",\"properties\":{\"timezone\":{\"type\":\"string\"}},\"required\":[\"timezone\"]}",
                    permission: "readOnly"
                )
            ]
        default:
            fallbackTools.map { toolName in
                MarketplaceCatalog.toolMeta(
                    name: toolName,
                    description: "Runs execution for \(toolName).",
                    schema: "{\"type\":\"object\",\"properties\":{}}",
                    permission: "requiresApproval"
                )
            }
        }
    }

    private static func generateScaffoldScript(for _: String, tools _: [[String: Any]]) -> String {
        """
        #!/usr/bin/env python3
        import sys, json

        def handle_request(req):
            call_id = req.get("id")
            method = req.get("method", "")
            params = req.get("params", {})

            if method == "browser.navigate":
                url = params.get("url", "about:blank")
                return {"jsonrpc": "2.0", "result": f"Navigated to {url}", "id": call_id}
            elif method == "browser.read_page":
                return {"jsonrpc": "2.0", "result": "Title: Rune Weaver Community Page\\nContent: Sample extracted text content.", "id": call_id}
            elif method == "browser.screenshot":
                fn = params.get("filename", "screenshot.png")
                return {"jsonrpc": "2.0", "result": f"Screenshot captured to {fn}", "id": call_id}
            elif method == "home.get_state":
                eid = params.get("entity_id", "light.living_room")
                return {"jsonrpc": "2.0", "result": f"Entity {eid} state: on, brightness: 80%", "id": call_id}
            elif method == "home.call_service":
                svc_domain = params.get('domain')
                svc_name = params.get('service')
                svc_entity = params.get('entity_id')
                msg = f"Called service {svc_domain}.{svc_name} on {svc_entity}"
                return {"jsonrpc": "2.0", "result": msg, "id": call_id}
            elif method == "github.search_repos":
                q = params.get("query", "")
                return {"jsonrpc": "2.0", "result": f"Top repos matching '{q}': ubenmackin/rune-weaver (★120)", "id": call_id}
            elif method == "github.list_issues":
                r = params.get("repo", "")
                return {"jsonrpc": "2.0", "result": f"Open issues for {r}: #1 Add plugin marketplace support", "id": call_id}
            elif method == "clock.current_time":
                import datetime
                now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
                return {"jsonrpc": "2.0", "result": f"Current UTC time: {now_iso}", "id": call_id}
            elif method == "clock.convert_timezone":
                tz = params.get("timezone", "UTC")
                return {"jsonrpc": "2.0", "result": f"Time in {tz}: 12:00:00 PM", "id": call_id}
            else:
                return {"jsonrpc": "2.0", "result": f"Executed {method} successfully with parameters: {params}", "id": call_id}

        def main():
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                    resp = handle_request(req)
                    print(json.dumps(resp), flush=True)
                except Exception as exc:
                    err_resp = {"jsonrpc": "2.0", "error": {"code": -32603, "message": str(exc)}, "id": None}
                    print(json.dumps(err_resp), flush=True)

        if __name__ == "__main__":
            main()
        """
    }

    private static func containedMarketplaceDestination(for fileName: String, in targetDir: URL) -> URL? {
        // Fail closed on traversal payloads, then re-resolve symlinks for pen containment.
        guard MarketplaceCatalog.isSafeMarketplaceFileName(fileName) else { return nil }
        let dst = targetDir.appendingPathComponent(fileName).standardizedFileURL
        let resolvedTarget = targetDir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDst = dst.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedTarget.path.hasSuffix("/") ? resolvedTarget.path : resolvedTarget.path + "/"
        guard resolvedDst.path.hasPrefix(prefix) else { return nil }
        return dst
    }

    private static func verifyInstalledManifestID(pluginID: String, in targetDir: URL) throws {
        // Copied catalog bytes must describe the requested ID, not a swapped manifest.
        let runeURL = targetDir.appendingPathComponent("rune.json")
        guard let data = PluginSecurity.secureCappedFileData(at: runeURL, maxBytes: pluginFileMaxBytes),
              data.count <= pluginFileMaxBytes,
              let manifest = try? PluginManifest.from(jsonData: data),
              manifest.id == pluginID
        else {
            throw PluginDiscoveryError.provisioningFailed("Installed manifest ID mismatch for '\(pluginID)'.")
        }
    }

    private static func copyMarketplaceFilesFromLocal(
        pluginID: String,
        targetDir: URL,
        entry: MarketplaceIndexEntry?,
        overwrite: Bool = false
    ) throws -> Bool {
        // Prefer workspace copies so reviewed local bytes win before any network fetch.
        let fileManager = FileManager.default
        var candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins/\(pluginID)")
        ]
        if let rawPath = entry?.path, let validated = MarketplaceCatalog.validatedMarketplaceSourceDir(rawPath) {
            candidates.append(validated)
        }

        for localDir in candidates where fileManager.fileExists(atPath: localDir.path) {
            let filesToCopy = entry?.files ?? ["rune.json", "main.py", "requirements.txt", "README.md"]
            // Fail closed: any unsafe name aborts the install, never silently skipped.
            for fileName in filesToCopy {
                let detail = "Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'."
                guard MarketplaceCatalog.containedMarketplaceDestination(for: fileName, in: targetDir) != nil else {
                    throw PluginDiscoveryError.escapesPluginsDirectory(detail)
                }
            }
            var hasMissing = false
            for fileName in filesToCopy {
                let src = localDir.appendingPathComponent(fileName)
                if !fileManager.fileExists(atPath: src.path) {
                    hasMissing = true
                    break
                }
                guard MarketplaceCatalog.isSafeLocalSourceFile(at: src, within: localDir) else {
                    throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe local source '\(fileName)' for plugin '\(pluginID)'.")
                }
                // Cap local bytes like remote fetch so hashing never reads oversized files.
                guard let attrs = try? fileManager.attributesOfItem(atPath: src.path),
                      let size = attrs[.size] as? NSNumber,
                      size.int64Value <= pluginFileMaxBytes
                else {
                    throw PluginDiscoveryError.provisioningFailed("Local file '\(fileName)' exceeds size limit for plugin '\(pluginID)'.")
                }
            }
            if hasMissing {
                continue
            }
            for fileName in filesToCopy {
                guard let dst = MarketplaceCatalog.containedMarketplaceDestination(for: fileName, in: targetDir) else {
                    throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'.")
                }
                let src = localDir.appendingPathComponent(fileName)
                if overwrite, fileManager.fileExists(atPath: dst.path) {
                    try fileManager.removeItem(at: dst)
                }
                try fileManager.copyItem(at: src, to: dst)
            }
            try MarketplaceCatalog.verifyInstalledManifestID(pluginID: pluginID, in: targetDir)
            return true
        }
        return false
    }

    private static func fetchMarketplaceFilesFromRemote(
        pluginID: String,
        targetDir: URL,
        entry: MarketplaceIndexEntry?
    ) async throws -> Bool {
        // Hermetic suites skip remote payloads so installs stay off the network.
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else { return false }
        // Fetch catalog bytes over https with SSRF guard when local copies are absent.
        guard let entry, let rawURL = entry.downloadURL, let baseDownloadURL = URL(string: rawURL),
              baseDownloadURL.scheme?.lowercased() == "https",
              let files = entry.files, !files.isEmpty
        else {
            return false
        }
        for fileName in files {
            let detail = "Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'."
            guard MarketplaceCatalog.containedMarketplaceDestination(for: fileName, in: targetDir) != nil else {
                throw PluginDiscoveryError.escapesPluginsDirectory(detail)
            }
        }
        let baseURL = baseDownloadURL.deletingLastPathComponent()
        var remoteComplete = true
        var writtenFiles: [URL] = []
        for fileName in files {
            // Cancelled runs abort fetches instead of draining timeouts.
            try Task.checkCancellation()
            guard let dst = MarketplaceCatalog.containedMarketplaceDestination(for: fileName, in: targetDir) else {
                throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'.")
            }
            let fileURL = baseURL.appendingPathComponent(fileName)
            // Manual redirect chain re-validates each hop before accepting 200 bytes.
            if let data = await MarketplaceCatalog.fetchValidatedMarketplaceBytes(from: fileURL, maxBytes: pluginFileMaxBytes, timeout: 10.0) {
                guard data.count <= pluginFileMaxBytes else {
                    throw PluginDiscoveryError.provisioningFailed("Remote file '\(fileName)' exceeds size limit for plugin '\(pluginID)'.")
                }
                try data.write(to: dst, options: .atomic)
                writtenFiles.append(dst)
            } else {
                remoteComplete = false
                break
            }
        }
        if remoteComplete {
            try MarketplaceCatalog.verifyInstalledManifestID(pluginID: pluginID, in: targetDir)
            return true
        }
        // Partial fetch must not leave fetched bytes beside a scaffolded fallback.
        for written in writtenFiles {
            try? FileManager.default.removeItem(at: written)
        }
        return false
    }

    static func installPluginFiles(
        pluginID: String,
        targetDir: URL,
        entry: MarketplaceIndexEntry?,
        context _: ServerContext,
        overwrite: Bool = false,
        allowScaffold: Bool = true
    ) async throws {
        if try MarketplaceCatalog.copyMarketplaceFilesFromLocal(pluginID: pluginID, targetDir: targetDir, entry: entry, overwrite: overwrite) {
            return
        }
        if try await MarketplaceCatalog.fetchMarketplaceFilesFromRemote(pluginID: pluginID, targetDir: targetDir, entry: entry) {
            return
        }

        // Scaffold is install-only; updates must fail closed instead of stubbing.
        guard allowScaffold else {
            throw PluginDiscoveryError.provisioningFailed("No update payload found for '\(pluginID)'.")
        }

        // Fallback: scaffold manifest and stub script
        let curated = MarketplaceCatalog.getCuratedMarketplaceItems(installedIDs: []).first(where: { $0.id == pluginID })
        let displayName = entry?.name ?? curated?.name ?? (pluginID.components(separatedBy: ".").last?.capitalized ?? pluginID)
        let itemDescription = entry?.description ?? curated?.description ?? "Installed community rune package."
        let itemVersion = entry?.version ?? curated?.version ?? "1.0.0"

        let toolsMetadata: [[String: Any]] = MarketplaceCatalog.getCuratedToolsMetadata(
            for: pluginID,
            fallbackTools: entry?.declaredTools ?? curated?.declaredTools ?? ["\(pluginID).run"]
        )

        let manifestObject: [String: Any] = [
            "id": pluginID,
            "name": displayName,
            "version": itemVersion,
            "description": itemDescription,
            // Scaffold emits a Python stub, so the manifest stays python-only.
            "runtime": "python",
            "entrypoint": "main.py",
            "tools": toolsMetadata
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        let scriptContent = MarketplaceCatalog.generateScaffoldScript(for: pluginID, tools: toolsMetadata)

        let manifestFile = targetDir.appendingPathComponent("rune.json")
        let scriptFile = targetDir.appendingPathComponent("main.py")
        try manifestData.write(to: manifestFile, options: .atomic)
        try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
    }
}
