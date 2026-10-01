// Rune Weaver Dashboard — Add/Edit modal for one target-bound credential binding.
//
// Purpose: Groups one secret key with its hosts, methods, and path prefixes in a single
// container so the pairing stays explicit: the secret is sent only when host, method, and
// effective path all match. Empty methods or prefixes mean Any while empty hosts means
// the binding can never send, and every prefix applies to every host in the same binding.
// Scope: Pure form state plus inline confinement errors and a live probe preview; TOML
// persistence, Keychain writes, and network allowlist updates stay with the owning pane
// through callbacks.
// Architectural role: Visual editor over the declarative credential-binding contract that
// mirrors the egress supervisor without duplicating its enforcement.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { previewBindingDecision } from "../policyBindingPreview";
import {
  canonicalHostLower,
  classifyWildcard,
  containsTOMLBreakingScalar,
  ipv4NumericValue,
  isSensitiveIPv4Value,
  parseTrimmedLines,
} from "../policyHostNormalize";
import {
  BINDING_METHODS,
  isBindingHostCoveredByNetwork,
  isValidBindingKey,
} from "../policyBindingValidation";

export type BindingMethod = (typeof BINDING_METHODS)[number];

// Draft handed to the owning pane on save. Snake_case aliases ride along so DTO
// readers and camelCase form readers accept the same object without converting.
export interface PolicyBindingDraft {
  key: string;
  hosts: string[];
  methods: string[];
  pathPrefixes: string[];
  allowedHosts: string[];
  allowedMethods: string[];
  allowedPathPrefixes: string[];
  allowed_hosts: string[];
  allowed_methods: string[];
  allowed_path_prefixes: string[];
}

// Initial values for edit mode. Every spelling is accepted so raw DTO rows and
// prior drafts prefill identically.
export interface PolicyBindingInitial {
  key?: string;
  hosts?: string[];
  methods?: string[];
  pathPrefixes?: string[];
  allowedHosts?: string[];
  allowedMethods?: string[];
  allowedPathPrefixes?: string[];
  allowed_hosts?: string[];
  allowed_methods?: string[];
  allowed_path_prefixes?: string[];
}

export interface PolicyBindingModalProps {
  mode?: "add" | "edit";
  initialBinding?: PolicyBindingInitial | null;
  initialKey?: string;
  editingKey?: string | null;
  // Binding keys already present in the live draft. The modal refuses to save
  // onto one unless it is the row being edited, so a rename cannot silently
  // discard the existing binding.
  existingBindingKeys?: string[];
  knownKeys?: string[];
  knownSecretKeys?: string[];
  secretKeys?: string[];
  secretStatus?: Record<string, boolean>;
  keychainStatus?: Record<string, boolean>;
  allowedDomains?: string[];
  networkAllowedDomains?: string[];
  onSave?: (draft: PolicyBindingDraft) => void | Promise<void>;
  onSubmit?: (draft: PolicyBindingDraft) => void | Promise<void>;
  onClose?: () => void;
  onRequestClose?: () => void;
  onAddAllowedDomains?: (domains: string[]) => void;
  onAddToAllowedDomains?: (domains: string[]) => void;
  onFixNetworkCoverage?: (domains: string[]) => void;
  onStoreInKeychain?: (key: string) => void | Promise<void>;
  onStoreSecret?: (key: string) => void | Promise<void>;
  returnFocusRef?: { current: HTMLElement | null } | null;
  invokingRowRef?: { current: HTMLElement | null } | null;
  triggerRef?: { current: HTMLElement | null } | null;
}

// Single owner for textarea list parsing lives in policyHostNormalize: blank
// lines drop so an accidental newline never becomes a stored entry, while
// trimming keeps the editor and the supervisor comparison in agreement. Both
// hosts and prefixes share this rule so the two fields cannot drift apart;
// empty stays Any for prefixes and unusable for hosts, with line numbers
// stable for inline errors.

// Hosts entry point over the shared list rule, so host splitting never diverges from prefix splitting.
export function parseHostsText(text: string): string[] {
  return parseTrimmedLines(text);
}

// Prefixes entry point over the shared list rule: blank lines ignored, empty list means Any.
export function parsePrefixesText(text: string): string[] {
  return parseTrimmedLines(text);
}

// IPv4 confinement numeric value plus sensitive-range verdict live in the
// shared policyHostNormalize owner (decimal/octal/hex 1-4-part parsing plus
// the full engine sensitive table); the modal imports them instead of keeping
// parallel copies. The server remains authoritative on confinement.

