// Rune Weaver Dashboard — Network egress section of the declarative security
// policy surface for policy.toml.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { authHeaders, checkSecretStatus, deleteSecret, listSecretKeys } from "../../api";
import {
  classifyWildcard,
  containsTOMLBreakingScalar,
  parseTrimmedLines,
} from "../../policyHostNormalize";
import {
  BINDING_METHODS,
  isValidBindingKey,
} from "../../policyBindingValidation";
import Modal from "../Modal";
import { validateBindingHostEntry } from "../PolicyBindingModal";
import { normalizeSecretKey } from "../StoreSecretModal";
import TabBar from "../TabBar";
import { CloseIcon } from "../icons";
import { ToastStack } from "../Toast";
import { useToastStack } from "../../hooks/useToastStack";
import {
  AccessCredentialsSection,
  type PolicyBindingDraft,
  type PolicyBindingEditingBinding,
  type PolicyBindingModalState,
} from "./AccessCredentialsSection";

// Postures the egress supervisor enforces. The pane offers only this surviving pair.
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

// Preview diff returned by POST /settings/policy/recheck-local.
interface LocalRecheckPreview {
  added: string[];
  removed: string[];
  unchanged: string[];
  unresolved: string[];
}

// Whether a raw key is usable as a binding name.
function isValidPolicyKey(rawKey: string): boolean { return isValidBindingKey(rawKey ?? ""); }
// Whether a stored value would break TOML quoting.
function hasTomlBreakingChars(entry: string): boolean { return containsTOMLBreakingScalar(entry ?? ""); }
// Splits multiline domain text into canonical entries.
export function parseDomainLines(raw: string): string[] { return parseTrimmedLines(raw ?? "").map((line) => line.toLowerCase()); }
// Joins stored domains for the multiline editor. One host per line keeps diffs readable.
export function formatDomainLines(domains: string[]): string { return (domains ?? []).join(String.fromCharCode(10)); }

