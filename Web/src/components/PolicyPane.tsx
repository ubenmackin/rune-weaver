// Rune Weaver Dashboard — Declarative security policy pane for policy.toml.
//
// Purpose: Owns the structured network-plus-credentials policy editor as its own
// settings surface. The file governs outbound egress boundaries and per-secret
// credential bindings only; the pane edits that structured shape and never raw
// TOML, so the file and the live supervisor cannot disagree on quoting.
// Scope: Loading the verified snapshot, inline fail-closed editing with field
// errors, and pane-local structured persistence. Keychain writes, network
// allowlist enforcement, and file serialization stay with their owners.
// Architectural role: Settings-adjacent pane rendered outside the shared config
// form, mirroring the indexing policy panel precedent. Writes apply live through
// the shared store with no restart and no filesystem watcher.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { authHeaders, checkSecretStatus } from "../api";
import {
  classifyWildcard,
  containsTOMLBreakingScalar,
  parseTrimmedLines,
} from "../policyHostNormalize";
import {
  BINDING_METHODS,
  bindingAttention,
  bindingHostsSummary,
  bindingScopeSummary,
  isValidBindingKey,
} from "../policyBindingValidation";
import Modal from "./Modal";
import { PolicyBindingModal, validateBindingHostEntry } from "./PolicyBindingModal";
import { CloseIcon, TrashIcon } from "./icons";

// Postures the egress supervisor enforces. Only these two persist; older files
// may still carry a legacy spelling that the engine maps on load, but the pane
// only ever offers the surviving pair.
const POLICY_MODES = ["allowlist_only", "unrestricted"] as const;

interface PolicyNetworkDraft {
  mode: string;
  allowed_domains: string[];
  blocked_domains: string[];
  // Server-owned display-only grants. Never sent on PUT or re-check writes;
  // the engine derives the stored set via classification instead. Optional on
  // the draft so older literals still typecheck; normalize always fills [].
  localExemptions?: string[];
}

interface PolicyBindingDraft {
  allowed_hosts: string[];
  allowed_methods: string[];
  allowed_path_prefixes: string[];
}

interface PolicyDraft {
  version: number;
  network: PolicyNetworkDraft;
  credentials: Record<string, PolicyBindingDraft>;
}

interface PolicyLoadResult {
  policy: PolicyDraft;
  path: string;
  loadedFromDisk: boolean;
  violations: string[];
  localAccess: PolicyLocalAccessReport | null;
}

// Classification report returned alongside a policy write. Granted names the
// exemptions added by the write, removed names grants the write dropped, and
// neverDialable names added entries that persist name-only with no grant.
interface PolicyLocalAccessReport {
  granted: string[];
  removed: string[];
  neverDialable: string[];
}

// Preview diff returned by POST /settings/policy/recheck-local. Added names
// grants the apply would create, removed names grants it would drop,
// unchanged names grants it would keep, and unresolved names entries that
// could not be proven. Every list is sorted. Preview never writes.
interface LocalRecheckPreview {
  added: string[];
  removed: string[];
  unchanged: string[];
  unresolved: string[];
}

// Whether a raw key is usable as a binding name. Delegates to the shared
// validation owner so the pane gate and the list badges agree on the
// surrogate alphabet; only the shape rule is reported since key names never
// carry secret bytes.
function isValidPolicyKey(rawKey: string): boolean {
  return isValidBindingKey(rawKey ?? "");
}

// Whether a stored value would break TOML quoting. Single-sourced through the
// shared containsTOMLBreakingScalar owner mirroring the store alphabet exactly
// (double quote plus C0 controls plus DEL), so the pane and the modal refuse
// the same bytes instead of keeping parallel copies that could drift.
function hasTomlBreakingChars(entry: string): boolean {
  return containsTOMLBreakingScalar(entry ?? "");
}

// Splits multiline domain text into canonical entries. Trimming plus
// lowercasing keeps the editor and the supervisor comparison in agreement,
// while blank lines drop so an accidental newline never becomes an entry
// that could authorize an empty host. Split/trim/filter lives in the shared
// parseTrimmedLines owner so domain, host, and prefix fields cannot drift.
export function parseDomainLines(raw: string): string[] {
  return parseTrimmedLines(raw ?? "").map((line) => line.toLowerCase());
}

// Joins stored domains for the multiline editor. One host per line keeps
// diffs readable and prevents a stray comma from merging two hosts.
export function formatDomainLines(domains: string[]): string {
  const newline = String.fromCharCode(10);
  return (domains ?? []).join(newline);
}

// Whether one domain line could be stored. Only an exact host or a single
// leading star-dot edge authorizes; every other star shape would never match
// at runtime yet would read as allowed, so it refuses here before save.
// Separators, userinfo, fragments, and port suffixes also refuse: a
// canonicalized URL host never carries them, so such an entry could only
// persist and then never authorize.
// Host-shape gate parity:
// This client-side validator intentionally mirrors the server-side host shape gate in
// Sources/RuneWeaverServer/ServerSettingsRoutes.swift (`validateHostEntry` / `validateUnbracketedHostShape`).
// Client validation provides immediate interactive feedback in the UI before network submission,
// while the server enforces the authoritative security boundary. Test suites in PolicyPane.test.tsx
// and SettingsRouteTests.swift pin matching acceptance/rejection vectors to prevent drift.
export function isValidDomainLine(entry: string): boolean {
  const lowered = (entry ?? "").trim().toLowerCase();
  if (!lowered) return false;
  if (hasTomlBreakingChars(entry)) return false;
  const tab = String.fromCharCode(9);
  if (lowered.includes(" ") || lowered.includes(tab)) return false;
  if (lowered.includes(",")) return false;
  if (lowered.includes("?") || lowered.includes("[") || lowered.includes("]")) return false;
  if (
    lowered.includes("/") ||
    lowered.includes("\\") ||
    lowered.includes("@") ||
    lowered.includes("#")
  ) {
    return false;
  }
  // A valid IPv6 literal always carries at least two colons, so a lone colon
  // can only be a port suffix (or another shape DNS never serves).
  if ((lowered.match(/:/g) ?? []).length === 1) return false;
  if (lowered.includes("*")) {
    // Single leading edge only: delegate the star shape to the shared
    // classifyWildcard owner mirroring the server leading-edge contract, so
    // the pane, modal, and preview share one shape verdict. Trailing and
    // malformed shapes refuse here before save.
    if (classifyWildcard(lowered) !== "leading") return false;
    const bare = lowered.slice(2);
    if (!bare) return false;
    if (bare.startsWith(".") || bare.endsWith(".")) return false;
    return true;
  }
  return true;
}

// Mirrors the storage-boundary shadow check: an allow entry that equals or
// covers a blocked entry never opens the host because blocked always wins,
// but the overlap signals a drifted allowlist worth resolving.
export function findEgressShadowWarnings(allowed: string[], blocked: string[]): string[] {
  const warnings: string[] = [];
  const allowedList = allowed ?? [];
  const blockedList = blocked ?? [];
  for (const blockedEntry of blockedList) {
    const loweredBlocked = (blockedEntry ?? "").trim().toLowerCase();
    if (!loweredBlocked) continue;
    for (const allowedEntry of allowedList) {
      const loweredAllowed = (allowedEntry ?? "").trim().toLowerCase();
      if (!loweredAllowed) continue;
      if (loweredAllowed === loweredBlocked) {
        warnings.push(
          "Domain '" + blockedEntry + "' appears in both allowed and blocked lists. Blocked wins " +
            "(blocked_domains takes priority), but the conflict should be resolved.",
        );
      } else if (loweredAllowed.startsWith("*.")) {
        const suffix = loweredAllowed.slice(1);
        const base = loweredAllowed.slice(2);
        if (loweredBlocked.endsWith(suffix) || loweredBlocked === base) {
          warnings.push(
            "Wildcard allowed domain '" + allowedEntry + "' would cover blocked domain '" +
              blockedEntry +
              "'. Blocked wins (blocked_domains takes priority), but the conflict should be resolved.",
          );
        }
      }
    }
  }
  return warnings;
}

