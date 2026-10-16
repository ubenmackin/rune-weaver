// Rune Weaver Dashboard — Credential binding preview decision for the policy editor.

import { classifyWildcard, normalizedHost, toStringList } from "./policyHostNormalize";

// Binding shape accepted from the policy DTO or the modal draft. Both camelCase and
// snake_case spellings are honored so callers never need to convert before probing.
export interface CredentialBindingInput {
  allowedHosts?: ReadonlyArray<string> | ReadonlySet<string>;
  allowed_hosts?: ReadonlyArray<string> | ReadonlySet<string>;
  allowedMethods?: ReadonlyArray<string> | ReadonlySet<string>;
  allowed_methods?: ReadonlyArray<string> | ReadonlySet<string>;
  allowedPathPrefixes?: ReadonlyArray<string>;
  allowed_path_prefixes?: ReadonlyArray<string>;
}

// Probe destination. Key names only the refusal wording, never the decision.
export interface BindingProbe {
  host: string;
  method: string;
  path: string;
  key?: string;
}

export function previewBindingDecision(
  binding: CredentialBindingInput | null | undefined,
  probe: BindingProbe,
): string | null;
export function previewBindingDecision(
  binding: CredentialBindingInput | null | undefined,
  host: string,
  method: string,
  path: string,
  key?: string,
): string | null;
export function previewBindingDecision(
  binding: CredentialBindingInput | null | undefined,
  hostOrProbe: string | BindingProbe,
  methodOrUndefined?: string,
  pathOrUndefined?: string,
  keyOrUndefined?: string,
): string | null {
  // Accept both call shapes so the modal probe and unit tests share one gate
  // without converting: a probe object carries host/method/path/key together
  // while positional args mirror the engine denyReason ordering.
  let host = "";
  let method = "";
  let path = "";
  let key = "KEY";
  if (typeof hostOrProbe === "object" && hostOrProbe !== null) {
    host = (hostOrProbe as BindingProbe).host ?? "";
    method = (hostOrProbe as BindingProbe).method ?? "";
    path = (hostOrProbe as BindingProbe).path ?? "";
    const probeKey = (hostOrProbe as BindingProbe).key;
    key = typeof probeKey === "string" && probeKey.trim() ? probeKey.trim() : "KEY";
  } else {
    host = (hostOrProbe as string) ?? "";
    method = methodOrUndefined ?? "";
    path = pathOrUndefined ?? "";
    key =
      typeof keyOrUndefined === "string" && keyOrUndefined.trim()
        ? keyOrUndefined.trim()
        : "KEY";
  }
  const displayKey = key;

  const hosts = toStringList(
    binding?.allowedHosts ?? binding?.allowed_hosts ?? [],
  );
  const methods = toStringList(
    binding?.allowedMethods ?? binding?.allowed_methods ?? [],
  );
  const prefixes = toStringList(
    binding?.allowedPathPrefixes ?? binding?.allowed_path_prefixes ?? [],
  );

  // Resolve the effective route path before any authorization decision. An
  // ambiguous escape spelling refuses rather than guessing, because proxy and
  // origin decoders can disagree on the same bytes.
  const resolved = resolveEffectiveRequestPath(host, path);
  if (resolved.kind === "rejected") {
    return `Credential '${displayKey}' is not authorized for '${host}${path}': ${resolved.reason}.`;
  }
  const effectivePath = resolved.effective;

  // Host check is required: empty hosts authorizes nothing, so an orphaned
  // binding fails closed instead of reading as wildcard.
  if (hosts.length === 0) {
    return `Credential '${displayKey}' has no allowed hosts configured. Add hosts to [credentials.${displayKey}].allowed_hosts in policy.toml.`;
  }
  const canonicalHost = normalizedHost(host);
  const hostAllowed = hosts.some((pattern) =>
    authorizes(canonicalHost, pattern),
  );
  if (!hostAllowed) {
    const allowed = [...hosts].sort().join(", ");
    return `Credential '${displayKey}' is not authorized for host '${host}'. Allowed: ${allowed}.`;
  }

  // Empty methods means Any: only a non-empty set constrains the verb, and the
  // comparison stays case-insensitive so `post` authorizes `POST`.
  if (methods.length > 0) {
    const uppered = method.trim().toUpperCase();
    const methodAllowed = methods.some(
      (entry) => entry.trim().toUpperCase() === uppered,
    );
    if (!methodAllowed) {
      const allowed = [...methods].sort().join(", ");
      return `Credential '${displayKey}' is not authorized for method '${method}' on host '${host}'. Allowed: ${allowed}.`;
    }
  }

  // Empty prefixes means Any: only a non-empty set constrains the route, and
  // the comparison runs over the resolved path so traversal spellings cannot
  // smuggle a prefix match.
  if (prefixes.length > 0) {
    const pathAllowed = prefixes.some((prefix) =>
      effectivePath.startsWith(prefix),
    );
    if (!pathAllowed) {
      const allowed = prefixes.join(", ");
      return `Credential '${displayKey}' is not authorized for path '${effectivePath}' on host '${host}'. Allowed prefixes: ${allowed}.`;
    }
  }

  return null;
}

