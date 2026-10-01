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
// like the supervisor treats them.
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
function normalizePolicyPayload(raw: unknown): PolicyDraft {
  const fallback: PolicyDraft = {
    version: 1,
    network: { mode: "allowlist_only", allowed_domains: [], blocked_domains: [] },
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
  return {
    version: typeof versionRaw === "number" && Number.isInteger(versionRaw) ? versionRaw : 1,
    network: {
      mode: modeRaw,
      allowed_domains: toList(allowedRaw),
      blocked_domains: toList(blockedRaw),
    },
    credentials,
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
  };
  return {
    policy: normalizePolicyPayload(payload.policy),
    path: typeof payload.path === "string" ? payload.path : "",
    loadedFromDisk: Boolean(payload.loaded_from_disk ?? payload.loadedFromDisk),
    violations: Array.isArray(payload.violations)
      ? payload.violations.filter((entry): entry is string => typeof entry === "string")
      : [],
  };
}

// Persists the structured policy draft. Sends the DTO only with no legacy raw
// text field so an old editor learns the new contract instead of persisting
// unvalidated text.
// Rejects leave the snapshot untouched so a 400 never silently persists.
export async function savePolicy(draft: PolicyDraft): Promise<PolicyLoadResult> {
  const res = await fetch("/settings/policy", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    credentials: "same-origin",
    body: JSON.stringify({ policy: draft }),
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
  };
  return {
    policy: normalizePolicyPayload(payload.policy),
    path: typeof payload.path === "string" ? payload.path : "",
    loadedFromDisk: Boolean(payload.loaded_from_disk ?? payload.loadedFromDisk),
    violations: Array.isArray(payload.violations)
      ? payload.violations.filter((entry): entry is string => typeof entry === "string")
      : [],
  };
}

export interface NetworkEgressEditorsProps {
  mode?: string;
  allowedDomains?: string[];
  blockedDomains?: string[];
  onModeChange?: (mode: string) => void;
  onAllowedDomainsChange?: (domains: string[]) => void;
  onBlockedDomainsChange?: (domains: string[]) => void;
}

// Structured network egress editors. The mode select offers exactly the two
// surviving postures while the domain textareas keep one host per line; blank
// lines drop on parse so an accidental newline never becomes a stored entry.
// Invalid shapes surface inline before save, shadow overlaps warn with
// blocked-wins copy, and persistence stays with the pane save so there is no
// second network write path to drift from dirty tracking.
export function NetworkEgressEditors({
  mode = "allowlist_only",
  allowedDomains = [],
  blockedDomains = [],
  onModeChange,
  onAllowedDomainsChange,
  onBlockedDomainsChange,
}: NetworkEgressEditorsProps) {
  const allowedList = allowedDomains ?? [];
  const blockedList = blockedDomains ?? [];
  const allowedText = formatDomainLines(allowedList);
  const blockedText = formatDomainLines(blockedList);
  const shadowWarnings = findEgressShadowWarnings(allowedList, blockedList);
  const invalidAllowed = allowedList.filter((entry) => !isValidDomainLine(entry));
  const invalidBlocked = blockedList.filter((entry) => !isValidDomainLine(entry));

  function handleAllowedTextChange(raw: string) {
    if (onAllowedDomainsChange) onAllowedDomainsChange(parseDomainLines(raw));
  }

  function handleBlockedTextChange(raw: string) {
    if (onBlockedDomainsChange) onBlockedDomainsChange(parseDomainLines(raw));
  }

  return (
    <section aria-label="Network egress" data-testid="network-egress-editors">
      <h4>Network egress</h4>
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
          value={allowedText}
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
          value={blockedText}
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
  // dirty on object identity or array order alone.
  const lastLoadedRef = useRef<string | null>(null);

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
  // for dirty state while this flag owns only the transient banner.
  function markEdited(updater: (prev: PolicyDraft) => PolicyDraft) {
    setDraft((prev) => {
      if (!prev) return prev;
      return updater(prev);
    });
    setSaved(false);
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
      setSaved(true);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to save security policy.");
      setSaved(false);
    } finally {
      setSaving(false);
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
                <strong>All 2 Formal Security Invariants Verified:</strong> Credential Binding
                Confinement and Rule Shadow Prevention hold.
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
              onModeChange={handleModeChange}
              onAllowedDomainsChange={handleAllowedDomainsChangeFromEditor}
              onBlockedDomainsChange={handleBlockedDomainsChangeFromEditor}
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

          <div style={{ display: "flex", gap: "8px", alignItems: "center", marginTop: "16px" }}>
            <button
              type="button"
              className="primary"
              data-testid="policy-save"
              onClick={() => void handleSave()}
              disabled={hasFieldErrors || saving || !draft}
            >
              {saving ? "Saving…" : "Save"}
            </button>
            {changed ? <span className="muted text-sm">Unsaved changes.</span> : null}
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
