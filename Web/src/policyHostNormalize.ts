// Rune Weaver Dashboard — Shared host normalization plus wildcard and TOML guards.
//
// Purpose: Single source for host canonicalization, wildcard-shape classification,
// and TOML-breaking scalar detection so the binding preview, the binding
// validation helpers, the policy pane, and the binding modal cannot drift on
// what a host means. Trimming, lowercasing, bracket stripping, zone folding,
// and trailing-dot dropping live here once; the wildcard edge mirrors the
// engine AllowedOriginPattern leading-edge contract; the TOML guard mirrors the
// store containsTOMLBreakingScalar alphabet exactly.
// Scope: Pure string helpers only — canonical host forms, numeric IP folding,
// wildcard classification, and TOML-breaking detection. Network allowlist
// coverage, binding Decisions, Keychain state, and TOML persistence stay with
// their owners.
// Architectural role: Shared pure helpers imported by the preview, validation,
// pane, and modal layers, keeping client verdicts honest with the egress
// supervisor without duplicating its enforcement or touching the network.

// Lowercases, strips brackets and zones, and drops trailing dots for network
// comparison so `API.Example.COM.` matches its stored form. Single owner for
// the trim/lowercase/bracket/zone/dot rule previously duplicated across the
// validation and preview layers.
export function canonicalHostLower(host: string): string {
  let cleaned = (host ?? "").trim().toLowerCase();
  if (cleaned.startsWith("[") && cleaned.endsWith("]") && cleaned.length >= 2) {
    cleaned = cleaned.slice(1, -1).trim();
  }
  const percent = cleaned.indexOf("%");
  if (percent !== -1) cleaned = cleaned.slice(0, percent);
  while (cleaned.endsWith(".") && cleaned.length > 1) cleaned = cleaned.slice(0, -1);
  return cleaned.trim();
}

// Parses one numeric IPv4 part with decimal, octal, and hex spellings so
// `0x7f`, `0177`, and `127` converge before range checks.
export function parseIPv4Part(part: string): number | null {
  if (!part) return null;
  if (/^0x[0-9a-f]+$/i.test(part)) {
    const value = parseInt(part, 16);
    return Number.isSafeInteger(value) ? value : null;
  }
  if (/^0[0-7]+$/.test(part) && part.length > 1) {
    const value = parseInt(part, 8);
    return Number.isSafeInteger(value) ? value : null;
  }
  if (/^[0-9]+$/.test(part)) {
    const value = parseInt(part, 10);
    return Number.isSafeInteger(value) ? value : null;
  }
  return null;
}

// Canonicalizes 1-4 part IPv4 spellings to dotted decimal, mirroring the
// engine resolver-number expansion so integer and short forms classify with
// their dotted twin instead of reading as a public name.
export function canonicalIPv4String(cleaned: string): string | null {
  if (!/^[0-9xXa-fA-F.]+$/.test(cleaned)) return null;
  const parts = cleaned.split(".");
  if (parts.length < 1 || parts.length > 4) return null;
  const values: number[] = [];
  for (const part of parts) {
    const parsed = parseIPv4Part(part);
    if (parsed === null || parsed < 0) return null;
    values.push(parsed);
  }
  let octets: [number, number, number, number] | null = null;
  if (values.length === 1) {
    const value = values[0];
    if (value > 0xffffffff) return null;
    octets = [
      (value >>> 24) & 0xff,
      (value >>> 16) & 0xff,
      (value >>> 8) & 0xff,
      value & 0xff,
    ];
  } else if (values.length === 2) {
    if (values[0] > 255 || values[1] > 0xffffff) return null;
    const second = values[1];
    octets = [
      values[0],
      (second >>> 16) & 0xff,
      (second >>> 8) & 0xff,
      second & 0xff,
    ];
  } else if (values.length === 3) {
    if (values[0] > 255 || values[1] > 255 || values[2] > 0xffff) return null;
    const third = values[2];
    octets = [values[0], values[1], (third >>> 8) & 0xff, third & 0xff];
  } else {
    for (const value of values) if (value > 255) return null;
    octets = [values[0], values[1], values[2], values[3]];
  }
  return octets.join(".");
}