// Host canonicalization plus wildcard classification plus list coercion live in the shared
// policyHostNormalize owner so the preview and validation layers agree.
function authorizes(canonicalHost: string, pattern: string): boolean {
  const trimmed = (pattern ?? "").trim();
  if (!trimmed) return false;
  const classification = classifyWildcard(trimmed.toLowerCase());
  if (classification === "none") {
    return normalizedHost(trimmed) === canonicalHost;
  }
  if (classification === "leading") {
    const base = normalizedHost(trimmed.slice(2));
    if (!base) return false;
    return canonicalHost === base || canonicalHost.endsWith(`.${base}`);
  }
  return false;
}

// Reason a raw host is ambiguous: an encoded separator or encoded dot. Such
// bytes decode differently across resolvers, so the binding refuses instead
// of authorizing an ambiguous authority.
function encodedHostReason(rawHost: string): string | null {
  const lowered = (rawHost ?? "").toLowerCase();
  if (lowered.includes("%2f") || lowered.includes("%5c")) {
    return "spells a separator as an escape";
  }
  if (lowered.includes("%2e")) return "spells a dot as an escape";
  return null;
}

// Reason a raw path is ambiguous: an encoded or raw separator, or a dot
// segment spelled as an escape. Checked per decoding layer so nested
// encodings are refused rather than smuggled through as opaque literals.
function encodedSpellingReason(raw: string): string | null {
  const lowered = raw.toLowerCase();
  if (lowered.includes("%2f") || lowered.includes("%5c") || raw.includes("\\")) {
    return "spells a separator as an escape, so its routed destination is ambiguous";
  }
  for (const segment of raw.split("/")) {
    if (!segment || !segment.includes("%")) continue;
    let decoded: string;
    try {
      decoded = decodeURIComponent(segment);
    } catch {
      continue;
    }
    if (decoded === "." || decoded === "..") {
      return "spells a dot segment as an escape, so its routed destination is ambiguous";
    }
  }
  return null;
}

// RFC 3986 section 5.2.4 dot-segment removal over an already-decoded path.
// Literal `.`/`..` normalize identically on every origin server, while encoded
// spellings never reach this step because resolution refuses them first.
function removeDotSegments(path: string): string {
  let input = path;
  let output = "";
  while (input.length > 0) {
    if (input.startsWith("../")) {
      input = input.slice(3);
    } else if (input.startsWith("./")) {
      input = input.slice(2);
    } else if (input.startsWith("/./")) {
      input = input.slice(2);
    } else if (input === "/.") {
      input = "/";
    } else if (input.startsWith("/../")) {
      input = input.slice(3);
      output = removeLastOutputSegment(output);
    } else if (input === "/..") {
      input = "/";
      output = removeLastOutputSegment(output);
    } else if (input === "." || input === "..") {
      input = "";
    } else {
      const rest = input.slice(1);
      const nextSlash = rest.indexOf("/");
      const segmentEnd = nextSlash === -1 ? input.length : nextSlash + 1;
      output += input.slice(0, segmentEnd);
      input = input.slice(segmentEnd);
    }
  }
  return output;
}

// Drops the final output segment per RFC 3986 when `..` climbs above it.
function removeLastOutputSegment(output: string): string {
  let next = output;
  while (next.length > 0 && !next.endsWith("/")) {
    next = next.slice(0, -1);
  }
  if (next.endsWith("/")) next = next.slice(0, -1);
  return next;
}

type EffectiveResolution =
  | { kind: "effective"; effective: string }
  | { kind: "rejected"; reason: string };

// Resolves one raw host plus raw path pair to the route path an origin server uses.
function resolveEffectiveRequestPath(
  host: string,
  rawPath: string,
): EffectiveResolution {
  const hostReason = encodedHostReason(host ?? "");
  if (hostReason) {
    return { kind: "rejected", reason: `host '${host}' ${hostReason}` };
  }
  let current = !rawPath ? "/" : rawPath;
  let layers = 0;
  const maximumDecodeLayers = 4;
  for (;;) {
    const ambiguous = encodedSpellingReason(current);
    if (ambiguous) {
      return { kind: "rejected", reason: `path '${rawPath}' ${ambiguous}` };
    }
    let decoded: string;
    try {
      decoded = decodeURIComponent(current);
    } catch {
      return {
        kind: "rejected",
        reason: `path '${rawPath}' carries malformed percent-encoding`,
      };
    }
    // decodeURIComponent leaves `+` alone and decodes `%25` to `%`, so one call peels exactly one
    // encoding layer and the loop re-checks the next.
    if (decoded === current) break;
    layers += 1;
    if (layers > maximumDecodeLayers) {
      return {
        kind: "rejected",
        reason: `path '${rawPath}' nests percent-encoding too deeply to resolve`,
      };
    }
    current = decoded;
  }
  const effective = removeDotSegments(current);
  return { kind: "effective", effective: effective ? effective : "/" };
}
