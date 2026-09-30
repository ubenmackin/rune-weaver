// Rune Weaver Tools — SSRF parsing façade over the shared Core classification.
//
// Purpose: keep the SSRF guard's established helper names while the parser and
// sensitive-range table live in `RuneWeaverCore`, so the egress guard and the
// policy invariant verifier classify hosts from one implementation. Scope:
// name aliases only — no parsing or range logic lives here. Architectural
// role: binds the Tools-side call sites to the shared Core layer; any new
// parsing or classification behavior belongs in the Core file, never here.

import RuneWeaverCore

/// Tools-side name for the shared IPv4/IPv6 parsing helpers.
typealias ApiIPv4Parsing = SensitiveAddressParsing

/// Tools-side name for the shared host normalization and origin helpers.
typealias ApiSSRFOrigin = SensitiveAddressNormalization

/// Tools-side name for the shared sensitive-range table.
typealias ApiSSRFAddresses = SensitiveAddressRanges

/// Parsed IPv4 octets re-exported so existing Tools consumers keep the type
/// name they used before the helper moved to the shared Core layer.
public typealias IPv4Octets = RuneWeaverCore.IPv4Octets