// Validates one loaded or edited draft against the fail-closed bounds the
// engine enforces. Returns human-readable problems; empty means saveable. Blank
// domain entries, wildcard shape, TOML-breaking scalars, empty host lists,
// confinement-refused hosts, unknown modes or methods, unrooted prefixes, and
// surrogate-alphabet violations all refuse here so the common rejections become
// inline field errors before a write; the storage-boundary invariants remain
// the final authority over what persists.
function validatePolicyDraft(draft: PolicyDraft | null): string[] {
  if (!draft) return [];
  const problems: string[] = [];
  const mode = (draft.network.mode ?? "").trim();
  if (!(POLICY_MODES as readonly string[]).includes(mode)) {
    problems.push("Mode must be one of " + POLICY_MODES.join(", ") + ".");
  }
  for (const entry of draft.network.allowed_domains ?? []) {
    if (!entry.trim()) {
      problems.push("Allowed domains must not contain blank entries.");
      break;
    }
    if (hasTomlBreakingChars(entry)) {
      problems.push("Allowed domain '" + entry + "' carries characters that would break TOML.");
      break;
    }
    if (!isValidDomainLine(entry)) {
      problems.push("Allowed domain '" + entry + "' is invalid — use an exact host or a single leading '*.example.com' edge.");
      break;
    }
  }
  for (const entry of draft.network.blocked_domains ?? []) {
    if (!entry.trim()) {
      problems.push("Blocked domains must not contain blank entries.");
      break;
    }
    if (hasTomlBreakingChars(entry)) {
      problems.push("Blocked domain '" + entry + "' carries characters that would break TOML.");
      break;
    }
    if (!isValidDomainLine(entry)) {
      problems.push("Blocked domain '" + entry + "' is invalid — use an exact host or a single leading '*.example.com' edge.");
      break;
    }
  }
  for (const [key, binding] of Object.entries(draft.credentials ?? {})) {
    if (!isValidPolicyKey(key)) {
      problems.push("Key '" + key + "' must use only letters, numbers, _, -, . (max 256 characters).");
      continue;
    }
    const hosts = binding.allowed_hosts ?? [];
    if (hosts.length === 0) {
      problems.push("Key '" + key + "' needs at least one host — empty hosts means the credential can never be sent.");
      continue;
    }
    for (const host of hosts) {
      const hostProblem = validateBindingHostEntry(host);
      if (hostProblem) {
        problems.push("Key '" + key + "' has an invalid host: " + hostProblem + ".");
        break;
      }
    }
    for (const method of binding.allowed_methods ?? []) {
      const uppered = (method ?? "").trim().toUpperCase();
      if (!(BINDING_METHODS as readonly string[]).includes(uppered)) {
        problems.push("Key '" + key + "' method '" + method + "' must be one of " + BINDING_METHODS.join(", ") + ".");
        break;
      }
    }
    for (const prefix of binding.allowed_path_prefixes ?? []) {
      if (!(prefix ?? "").trim().startsWith("/")) {
        problems.push("Key '" + key + "' prefix '" + prefix + "' must start with '/'.");
        break;
      }
    }
  }
  return problems;
}

// Canonicalizes a policy draft for dirty tracking. Domain lists and binding
// arrays behave as sets while credential keys behave as a map, so a plain
// stringify would read the same posture dirty when only ordering moved.
// Sorting each collection keeps changed meaning content changed. Domains and
// hosts normalize via trim plus lowercase, methods via trim plus uppercase,
// and path prefixes via trim before comparison, so semantically-equal drafts
// (`API.COM` vs `api.com`, ` post ` vs `POST`, ` /v1 ` vs `/v1`) read clean
// like the supervisor treats them. network.localExemptions is server-owned
// display-only and is always excluded here so a server-derived grant never
// reads dirty; the pane tracks the last loaded exemptions in a separate ref
// for post-save diffing instead.
export function canonicalPolicySnapshot(policy: PolicyDraft | null): string | null {
  if (!policy) return null;
  const normalizeDomain = (entry: string): string => (entry ?? "").trim().toLowerCase();
  const normalizeMethod = (entry: string): string => (entry ?? "").trim().toUpperCase();
  const allowed = [...(policy.network.allowed_domains ?? [])].map(normalizeDomain).sort();
  const blocked = [...(policy.network.blocked_domains ?? [])].map(normalizeDomain).sort();
  const sortedKeys = Object.keys(policy.credentials ?? {}).sort();
  const credentials: Record<string, PolicyBindingDraft> = {};
  for (const key of sortedKeys) {
    const binding = policy.credentials[key];
    credentials[key] = {
      allowed_hosts: [...(binding.allowed_hosts ?? [])].map(normalizeDomain).sort(),
      allowed_methods: [...(binding.allowed_methods ?? [])].map(normalizeMethod).sort(),
      allowed_path_prefixes: [...(binding.allowed_path_prefixes ?? [])].map((entry) => (entry ?? "").trim()).sort(),
    };
  }
  return JSON.stringify({
    version: policy.version,
    network: {
      mode: policy.network.mode,
      allowed_domains: allowed,
      blocked_domains: blocked,
    },
    credentials,
  });
}

// Normalizes a wire policy payload into the pane draft shape. Accepts the
// snake_case the engine sends while tolerating camelCase from older doubles,
// so a drifted payload still loads instead of blanking the form.
// network.localExemptions is display-only: both the camelCase wire spelling
// and the snake_case tolerant spelling decode here, defaulting to [].
function normalizePolicyPayload(raw: unknown): PolicyDraft {
  const fallback: PolicyDraft = {
    version: 1,
    network: { mode: "allowlist_only", allowed_domains: [], blocked_domains: [], localExemptions: [] },
    credentials: {},
  };
  if (!raw || typeof raw !== "object") return fallback;
  const payload = raw as Record<string, unknown>;
  const networkRaw = (payload.network ?? {}) as Record<string, unknown>;
  const modeRawRaw =
    typeof networkRaw.mode === "string" && (networkRaw.mode as string).trim()
      ? (networkRaw.mode as string).trim()
      : "allowlist_only";
  const modeRaw = modeRawRaw === "deny_by_default" ? "allowlist_only" : modeRawRaw;
  const allowedRaw =
    (networkRaw.allowed_domains as unknown) ??
    (networkRaw.allowedDomains as unknown) ??
    [];
  const blockedRaw =
    (networkRaw.blocked_domains as unknown) ??
    (networkRaw.blockedDomains as unknown) ??
    [];
  const toList = (value: unknown): string[] =>
    Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
  const credentialsRaw = (payload.credentials ?? {}) as Record<string, unknown>;
  const credentials: Record<string, PolicyBindingDraft> = {};
  for (const [key, bindingRaw] of Object.entries(credentialsRaw)) {
    if (!bindingRaw || typeof bindingRaw !== "object") continue;
    const binding = bindingRaw as Record<string, unknown>;
    const hosts =
      (binding.allowed_hosts as unknown) ?? (binding.allowedHosts as unknown) ?? [];
    const methods =
      (binding.allowed_methods as unknown) ?? (binding.allowedMethods as unknown) ?? [];
    const prefixes =
      (binding.allowed_path_prefixes as unknown) ??
      (binding.allowedPathPrefixes as unknown) ??
      [];
    credentials[key] = {
      allowed_hosts: toList(hosts),
      allowed_methods: toList(methods).map((entry) => entry.trim().toUpperCase()).filter(Boolean),
      allowed_path_prefixes: toList(prefixes),
    };
  }
  const versionRaw = payload.version;
  const localRaw =
    (networkRaw.localExemptions as unknown) ??
    (networkRaw.local_exemptions as unknown) ??
    [];
  return {
    version: typeof versionRaw === "number" && Number.isInteger(versionRaw) ? versionRaw : 1,
    network: {
      mode: modeRaw,
      allowed_domains: toList(allowedRaw),
      blocked_domains: toList(blockedRaw),
      localExemptions: toList(localRaw),
    },
    credentials,
  };
}

