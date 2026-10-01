// Rune Weaver Dashboard — Credential binding list helpers for the policy pane.
//
// Purpose: Owns the pure row-level summaries and attention signal behind the
// searchable credentials list, so dozens of bindings stay scannable without
// opening an editor: one binding pairs one key with hosts, methods, and path
// prefixes, and the secret is sent only when all three match. Empty hosts
// means the credential can never be sent while empty methods or prefixes mean
// Any, and every prefix applies to every host in the same binding.
// Scope: Key-shape validation, compact host and scope summaries, and the
// needs-attention verdict (uncovered hosts, empty hosts, field errors) only;
// network allowlist editing, Keychain presence probing, and TOML persistence
// stay with the owning pane and the server.
// Architectural role: Shared pure helpers imported by the credentials list and
// the binding modal for badges, filters, and host-coverage verdicts, mirroring
// the egress supervisor without duplicating its enforcement or touching the
// network.
import { canonicalHostLower, toStringList } from "./policyHostNormalize";

// Binding shape accepted from the policy DTO or the binding modal draft. Both
// snake_case and camelCase spellings are honored so DTO rows and modal drafts
// summarize identically without a conversion step at the call site.
export interface CredentialBindingLike {
  key?: string;
  hosts?: ReadonlyArray<string> | ReadonlySet<string>;
  methods?: ReadonlyArray<string> | ReadonlySet<string>;
  pathPrefixes?: ReadonlyArray<string> | ReadonlySet<string>;
  allowedHosts?: ReadonlyArray<string> | ReadonlySet<string>;
  allowed_hosts?: ReadonlyArray<string> | ReadonlySet<string>;
  allowedMethods?: ReadonlyArray<string> | ReadonlySet<string>;
  allowed_methods?: ReadonlyArray<string> | ReadonlySet<string>;
  allowedPathPrefixes?: ReadonlyArray<string> | ReadonlySet<string>;
  allowed_path_prefixes?: ReadonlyArray<string> | ReadonlySet<string>;
}

// Verbs the binding gate recognizes. Empty stays Any, so summaries render an
// explicit Any label instead of an empty string that could read as unset.
export const BINDING_METHODS = [
  "GET",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "HEAD",
  "OPTIONS",
] as const;

// Whether a raw key is usable as a binding name. Trims first, then enforces
// the surrogate alphabet so Keychain issuance and binding resolution agree;
// key names never carry secret bytes, so only the shape rule is reported.
export function isValidBindingKey(rawKey: string): boolean {
  const key = (rawKey ?? "").trim();
  if (!key || key.length > 256) return false;
  for (const ch of key) {
    const code = ch.codePointAt(0) ?? 0;
    const isUpper = code >= 65 && code <= 90;
    const isLower = code >= 97 && code <= 122;
    const isDigit = code >= 48 && code <= 57;
    if (!(isUpper || isLower || isDigit || ch === "_" || ch === "-" || ch === ".")) {
      return false;
    }
  }
  return true;
}

// Reads the hosts of a binding regardless of spelling, preserving stored
// order so the first host stays stable as the row headline.
function bindingHosts(binding: CredentialBindingLike | null | undefined): string[] {
  if (!binding || typeof binding !== "object") return [];
  const like = binding as Record<string, unknown>;
  return toStringList(
    (like.hosts as ReadonlyArray<string> | undefined) ??
      (like.allowedHosts as ReadonlyArray<string> | undefined) ??
      (like.allowed_hosts as ReadonlyArray<string> | undefined) ??
      [],
  );
}

// Reads the methods of a binding regardless of spelling. Callers normalize
// case, since the gate compares case-insensitively and the editor stores
// uppercased verbs.
function bindingMethods(binding: CredentialBindingLike | null | undefined): string[] {
  if (!binding || typeof binding !== "object") return [];
  const like = binding as Record<string, unknown>;
  return toStringList(
    (like.methods as ReadonlyArray<string> | undefined) ??
      (like.allowedMethods as ReadonlyArray<string> | undefined) ??
      (like.allowed_methods as ReadonlyArray<string> | undefined) ??
      [],
  );
}