// Folds pure IPv6 hextets to minimal lowercase hex, expanding `::` to the
// full eight groups so compressed and expanded spellings compare equally.
export function normalizeIPv6Hextets(cleaned: string): string | null {
  if (!/^[0-9a-f:]+$/i.test(cleaned)) return null;
  if (cleaned.split("::").length > 2) return null;
  let groups: number[] | null = null;
  if (cleaned.includes("::")) {
    const [left, right] = cleaned.split("::");
    const leftParts = left ? left.split(":") : [];
    const rightParts = right ? right.split(":") : [];
    for (const part of [...leftParts, ...rightParts]) {
      if (!/^[0-9a-f]{1,4}$/i.test(part)) return null;
    }
    const missing = 8 - (leftParts.length + rightParts.length);
    if (missing < 0) return null;
    const leftNums = leftParts.map((part) => parseInt(part, 16));
    const rightNums = rightParts.map((part) => parseInt(part, 16));
    groups = [...leftNums, ...Array(missing).fill(0), ...rightNums];
  } else {
    const parts = cleaned.split(":");
    if (parts.length !== 8) return null;
    groups = [];
    for (const part of parts) {
      if (!/^[0-9a-f]{1,4}$/i.test(part)) return null;
      groups.push(parseInt(part, 16));
    }
  }
  if (!groups || groups.length !== 8) return null;
  return groups.map((value) => value.toString(16)).join(":");
}

// Normalizes a dotted-tail IPv6 literal by folding its IPv4 tail first, so
// `::0.0.0.1` decides like its `::1` twin instead of reading as a plain name.
export function normalizeMixedIPv6(cleaned: string): string | null {
  const lastColon = cleaned.lastIndexOf(":");
  if (lastColon === -1) return null;
  const head = cleaned.slice(0, lastColon);
  const tail = cleaned.slice(lastColon + 1);
  if (!tail.includes(".")) return null;
  const canonicalTail = canonicalIPv4String(tail);
  if (canonicalTail === null) return null;
  const tailParts = canonicalTail.split(".").map(Number);
  const high = (tailParts[0] * 256 + tailParts[1]).toString(16);
  const low = (tailParts[2] * 256 + tailParts[3]).toString(16);
  const combined = head ? `${head}:${high}:${low}` : `${high}:${low}`;
  return normalizeIPv6Hextets(combined);
}

// Normalizes a URL host for binding comparison. Dotted numeric spellings
// converge on canonical octets and IPv6 hextets fold to minimal hex so casing,
// trailing dots, and alternate numeric spellings agree; unproven forms stay
// distinct and fail closed via mismatch rather than laundering onto a tail.
export function normalizedHost(host: string): string {
  const cleaned = canonicalHostLower(host);
  if (!cleaned) return "";
  // Dotted-colon mixes collapse only on a proven IPv4 tail; otherwise the
  // spelling stays distinct so an unverified prefix cannot claim an allowlist.
  if (cleaned.includes(":") && cleaned.includes(".")) {
    const tailNormalized = normalizeMixedIPv6(cleaned);
    if (tailNormalized !== null) return tailNormalized;
    return cleaned;
  }
  const ipv4 = canonicalIPv4String(cleaned);
  if (ipv4 !== null) return ipv4;
  if (cleaned.includes(":") && !cleaned.includes(".")) {
    const ipv6 = normalizeIPv6Hextets(cleaned);
    if (ipv6 !== null) return ipv6;
  }
  return cleaned;
}

export type WildcardClassification =
  | "none"
  | "leading"
  | "trailing"
  | "invalidShape"
  | "invalidSuffix"
  | "invalidStem";

// Classifies the wildcard shape of a lowercased pattern. Exactly one exclusive
// edge (`*.` or `.*`) with a named remainder is meaningful; every other star
// shape, glob syntax, or port qualifier refuses so a typo fails closed.
// Mirrors the engine AllowedOriginPattern.classifyWildcard leading-edge
// contract so the pane, modal, and preview share one shape verdict.
export function classifyWildcard(lowered: string): WildcardClassification {
  const starCount = lowered.split("").filter((ch) => ch === "*").length;
  if (starCount === 0) return "none";
  if (lowered.includes("?") || lowered.includes("[") || lowered.includes("]")) {
    return "invalidShape";
  }
  if (lowered.includes(":")) return "invalidShape";
  const hasLeading = lowered.startsWith("*.");
  const hasTrailing = lowered.endsWith(".*");
  if (!(starCount === 1 && hasLeading !== hasTrailing)) return "invalidShape";
  if (hasLeading) {
    const bare = lowered.slice(2);
    if (!bare || bare.includes("*")) return "invalidSuffix";
    return "leading";
  }
  const stem = lowered.slice(0, -2);
  if (!stem || stem.includes("*")) return "invalidStem";
  return "trailing";
}