// Normalizes a string list from the wire. Non-strings drop so a drifted
// payload still loads instead of blanking the form.
function toStringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === "string")
    : [];
}

// Normalizes the local-access report the server returns alongside a policy
// write. Accepts camelCase and snake_case spellings, defaulting every list
// to [] so a missing report never crashes the disclosure.
function normalizeLocalAccessReport(raw: unknown): PolicyLocalAccessReport | null {
  if (!raw || typeof raw !== "object") return null;
  const payload = raw as Record<string, unknown>;
  const granted = toStringList(payload.granted);
  const removed = toStringList(payload.removed);
  const neverDialable = toStringList(
    (payload.neverDialable as unknown) ?? (payload.never_dialable as unknown) ?? [],
  );
  return { granted, removed, neverDialable };
}

// Builds the write payload for PUT and re-check endpoints. localExemptions
// is server-owned display-only and is never sent as a write input (Shared
// Contract C): the engine derives the stored set via classification.
function policyWritePayload(draft: PolicyDraft): unknown {
  return {
    version: draft.version,
    network: {
      mode: draft.network.mode,
      allowed_domains: draft.network.allowed_domains ?? [],
      blocked_domains: draft.network.blocked_domains ?? [],
    },
    credentials: draft.credentials ?? {},
  };
}

// Normalizes the re-check preview diff. Every list defaults to [] so a
// drifted payload still renders instead of crashing the modal.
function normalizeRecheckPreview(raw: unknown): LocalRecheckPreview {
  if (!raw || typeof raw !== "object") return { added: [], removed: [], unchanged: [], unresolved: [] };
  const payload = raw as Record<string, unknown>;
  return {
    added: toStringList(payload.added),
    removed: toStringList(payload.removed),
    unchanged: toStringList(payload.unchanged),
    unresolved: toStringList(payload.unresolved),
  };
}

