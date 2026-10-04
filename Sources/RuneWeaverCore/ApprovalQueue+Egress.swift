// Rune Weaver Core — Approval queue egress-host extraction.
//
// Purpose: hold the link-detector plus per-tool egress-host derivation so
// triage badges stay single-sourced while the queue actor keeps its queueing,
// enrichment, and waiter lifecycle. Scope: pure static scanning only (link
// URLs, URL-alias hosts, command-text hosts, schemeless fallback); queue
// state and decisions stay with the actor. Architectural role: focused helper
// backing `ApprovalQueue` keeping the actor body within the type-length
// budget; bash and desktop screening route through here so the detector shape
// cannot drift between call sites.

import Foundation

// MARK: - ApprovalQueue Egress Host Extraction

extension ApprovalQueue {
    /// Extracts every explicit HTTP/HTTPS URL present in free text.
    ///
    /// Single owner of link-detector scanning for egress triage: bash and
    /// desktop screening route through here so the detector shape cannot
    /// drift between call sites. Schemeless hosts are out of scope here;
    /// `extractEgressHost` layers those per tool below.
    /// - Parameter text: Command or typed text to scan.
    /// - Returns: Absolute HTTP/HTTPS URL strings in match order.
    public static func extractLinkURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let nsString = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match in
            guard let matchURL = match.url,
                  let scheme = matchURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return matchURL.absoluteString
        }
    }

    /// Builds and enqueues a request for a tool call.
    /// Extracts any target egress host from the tool arguments if applicable.
    ///
    /// Per-tool scoping keeps unrelated keys from over-extracting: URL-bearing
    /// tools read only their URL aliases, `bash.exec` reads its command
    /// (including schemeless `curl example.com` spellings the link detector
    /// misses), and `desktop.action` reads typed `actions[].text`. Unknown
    /// tools fall back to the broad pass so a new egress-bearing tool still
    /// surfaces a host for triage instead of parking without a badge.
    ///
    /// Single-host triage limit: this returns the first host only while
    /// enforcement screens every host in the batch, so a multi-host batch
    /// badges its first host and cannot approve the whole batch on one badge;
    /// unifying multi-host badging remains a tracked follow-up.
    public static func extractEgressHost(toolName: String, argumentsJSON: String) -> String? {
        extractAllEgressHosts(toolName: toolName, argumentsJSON: argumentsJSON).first
    }

    /// Extracts every egress host in a tool call, in first-seen order.
    ///
    /// Single owner with `extractEgressHost` for detector shape: badge callers
    /// take the first element while enforcement callers screen each element
    /// with per-host dedupe, so triage and screening cannot drift on which
    /// hosts a command names.
    /// - Parameters:
    ///   - toolName: Tool name selecting the scoped extraction.
    ///   - argumentsJSON: Raw tool arguments document.
    /// - Returns: Hosts in first-seen order, without duplicates.
    public static func extractAllEgressHosts(toolName: String, argumentsJSON: String) -> [String] {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        switch toolName {
        case "bash.exec":
            guard let cmd = dict["command"] as? String else { return [] }
            return allHostsFromCommandText(cmd)
        case "desktop.action":
            guard let actions = dict["actions"] as? [[String: Any]] else { return [] }
            var hosts: [String] = []
            var seen = Set<String>()
            for action in actions {
                guard let text = action["text"] as? String else { continue }
                for host in allHostsFromCommandText(text) {
                    let canonical = host.lowercased()
                    guard !seen.contains(canonical) else { continue }
                    seen.insert(canonical)
                    hosts.append(host)
                }
            }
            return hosts
        case "api.request", "web.fetch", "browser.navigate", "browser.act", "web.search":
            guard let host = hostFromURLAliases(dict) else { return [] }
            return [host]
        default:
            var hosts: [String] = []
            var seen = Set<String>()
            func appendUnique(_ host: String) {
                let canonical = host.lowercased()
                guard !seen.contains(canonical) else { return }
                seen.insert(canonical)
                hosts.append(host)
            }
            if let host = hostFromURLAliases(dict) {
                appendUnique(host)
            }
            var textCandidates: [String] = []
            if let cmd = dict["command"] as? String {
                textCandidates.append(cmd)
            }
            if let actions = dict["actions"] as? [[String: Any]] {
                for action in actions {
                    if let text = action["text"] as? String {
                        textCandidates.append(text)
                    }
                }
            }
            for text in textCandidates {
                for host in allHostsFromCommandText(text) {
                    appendUnique(host)
                }
            }
            return hosts
        }
    }

    /// Reads the first URL-alias key carrying an absolute or bare host value.
    private static func hostFromURLAliases(_ dict: [String: Any]) -> String? {
        for key in ["url", "page", "page_url", "pageUrl", "uri", "link"] {
            guard let raw = dict[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let parsed = URL(string: trimmed), let host = parsed.host, !host.isEmpty {
                return host
            }
            // A bare `example.com/path` value carries no scheme for the URL
            // parser, so retry against an assumed https origin before giving
            // up: triage must still badge the host instead of parking blind.
            if !trimmed.contains(" "), !trimmed.contains("\t"),
               let assumed = URL(string: "https://" + trimmed),
               let host = assumed.host, !host.isEmpty,
               trimmed.contains(".")
            {
                return host
            }
        }
        return nil
    }

    /// Extracts every egress host from command or typed text, in first-seen order.
    ///
    /// Links first (detector order), then every schemeless bare host the
    /// detector misses, so `curl example.com && curl evil.com` surfaces both
    /// instead of screening only the first.
    /// - Parameter text: Command or typed text to scan.
    /// - Returns: Hosts in first-seen order, without duplicates.
    private static func allHostsFromCommandText(_ text: String) -> [String] {
        var hosts: [String] = []
        var seen = Set<String>()
        for rawURL in extractLinkURLs(from: text) {
            guard let host = URL(string: rawURL)?.host, !host.isEmpty else { continue }
            let canonical = host.lowercased()
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            hosts.append(host)
        }
        for bare in extractAllSchemelessHosts(in: text) {
            let canonical = bare.lowercased()
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            hosts.append(bare)
        }
        return hosts
    }

    /// Finds every bare dotted host or IPv4 literal in shell text.
    ///
    /// Loops all regex matches (not just the first) so a multi-host command
    /// cannot screen only its first schemeless host while the second executes
    /// unscreened. Conservative by design: dotted names require a two-letter
    /// alphabetic tail (or a quad address), so prose like `version 2.0` never
    /// badges while `curl example.com` and `ping 10.0.0.1` still surface.
    /// - Parameter text: Command or typed text to scan.
    /// - Returns: Bare hosts in match order, without duplicates.
    public static func extractAllSchemelessHosts(in text: String) -> [String] {
        let pattern = #"\b(?:((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,})|(\d{1,3}(?:\.\d{1,3}){3}))(?::\d+)?(?:/[^\s]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)
        var hosts: [String] = []
        var seen = Set<String>()
        for match in matches {
            var candidate: String?
            for group in [1, 2] {
                let groupRange = match.range(at: group)
                guard groupRange.location != NSNotFound else { continue }
                let segment = nsText.substring(with: groupRange)
                guard !segment.isEmpty else { continue }
                if group == 2 {
                    let octets = segment.split(separator: ".").compactMap { Int($0) }
                    guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else { continue }
                }
                candidate = segment
                break
            }
            guard let host = candidate else { continue }
            let canonical = host.lowercased()
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            hosts.append(host)
        }
        return hosts
    }
}