// Reads the path prefixes of a binding regardless of spelling. Empty stays
// Any, so summaries render the Any label instead of a blank.
function bindingPrefixes(binding: CredentialBindingLike | null | undefined): string[] {
  if (!binding || typeof binding !== "object") return [];
  const like = binding as Record<string, unknown>;
  return toStringList(
    (like.pathPrefixes as ReadonlyArray<string> | undefined) ??
      (like.allowedPathPrefixes as ReadonlyArray<string> | undefined) ??
      (like.allowed_path_prefixes as ReadonlyArray<string> | undefined) ??
      [],
  );
}

// Compact hosts headline: the first host plus an overflow count. Empty means
// the binding can never send, so the summary names that outcome instead of
// rendering a blank that could read as wildcard.
export function bindingHostsSummary(
  hostsOrBinding: ReadonlyArray<string> | ReadonlySet<string> | CredentialBindingLike | null | undefined,
): string {
  const hosts = Array.isArray(hostsOrBinding) || hostsOrBinding instanceof Set
    ? toStringList(hostsOrBinding as ReadonlyArray<string> | ReadonlySet<string>)
    : bindingHosts(hostsOrBinding as CredentialBindingLike | null | undefined);
  if (hosts.length === 0) return "No hosts — never sent";
  if (hosts.length === 1) return hosts[0];
  return `${hosts[0]} +${hosts.length - 1} more`;
}

// Compact scope headline: methods plus path prefixes in one line. Empty
// methods or prefixes render as Any so the conjunction reads explicitly and
// an unset scope is never mistaken for a narrow one.
export function bindingScopeSummary(
  binding: CredentialBindingLike | null | undefined,
): string {
  const methods = bindingMethods(binding)
    .map((entry) => (entry ?? "").trim().toUpperCase())
    .filter(Boolean)
    .sort();
  const prefixes = bindingPrefixes(binding);
  const methodsLabel = methods.length > 0 ? methods.join(", ") : "Any method";
  const prefixesLabel = prefixes.length > 0 ? prefixes.join(", ") : "Any path";
  return `${methodsLabel} · ${prefixesLabel}`;
}

// Canonicalizes one network domain entry the same way the egress policy does:
// the `*.` edge passes through with a normalized base while every other entry
// normalizes whole, so coverage agrees with enforcement on case and dots.
function canonicalNetworkEntry(entry: string): string {
  const trimmed = (entry ?? "").trim();
  if (trimmed.toLowerCase().startsWith("*.")) {
    return `*.${canonicalHostLower(trimmed.slice(2))}`;
  }
  return canonicalHostLower(trimmed);
}

// Whether one binding host pattern is covered by the network allowlist. Exact
// patterns are covered by an exact entry or a wildcard above them; wildcard
// patterns need a wildcard at or above their base since one exact entry
// cannot cover a whole subtree. Uncovered bindings stay denied at runtime, so
// the list surfaces them before the owner probes.
export function isBindingHostCoveredByNetwork(
  bindingPattern: string,
  allowedDomains: ReadonlyArray<string> | null | undefined,
): boolean {
  const trimmed = (bindingPattern ?? "").trim();
  if (!trimmed) return false;
  const lowered = trimmed.toLowerCase();
  const isWildcard = lowered.startsWith("*.");
  if (isWildcard) {
    const base = canonicalHostLower(trimmed.slice(2));
    if (!base) return false;
    for (const entry of allowedDomains ?? []) {
      const canonical = canonicalNetworkEntry(entry);
      if (!canonical.startsWith("*.")) continue;
      const networkBase = canonical.slice(2);
      if (!networkBase) continue;
      if (base === networkBase || base.endsWith(`.${networkBase}`)) return true;
    }
    return false;
  }
  const canonicalHost = canonicalHostLower(trimmed);
  for (const entry of allowedDomains ?? []) {
    const canonical = canonicalNetworkEntry(entry);
    if (!canonical.startsWith("*.")) {
      if (canonical === canonicalHost) return true;
      continue;
    }
    const networkBase = canonical.slice(2);
    if (!networkBase) continue;
    if (canonicalHost === networkBase || canonicalHost.endsWith(`.${networkBase}`)) {
      return true;
    }
  }
  return false;
}