// Whether one domain line could be stored. Only an exact host or a single leading star-dot edge
// authorizes; every other star shape would never match at runtime yet would read as allowed, so it
// refuses here before save.
export function isValidDomainLine(entry: string): boolean {
  const lowered = (entry ?? "").trim().toLowerCase();
  if (!lowered) return false;
  if (hasTomlBreakingChars(entry)) return false;
  const tab = String.fromCharCode(9);
  if (lowered.includes(" ") || lowered.includes(tab)) return false;
  if (lowered.includes(",")) return false;
  // Brackets refuse for network entries: only bindings accept bracketed IPv6
  // literals, so a network line carrying [ or ] never authorizes.
  if (lowered.includes("[") || lowered.includes("]")) return false;
  if (lowered.includes("?")) return false;
  if (lowered.includes("/") || lowered.includes("\\") || lowered.includes("@") || lowered.includes("#")) {
    return false;
  }
  // A valid IPv6 literal always carries at least two colons, so a lone colon
  // can only be a port suffix (or another shape DNS never serves).
  if ((lowered.match(/:/g) ?? []).length === 1) return false;
  if (lowered.includes("*")) {
    // Single leading edge only: delegate the star shape to the shared classifyWildcard owner
    // mirroring the server leading-edge contract, so the pane, modal, and preview share one shape
    // verdict.
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

// Validates one loaded or edited draft against the fail-closed bounds the engine enforces. Returns
// human-readable problems; empty means saveable.
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
      problems.push("Allowed domain '" + entry + "' is invalid: use an exact host or a single leading '*.example.com' edge.");
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
      problems.push("Blocked domain '" + entry + "' is invalid: use an exact host or a single leading '*.example.com' edge.");
      break;
    }
  }
  for (const [key, binding] of Object.entries(draft.credentials ?? {})) {
    // TOML-breaking bytes refuse before the alphabet check so an unquotable
    // key can never reach disk serialization even if the alphabet widens.
    if (hasTomlBreakingChars(key)) {
      problems.push("Key '" + key + "' carries characters that would break TOML.");
      continue;
    }
    if (!isValidPolicyKey(key)) {
      problems.push("Key '" + key + "' must use only letters, numbers, _, -, . (max 256 characters).");
      continue;
    }
    const hosts = binding.allowed_hosts ?? [];
    if (hosts.length === 0) {
      problems.push("Key '" + key + "' needs at least one host. Empty hosts mean the credential can never be sent.");
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

// Canonicalizes a policy draft for dirty tracking. Domain lists and binding arrays behave as sets
// while credential keys behave as a map, so a plain stringify would read the same posture dirty when
// only ordering moved.
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

// Normalizes a wire policy payload into the pane draft shape. Accepts the camelCase the engine
// sends while tolerating snake_case fallback from older drafts, so a drifted payload still loads
// instead of blanking the form.
function normalizePolicyPayload(raw: unknown): PolicyDraft {
  const fallback: PolicyDraft = {
    version: 1,
    network: { mode: "allowlist_only", allowed_domains: [], blocked_domains: [], localExemptions: [] },
    credentials: {},
  };
  if (!raw || typeof raw !== "object") return fallback;
  const payload = raw as Record<string, unknown>;
  const networkRaw = (payload.network ?? {}) as Record<string, unknown>;
  const modeRaw =
    typeof networkRaw.mode === "string" && (networkRaw.mode as string).trim()
      ? (networkRaw.mode as string).trim()
      : "allowlist_only";
  const allowedRaw =
    (networkRaw.allowedDomains as unknown) ??
    (networkRaw.allowed_domains as unknown) ??
    [];
  const blockedRaw =
    (networkRaw.blockedDomains as unknown) ??
    (networkRaw.blocked_domains as unknown) ??
    [];
  const credentialsRaw = (payload.credentials ?? {}) as Record<string, unknown>;
  const credentials: Record<string, PolicyBindingDraft> = {};
  for (const [key, bindingRaw] of Object.entries(credentialsRaw)) {
    if (!bindingRaw || typeof bindingRaw !== "object") continue;
    const binding = bindingRaw as Record<string, unknown>;
    const hosts =
      (binding.allowedHosts as unknown) ?? (binding.allowed_hosts as unknown) ?? [];
    const methods =
      (binding.allowedMethods as unknown) ?? (binding.allowed_methods as unknown) ?? [];
    const prefixes =
      (binding.allowedPathPrefixes as unknown) ??
      (binding.allowed_path_prefixes as unknown) ??
      [];
    credentials[key] = {
      allowed_hosts: toStringList(hosts),
      allowed_methods: toStringList(methods).map((entry) => entry.trim().toUpperCase()).filter(Boolean),
      allowed_path_prefixes: toStringList(prefixes),
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
      allowed_domains: toStringList(allowedRaw),
      blocked_domains: toStringList(blockedRaw),
      localExemptions: toStringList(localRaw),
    },
    credentials,
  };
}

// Normalizes a string list from the wire. Non-strings drop.
function toStringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
}

// Normalizes the local-access report the server returns alongside a policy
// write. Accepts camelCase; tolerates snake_case only for never_dialable,
// defaulting every list to [] so a missing report never crashes the disclosure.
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

// Translates the snake_case draft into the camelCase wire shape. localExemptions
// stays server-owned and never rides a write; binding methods normalize to upper case.
function policyWritePayload(draft: PolicyDraft): unknown {
  const credentials: Record<
    string,
    { allowedHosts: string[]; allowedMethods: string[]; allowedPathPrefixes: string[] }
  > = {};
  for (const [key, binding] of Object.entries(draft.credentials ?? {})) {
    credentials[key] = {
      allowedHosts: [...(binding.allowed_hosts ?? [])],
      allowedMethods: [...(binding.allowed_methods ?? [])]
        .map((entry) => (entry ?? "").trim().toUpperCase())
        .filter(Boolean),
      allowedPathPrefixes: [...(binding.allowed_path_prefixes ?? [])],
    };
  }
  return {
    version: draft.version,
    network: {
      mode: draft.network.mode,
      allowedDomains: [...(draft.network.allowed_domains ?? [])],
      blockedDomains: [...(draft.network.blocked_domains ?? [])],
    },
    credentials,
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

// Loads the structured policy snapshot. Reads through the shared owner gate so token mode carries
// the bearer instead of 401ing on a bare fetch.
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

// Persists the structured policy draft. Sends the DTO only so the endpoint
// validates the structured contract.
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

// Previews the local-access re-check for the current draft.
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

const EMPTY_DOMAINS: string[] = [];

// Structured network egress editors.
export function NetworkEgressEditors({
  mode = "allowlist_only",
  allowedDomains = EMPTY_DOMAINS,
  blockedDomains = EMPTY_DOMAINS,
  localExemptions = EMPTY_DOMAINS,
  onModeChange,
  onAllowedDomainsChange,
  onBlockedDomainsChange,
  onRecheck,
  rechecking,
  applying,
}: NetworkEgressEditorsProps) {
  const allowedList = useMemo(() => allowedDomains ?? EMPTY_DOMAINS, [allowedDomains]);
  const blockedList = useMemo(() => blockedDomains ?? EMPTY_DOMAINS, [blockedDomains]);
  const localList = localExemptions ?? EMPTY_DOMAINS;
  // Display buffers keep the typed text while the parent draft stays canonical,
  // so a trailing space stays visible instead of vanishing on the next render.
  const [allowedBuffer, setAllowedBuffer] = useState<string>(() => formatDomainLines(allowedList));
  const [blockedBuffer, setBlockedBuffer] = useState<string>(() => formatDomainLines(blockedList));
  const allowedBufferRef = useRef(allowedBuffer);
  allowedBufferRef.current = allowedBuffer;
  const blockedBufferRef = useRef(blockedBuffer);
  blockedBufferRef.current = blockedBuffer;
  const localText = formatDomainLines(localList);
  const shadowWarnings = findEgressShadowWarnings(allowedList, blockedList);
  const invalidAllowed = allowedList.filter((entry) => !isValidDomainLine(entry));
  const invalidBlocked = blockedList.filter((entry) => !isValidDomainLine(entry));

  useEffect(() => {
    const propText = formatDomainLines(allowedList);
    if (JSON.stringify(parseDomainLines(allowedBufferRef.current)) !== JSON.stringify(allowedList)) {
      setAllowedBuffer(propText);
    }
  }, [allowedList]);

  useEffect(() => {
    const propText = formatDomainLines(blockedList);
    if (JSON.stringify(parseDomainLines(blockedBufferRef.current)) !== JSON.stringify(blockedList)) {
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
          {allowedList.length} {allowedList.length === 1 ? "host" : "hosts"} (one per line,
          blank lines ignored)
        </span>
        {invalidAllowed.length > 0 ? (
          <span className="danger text-sm" data-testid="allowed-domains-error">
            Allowed domain &apos;{invalidAllowed[0]}&apos; is invalid: use an exact host or a
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
          {blockedList.length} {blockedList.length === 1 ? "host" : "hosts"} (one per line,
          blank lines ignored)
        </span>
        {invalidBlocked.length > 0 ? (
          <span className="danger text-sm" data-testid="blocked-domains-error">
            Blocked domain &apos;{invalidBlocked[0]}&apos; is invalid: use an exact host or a
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
          {localList.length} {localList.length === 1 ? "host" : "hosts"} (read-only, one per line)
        </span>
        <span className="form-group-hint" data-testid="local-exemptions-hint">
          Not editable here. The server derives these grants. Exact hosts in Allowed domains that resolve to private addresses are granted when added or via Re-check local access. Wildcards never auto-grant. Metadata and link-local hosts are never allowed.
        </span>
      </div>
      {shadowWarnings.length > 0 ? (
        <div
          data-testid="egress-shadow-warning"
          className="policy-egress-shadow-warning"
        >
          <ul className="policy-list-indent">
            {shadowWarnings.map((entry, index) => (
              <li key={index}>{entry}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}

// Declarative network-plus-credentials policy surface for the Settings Policy tab.
export interface AccessNetworkSectionProps {
  activeView?: "network" | "credentials";
}

export function AccessNetworkSection({ activeView }: AccessNetworkSectionProps = {}) {
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
  const [bindingModal, setBindingModal] = useState<PolicyBindingModalState | null>(null);
  // Full Keychain enumeration for the unlinked section. Refreshed on mount
  // and after each store or delete so orphan rows read immediately.
  const [listedKeys, setListedKeys] = useState<string[]>([]);
  // Tracks enumeration so the empty line never claims a fully-linked state
  // before the first successful load or after a failed enumeration.
  const [listedLoaded, setListedLoaded] = useState(false);
  const [listedError, setListedError] = useState(false);
  // Non-blocking delete confirmation: the pending key renders a true modal so
  // a binding is never removed by an accidental click, mirroring the plugin
  // uninstall confirmation.
  const [pendingDeleteKey, setPendingDeleteKey] = useState<string | null>(null);
  // Combined-delete opt-in for the binding confirm: when checked the same
  // confirm also deletes the Keychain value so no orphan lands in Unlinked.
  const [deleteAlsoSecret, setDeleteAlsoSecret] = useState<boolean>(false);
  // In-place Keychain value entry: null stays closed, otherwise the normalized
  // key plus whether a value is already stored drives Store versus Update copy.
  const [secretModal, setSecretModal] = useState<{ key: string; isUpdate: boolean } | null>(null);
  // Pending Keychain value deletion: the key renders a dedicated confirm modal
  // so a stored value is never removed by an accidental click. The binding
  // itself stays; only the secret slot is deleted.
  const [pendingDeleteSecretKey, setPendingDeleteSecretKey] = useState<string | null>(null);
  // Last accepted snapshot for dirty tracking.
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
  const [policySubTab, setPolicySubTab] = useState<"network" | "credentials">("network");
  const currentTab = activeView ?? policySubTab;
  // Success-only toasts: failures stay as inline banners with no toast.
  const { toasts, pushSuccessToast, dismissToast } = useToastStack();

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

  const refreshListedKeys = useCallback(async () => {
    try {
      const keys = await listSecretKeys();
      setListedKeys(Array.isArray(keys) ? keys : []);
      setListedError(false);
    } catch {
      // Enumeration stays silent; the empty line stays hidden without evidence.
      setListedError(true);
    } finally {
      setListedLoaded(true);
    }
  }, []);

  useEffect(() => {
    void refreshListedKeys();
  }, [refreshListedKeys]);

  // Keys without a draft binding. Derived from the live draft so a rename
  // re-sorts without a refetch.
  const unlinkedKeys = useMemo(() => {
    const bound = new Set<string>();
    for (const key of Object.keys(draft?.credentials ?? {})) {
      const normalized = normalizeSecretKey(key);
      if (normalized) bound.add(normalized);
    }
    const seen = new Set<string>();
    const rows: string[] = [];
    for (const raw of listedKeys ?? []) {
      const normalized = normalizeSecretKey(raw);
      if (!normalized || bound.has(normalized) || seen.has(normalized)) continue;
      seen.add(normalized);
      rows.push(normalized);
    }
    rows.sort((a, b) => a.localeCompare(b));
    return rows;
  }, [draft, listedKeys]);

  // Listed keys are stored by definition, so the Link modal badges them green
  // even though the presence probe only covers bound draft keys.
  const modalSecretStatus = useMemo(
    () => ({
      ...secretStatus,
      ...Object.fromEntries(unlinkedKeys.map((key): [string, boolean] => [key, true])),
    }),
    [secretStatus, unlinkedKeys],
  );

  function handleLinkUnlinkedSecret(rawKey: string) {
    const normalized = normalizeSecretKey(rawKey ?? "");
    if (!normalized) return;
    setBindingModal({ mode: "add", editingKey: null, initialKey: normalized });
  }

  // Field errors gate the pane-local Save. Computed from the live draft so a
  // rejected shape disables persistence before any network write.
  const fieldErrors = useMemo(() => validatePolicyDraft(draft), [draft]);
  const hasFieldErrors = fieldErrors.length > 0;

  const draftSnapshot = draft ? canonicalPolicySnapshot(draft) : null;
  const changed =
    draftSnapshot !== null &&
    lastLoadedRef.current !== null &&
    draftSnapshot !== lastLoadedRef.current;

  // Any edit clears the saved confirmation so a stale success never reads as covering the current
  // draft. The snapshot comparison above stays the source for dirty state while this flag owns only
  // the transient banner.
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
    markEdited((prev) => ({ ...prev, network: { ...prev.network, mode: nextMode } }));
  }
  function handleAllowedDomainsChangeFromEditor(domains: string[]) {
    markEdited((prev) => ({ ...prev, network: { ...prev.network, allowed_domains: domains } }));
  }
  function handleBlockedDomainsChangeFromEditor(domains: string[]) {
    markEdited((prev) => ({ ...prev, network: { ...prev.network, blocked_domains: domains } }));
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
    setDeleteAlsoSecret(false);
  }

  function handleCancelDeleteBinding() {
    setPendingDeleteKey(null);
    setDeleteAlsoSecret(false);
  }

  // Single owner of the combined binding-plus-optional-secret confirm.
  async function handleConfirmDeleteBinding() {
    const key = pendingDeleteKey;
    if (!key) return;
    const shouldDeleteSecret = deleteAlsoSecret;
    setPendingDeleteKey(null);
    setDeleteAlsoSecret(false);
    handleDeleteBinding(key);
    if (!shouldDeleteSecret) return;
    try {
      await deleteSecret(key);
      const status = await checkSecretStatus([key]);
      mergeSingleKeyStatus(key, status);
    } catch {
      // Deletion failures stay silent; the badge keeps its Stored reading.
    }
    void refreshListedKeys();
  }

  // Opens the in-place Keychain entry for one binding key.
  function openSecretModal(rawKey: string) {
    const normalized = normalizeSecretKey(rawKey ?? "");
    if (!normalized) return;
    setSecretModal({
      key: normalized,
      isUpdate: secretStatus[normalized] === true,
    });
  }

  function handleCloseSecretModal() {
    setSecretModal(null);
  }

  // Merges one probed key into the presence map intersected with live keys so a deleted binding
  // cannot persist as a stale Stored pill.
  function mergeSingleKeyStatus(
    probeKey: string,
    status: Record<string, boolean> | null | undefined,
  ) {
    if (!probeKey || !status) return;
    const live = new Set(Object.keys(draft?.credentials ?? {}));
    live.add(probeKey);
    setSecretStatus((prev) => {
      const next = { ...prev, ...status };
      for (const entry of Object.keys(next)) {
        if (!live.has(entry)) delete next[entry];
      }
      return next;
    });
  }

  // Refreshes the badge after a store without closing the binding modal: the
  // single-key probe merges into the map intersected with live keys so a
  // deleted binding cannot persist as a stale Stored pill.
  async function handleSecretModalSuccess(key: string) {
    const normalized = normalizeSecretKey(key ?? "");
    const probeKey = normalized || key;
    if (!probeKey) return;
    try {
      const status = await checkSecretStatus([probeKey]);
      mergeSingleKeyStatus(probeKey, status);
    } catch {
      // Presence probes stay silent so rows fall back to Missing.
    }
    void refreshListedKeys();
  }

  function handleRequestDeleteSecret(key: string) {
    const normalized = normalizeSecretKey(key ?? "");
    if (!normalized) return;
    setPendingDeleteSecretKey(normalized);
  }

  function handleCancelDeleteSecret() {
    setPendingDeleteSecretKey(null);
  }

  // Deletes only the Keychain value; the binding stays. The single-key probe
  // flips the badge back to Missing.
  async function handleConfirmDeleteSecret() {
    const key = pendingDeleteSecretKey;
    if (!key) return;
    setPendingDeleteSecretKey(null);
    try {
      await deleteSecret(key);
      const status = await checkSecretStatus([key]);
      mergeSingleKeyStatus(key, status);
    } catch {
      // Deletion failures stay silent; the badge keeps its Stored reading.
    }
    void refreshListedKeys();
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
    // Pasted surrogate spellings resolve to the bare slot so the draft never
    // stores a colon-bearing key the gate would refuse. Keys outside the
    // surrogate alphabet refuse here so an unusable name never enters the draft.
    const nextKey = normalizeSecretKey(modalDraft?.key ?? "");
    if (!nextKey) return;
    // Fail closed on unquotable bytes before the alphabet gate so the draft
    // never stages a key the store could not serialize back to TOML.
    if (hasTomlBreakingChars(nextKey)) return;
    if (!isValidPolicyKey(nextKey)) return;
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
      pushSuccessToast("Policy saved. Changes apply immediately with no restart.");
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

  // Applies the previewed re-check, then refreshes the draft, banner, and last-loaded tracking from
  // the response.
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
      pushSuccessToast("Policy saved. Changes apply immediately with no restart.");
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

  // Probes Keychain presence for the live binding keys. The effect derives the keys from the
  // signature instead of reading the draft, so a keystroke that only reshapes field text never
  // re-probes.
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
  const editingBinding: PolicyBindingEditingBinding | null = useMemo(() => {
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
        <p className="settings-section-hint">
          System-boundary file roots and blocked paths live in Access →
          Files; fine-grained file write posture (Stage, Ask, Live, Deny per path)
          lives in Access → Files.
        </p>
        {policyPath ? (
          <p className="muted text-sm" data-testid="policy-location">
            Location: <code>{policyPath}</code> ({loadedFromDisk ? "Customized" : "Factory Defaults"})
          </p>
        ) : null}
      </div>

      {loading ? <p className="muted text-sm">Loading policy…</p> : null}

      {!loading ? (
        <div className="policy-invariants" data-testid="policy-invariants">
          {violations.length === 0 ? (
            <div className="policy-invariants-ok">
              <span>
                <strong>All 3 Formal Security Invariants Verified:</strong> Credential Binding
                Confinement, Rule Shadow Prevention, and Local Exemption Safety hold.
              </span>
            </div>
          ) : (
            <div className="policy-invariants-violation">
              <div className="policy-invariants-title">
                <span>
                  {violations.length} Invariant Violation(s) Detected (Policy will fall back to safe
                  default):
                </span>
              </div>
              <ul className="policy-invariants-list">
                {violations.map((entry, index) => (
                  <li key={index} className="policy-invariants-item">
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
          className="settings-save-success"
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
          className="policy-never-dialable"
        >
          Local network access not granted for never-dialable hosts:{" "}
          {neverDialableHosts.join(", ")}. These entries persist name-only with no grant.
        </div>
      ) : null}

      {error ? (
        <div className="error-banner" data-testid="policy-error">
          {error}
        </div>
      ) : null}

      {fieldErrors.length > 0 && draft ? (
        <div className="error-banner" data-testid="policy-field-errors">
          <ul className="policy-list-indent">
            {fieldErrors.map((entry, index) => (
              <li key={index}>{entry}</li>
            ))}
          </ul>
        </div>
      ) : null}

      <ToastStack toasts={toasts} onDismiss={dismissToast} />

      {draft ? (
        <>
          {!activeView ? (
            <TabBar
              tabs={[
                { key: "network", label: "Network", count: null, testId: "policytab-network" },
                { key: "credentials", label: "Credentials", count: null, testId: "policytab-credentials" },
              ]}
              activeKey={policySubTab}
              onSelect={(key) => setPolicySubTab(key === "credentials" ? "credentials" : "network")}
              ariaLabel="Policy sections"
              idPrefix="policy-tab"
              panelIdPrefix="policy-panel"
            />
          ) : null}
          {currentTab === "network" ? (
            <section
              id="policy-panel-network"
              role="tabpanel"
              aria-label="Network"
              data-testid="policy-network-section"
            >
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
          ) : null}

          {/* Single-view mounts render only their view so Network and
              Credentials never share a tab strip; the tab shell keeps the
              credentials section mounted for modal continuity across switches. */}
          {activeView === "network" ? null : (
          <AccessCredentialsSection
            active={currentTab === "credentials"}
            bindings={draft.credentials}
            secretStatus={secretStatus}
            allowedDomains={allowedDomainsForBindings}
            unlinkedKeys={unlinkedKeys}
            listedLoaded={listedLoaded}
            listedError={listedError}
            onAdd={() => setBindingModal({ mode: "add", editingKey: null })}
            onEdit={(key) => setBindingModal({ mode: "edit", editingKey: key })}
            onDeleteRequest={handleRequestDeleteBinding}
            onSetSecret={openSecretModal}
            onDeleteSecretRequest={handleRequestDeleteSecret}
            onLinkUnlinkedSecret={handleLinkUnlinkedSecret}
            bindingModal={bindingModal}
            editingBinding={editingBinding}
            bindingKeys={bindingKeys}
            modalSecretStatus={modalSecretStatus}
            onBindingModalSave={handleBindingModalSave}
            onBindingModalClose={() => setBindingModal(null)}
            onAddAllowedDomains={handleAddAllowedDomains}
            isStoreOpen={Boolean(secretModal)}
            secretModal={secretModal}
            onSecretModalClose={handleCloseSecretModal}
            onSecretModalSuccess={(key) => void handleSecretModalSuccess(key)}
            pendingDeleteKey={pendingDeleteKey}
            deleteAlsoSecret={deleteAlsoSecret}
            onDeleteAlsoSecretChange={setDeleteAlsoSecret}
            onCancelDeleteBinding={handleCancelDeleteBinding}
            onConfirmDeleteBinding={() => void handleConfirmDeleteBinding()}
            pendingDeleteSecretKey={pendingDeleteSecretKey}
            onCancelDeleteSecret={handleCancelDeleteSecret}
            onConfirmDeleteSecret={() => void handleConfirmDeleteSecret()}
          />
          )}

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
                <p className="muted text-sm m-0 mb-2">
                  Preview of the local-access grants this draft would create. Apply grants
                  re-classifies every exact host server-side and persists the result.
                </p>
                <div data-testid="policy-recheck-added" className="mb-2">
                  <strong>Added ({recheckPreview.added.length}):</strong>{" "}
                  {recheckPreview.added.length > 0 ? recheckPreview.added.join(", ") : "none"}
                </div>
                <div data-testid="policy-recheck-removed" className="mb-2">
                  <strong>Removed ({recheckPreview.removed.length}):</strong>{" "}
                  {recheckPreview.removed.length > 0 ? recheckPreview.removed.join(", ") : "none"}
                </div>
                <div data-testid="policy-recheck-unchanged" className="mb-2">
                  <strong>Unchanged ({recheckPreview.unchanged.length}):</strong>{" "}
                  {recheckPreview.unchanged.length > 0
                    ? recheckPreview.unchanged.join(", ")
                    : "none"}
                </div>
                {recheckPreview.unresolved.length > 0 ? (
                  <div data-testid="policy-recheck-unresolved" className="mb-2">
                    <strong>Unresolved ({recheckPreview.unresolved.length}):</strong>{" "}
                    {recheckPreview.unresolved.join(", ")}
                    <p className="muted text-sm m-0 mt-1">
                      Cannot apply while {recheckPreview.unresolved.length}{" "}
                      {recheckPreview.unresolved.length === 1 ? "host remains" : "hosts remain"}{" "}
                      unresolved. Resolve or remove these hosts before applying.
                    </p>
                  </div>
                ) : null}
                {recheckError ? (
                  <div
                    className="error-banner mt-2"
                    data-testid="policy-recheck-error"
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
            <span className="muted text-sm" data-testid="policy-save-hint">
              {changed
                ? "Unsaved changes: bindings stage here until Save."
                : "Bindings stage here until Save; Keychain secrets save immediately."}
            </span>
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
          <p className="muted text-sm mt-3">
            Prefer the terminal? Run <code>rune-weaver policy show</code> to inspect this file;
            dashboard edits here are the supported path and apply without leaving this pane.
          </p>
        </>
      ) : null}
    </section>
  );
}

export default AccessNetworkSection;