// Validates one host line against the confinement the supervisor enforces. Only
// a single leading `*.` edge is meaningful; every other star shape, scheme,
// port, or sensitive literal fails closed with the entry echoed for repair.
// Brackets are an IPv6 literal delimiter rather than glob syntax, so the
// bracket branch below mirrors the server's bracket-stripping canonicalizer.
export function validateBindingHostEntry(entry: string): string | null {
  const trimmed = (entry ?? "").trim();
  if (!trimmed) return "must not be blank";
  if (trimmed.length > 253) {
    return `must not exceed 253 characters (got ${trimmed.length})`;
  }
  const lowered = trimmed.toLowerCase();
  if (lowered.includes("://")) {
    return `must not contain a scheme (got '${entry}'); list the host instead`;
  }
  if (/\s/.test(trimmed)) {
    return `must not contain whitespace (got '${entry}')`;
  }
  // TOML-breaking scalars share one owner mirroring the store alphabet
  // exactly (double quote plus C0 controls plus DEL). The shared gate owns
  // the refusal while the branches below keep distinct repair messages.
  if (containsTOMLBreakingScalar(trimmed)) {
    // eslint-disable-next-line no-control-regex
    if (/[\u0000-\u001F\u007F]/.test(trimmed)) {
      return `must not contain control characters (got '${entry}')`;
    }
    return `must not contain quotes (got '${entry}'); quotes would break TOML`;
  }
  if (trimmed.includes("?") || trimmed.includes("#")) {
    return `must be a host without query or fragment (got '${entry}')`;
  }
  if (trimmed.includes("@")) {
    return `must not contain userinfo (got '${entry}')`;
  }
  if (trimmed.includes("/") || trimmed.includes("\\")) {
    return `must not contain path separators (got '${entry}'); list the host instead`;
  }
  if (lowered === "*") {
    return `must not contain bare "*" (would allow every host)`;
  }
  if (trimmed.includes("*")) {
    // Wildcard shape shares one owner mirroring the server leading-edge
    // contract: only a single leading `*.` edge with a named suffix
    // authorizes, so trailing, doubled, embedded, glob, and port-qualified
    // shapes all refuse here before confinement. The pane and the preview
    // share this same classifier instead of keeping parallel copies.
    const classification = classifyWildcard(lowered);
    if (classification === "invalidSuffix") {
      return `wildcard must name a base domain after "*." (got '${entry}')`;
    }
    if (classification !== "leading") {
      return `only a single leading "*." wildcard is allowed (got '${entry}')`;
    }
    const base = trimmed.slice(2).trim();
    if (!base) {
      return `wildcard must name a base domain after "*." (got '${entry}')`;
    }
    if (base.includes(":") || base.includes("*") || /\s/.test(base)) {
      return `wildcard base must be a plain host (got '${entry}')`;
    }
    const baseLower = canonicalHostLower(base);
    if (baseLower === "localhost" || baseLower === "metadata.google.internal") {
      return `wildcard base '${base}' can never be bound (confinement)`;
    }
    const baseValue = ipv4NumericValue(baseLower);
    if (baseValue !== null && isSensitiveIPv4Value(baseValue)) {
      return `wildcard base '${base}' targets a loopback, private, or link-local range and can never be bound`;
    }
    if (baseLower === "169.254.169.254") {
      return `metadata host '${base}' can never be bound`;
    }
    return null;
  }
  if (trimmed.includes("[") !== trimmed.includes("]")) {
    return `must not contain unbalanced brackets (got '${entry}')`;
  }
  if (trimmed.includes("[") || trimmed.includes("]")) {
    if (!trimmed.startsWith("[") || (trimmed.match(/\[/g) ?? []).length !== 1) {
      return `brackets are only for IPv6 literals (got '${entry}')`;
    }
    const close = trimmed.indexOf("]");
    const inner = trimmed.slice(1, close);
    if (!inner || !inner.includes(":")) {
      return `brackets are only for IPv6 literals (got '${entry}')`;
    }
    const after = trimmed.slice(close + 1);
    if (after) {
      return `must be a host without a port (got '${entry}'); bindings match hosts, not ports`;
    }
    const innerLower = inner.toLowerCase();
    if (innerLower === "::1" || innerLower === "::") {
      return `loopback address '${entry}' can never be bound`;
    }
    if (innerLower.startsWith("fe80:")) {
      return `link-local address '${entry}' can never be bound`;
    }
    return null;
  }
  // Unbracketed colon is either a bare IPv6 literal or a forbidden host:port.
  // A single colon with a numeric tail is a port and refuses; multi-colon
  // literals fall through to the IPv6 confinement below.
  const colonCount = (trimmed.match(/:/g) ?? []).length;
  if (colonCount === 1 && !trimmed.includes(".")) {
    const suffix = trimmed.slice(trimmed.indexOf(":") + 1);
    if (/^[0-9]*$/.test(suffix)) {
      return `must be a host without a port (got '${entry}'); bindings match hosts, not ports`;
    }
    return `must not contain ":" (got '${entry}')`;
  }
  if (colonCount === 1 && trimmed.includes(".")) {
    return `must be a host without a port (got '${entry}'); bindings match hosts, not ports`;
  }
  if (colonCount >= 1 && trimmed.includes(":") && !trimmed.includes(".")) {
    const innerLower = trimmed.toLowerCase();
    if (innerLower === "::1" || innerLower === "::") {
      return `loopback address '${entry}' can never be bound`;
    }
    if (innerLower.startsWith("fe80:")) {
      return `link-local address '${entry}' can never be bound`;
    }
    if (/^[0-9a-f:]+$/i.test(trimmed)) return null;
    return `must not contain ":" (got '${entry}')`;
  }
  // Dotted-tail IPv6 literals carry an IPv4 tail that confinement must judge
  // like its dotted twin, so a private tail cannot hide behind a prefix.
  if (trimmed.includes(":") && trimmed.includes(".")) {
    const tail = trimmed.slice(trimmed.lastIndexOf(":") + 1);
    const tailValue = ipv4NumericValue(tail);
    if (tailValue !== null && isSensitiveIPv4Value(tailValue)) {
      return `host '${entry}' targets a loopback, private, or link-local range and can never be bound`;
    }
  }
  // Trailing dots strip via the shared canonicalizer (all dots, mirroring the
  // engine) so `127.0.0.1..` refuses like `127.0.0.1` instead of bypassing.
  const hostLower = canonicalHostLower(trimmed);
  if (hostLower === "localhost") {
    return `loopback host 'localhost' can never be bound`;
  }
  if (hostLower === "metadata.google.internal") {
    return `metadata host '${entry}' can never be bound`;
  }
  if (hostLower === "169.254.169.254") {
    return `metadata host '${entry}' can never be bound`;
  }
  const numeric = ipv4NumericValue(hostLower);
  if (numeric !== null) {
    if (isSensitiveIPv4Value(numeric)) {
      return `host '${entry}' targets a loopback, private, or link-local range and can never be bound`;
    }
    return null;
  }
  return null;
}

// Validates one path prefix. Prefixes compare verbatim against the resolved
// route path, so only the leading slash is structural; whitespace and raw
// separators would never match yet would read as configured.
export function validateBindingPrefix(entry: string): string | null {
  const trimmed = (entry ?? "").trim();
  if (!trimmed) return "must not be blank";
  if (!trimmed.startsWith("/")) {
    return `must start with '/' (got '${entry}')`;
  }
  if (/\s/.test(trimmed)) {
    return `must not contain whitespace (got '${entry}')`;
  }
  // TOML-breaking scalars share one owner mirroring the store alphabet
  // exactly (double quote plus C0 controls plus DEL). The shared gate owns
  // the refusal while the branches below keep distinct repair messages.
  if (containsTOMLBreakingScalar(trimmed)) {
    // eslint-disable-next-line no-control-regex
    if (/[\u0000-\u001F\u007F]/.test(trimmed)) {
      return `must not contain control characters (got '${entry}')`;
    }
    return `must not contain quotes (got '${entry}'); quotes would break TOML`;
  }
  if (trimmed.includes("\\")) {
    return `must not contain backslashes (got '${entry}')`;
  }
  return null;
}

function initialHostsText(initial: PolicyBindingInitial | null | undefined): string {
  const hosts =
    initial?.hosts ??
    initial?.allowedHosts ??
    initial?.allowed_hosts ??
    [];
  return (hosts ?? []).join("\n");
}

function initialMethods(initial: PolicyBindingInitial | null | undefined): string[] {
  const methods =
    initial?.methods ??
    initial?.allowedMethods ??
    initial?.allowed_methods ??
    [];
  return [...(methods ?? [])].map((method) => method.trim().toUpperCase()).filter(Boolean);
}

function initialPrefixesText(initial: PolicyBindingInitial | null | undefined): string {
  const prefixes =
    initial?.pathPrefixes ??
    initial?.allowedPathPrefixes ??
    initial?.allowed_path_prefixes ??
    [];
  return (prefixes ?? []).join("\n");
}

function initialKeyValue(
  initial: PolicyBindingInitial | null | undefined,
  initialKey: string | undefined,
  editingKey: string | null | undefined,
): string {
  return initial?.key ?? initialKey ?? editingKey ?? "";
}

export function PolicyBindingModal(props: PolicyBindingModalProps) {
  const mode = props.mode ?? (props.initialBinding ? "edit" : "add");
  const knownKeys = useMemo(
    () => props.knownSecretKeys ?? props.knownKeys ?? props.secretKeys ?? [],
    [props.knownSecretKeys, props.knownKeys, props.secretKeys],
  );
  const secretStatus = props.secretStatus ?? props.keychainStatus ?? {};
  const allowedDomains = useMemo(
    () => props.allowedDomains ?? props.networkAllowedDomains ?? [],
    [props.allowedDomains, props.networkAllowedDomains],
  );
  const handleSaveProp = props.onSave ?? props.onSubmit;
  const handleAddAllowedDomains =
    props.onAddAllowedDomains ??
    props.onAddToAllowedDomains ??
    props.onFixNetworkCoverage;
  const handleStoreInKeychain = props.onStoreInKeychain ?? props.onStoreSecret;
  // Stable close wiring: the latest close handler plus focus target ride in
  // refs so requestClose keeps an empty dependency identity even when the
  // parent passes an inline onClose. Escape and click-outside effects then
  // subscribe once instead of per render. Ref updates live in effects so the
  // render stays pure.
  const closeHandlerRef = useRef(props.onClose ?? props.onRequestClose);
  const focusTargetRef = useRef(
    props.returnFocusRef ?? props.invokingRowRef ?? props.triggerRef ?? null,
  );
  useEffect(() => {
    closeHandlerRef.current = props.onClose ?? props.onRequestClose;
  }, [props.onClose, props.onRequestClose]);
  useEffect(() => {
    focusTargetRef.current =
      props.returnFocusRef ?? props.invokingRowRef ?? props.triggerRef ?? null;
  }, [props.returnFocusRef, props.invokingRowRef, props.triggerRef]);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const keyInputRef = useRef<HTMLInputElement | null>(null);

  // Add starts empty with Any defaults; edit prefills every section from the
  // stored binding so the conjunction preview matches the row that opened it.
  const [keyInput, setKeyInput] = useState(() =>
    initialKeyValue(props.initialBinding, props.initialKey, props.editingKey),
  );
  const [hostsText, setHostsText] = useState(() =>
    initialHostsText(props.initialBinding),
  );
  const [methodsMode, setMethodsMode] = useState<"any" | "select">(() =>
    initialMethods(props.initialBinding).length > 0 ? "select" : "any",
  );
  const [selectedMethods, setSelectedMethods] = useState<string[]>(() =>
    initialMethods(props.initialBinding),
  );
  // Prefixes hide behind a collapsed disclosure: empty still means Any and the
  // section never blocks an Any-intent save.
  const [prefixesText, setPrefixesText] = useState(() =>
    initialPrefixesText(props.initialBinding),
  );
  const [probeHost, setProbeHost] = useState("");
  const [probeMethod, setProbeMethod] = useState("GET");
  const [probePath, setProbePath] = useState("/");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  // Move keyboard focus into the dialog on open so screen-reader and keyboard
  // users land on the key field instead of the page behind the backdrop.
  useEffect(() => {
    keyInputRef.current?.focus();
  }, []);

  // Memoized close so the Escape and click-outside effects always observe
  // the latest close handler and focus target without a stale closure.
  // Return focus to the invoking row so keyboard users never lose place.
  // The row stays mounted outside the portal, so a synchronous focus keeps
  // the tab order deterministic across Escape and click-outside. Refs keep
  // this callback stable across renders, so the effects below subscribe once.
  const requestClose = useCallback(() => {
    closeHandlerRef.current?.();
    try {
      focusTargetRef.current?.current?.focus();
    } catch {
      // Focusing is best-effort: a detached row must never block dismissal.
    }
  }, []);

  // Escape closes and returns focus, matching the grouped navigation dropdowns.
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.stopPropagation();
        requestClose();
      }
    }
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [requestClose]);

  // Click-outside closes through the same containment probe as the dropdowns:
  // a mousedown outside the dialog container dismisses while clicks inside are
  // ignored, with no hover-open path.
  useEffect(() => {
    function handleMouseDown(event: MouseEvent) {
      const target = event.target;
      if (
        target instanceof Node &&
        containerRef.current &&
        !containerRef.current.contains(target)
      ) {
        requestClose();
      }
    }
    document.addEventListener("mousedown", handleMouseDown);
    return () => document.removeEventListener("mousedown", handleMouseDown);
  }, [requestClose]);

  const keyTrimmed = keyInput.trim();
  const hostsList = useMemo(() => parseHostsText(hostsText), [hostsText]);
  const prefixesList = useMemo(() => parsePrefixesText(prefixesText), [prefixesText]);
  const methodsForSave = useMemo(
    () => (methodsMode === "any" ? [] : [...selectedMethods].sort()),
    [methodsMode, selectedMethods],
  );

  // The key this modal opened for, so an unchanged edit can be told apart from
  // a rename onto another binding's key when checking for duplicates.
  const originalKey = (props.editingKey ?? props.initialKey ?? props.initialBinding?.key ?? "").trim();
  const existingBindingKeys = props.existingBindingKeys ?? [];

  // Key shape gates resolution; an existing binding key is refused unless it is
  // the row being edited, because saving a rename onto a live key would silently
  // discard that binding before the pane ever sees the conflict.
  const keyError = useMemo(() => {
    if (!keyTrimmed) return "Key is required.";
    if (!isValidBindingKey(keyTrimmed)) {
      return "Key must use only letters, numbers, _, -, . (max 256 characters).";
    }
    if (keyTrimmed !== originalKey && existingBindingKeys.includes(keyTrimmed)) {
      return `A binding for '${keyTrimmed}' already exists. Edit that binding instead of renaming onto it.`;
    }
    return null;
  }, [keyTrimmed, originalKey, existingBindingKeys]);

  // Per-line confinement errors stay inline with the hosts editor so the
  // offending line is repairable without leaving the modal.
  const hostLineErrors = useMemo(() => {
    const problems: Array<{ line: number; entry: string; error: string }> = [];
    const lines = (hostsText ?? "").split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const raw = lines[index];
      if (!raw.trim()) continue;
      const problem = validateBindingHostEntry(raw.trim());
      if (problem) problems.push({ line: index + 1, entry: raw.trim(), error: problem });
    }
    return problems;
  }, [hostsText]);

  const hostsError = useMemo(() => {
    if (hostsList.length === 0) {
      return "Add at least one host — empty hosts means the credential can never be sent.";
    }
    if (hostLineErrors.length > 0) {
      return hostLineErrors
        .map((problem) => `Line ${problem.line}: ${problem.error}`)
        .join(" ");
    }
    return null;
  }, [hostsList, hostLineErrors]);

  const methodsError = useMemo(() => {
    if (methodsMode === "select" && selectedMethods.length === 0) {
      return "Select at least one method or choose Any.";
    }
    for (const method of selectedMethods) {
      if (!(BINDING_METHODS as readonly string[]).includes(method)) {
        return `Unknown method '${method}'. Choose from ${BINDING_METHODS.join(", ")}.`;
      }
    }
    return null;
  }, [methodsMode, selectedMethods]);

  const prefixLineErrors = useMemo(() => {
    const problems: Array<{ line: number; entry: string; error: string }> = [];
    const lines = (prefixesText ?? "").split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const raw = lines[index];
      if (!raw.trim()) continue;
      const problem = validateBindingPrefix(raw.trim());
      if (problem) problems.push({ line: index + 1, entry: raw.trim(), error: problem });
    }
    return problems;
  }, [prefixesText]);

  const prefixesError = useMemo(() => {
    if (prefixLineErrors.length > 0) {
      return prefixLineErrors
        .map((problem) => `Line ${problem.line}: ${problem.error}`)
        .join(" ");
    }
    return null;
  }, [prefixLineErrors]);

  const hasErrors = Boolean(keyError ?? hostsError ?? methodsError ?? prefixesError);

  // Prefixes apply to every host in the same binding, so more than one host
  // plus any prefix is a cross-product the owner should confirm explicitly.
  const showCrossProductWarning = hostsList.length > 1 && prefixesList.length > 0;

  const uncoveredHosts = useMemo(
    () => hostsList.filter((host) => !isBindingHostCoveredByNetwork(host, allowedDomains)),
    [hostsList, allowedDomains],
  );

  // Live probe mirrors the supervisor verdict for the current draft: host,
  // method, and effective path must all match or the reason names the gate.
  const probeDecision = useMemo(
    () =>
      previewBindingDecision(
        {
          allowedHosts: hostsList,
          allowedMethods: methodsForSave,
          allowedPathPrefixes: prefixesList,
        },
        probeHost.trim() || hostsList[0] || "",
        probeMethod.trim() || "GET",
        probePath || "/",
        keyTrimmed || "KEY",
      ),
    [hostsList, methodsForSave, prefixesList, probeHost, probeMethod, probePath, keyTrimmed],
  );

  const conjunctionSentence = useMemo(() => {
    const keyLabel = keyTrimmed || "…";
    const hostsLabel = hostsList.length > 0 ? hostsList.join(", ") : "no hosts (unusable)";
    const methodsLabel = methodsForSave.length > 0 ? methodsForSave.join(", ") : "Any method";
    const prefixesLabel =
      prefixesList.length > 0 ? prefixesList.join(", ") : "Any path";
    return `Key '${keyLabel}' will be sent iff host matches (${hostsLabel}) and method matches (${methodsLabel}) and path matches (${prefixesLabel}).`;
  }, [keyTrimmed, hostsList, methodsForSave, prefixesList]);

  const keyInKeychain = keyTrimmed ? secretStatus[keyTrimmed] === true : false;
  const showKeychainShortcut = Boolean(keyTrimmed) && !keyInKeychain;

  function toggleMethod(method: string) {
    setSelectedMethods((previous) =>
      previous.includes(method)
        ? previous.filter((entry) => entry !== method)
        : [...previous, method].sort(),
    );
  }

  async function handleSave() {
    if (hasErrors || saving) return;
    setSaveError(null);
    setSaving(true);
    try {
      const draft: PolicyBindingDraft = {
        key: keyTrimmed,
        hosts: hostsList,
        methods: methodsForSave,
        pathPrefixes: prefixesList,
        allowedHosts: hostsList,
        allowedMethods: methodsForSave,
        allowedPathPrefixes: prefixesList,
        allowed_hosts: hostsList,
        allowed_methods: methodsForSave,
        allowed_path_prefixes: prefixesList,
      };
      await handleSaveProp?.(draft);
      requestClose();
    } catch (error) {
      setSaveError(error instanceof Error ? error.message : "Failed to save binding.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={requestClose} role="presentation">
      <div
        ref={containerRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label={mode === "edit" ? "Edit credential binding" : "Add credential binding"}
        data-testid="policy-binding-modal"
        className="modal-container policy-binding-modal"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="modal-header">
          <div>
            <h3>{mode === "edit" ? "Edit credential binding" : "Add credential binding"}</h3>
            <span className="muted text-sm">
              {mode === "edit" ? "Update hosts, methods, and paths for this key." : "Pair one key with the hosts, methods, and paths it may reach."}
            </span>
          </div>
          <button
            type="button"
            className="icon-button"
            onClick={requestClose}
            aria-label="Close modal"
          >
            <span aria-hidden="true">×</span>
          </button>
        </div>

        <div className="modal-body">
          {saveError ? <div className="error-banner">{saveError}</div> : null}
          {/* Single pairing container: key, hosts, methods, and paths read as
              one rule so the conjunction is never edited as separate rows. */}
          <div data-testid="binding-pairing-container">
            <p data-testid="binding-pairing-sentence" className="muted text-sm">
              One binding pairs one key with hosts, methods, and path prefixes. The
              secret is sent only when host, method, and effective path all match —
              prefixes apply to every host in this binding.
            </p>

            <section data-testid="key-section">
              <h4>Key</h4>
              <div className="form-group">
                <label htmlFor="binding-key-input">Key</label>
                <input
                  ref={keyInputRef}
                  id="binding-key-input"
                  type="text"
                  className="input-field"
                  aria-label="Key"
                  placeholder="e.g. GITHUB_PAT"
                  value={keyInput}
                  onChange={(event) => setKeyInput(event.target.value)}
                  list="binding-known-keys-list"
                  autoComplete="off"
                  spellCheck={false}
                />
                <datalist id="binding-known-keys-list">
                  {knownKeys.map((known) => (
                    <option key={known} value={known} />
                  ))}
                </datalist>
                <span className="form-group-hint">
                  Letters, numbers, _, -, . only (max 256 characters).
                </span>
              </div>
              {knownKeys.length > 0 ? (
                <div className="form-group">
                  <label htmlFor="binding-known-keys-select">Known keys</label>
                  <select
                    id="binding-known-keys-select"
                    className="input-field"
                    aria-label="Known keys"
                    value={knownKeys.includes(keyTrimmed) ? keyTrimmed : ""}
                    onChange={(event) => setKeyInput(event.target.value)}
                  >
                    <option value="">Choose a known key…</option>
                    {knownKeys.map((known) => (
                      <option key={known} value={known}>
                        {known}
                      </option>
                    ))}
                  </select>
                </div>
              ) : null}
              {keyError ? (
                <div className="error-banner" data-testid="key-error">
                  {keyError}
                </div>
              ) : null}
              <div style={{ display: "flex", alignItems: "center", gap: "8px", marginTop: "6px" }}>
                <span
                  data-testid="keychain-badge"
                  className="status-pill"
                  aria-live="polite"
                >
                  {keyInKeychain ? "In Keychain" : "Not in Keychain"}
                </span>
                {showKeychainShortcut && handleStoreInKeychain ? (
                  <button
                    type="button"
                    className="ghost btn-sm"
                    onClick={() => void handleStoreInKeychain(keyTrimmed)}
                  >
                    Store in Keychain
                  </button>
                ) : null}
              </div>
            </section>

            <section data-testid="hosts-section">
              <h4>Hosts</h4>
              <div className="form-group">
                <label htmlFor="binding-hosts-input">Hosts, one per line</label>
                <textarea
                  id="binding-hosts-input"
                  className="input-field"
                  aria-label="Hosts"
                  placeholder={"api.example.com\n*.example.com"}
                  rows={4}
                  value={hostsText}
                  onChange={(event) => setHostsText(event.target.value)}
                  spellCheck={false}
                />
                <span className="form-group-hint">
                  Exact hosts plus a single leading *. edge. Empty hosts means the
                  credential can never be sent.
                </span>
              </div>
              {hostLineErrors.length > 0 ? (
                <div data-testid="hosts-errors" className="error-banner">
                  <ul style={{ margin: 0, paddingLeft: "18px" }}>
                    {hostLineErrors.map((problem) => (
                      <li key={`${problem.line}-${problem.entry}`}>
                        Line {problem.line} ({problem.entry}): {problem.error}
                      </li>
                    ))}
                  </ul>
                </div>
              ) : null}
              {hostsError && hostLineErrors.length === 0 ? (
                <div className="error-banner" data-testid="hosts-errors">
                  {hostsError}
                </div>
              ) : null}
            </section>

            <section aria-label="Methods" data-testid="methods-section">
              <h4>Methods</h4>
              <div role="radiogroup" aria-label="Method scope">
                <label className="checkbox-row">
                  <input
                    type="radio"
                    name="binding-methods-mode"
                    checked={methodsMode === "any"}
                    onChange={() => setMethodsMode("any")}
                  />
                  <span>Any (empty means Any)</span>
                </label>
                <label className="checkbox-row">
                  <input
                    type="radio"
                    name="binding-methods-mode"
                    checked={methodsMode === "select"}
                    onChange={() => setMethodsMode("select")}
                  />
                  <span>Select methods</span>
                </label>
              </div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: "8px", marginTop: "8px" }}>
                {BINDING_METHODS.map((method) => (
                  <label key={method} className="checkbox-row">
                    <input
                      type="checkbox"
                      checked={
                        methodsMode === "select" ? selectedMethods.includes(method) : false
                      }
                      disabled={methodsMode === "any"}
                      onChange={() => toggleMethod(method)}
                      aria-label={method}
                    />
                    <span>{method}</span>
                  </label>
                ))}
              </div>
              {methodsError ? (
                <div className="error-banner" data-testid="methods-error">
                  {methodsError}
                </div>
              ) : null}
            </section>

            <section aria-label="Paths" data-testid="paths-section">
              <details data-testid="paths-disclosure">
                <summary>Restrict to paths (optional)</summary>
                <p className="muted text-sm">
                  Prefixes apply to every host in this binding. Empty means Any.
                </p>
                <div className="form-group">
                  <label htmlFor="binding-paths-input">Path prefixes, one per line</label>
                  <textarea
                    id="binding-paths-input"
                    className="input-field"
                    aria-label="Path prefixes"
                    placeholder={"/v1/\n/repos/"}
                    rows={3}
                    value={prefixesText}
                    onChange={(event) => setPrefixesText(event.target.value)}
                    spellCheck={false}
                  />
                  <span className="form-group-hint">
                    Each prefix must start with /. Empty means Any.
                  </span>
                </div>
                {prefixLineErrors.length > 0 ? (
                  <div data-testid="paths-error" className="error-banner">
                    <ul style={{ margin: 0, paddingLeft: "18px" }}>
                      {prefixLineErrors.map((problem) => (
                        <li key={`${problem.line}-${problem.entry}`}>
                          Line {problem.line} ({problem.entry}): {problem.error}
                        </li>
                      ))}
                    </ul>
                  </div>
                ) : null}
              </details>
            </section>

            {showCrossProductWarning ? (
              <div
                data-testid="cross-product-warning"
                className="warning-banner"
                role="note"
                style={{
                  padding: "8px 12px",
                  borderRadius: "6px",
                  backgroundColor: "rgba(245, 158, 11, 0.12)",
                  border: "1px solid rgba(245, 158, 11, 0.35)",
                  fontSize: "0.85rem",
                  marginTop: "8px",
                }}
              >
                Prefixes apply to every host in this binding — with {hostsList.length} hosts
                and {prefixesList.length} {prefixesList.length === 1 ? "prefix" : "prefixes"} this
                creates a cross-product: each prefix is checked on every host.
              </div>
            ) : null}
          </div>

          <div data-testid="binding-review" style={{ marginTop: "16px" }}>
            <h4>Review</h4>
            <p className="muted text-sm" data-testid="binding-conjunction">
              {conjunctionSentence}
            </p>
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr 1fr",
                gap: "8px",
              }}
            >
              <div className="form-group">
                <label htmlFor="binding-probe-method">Probe method</label>
                <input
                  id="binding-probe-method"
                  type="text"
                  className="input-field"
                  aria-label="Probe method"
                  value={probeMethod}
                  onChange={(event) => setProbeMethod(event.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
              <div className="form-group">
                <label htmlFor="binding-probe-host">Probe host</label>
                <input
                  id="binding-probe-host"
                  type="text"
                  className="input-field"
                  aria-label="Probe host"
                  placeholder={hostsList[0] ?? "api.example.com"}
                  value={probeHost}
                  onChange={(event) => setProbeHost(event.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
              <div className="form-group">
                <label htmlFor="binding-probe-path">Probe path</label>
                <input
                  id="binding-probe-path"
                  type="text"
                  className="input-field"
                  aria-label="Probe path"
                  value={probePath}
                  onChange={(event) => setProbePath(event.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
            </div>
            <div data-testid="probe-result" aria-live="polite" className="muted text-sm">
              {probeDecision === null ? (
                <span>Yes — the secret would be sent.</span>
              ) : (
                <span>No — {probeDecision}</span>
              )}
            </div>
            <div data-testid="network-coverage" className="muted text-sm" style={{ marginTop: "8px" }}>
              {hostsList.length === 0 ? (
                <span>Add hosts to check network coverage.</span>
              ) : uncoveredHosts.length === 0 ? (
                <span>All binding hosts are covered by Allowed Domains.</span>
              ) : (
                <span>
                  {uncoveredHosts.length} of {hostsList.length} {hostsList.length === 1 ? "host is" : "hosts are"} not in
                  Allowed Domains: {uncoveredHosts.join(", ")}.{" "}
                  {handleAddAllowedDomains ? (
                    <button
                      type="button"
                      className="ghost btn-sm"
                      onClick={() => handleAddAllowedDomains(uncoveredHosts)}
                    >
                      Also add to Allowed Domains
                    </button>
                  ) : null}
                </span>
              )}
            </div>
          </div>
        </div>

        <div className="modal-footer">
          <button type="button" className="ghost" onClick={requestClose}>
            Cancel
          </button>
          <button
            type="button"
            className="primary"
            onClick={() => void handleSave()}
            disabled={hasErrors || saving}
          >
            {saving ? "Saving…" : mode === "edit" ? "Save changes" : "Save binding"}
          </button>
        </div>
      </div>
    </div>
  );
}

export default PolicyBindingModal;
