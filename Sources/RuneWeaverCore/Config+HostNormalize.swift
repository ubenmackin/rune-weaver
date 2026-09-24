// Rune Weaver Core — Host normalization and allowlist dedupe for the server endpoint.
//
// Single-sourced Host comparison semantics shared by the Host gate, the settings
// update path, file-load validation, and the boot health snapshot: trim plus
// lowercase plus bracketed-IPv6 plus port-strip normalization with first-seen
// dedupe and IPv6 bracketed/bare expansion, dropping widening shapes fail-closed.

import Foundation

// MARK: - ServerEndpointConfig Host Normalization

// swiftformat:disable extensionAccessControl

extension ServerEndpointConfig {
    /// Normalizes one Host value to the compared form.
    ///
    /// Single source of truth for trim plus lowercase plus bracketed-IPv6 plus
    /// port-strip normalization shared by the Host gate, the settings PUT, and
    /// file-load validation so stored allowlist entries and inbound Host headers
    /// compare under identical semantics. A bracketed literal strips only for
    /// an empty suffix or a colon plus numeric port (`[::1]`, `[::1]:8082`);
    /// any other trailing shape stays verbatim so `[::1]evil` never truncates
    /// to an allowlisted literal. An unbracketed `host:port` strips only for
    /// an empty or numeric port (`example.com:8082`); any other suffix stays
    /// verbatim so `evil.com:evil` never truncates to an allowlisted host.
    /// - Parameter entry: Raw Host header value or configured entry.
    /// - Returns: Lowercased, port-stripped host.
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
            // A suffix strips only for an empty or numeric port, mirroring the
            // bracketed rule above so `evil.com:evil` stays verbatim instead
            // of truncating to an allowlisted host. An empty suffix satisfies
            // allSatisfy, so `example.com:` still strips.
            let suffix = trimmed[trimmed.index(after: colonIndex)...]
            if suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                return String(trimmed[..<colonIndex])
            }
            return trimmed
        }
        return trimmed
    }

    /// Dedupes normalized Host entries preserving first-seen order plus IPv6 expansion.
    ///
    /// Raw-input entry point for file-load decoding and the settings PUT: trim
    /// plus lowercase plus port-strip plus dedupe so stored allowlists compare
    /// under identical semantics instead of diverging on casing or `:port`
    /// spellings. Widening shapes (scheme, wildcards, CIDR, bare `*`,
    /// unbalanced or non-IPv6 brackets, trailing dot) drop fail-closed through
    /// `RuneWeaverConfig.validateAllowedHosts` matching the gate, so a carved
    /// fragment like `http` from `http://evil.com` never allowlists. Empty and
    /// over-long fragments drop, the raw count is capped at `maxAllowedHosts`,
    /// and IPv6 literals store both the bracketed and bare spellings because
    /// clients send either form and the comparison stays exact without
    /// canonicalizing inbound Hosts.
    /// - Parameter hosts: Raw configured entries.
    /// - Returns: Normalized, deduped allowlist with IPv6 counterparts.
    public static func dedupeNormalizedHosts(_ hosts: [String]) -> [String] {
        dedupeHosts(hosts, limitRawCount: true)
    }

    /// Dedupes already-stored boot allowlists without the raw-count prefix cap.
    ///
    /// Boot entry point for the health snapshot (and any re-normalization of
    /// an already-deduped store): the raw count was bounded at write time by
    /// `RuneWeaverConfig.validateAllowedHosts`, so re-applying
    /// `prefix(maxAllowedHosts)` here would truncate an already-expanded
    /// store — 11 IPv6 entries persist as 22 (bracketed plus bare) and must
    /// advertise as 22 instead of being cut back to 20. Shares the same
    /// validation, normalization, and IPv6-expansion semantics as
    /// `dedupeNormalizedHosts`; only the raw-count prefix is skipped.
    /// - Parameter hosts: Already-stored boot allowlist entries.
    /// - Returns: Normalized, deduped allowlist with IPv6 counterparts.
    public static func dedupeNormalizedBootHosts(_ hosts: [String]) -> [String] {
        dedupeHosts(hosts, limitRawCount: false)
    }

    /// Shared dedupe core for raw-input and boot allowlists.
    ///
    /// Keeps validation, normalization, and IPv6-expansion single-sourced so
    /// the file, the PUT, the health snapshot, and the gate cannot drift; the
    /// caller selects only whether the raw-count prefix applies.
    /// - Parameters:
    ///   - hosts: Candidate entries.
    ///   - limitRawCount: True caps the raw scan at `maxAllowedHosts`; false
    ///     scans every entry for already-bounded boot values.
    /// - Returns: Normalized, deduped allowlist with IPv6 counterparts.
    private static func dedupeHosts(_ hosts: [String], limitRawCount: Bool) -> [String] {
        var seen = Set<String>()
        var deduped: [String] = []
        let candidates = limitRawCount ? Array(hosts.prefix(maxAllowedHosts)) : hosts
        deduped.reserveCapacity(min(candidates.count * 2, maxAllowedHosts * 4))
        for entry in candidates {
            // Drop widening shapes matching the gate instead of allowlisting a
            // carved fragment; file-load and the PUT validate the raw entries
            // upfront so invalid values still throw there instead of silently
            // dropping.
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