// Attention verdict for one row. Flags uncovered hosts (would stay denied),
// empty hosts (can never send), and field errors the save gate would refuse
// (key shape, blank entries, unknown methods, unrooted prefixes) so the dot
// marks exactly the rows worth opening.
export interface BindingAttentionResult {
  needsAttention: boolean;
  reasons: string[];
  uncoveredHosts: string[];
}

export function bindingAttention(
  binding: CredentialBindingLike | null | undefined,
  allowedDomains?: ReadonlyArray<string> | null,
): BindingAttentionResult;
export function bindingAttention(
  key: string,
  binding: CredentialBindingLike | null | undefined,
  allowedDomains?: ReadonlyArray<string> | null,
): BindingAttentionResult;
export function bindingAttention(
  keyOrBinding: string | CredentialBindingLike | null | undefined,
  bindingOrDomains?: CredentialBindingLike | ReadonlyArray<string> | null,
  maybeDomains?: ReadonlyArray<string> | null,
): BindingAttentionResult {
  // Accept both call shapes so pane rows (key plus binding) and unit probes
  // (binding carrying its own key) share one gate without converting.
  let key = "";
  let binding: CredentialBindingLike | null | undefined;
  let allowedDomains: ReadonlyArray<string> | null | undefined;
  if (typeof keyOrBinding === "string") {
    key = keyOrBinding;
    binding = (bindingOrDomains as CredentialBindingLike | null | undefined) ?? null;
    allowedDomains = maybeDomains ?? [];
  } else {
    binding = keyOrBinding ?? null;
    allowedDomains = (bindingOrDomains as ReadonlyArray<string> | null | undefined) ?? [];
    const like = (binding ?? {}) as Record<string, unknown>;
    key = typeof like.key === "string" ? (like.key as string) : "";
  }

  const reasons: string[] = [];
  const hosts = bindingHosts(binding);
  const methods = bindingMethods(binding);
  const prefixes = bindingPrefixes(binding);

  // Key shape gates resolution: an unusable name can never match a surrogate,
  // so it needs attention even before host coverage is considered.
  if (!isValidBindingKey(key)) {
    reasons.push(`Key '${key || "(blank)"}' must use only letters, numbers, _, -, . (max 256 characters).`);
  }

  // Empty hosts authorizes nothing, so an orphaned binding fails closed and
  // must read as attention rather than as a quiet wildcard.
  if (hosts.length === 0) {
    reasons.push("Empty hosts means the credential can never be sent.");
  } else {
    for (const host of hosts) {
      if (!(host ?? "").trim()) {
        reasons.push("Hosts must not contain blank entries.");
        break;
      }
    }
  }

  // Unknown verbs never match at runtime yet would read as configured, so the
  // row flags them instead of waiting for a probe to fail.
  for (const method of methods) {
    const uppered = (method ?? "").trim().toUpperCase();
    if (!(BINDING_METHODS as readonly string[]).includes(uppered)) {
      reasons.push(`Method '${method}' must be one of ${BINDING_METHODS.join(", ")}.`);
      break;
    }
  }

  // Prefixes compare verbatim against the resolved route path, so only the
  // leading slash is structural; anything else would never match. Trimmed
  // before the slash check so padded input agrees with the server gate.
  for (const prefix of prefixes) {
    if (!(prefix ?? "").trim() || !(prefix ?? "").trim().startsWith("/")) {
      reasons.push(`Prefix '${prefix}' must start with '/'.`);
      break;
    }
  }

  // Coverage runs last so field errors still surface when the network list is
  // empty; an uncovered host stays denied even when every field is valid.
  const uncoveredHosts = hosts.filter(
    (host) => (host ?? "").trim() && !isBindingHostCoveredByNetwork(host, allowedDomains ?? []),
  );
  if (uncoveredHosts.length > 0) {
    reasons.push(
      `${uncoveredHosts.length} of ${hosts.length} ${hosts.length === 1 ? "host is" : "hosts are"} not in Allowed Domains: ${uncoveredHosts.join(", ")}.`,
    );
  }

  return { needsAttention: reasons.length > 0, reasons, uncoveredHosts };
}