// Loads the structured policy snapshot. Reads through the shared owner gate so
// token mode carries the bearer instead of 401ing on a bare fetch. There is no
// raw TOML on the wire: the dashboard edits the structured shape and the server
// owns serialization.
export async function fetchPolicy(): Promise<PolicyLoadResult> {
  const res = await fetch("/settings/policy", {
    headers: authHeaders(),
    credentials: "same-origin",
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const serverReason = (data as { reason?: string }).reason;
    const reason = serverReason
      ? `Failed to load policy: ${serverReason}`
      : "Failed to load policy: " + res.statusText;
    throw new Error(reason);
  }
  const payload = data as {
    policy?: unknown;
    path?: string;
    loaded_from_disk?: boolean;
    loadedFromDisk?: boolean;
    violations?: string[];
    localAccess?: unknown;
    local_access?: unknown;
  };
  return {
    policy: normalizePolicyPayload(payload.policy),
    path: typeof payload.path === "string" ? payload.path : "",
    loadedFromDisk: Boolean(payload.loaded_from_disk ?? payload.loadedFromDisk),
    violations: Array.isArray(payload.violations)
      ? payload.violations.filter((entry): entry is string => typeof entry === "string")
      : [],
    localAccess: normalizeLocalAccessReport(payload.localAccess ?? payload.local_access),
  };
}

// Persists the structured policy draft. Sends the DTO only with no legacy raw
// text field so an old editor learns the new contract instead of persisting
// unvalidated text. localExemptions is display-only and is never sent: the
// server derives the stored set via classification (Shared Contract C).
// Rejects leave the snapshot untouched so a 400 never silently persists.
export async function savePolicy(draft: PolicyDraft): Promise<PolicyLoadResult> {
  const res = await fetch("/settings/policy", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    credentials: "same-origin",
    body: JSON.stringify({ policy: policyWritePayload(draft) }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const reason =
      (data as { reason?: string }).reason || "Failed to save policy: " + res.statusText;
    throw new Error(reason);
  }
  const payload = data as {
    policy?: unknown;
    path?: string;
    loaded_from_disk?: boolean;
    loadedFromDisk?: boolean;
    violations?: string[];
    localAccess?: unknown;
    local_access?: unknown;
  };
  return {
    policy: normalizePolicyPayload(payload.policy),
    path: typeof payload.path === "string" ? payload.path : "",
    loadedFromDisk: Boolean(payload.loaded_from_disk ?? payload.loadedFromDisk),
    violations: Array.isArray(payload.violations)
      ? payload.violations.filter((entry): entry is string => typeof entry === "string")
      : [],
    localAccess: normalizeLocalAccessReport(payload.localAccess ?? payload.local_access),
  };
}

// Previews the local-access re-check for the current draft. Never writes:
// the server diffs the proposed grant set against the stored set and reports
// unresolved entries instead of erroring so the UI can show them before
// confirming.
export async function previewLocalRecheck(draft: PolicyDraft): Promise<LocalRecheckPreview> {
  const res = await fetch("/settings/policy/recheck-local", {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    credentials: "same-origin",
    body: JSON.stringify({ policy: policyWritePayload(draft) }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const reason =
      (data as { reason?: string }).reason || "Failed to preview local access: " + res.statusText;
    throw new Error(reason);
  }
  return normalizeRecheckPreview(data);
}

// Applies the local-access re-check for the current draft. Re-classifies
// every exact/literal entry server-side; any entry without proof aborts the
// whole write with a 400 naming every unresolved entry.
export async function applyLocalRecheck(draft: PolicyDraft): Promise<PolicyLoadResult> {
  const res = await fetch("/settings/policy/recheck-local/apply", {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    credentials: "same-origin",
    body: JSON.stringify({ policy: policyWritePayload(draft) }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const reason =
      (data as { reason?: string }).reason || "Failed to apply local access re-check: " + res.statusText;
    throw new Error(reason);
  }
  const payload = data as {
    policy?: unknown;
    path?: string;
    loaded_from_disk?: boolean;
    loadedFromDisk?: boolean;
    violations?: string[];
    localAccess?: unknown;
    local_access?: unknown;
  };
  return {
    policy: normalizePolicyPayload(payload.policy),
    path: typeof payload.path === "string" ? payload.path : "",
    loadedFromDisk: Boolean(payload.loaded_from_disk ?? payload.loadedFromDisk),
    violations: Array.isArray(payload.violations)
      ? payload.violations.filter((entry): entry is string => typeof entry === "string")
      : [],
    localAccess: normalizeLocalAccessReport(payload.localAccess ?? payload.local_access),
  };
}

export interface NetworkEgressEditorsProps {
  mode?: string;
  allowedDomains?: string[];
  blockedDomains?: string[];
  localExemptions?: string[];
  onModeChange?: (mode: string) => void;
  onAllowedDomainsChange?: (domains: string[]) => void;
  onBlockedDomainsChange?: (domains: string[]) => void;
  onRecheck?: () => void;
  rechecking?: boolean;
  applying?: boolean;
}

// Structured network egress editors. The mode select offers exactly the two
// surviving postures while the domain textareas keep one host per line; blank
// lines drop on parse so an accidental newline never becomes a stored entry.
// Invalid shapes surface inline before save, shadow overlaps warn with
// blocked-wins copy, and persistence stays with the pane save so there is no
// second network write path to drift from dirty tracking. Local exemptions
// render display-only: the server owns the grant set and the pane never edits
// or sends it.
export function NetworkEgressEditors({
  mode = "allowlist_only",
  allowedDomains = [],
  blockedDomains = [],
  localExemptions = [],
  onModeChange,
  onAllowedDomainsChange,
  onBlockedDomainsChange,
  onRecheck,
  rechecking,
  applying,
}: NetworkEgressEditorsProps) {
  const allowedList = allowedDomains ?? [];
  const blockedList = blockedDomains ?? [];
  const localList = localExemptions ?? [];
  // Display buffers keep the typed text while the parent draft stays canonical,
  // so a trailing space stays visible instead of vanishing on the next render.
  const [allowedBuffer, setAllowedBuffer] = useState<string>(() => formatDomainLines(allowedList));
  const [blockedBuffer, setBlockedBuffer] = useState<string>(() => formatDomainLines(blockedList));
  const localText = formatDomainLines(localList);
  const shadowWarnings = findEgressShadowWarnings(allowedList, blockedList);
  const invalidAllowed = allowedList.filter((entry) => !isValidDomainLine(entry));
  const invalidBlocked = blockedList.filter((entry) => !isValidDomainLine(entry));

  useEffect(() => {
    const propText = formatDomainLines(allowedList);
    if (JSON.stringify(parseDomainLines(allowedBuffer)) !== JSON.stringify(allowedList)) {
      setAllowedBuffer(propText);
    }
  }, [allowedList]);

  useEffect(() => {
    const propText = formatDomainLines(blockedList);
    if (JSON.stringify(parseDomainLines(blockedBuffer)) !== JSON.stringify(blockedList)) {
      setBlockedBuffer(propText);
    }
  }, [blockedList]);

  function handleAllowedTextChange(raw: string) {
    setAllowedBuffer(raw);
    if (onAllowedDomainsChange) onAllowedDomainsChange(parseDomainLines(raw));
  }

  function handleBlockedTextChange(raw: string) {
    setBlockedBuffer(raw);
    if (onBlockedDomainsChange) onBlockedDomainsChange(parseDomainLines(raw));
  }

  return (
    <section aria-label="Network egress" data-testid="network-egress-editors" className="policy-network-section">
      <div className="settings-section-header">
        <h4>Network egress</h4>
        {onRecheck ? (
          <button type="button" className="ghost" data-testid="policy-recheck"
            onClick={onRecheck} disabled={rechecking || applying}>
            {rechecking ? "Checking…" : "Re-check local access"}
          </button>
        ) : null}
      </div>
      <p className="settings-section-hint">
        Outbound boundaries. One binding pairs one key with hosts, methods, and path
        prefixes below.
      </p>
      <div className="form-group">
        <label htmlFor="policy-mode">Mode</label>
        <select
          id="policy-mode"
          aria-label="Mode"
          className="input-field"
          value={mode}
          onChange={(event) => {
            if (onModeChange) onModeChange(event.target.value);
          }}
        >
          <option value="allowlist_only">Allowlist</option>
          <option value="unrestricted">Unrestricted</option>
        </select>
        <span className="form-group-hint">
          Blocked domains always win, even in Unrestricted. SSRF protections and credential
          bindings still apply in Unrestricted.
        </span>
      </div>
      <div className="form-group">
        <label htmlFor="policy-allowed-domains">Allowed domains</label>
        <textarea
          id="policy-allowed-domains"
          aria-label="Allowed domains"
          className="input-field"
          value={allowedBuffer}
          onChange={(event) => handleAllowedTextChange(event.target.value)}
          placeholder="api.example.com"
          rows={5}
        />
        <span className="form-group-hint" data-testid="allowed-domains-count">
          {allowedList.length} {allowedList.length === 1 ? "host" : "hosts"} — one per line —
          blank lines ignored
        </span>
        {invalidAllowed.length > 0 ? (
          <span className="danger text-sm" data-testid="allowed-domains-error">
            Allowed domain &apos;{invalidAllowed[0]}&apos; is invalid — use an exact host or a
            single leading &apos;*.example.com&apos; edge.
          </span>
        ) : null}
      </div>
      <div className="form-group">
        <label htmlFor="policy-blocked-domains">Blocked domains</label>
        <textarea
          id="policy-blocked-domains"
          aria-label="Blocked domains"
          className="input-field"
          value={blockedBuffer}
          onChange={(event) => handleBlockedTextChange(event.target.value)}
          placeholder="metadata.google.internal"
          rows={5}
        />
        <span className="form-group-hint" data-testid="blocked-domains-count">
          {blockedList.length} {blockedList.length === 1 ? "host" : "hosts"} — one per line —
          blank lines ignored
        </span>
        {invalidBlocked.length > 0 ? (
          <span className="danger text-sm" data-testid="blocked-domains-error">
            Blocked domain &apos;{invalidBlocked[0]}&apos; is invalid — use an exact host or a
            single leading &apos;*.example.com&apos; edge.
          </span>
        ) : null}
      </div>
      <div className="form-group">
        <label htmlFor="policy-local-exemptions">Local network access</label>
        <textarea
          id="policy-local-exemptions"
          aria-label="Local network access"
          data-testid="policy-local-exemptions"
          className="input-field"
          value={localText}
          readOnly
          placeholder="No local exemptions"
          rows={5}
        />
        <span className="form-group-hint" data-testid="local-exemptions-count">
          {localList.length} {localList.length === 1 ? "host" : "hosts"} — read-only, one per line
        </span>
        <span className="form-group-hint" data-testid="local-exemptions-hint">
          Not editable here — the server derives these grants. Exact hosts in Allowed domains that resolve to private addresses are granted when added or via Re-check local access. Wildcards never auto-grant. Metadata and link-local hosts are never allowed.
        </span>
      </div>
      {shadowWarnings.length > 0 ? (
        <div
          data-testid="egress-shadow-warning"
          style={{
            padding: "8px 12px",
            borderRadius: "6px",
            backgroundColor: "rgba(245, 158, 11, 0.12)",
            border: "1px solid rgba(245, 158, 11, 0.35)",
            color: "var(--warning-color, #b45309)",
            fontSize: "0.85rem",
            marginTop: "8px",
          }}
        >
          <ul style={{ margin: 0, paddingLeft: "18px" }}>
            {shadowWarnings.map((entry, index) => (
              <li key={index}>{entry}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}

export interface CredentialsListProps {
  bindings?: Record<string, PolicyBindingDraft>;
  secretStatus?: Record<string, boolean>;
  allowedDomains?: string[];
  onAdd?: () => void;
  onEdit?: (key: string) => void;
  onDeleteRequest?: (key: string) => void;
}

// Searchable credentials list. Rows stay compact so dozens scan without
// scrolling fatigue: key headline, Keychain presence, host and scope
// summaries, and a single attention dot. Search matches key plus host
// substrings case-insensitively while the toggle narrows to rows worth
// opening; rows themselves hold no editors so binding edits always flow
// through the modal and the pane save.
export function CredentialsList({
  bindings = {},
  secretStatus = {},
  allowedDomains = [],
  onAdd,
  onEdit,
  onDeleteRequest,
}: CredentialsListProps) {
  const [query, setQuery] = useState<string>("");
  const [attentionOnly, setAttentionOnly] = useState<boolean>(false);

  // Sorted entries keep the list deterministic across saves; attention and
  // summaries derive per render so a network edit immediately re-badges every
  // row without a second probe.
  const entries = useMemo(
    () => Object.entries(bindings ?? {}).sort(([a], [b]) => a.localeCompare(b)),
    [bindings],
  );

  const enriched = useMemo(
    () =>
      entries.map(([key, binding]) => {
        const hosts = binding?.allowed_hosts ?? [];
        const attention = bindingAttention(key, binding, allowedDomains ?? []);
        return {
          key,
          binding,
          hosts,
          attention,
          hostsSummary: bindingHostsSummary(hosts),
          scopeSummary: bindingScopeSummary(binding),
          stored: (secretStatus ?? {})[key] === true,
        };
      }),
    [entries, allowedDomains, secretStatus],
  );

  const normalizedQuery = query.trim().toLowerCase();
  const filtered = useMemo(() => {
    let rows = enriched;
    if (normalizedQuery) {
      rows = rows.filter(
        (row) =>
          row.key.toLowerCase().includes(normalizedQuery) ||
          (row.hosts ?? []).some((host) =>
            (host ?? "").toLowerCase().includes(normalizedQuery),
          ),
      );
    }
    if (attentionOnly) {
      rows = rows.filter((row) => row.attention.needsAttention);
    }
    return rows;
  }, [enriched, normalizedQuery, attentionOnly]);

  // Empty policy reads as an invitation, not a blank table: one sentence
  // explains the Keychain pairing before offering the add path.
  if (entries.length === 0) {
    return (
      <div data-testid="credentials-list">
        <div
          style={{ display: "flex", gap: "8px", alignItems: "center", marginBottom: "8px" }}
          data-testid="credentials-list-header"
        >
          <span className="muted text-sm" data-testid="credentials-count">
            0 bindings
          </span>
          <span style={{ flex: 1 }} />
          <button type="button" className="ghost btn-sm" data-testid="credentials-add" onClick={() => onAdd?.()}>
            Add binding
          </button>
        </div>
        <div
          data-testid="credentials-empty"
          style={{
            padding: "12px",
            borderRadius: "6px",
            border: "1px dashed rgba(148, 163, 184, 0.4)",
            fontSize: "0.85rem",
          }}
        >
          <p className="muted" style={{ margin: "0 0 4px 0" }}>
            No credential bindings yet.
          </p>
          <p className="muted" style={{ margin: "0 0 8px 0" }}>
            Store the secret value in Keychain as <code>rwsecret:&lt;key&gt;</code>, then bind
            that key to the hosts it may reach.
          </p>
          <button
            type="button"
            className="ghost btn-sm"
            data-testid="credentials-empty-add"
            onClick={() => onAdd?.()}
          >
            Add binding
          </button>
        </div>
      </div>
    );
  }

  return (
    <div data-testid="credentials-list">
      <div
        style={{ display: "flex", gap: "8px", alignItems: "center", flexWrap: "wrap", marginBottom: "8px" }}
        data-testid="credentials-list-header"
      >
        <span className="muted text-sm" data-testid="credentials-count">
          {filtered.length === entries.length
            ? `${entries.length} ${entries.length === 1 ? "binding" : "bindings"}`
            : `${filtered.length} of ${entries.length} bindings`}
        </span>
        <input
          type="text"
          className="input-field"
          aria-label="Search bindings"
          placeholder="Search by key or host…"
          data-testid="credentials-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          autoComplete="off"
          spellCheck={false}
          style={{ maxWidth: "220px" }}
        />
        <label className="checkbox-row" style={{ fontSize: "0.82rem" }}>
          <input
            type="checkbox"
            data-testid="credentials-attention-toggle"
            aria-label="Needs attention only"
            checked={attentionOnly}
            onChange={(event) => setAttentionOnly(event.target.checked)}
          />
          <span>Needs attention</span>
        </label>
        <span style={{ flex: 1 }} />
        <button type="button" className="ghost btn-sm" data-testid="credentials-add" onClick={() => onAdd?.()}>
          Add binding
        </button>
      </div>
      {filtered.length === 0 ? (
        <div data-testid="credentials-no-match" className="muted text-sm" style={{ padding: "8px 0" }}>
          No bindings match this filter.{" "}
          <button
            type="button"
            className="ghost btn-sm"
            onClick={() => {
              setQuery("");
              setAttentionOnly(false);
            }}
          >
            Clear search
          </button>
        </div>
      ) : (
        <ul style={{ listStyle: "none", margin: 0, padding: 0 }} aria-label="Credential bindings">
          {filtered.map((row) => (
            <li
              key={row.key}
              data-testid="credential-row"
              data-key={row.key}
              style={{
                display: "flex",
                gap: "8px",
                alignItems: "center",
                padding: "6px 8px",
                borderBottom: "1px solid rgba(148, 163, 184, 0.18)",
              }}
            >
              <button
                type="button"
                data-testid={`edit-binding-${row.key}`}
                aria-label={`Edit ${row.key}`}
                onClick={() => onEdit?.(row.key)}
                title={row.attention.needsAttention ? row.attention.reasons.join(" ") : `Edit ${row.key}`}
                style={{
                  flex: 1,
                  display: "flex",
                  gap: "8px",
                  alignItems: "center",
                  background: "none",
                  border: "none",
                  padding: 0,
                  cursor: "pointer",
                  textAlign: "left",
                  fontSize: "0.82rem",
                  minWidth: 0,
                }}
              >
                {row.attention.needsAttention ? (
                  <span
                    data-testid="binding-attention"
                    aria-label="Needs attention"
                    title={row.attention.reasons.join(" ")}
                    style={{ color: "var(--warning-color, #f59e0b)", fontSize: "0.7rem", flexShrink: 0 }}
                  >
                    ●
                  </span>
                ) : null}
                <code style={{ fontFamily: "monospace", flexShrink: 0 }}>{row.key}</code>
                <span
                  data-testid="keychain-badge"
                  className="status-pill"
                  style={{
                    fontSize: "0.72rem",
                    padding: "1px 8px",
                    borderRadius: "999px",
                    border: "1px solid rgba(148, 163, 184, 0.35)",
                    flexShrink: 0,
                  }}
                >
                  {row.stored ? "Keychain Stored" : "Keychain Missing"}
                </span>
                <span
                  data-testid="binding-hosts-summary"
                  className="muted"
                  style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}
                >
                  {row.hostsSummary}
                </span>
                <span data-testid="binding-scope-summary" className="muted" style={{ flexShrink: 0 }}>
                  {row.scopeSummary}
                </span>
              </button>
              <button
                type="button"
                className="icon-button"
                aria-label={`Delete ${row.key}`}
                data-testid={`delete-binding-${row.key}`}
                onClick={(event) => {
                  event.stopPropagation();
                  onDeleteRequest?.(row.key);
                }}
                title={`Delete ${row.key}`}
              >
                <TrashIcon size={14} />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function PolicyPane() {
  const [draft, setDraft] = useState<PolicyDraft | null>(null);
  const [policyPath, setPolicyPath] = useState<string>("");
  const [loadedFromDisk, setLoadedFromDisk] = useState<boolean>(false);
  const [violations, setViolations] = useState<string[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [saving, setSaving] = useState<boolean>(false);
  const [saved, setSaved] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  // Keychain presence per binding key, probed after load so rows can badge
  // Stored versus Missing without blocking the policy render on secrets.
  const [secretStatus, setSecretStatus] = useState<Record<string, boolean>>({});
  // Binding modal state: null stays closed, otherwise add starts empty while
  // edit prefills from the live draft key.
  const [bindingModal, setBindingModal] = useState<{
    mode: "add" | "edit";
    editingKey: string | null;
  } | null>(null);
  // Non-blocking delete confirmation: the pending key renders a true modal so
  // a binding is never removed by an accidental click, mirroring the plugin
  // uninstall confirmation.
  const [pendingDeleteKey, setPendingDeleteKey] = useState<string | null>(null);
  // Last accepted snapshot for dirty tracking. Changed is a canonical deep
  // compare of the live draft against this snapshot, so an edit that returns
  // to the loaded shape or only reorders sets reads clean instead of staying
  // dirty on object identity or array order alone. localExemptions is excluded
  // from the canonical snapshot (server-owned display-only); the last loaded
  // grant set is tracked separately below for post-save diffing.
  const lastLoadedRef = useRef<string | null>(null);
  // Last loaded local exemptions for post-save diffing. Updated on every
  // accepted load/save/apply; never part of the dirty comparison.
  const lastLocalExemptionsRef = useRef<string[]>([]);
  // Save disclosure for the server classification report. Granted names new
  // local grants from the write; neverDialable names entries that persist
  // name-only with no grant. Shown alongside the saved banner only.
  const [localGranted, setLocalGranted] = useState<string[]>([]);
  const [localRemoved, setLocalRemoved] = useState<string[]>([]);
  const [neverDialableHosts, setNeverDialableHosts] = useState<string[]>([]);
  // Re-check preview state. Preview never writes; Apply grants persists the
  // re-classified set while Cancel discards the preview without writing.
  const [recheckPreview, setRecheckPreview] = useState<LocalRecheckPreview | null>(null);
  const [recheckOpen, setRecheckOpen] = useState<boolean>(false);
  const [rechecking, setRechecking] = useState<boolean>(false);
  const [applying, setApplying] = useState<boolean>(false);
  const [recheckError, setRecheckError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await fetchPolicy();
      setDraft(result.policy);
      setPolicyPath(result.path);
      setLoadedFromDisk(result.loadedFromDisk);
      setViolations(result.violations);
      lastLoadedRef.current = canonicalPolicySnapshot(result.policy);
      lastLocalExemptionsRef.current = [...(result.policy.network.localExemptions ?? [])];
      setLocalGranted([]);
      setLocalRemoved([]);
      setNeverDialableHosts([]);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load security policy.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // Field errors gate the pane-local Save. Computed from the live draft so a
  // rejected shape disables persistence before any network write.
  const fieldErrors = useMemo(() => validatePolicyDraft(draft), [draft]);
  const hasFieldErrors = fieldErrors.length > 0;

  const draftSnapshot = draft ? canonicalPolicySnapshot(draft) : null;
  const changed =
    draftSnapshot !== null &&
    lastLoadedRef.current !== null &&
    draftSnapshot !== lastLoadedRef.current;

  // Any edit clears the saved confirmation so a stale success never reads as
  // covering the current draft. The snapshot comparison above stays the source
  // for dirty state while this flag owns only the transient banner. Grant
  // disclosures clear with the banner since they describe the last write.
  function markEdited(updater: (prev: PolicyDraft) => PolicyDraft) {
    setDraft((prev) => {
      if (!prev) return prev;
      return updater(prev);
    });
    setSaved(false);
    setLocalGranted([]);
    setNeverDialableHosts([]);
  }

  function handleModeChange(nextMode: string) {
    markEdited((prev) => ({
      ...prev,
      network: { ...prev.network, mode: nextMode },
    }));
  }

  function handleAllowedDomainsChangeFromEditor(domains: string[]) {
    markEdited((prev) => ({
      ...prev,
      network: { ...prev.network, allowed_domains: domains },
    }));
  }

  function handleBlockedDomainsChangeFromEditor(domains: string[]) {
    markEdited((prev) => ({
      ...prev,
      network: { ...prev.network, blocked_domains: domains },
    }));
  }

  function handleDeleteBinding(key: string) {
    markEdited((prev) => {
      const next = { ...prev.credentials };
      delete next[key];
      return { ...prev, credentials: next };
    });
    // Prune the deleted key immediately so its Keychain badge cannot linger
    // as a stale pill until the next presence probe intersects live keys.
    setSecretStatus((prev) => {
      if (!(key in prev)) return prev;
      const next = { ...prev };
      delete next[key];
      return next;
    });
  }

  function handleRequestDeleteBinding(key: string) {
    setPendingDeleteKey(key);
  }

  function handleCancelDeleteBinding() {
    setPendingDeleteKey(null);
  }

  function handleConfirmDeleteBinding() {
    if (!pendingDeleteKey) return;
    handleDeleteBinding(pendingDeleteKey);
    setPendingDeleteKey(null);
  }

  // Modal save writes into the live draft only; the pane Save button owns
  // persistence through savePolicy so network writes stay single-pathed. A
  // renamed key moves the binding instead of forking it.
  function handleBindingModalSave(modalDraft: {
    key: string;
    hosts?: string[];
    methods?: string[];
    pathPrefixes?: string[];
    allowedHosts?: string[];
    allowed_hosts?: string[];
    allowedMethods?: string[];
    allowed_methods?: string[];
    allowedPathPrefixes?: string[];
    allowed_path_prefixes?: string[];
  }) {
    const nextKey = (modalDraft?.key ?? "").trim();
    if (!nextKey) return;
    const hosts =
      modalDraft.hosts ?? modalDraft.allowedHosts ?? modalDraft.allowed_hosts ?? [];
    const methods =
      modalDraft.methods ?? modalDraft.allowedMethods ?? modalDraft.allowed_methods ?? [];
    const prefixes =
      modalDraft.pathPrefixes ??
      modalDraft.allowedPathPrefixes ??
      modalDraft.allowed_path_prefixes ??
      [];
    const editingKey = bindingModal?.editingKey ?? null;
    markEdited((prev) => {
      const next = { ...prev.credentials };
      if (editingKey && editingKey !== nextKey) {
        delete next[editingKey];
      }
      next[nextKey] = {
        allowed_hosts: [...hosts],
        allowed_methods: [...methods].map((entry) => (entry ?? "").trim().toUpperCase()).filter(Boolean),
        allowed_path_prefixes: [...prefixes],
      };
      return { ...prev, credentials: next };
    });
    // A rename orphans the old key: prune it now so the probe intersection
    // below only needs to cover deletes arriving outside the modal.
    if (editingKey && editingKey !== nextKey) {
      setSecretStatus((prev) => {
        if (!(editingKey in prev)) return prev;
        const next = { ...prev };
        delete next[editingKey];
        return next;
      });
    }
  }

  // Coverage shortcut from the modal: uncovered hosts join the allowlist so
  // the binding can authorize without a second trip to the network editor.
  // Matching stays case-insensitive while stored casing is preserved.
  function handleAddAllowedDomains(domains: string[]) {
    const additions = (domains ?? []).map((entry) => (entry ?? "").trim()).filter(Boolean);
    if (additions.length === 0) return;
    markEdited((prev) => {
      const seen = new Set((prev.network.allowed_domains ?? []).map((entry) => entry.trim().toLowerCase()));
      const merged = [...prev.network.allowed_domains];
      for (const entry of additions) {
        if (!seen.has(entry.toLowerCase())) {
          seen.add(entry.toLowerCase());
          merged.push(entry);
        }
      }
      return { ...prev, network: { ...prev.network, allowed_domains: merged } };
    });
  }

  async function handleSave() {
    if (!draft || hasFieldErrors || saving) return;
    setSaving(true);
    setError(null);
    try {
      const result = await savePolicy(draft);
      setDraft(result.policy);
      setPolicyPath(result.path);
      setLoadedFromDisk(result.loadedFromDisk);
      setViolations(result.violations);
      lastLoadedRef.current = canonicalPolicySnapshot(result.policy);
      lastLocalExemptionsRef.current = [...(result.policy.network.localExemptions ?? [])];
      setLocalGranted(result.localAccess?.granted ?? []);
      setLocalRemoved(result.localAccess?.removed ?? []);
      setNeverDialableHosts(result.localAccess?.neverDialable ?? []);
      setSaved(true);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to save security policy.");
      setSaved(false);
    } finally {
      setSaving(false);
    }
  }

  // Previews the local-access re-check for the current draft, then opens the
  // confirm modal. Preview never writes; unresolved entries report instead of
  // erroring so the UI can show them before confirming.
  async function handleRecheck() {
    if (!draft || rechecking || applying) return;
    setRechecking(true);
    setRecheckError(null);
    try {
      const preview = await previewLocalRecheck(draft);
      setRecheckPreview(preview);
      setRecheckOpen(true);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to preview local access.");
    } finally {
      setRechecking(false);
    }
  }

  function handleCloseRecheck() {
    if (applying) return;
    setRecheckOpen(false);
  }

  // Applies the previewed re-check, then refreshes the draft, banner, and
  // last-loaded tracking from the response. Apply grants stays disabled while
  // unresolved is non-empty; a 400 keeps the draft and surfaces the server
  // reason naming unresolved hosts.
  async function handleApplyRecheck() {
    if (!draft || !recheckPreview || applying) return;
    if (recheckPreview.unresolved.length > 0) return;
    setApplying(true);
    setRecheckError(null);
    setError(null);
    try {
      const result = await applyLocalRecheck(draft);
      setDraft(result.policy);
      setPolicyPath(result.path);
      setLoadedFromDisk(result.loadedFromDisk);
      setViolations(result.violations);
      lastLoadedRef.current = canonicalPolicySnapshot(result.policy);
      lastLocalExemptionsRef.current = [...(result.policy.network.localExemptions ?? [])];
      setLocalGranted(result.localAccess?.granted ?? []);
      setLocalRemoved(result.localAccess?.removed ?? []);
      setNeverDialableHosts(result.localAccess?.neverDialable ?? []);
      setSaved(true);
      setRecheckOpen(false);
      setRecheckPreview(null);
    } catch (err: unknown) {
      const message =
        err instanceof Error ? err.message : "Failed to apply local access re-check.";
      setError(message);
      setRecheckError(message);
      setSaved(false);
    } finally {
      setApplying(false);
    }
  }

  const bindingEntries = useMemo(
    () => (draft ? Object.entries(draft.credentials ?? {}).sort(([a], [b]) => a.localeCompare(b)) : []),
    [draft],
  );

  const bindingKeys = useMemo(() => bindingEntries.map(([key]) => key), [bindingEntries]);

  // Stable key signature so Keychain presence refetches only when the binding
  // set changes, not on every network keystroke.
  const credentialKeysSignature = useMemo(() => bindingKeys.join("\n"), [bindingKeys]);

  // Probes Keychain presence for the live binding keys. The effect derives the
  // keys from the signature instead of reading the draft, so a keystroke that
  // only reshapes field text never re-probes. Merged status intersects with
  // the live keys so a deleted binding cannot persist as a stale badge.
  // Failures stay silent so rows fall back to Missing instead of blocking
  // the policy render.
  useEffect(() => {
    const keys = credentialKeysSignature ? credentialKeysSignature.split("\n") : [];
    if (keys.length === 0) {
      setSecretStatus({});
      return;
    }
    const live = new Set(keys);
    let cancelled = false;
    void checkSecretStatus(keys)
      .then((status) => {
        if (!cancelled && status) {
          setSecretStatus((prev) => {
            const next = { ...prev, ...status };
            for (const key of Object.keys(next)) {
              if (!live.has(key)) delete next[key];
            }
            return next;
          });
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [credentialKeysSignature]);

  const allowedDomainsForBindings = useMemo(
    () => draft?.network.allowed_domains ?? [],
    [draft],
  );

  // Prefill for edit mode, read from the live draft so the modal conjunction
  // matches the row that opened it. Add mode leaves the binding undefined so
  // the modal starts empty with Any defaults.
  const editingBinding = useMemo(() => {
    if (!bindingModal || bindingModal.mode !== "edit" || !bindingModal.editingKey || !draft) {
      return null;
    }
    const stored = draft.credentials[bindingModal.editingKey];
    if (!stored) return null;
    return {
      key: bindingModal.editingKey,
      hosts: stored.allowed_hosts ?? [],
      methods: stored.allowed_methods ?? [],
      pathPrefixes: stored.allowed_path_prefixes ?? [],
    };
  }, [bindingModal, draft]);

  return (
    <section className="settings-section card" aria-label="Policy" data-testid="policy-pane">
      <div className="settings-section-title-group">
        <h3>Policy</h3>
        <p className="settings-section-hint">
          Declarative network egress plus target-bound credentials. Changes apply
          immediately with no restart.
        </p>
        {policyPath ? (
          <p className="muted text-sm" data-testid="policy-location">
            Location: <code>{policyPath}</code> ({loadedFromDisk ? "Customized" : "Factory Defaults"})
          </p>
        ) : null}
      </div>

      {loading ? <p className="muted text-sm">Loading policy…</p> : null}

      {!loading ? (
        <div style={{ marginTop: "12px", marginBottom: "14px" }} data-testid="policy-invariants">
          {violations.length === 0 ? (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: "8px",
                padding: "8px 12px",
                borderRadius: "6px",
                backgroundColor: "rgba(16, 185, 129, 0.1)",
                border: "1px solid rgba(16, 185, 129, 0.25)",
                color: "var(--success-color, #10b981)",
                fontSize: "0.85rem",
              }}
            >
              <span>
                <strong>All 3 Formal Security Invariants Verified:</strong> Credential Binding
                Confinement, Rule Shadow Prevention, and Local Exemption Safety hold.
              </span>
            </div>
          ) : (
            <div
              style={{
                padding: "10px 14px",
                borderRadius: "6px",
                backgroundColor: "rgba(239, 68, 68, 0.1)",
                border: "1px solid rgba(239, 68, 68, 0.3)",
                color: "var(--danger-color, #ef4444)",
                fontSize: "0.85rem",
              }}
            >
              <div style={{ fontWeight: "bold", marginBottom: "4px" }}>
                <span>
                  {violations.length} Invariant Violation(s) Detected (Policy will fall back to safe
                  default):
                </span>
              </div>
              <ul style={{ margin: "4px 0 0 20px", padding: 0 }}>
                {violations.map((entry, index) => (
                  <li key={index} style={{ marginBottom: "2px" }}>
                    {entry}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      ) : null}

      {saved ? (
        <div
          data-testid="policy-saved"
          style={{
            padding: "8px 12px",
            borderRadius: "6px",
            backgroundColor: "rgba(16, 185, 129, 0.15)",
            color: "#10b981",
            fontSize: "0.85rem",
            marginBottom: "12px",
          }}
        >
          Policy saved. Changes apply immediately with no restart.
          {localGranted.length > 0 ? (
            <span data-testid="policy-local-granted">
              {" "}
              Local network access granted for: {localGranted.join(", ")}.
            </span>
          ) : null}
          {localRemoved.length > 0 ? (
            <span data-testid="policy-local-removed">
              {" "}
              Local network access removed for: {localRemoved.join(", ")}.
            </span>
          ) : null}
        </div>
      ) : null}

      {saved && neverDialableHosts.length > 0 ? (
        <div
          data-testid="policy-local-never-dialable"
          style={{
            padding: "8px 12px",
            borderRadius: "6px",
            backgroundColor: "rgba(245, 158, 11, 0.12)",
            border: "1px solid rgba(245, 158, 11, 0.35)",
            color: "var(--warning-color, #b45309)",
            fontSize: "0.85rem",
            marginBottom: "12px",
          }}
        >
          Local network access not granted for never-dialable hosts:{" "}
          {neverDialableHosts.join(", ")}. These entries persist name-only with no grant.
        </div>
      ) : null}

      {error ? (
        <div className="error-banner" data-testid="policy-error" style={{ marginBottom: "12px" }}>
          {error}
        </div>
      ) : null}

      {fieldErrors.length > 0 && draft ? (
        <div className="error-banner" data-testid="policy-field-errors" style={{ marginBottom: "12px" }}>
          <ul style={{ margin: 0, paddingLeft: "18px" }}>
            {fieldErrors.map((entry, index) => (
              <li key={index}>{entry}</li>
            ))}
          </ul>
        </div>
      ) : null}

      {draft ? (
        <>
          <section aria-label="Network" data-testid="policy-network-section">
            <NetworkEgressEditors
              mode={draft.network.mode}
              allowedDomains={draft.network.allowed_domains}
              blockedDomains={draft.network.blocked_domains}
              localExemptions={draft.network.localExemptions}
              onModeChange={handleModeChange}
              onAllowedDomainsChange={handleAllowedDomainsChangeFromEditor}
              onBlockedDomainsChange={handleBlockedDomainsChangeFromEditor}
              onRecheck={() => void handleRecheck()}
              rechecking={rechecking}
              applying={applying}
            />
          </section>

          <section
            aria-label="Credentials"
            data-testid="policy-credentials-section"
            style={{ marginTop: "16px" }}
          >
            <h4>Target-bound credentials</h4>
            <p className="settings-section-hint">
              One binding pairs one key with hosts, methods, and path prefixes. The secret is
              sent only when host, method, and effective path all match — prefixes apply to every
              host in the same binding. Empty hosts means the credential can never be sent; empty
              methods or prefixes mean Any.
            </p>
            <CredentialsList
              bindings={draft.credentials}
              secretStatus={secretStatus}
              allowedDomains={allowedDomainsForBindings}
              onAdd={() => setBindingModal({ mode: "add", editingKey: null })}
              onEdit={(key) => setBindingModal({ mode: "edit", editingKey: key })}
              onDeleteRequest={handleRequestDeleteBinding}
            />
          </section>

          {bindingModal ? (
            <PolicyBindingModal
              mode={bindingModal.mode}
              initialBinding={editingBinding ?? undefined}
              editingKey={bindingModal.editingKey}
              existingBindingKeys={bindingKeys}
              secretStatus={secretStatus}
              allowedDomains={allowedDomainsForBindings}
              onSave={handleBindingModalSave}
              onClose={() => setBindingModal(null)}
              onAddAllowedDomains={handleAddAllowedDomains}
            />
          ) : null}

          {pendingDeleteKey ? (
            <Modal
              label="Confirm delete binding"
              onClose={handleCancelDeleteBinding}
              containerClassName="modal-container session-delete-modal"
            >
              <div className="modal-header">
                <h3>Delete binding?</h3>
                <button
                  type="button"
                  className="icon-button"
                  onClick={handleCancelDeleteBinding}
                  aria-label="Close"
                >
                  <CloseIcon size={16} />
                </button>
              </div>
              <div className="modal-body">
                <p className="muted" style={{ margin: 0 }}>
                  This will remove the binding for &lsquo;{pendingDeleteKey}&rsquo;. The Keychain
                  secret stays stored; only the policy binding is removed. This cannot be undone.
                </p>
              </div>
              <div className="modal-footer">
                <button type="button" className="ghost" onClick={handleCancelDeleteBinding}>
                  Keep
                </button>
                <button
                  type="button"
                  className="danger"
                  onClick={handleConfirmDeleteBinding}
                  aria-label={`Confirm delete ${pendingDeleteKey}`}
                >
                  Delete
                </button>
              </div>
            </Modal>
          ) : null}

          {recheckOpen && recheckPreview ? (
            <Modal
              label="Re-check local network access"
              onClose={handleCloseRecheck}
              containerClassName="modal-container"
              testId="policy-recheck-modal"
            >
              <div className="modal-header">
                <h3>Re-check local access</h3>
                <button
                  type="button"
                  className="icon-button"
                  onClick={handleCloseRecheck}
                  aria-label="Close"
                >
                  <CloseIcon size={16} />
                </button>
              </div>
              <div className="modal-body">
                <p className="muted text-sm" style={{ margin: "0 0 8px 0" }}>
                  Preview of the local-access grants this draft would create. Apply grants
                  re-classifies every exact host server-side and persists the result.
                </p>
                <div data-testid="policy-recheck-added" style={{ marginBottom: "8px" }}>
                  <strong>Added ({recheckPreview.added.length}):</strong>{" "}
                  {recheckPreview.added.length > 0 ? recheckPreview.added.join(", ") : "none"}
                </div>
                <div data-testid="policy-recheck-removed" style={{ marginBottom: "8px" }}>
                  <strong>Removed ({recheckPreview.removed.length}):</strong>{" "}
                  {recheckPreview.removed.length > 0 ? recheckPreview.removed.join(", ") : "none"}
                </div>
                <div data-testid="policy-recheck-unchanged" style={{ marginBottom: "8px" }}>
                  <strong>Unchanged ({recheckPreview.unchanged.length}):</strong>{" "}
                  {recheckPreview.unchanged.length > 0
                    ? recheckPreview.unchanged.join(", ")
                    : "none"}
                </div>
                {recheckPreview.unresolved.length > 0 ? (
                  <div data-testid="policy-recheck-unresolved" style={{ marginBottom: "8px" }}>
                    <strong>Unresolved ({recheckPreview.unresolved.length}):</strong>{" "}
                    {recheckPreview.unresolved.join(", ")}
                    <p className="muted text-sm" style={{ margin: "4px 0 0 0" }}>
                      Cannot apply while {recheckPreview.unresolved.length}{" "}
                      {recheckPreview.unresolved.length === 1 ? "host remains" : "hosts remain"}{" "}
                      unresolved. Resolve or remove these hosts before applying.
                    </p>
                  </div>
                ) : null}
                {recheckError ? (
                  <div
                    className="error-banner"
                    data-testid="policy-recheck-error"
                    style={{ marginTop: "8px" }}
                  >
                    {recheckError}
                  </div>
                ) : null}
              </div>
              <div className="modal-footer">
                <button
                  type="button"
                  className="ghost"
                  data-testid="policy-recheck-cancel"
                  onClick={handleCloseRecheck}
                  disabled={applying}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="primary"
                  data-testid="policy-recheck-confirm"
                  onClick={() => void handleApplyRecheck()}
                  disabled={recheckPreview.unresolved.length > 0 || applying}
                >
                  {applying ? "Applying…" : "Apply grants"}
                </button>
              </div>
            </Modal>
          ) : null}

          <div className="settings-footer">
            {changed ? <span className="muted text-sm">Unsaved changes.</span> : null}
            <button
              type="button"
              className="primary-button save-button"
              data-testid="policy-save"
              onClick={() => void handleSave()}
              disabled={hasFieldErrors || saving || !draft}
            >
              {saving ? "Saving…" : "Save"}
            </button>
          </div>
          <p className="muted text-sm" style={{ marginTop: "12px" }}>
            Prefer the terminal? Run <code>rune-weaver policy show</code> to inspect this file;
            dashboard edits here are the supported path and apply without leaving this pane.
          </p>
        </>
      ) : null}
    </section>
  );
}

export default PolicyPane;