// Whether policy text carries scalars a TOML basic string must escape: the
// double quote, C0 controls, and DEL. Mirrors the store
// containsTOMLBreakingScalar alphabet exactly — only `"` breaks quoting, so
// single quotes and backticks stay allowed and every layer refuses the same
// bytes instead of keeping parallel copies that could drift.
export function containsTOMLBreakingScalar(value: string): boolean {
  const text = value ?? "";
  if (text.includes('"')) return true;
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0;
    if ((code >= 0 && code <= 31) || code === 127) return true;
  }
  return false;
}

// Coerces an array-or-set binding list into a plain string array without
// mutating the caller, so DTO sets and modal arrays probe identically.
// Single owner for the array-or-set coercion previously duplicated across the
// preview and validation layers; non-string entries drop so a drifted payload
// cannot smuggle a non-string into matching.
export function toStringList(
  value: ReadonlyArray<string> | ReadonlySet<string> | unknown,
): string[] {
  if (value instanceof Set) return [...value].filter((entry): entry is string => typeof entry === "string");
  if (Array.isArray(value)) return value.filter((entry): entry is string => typeof entry === "string");
  return [];
}

// Single owner for textarea list parsing: blank lines drop so an accidental
// newline never becomes a stored entry, while trimming keeps the editor and
// the supervisor comparison in agreement. Both hosts and prefixes share this
// rule so the two fields cannot drift apart; callers apply case folding
// (domains lower, hosts as-is) on top of this split/trim/filter base.
export function parseTrimmedLines(text: string): string[] {
  return (text ?? "")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

// Best-effort IPv4 numeric value for confinement checks, accepting decimal,
// octal, and hex spellings plus 1-4 part forms so `2130706433` refuses like
// `127.0.0.1` instead of reading as a public name. Delegates to
// canonicalHostLower plus canonicalIPv4String so alternate spellings,
// casing, and all trailing dots converge before range checks instead of
// keeping a parallel parser that could drift from the shared owner.
export function ipv4NumericValue(host: string): number | null {
  const cleaned = canonicalHostLower(host ?? "");
  if (!cleaned) return null;
  const canonical = canonicalIPv4String(cleaned);
  if (canonical === null) return null;
  const octets = canonical.split(".").map(Number);
  if (octets.length !== 4) return null;
  return (((octets[0] * 256 + octets[1]) * 256 + octets[2]) * 256 + octets[3]) >>> 0;
}

// Whether a literal IPv4 value sits in a range bindings can never target.
// Mirrors the engine SensitiveAddressRanges.isSensitiveIPv4Value table exactly
// (loopback 127/8, unspecified 0/8, link-local 169.254/16, private RFC 1918,
// shared 100.64/10, 192.0.0/24, TEST-NET-1 192.0.2/24, deprecated 6to4 relay
// 192.88.99/24, benchmarking 198.18/15, TEST-NET-2 198.51.100/24, TEST-NET-3
// 203.0.113/24, multicast 224/4, reserved 240/4) so the client refuses what
// the server refuses instead of allowing a subset. Client preview only: the
// server remains authoritative and the egress supervisor plus storage-boundary
// invariants enforce this same table on every write.
export function isSensitiveIPv4Value(value: number): boolean {
  const v = (value >>> 0);
  if (((v & 0xff000000) >>> 0) === 0x7f000000) return true;
  if (((v & 0xff000000) >>> 0) === 0x00000000) return true;
  if (((v & 0xffff0000) >>> 0) === 0xa9fe0000) return true;
  if (((v & 0xff000000) >>> 0) === 0x0a000000) return true;
  if (((v & 0xfff00000) >>> 0) === 0xac100000) return true;
  if (((v & 0xffff0000) >>> 0) === 0xc0a80000) return true;
  if (((v & 0xffc00000) >>> 0) === 0x64400000) return true;
  if (((v & 0xffffff00) >>> 0) === 0xc0000000) return true;
  if (((v & 0xffffff00) >>> 0) === 0xc0000200) return true;
  if (((v & 0xffffff00) >>> 0) === 0xc0586300) return true;
  if (((v & 0xfffe0000) >>> 0) === 0xc6120000) return true;
  if (((v & 0xffffff00) >>> 0) === 0xc6336400) return true;
  if (((v & 0xffffff00) >>> 0) === 0xcb007100) return true;
  if (((v & 0xf0000000) >>> 0) === 0xe0000000) return true;
  if (((v & 0xf0000000) >>> 0) === 0xf0000000) return true;
  return false;
}
