// Rune Weaver Core — Host normalization and allowlist dedupe for the server endpoint.

import Foundation

// MARK: - ServerEndpointConfig Host Normalization

// swiftformat:disable extensionAccessControl

extension ServerEndpointConfig {
    /// Normalizes one Host value to the compared form.
    public static func normalizeHost(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("[") {
            if let closingBracketIndex = trimmed.firstIndex(of: "]") {
                let after = trimmed[trimmed.index(after: closingBracketIndex)...]
                if after.isEmpty {
                    return String(trimmed[...closingBracketIndex])
                }
                if after.hasPrefix(":") {
                    let portPart = after.dropFirst()
                    if !portPart.isEmpty, portPart.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                        return String(trimmed[...closingBracketIndex])
                    }
                }
                return trimmed
            }
            return trimmed
        }
        // Multiple colons with no brackets mark an unbracketed IPv6 literal,
        // which keeps its colons instead of being mistaken for host:port.
        if trimmed.filter({ $0 == ":" }).count > 1 {
            return trimmed
        }
        if let colonIndex = trimmed.firstIndex(of: ":") {
            // Preserve the carved fragment for scheme inputs (`http://...` ->
            // `http`) so the pinned parity fixtures stay stable; validation
            // drops these fail-closed before any allowlist stores them.
            if trimmed.contains("://") {
                return String(trimmed[..<colonIndex])
            }
            // A suffix strips only for an empty or numeric port, mirroring the bracketed rule above
            // so `evil.com:evil` stays verbatim instead of truncating to an allowlisted host.
            let suffix = trimmed[trimmed.index(after: colonIndex)...]
            if suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                return String(trimmed[..<colonIndex])
            }
            return trimmed
        }
        return trimmed
    }

    /// Dedupes normalized Host entries preserving first-seen order plus IPv6 expansion.
    public static func dedupeNormalizedHosts(_ hosts: [String]) -> [String] {
        dedupeHosts(hosts, limitRawCount: true)
    }

    /// Dedupes already-stored boot allowlists without the raw-count prefix cap.
    public static func dedupeNormalizedBootHosts(_ hosts: [String]) -> [String] {
        dedupeHosts(hosts, limitRawCount: false)
    }

    /// Shared dedupe core for raw-input and boot allowlists.
    private static func dedupeHosts(_ hosts: [String], limitRawCount: Bool) -> [String] {
        var seen = Set<String>()
        var deduped: [String] = []
        let candidates = limitRawCount ? Array(hosts.prefix(maxAllowedHosts)) : hosts
        deduped.reserveCapacity(min(candidates.count * 2, maxAllowedHosts * 4))
        for entry in candidates {
            // Drop widening shapes matching the gate instead of allowlisting a carved fragment;
            // file-load and the PUT validate the raw entries upfront so invalid values still throw
            // there instead of silently dropping.
            guard (try? RuneWeaverConfig.validateAllowedHosts([entry])) != nil else {
                continue
            }
            let normalized = normalizeHost(entry)
            guard !normalized.isEmpty else { continue }
            guard normalized.count <= maxAllowedHostLength else { continue }
            if seen.insert(normalized).inserted {
                deduped.append(normalized)
            }
            // Clients send IPv6 literals bracketed or bare, so both spellings
            // are stored to keep the comparison exact without canonicalizing
            // inbound Hosts away from their compared form.
            if normalized.contains(":") {
                if normalized.hasPrefix("["), normalized.hasSuffix("]"), normalized.count >= 2 {
                    let bare = String(normalized.dropFirst().dropLast())
                    if !bare.isEmpty, bare.count <= maxAllowedHostLength, seen.insert(bare).inserted {
                        deduped.append(bare)
                    }
                } else if !normalized.hasPrefix("[") {
                    let bracketed = "[\(normalized)]"
                    if bracketed.count <= maxAllowedHostLength, seen.insert(bracketed).inserted {
                        deduped.append(bracketed)
                    }
                }
            }
        }
        return deduped
    }
}
