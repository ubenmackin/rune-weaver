// Rune Weaver Tools — SSRF parsing façade over the shared Core classification.

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
