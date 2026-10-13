// Rune Weaver Dashboard — Inline session approval banner row for the chat view.

import { useEffect, useRef, useState } from "react";
import {
  trustDurationOptions,
  type AccessScopeDTO,
  type PermissionRequest,
  type TrustDuration,
} from "../api";
import BashTierLine from "./BashTierLine";

export interface InlineApprovalBannerProps {
  request: PermissionRequest;
  deciding: boolean;
  // Every banner path — quick picks, the scope popover, egress picks, and the
  // one-shot cards — sends this one unified decision payload.
  onDecide: (
    id: string,
    approved: boolean,
    duration: TrustDuration,
    scope?: InlineApprovalScope,
  ) => void;
  menuPlacement?: "auto" | "up" | "down";
}

// Scope vocabulary the inline popover builds: the shared decision DTO's four
// kinds plus the path, pattern, and subdomain extensions the engine's rule
// model carries. Exactly one scope rides a decision, so the popover never
// widens past the kind and entries the owner picked.
export type InlineApprovalScope =
  | AccessScopeDTO
  | { kind: "domain"; host: string; subdomains: boolean }
  | { kind: "pathPrefix"; prefix: string }
  | { kind: "glob"; pattern: string };

// How wide a scoped decision reaches, in picker order. `multiple` marks the
// kinds whose list editor collects more than one entry; every single-value
// kind names exactly one target, path, host, or pattern, so its editor holds
// one entry rather than silently dropping the rest.
export type ScopeKind =
  | "thisTarget"
  | "allTargets"
  | "recipients"
  | "paths"
  | "hosts"
  | "pattern";

interface ScopeKindOption {
  value: ScopeKind;
  label: string;
  multiple: boolean;
}

export const scopeKindOptions: ScopeKindOption[] = [
  { value: "thisTarget", label: "This target", multiple: false },
  { value: "allTargets", label: "All targets", multiple: false },
  { value: "recipients", label: "Recipients", multiple: true },
  { value: "paths", label: "Paths", multiple: false },
  { value: "hosts", label: "Hosts / domains", multiple: false },
  { value: "pattern", label: "Pattern", multiple: false },
];

// Builds the one scope a popover submit sends, or null when the entries name
// nothing. Fail-closed: a blank or whitespace-only entry set refuses to send
// instead of shipping a scope that would match every call of the tool.
// Recipient spelling is deliberately left to the engine's canonicalizer, so
// the owner's typed spelling reaches the wire untouched.
export function buildInlineScope(
  kind: ScopeKind,
  entries: string[],
  subdomains: boolean,
): InlineApprovalScope | null {
  const cleaned = entries
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  switch (kind) {
    case "allTargets":
      return { kind: "tool" };
    case "thisTarget":
      return cleaned.length > 0 ? { kind: "exactTarget", target: cleaned[0] } : null;
    case "recipients":
      return cleaned.length > 0 ? { kind: "recipientSet", handles: cleaned } : null;
    case "paths":
      return cleaned.length > 0 ? { kind: "pathPrefix", prefix: cleaned[0] } : null;
    case "hosts":
      return cleaned.length > 0
        ? { kind: "domain", host: cleaned[0], subdomains }
        : null;
    case "pattern":
      return cleaned.length > 0 ? { kind: "glob", pattern: cleaned[0] } : null;
    default:
      return null;
  }
}

export interface SplitEgressOption {
  value: TrustDuration;
  label: string;
  approved: boolean;
  isDanger?: boolean;
}

// Egress-parked requests ride the same unified payload as every other
// request: each item is one (approved, duration) pair and the server resolves
// the domain scope from the parked request itself, so no egress tier travels
// on the wire. Session trust is the `forSession` duration; the two Always
// entries are the durable pair the server turns into a domain rule, and the
// deny-always entry mints the matching durable deny.
export const splitEgressOptions: SplitEgressOption[] = [
  { value: "thisTime", label: "Allow Once", approved: true },
  { value: "forSession", label: "Allow During Session", approved: true },
  { value: "forever", label: "Always Allow", approved: true },
  { value: "forever", label: "Deny Always", approved: false, isDanger: true },
];

interface SplitAllowOption {
  value: TrustDuration;
  label: string;
  widen: boolean;
}

// Single-sourced from the shared trust-duration tiers. Exported so tests can
// pin the banner's rendered options to those tiers and catch a newly added or
// renamed duration drifting out of the inline chat flow.
export const splitAllowOptions: SplitAllowOption[] = [
  ...trustDurationOptions.map((option) => ({
    value: option.value,
    label: option.label,
    widen: false,
  })),
  // Widening is offered for every tier except the one-shot `thisTime` grant,
  // which persists nothing and so can never widen. Deriving both lists from
  // the shared tiers keeps the inline banner in lockstep with the inbox and
  // the engine instead of re-declaring duration values and labels here.
  ...trustDurationOptions
    .filter((option) => option.value !== "thisTime")
    .map((option) => ({
      value: option.value,
      label: `${option.label} (all targets)`,
      widen: true,
    })),
];

// Keep inline rows compact: full arguments stay on `title` while the visible
// line truncates, so a large tool payload cannot stretch the chat footer.
const MAX_INLINE_ARGS_CHARS = 280;

// Single-sourced tier check for the popover's duration select, mirroring the
// inbox's local guard: a drifted value can never reach the decision payload.
function isTrustDurationValue(value: string): value is TrustDuration {
  return trustDurationOptions.some((option) => option.value === value);
}

function truncateArgs(value: string): string {
  if (value.length <= MAX_INLINE_ARGS_CHARS) return value;
  return `${value.slice(0, MAX_INLINE_ARGS_CHARS)}…`;
}

// Forward-compatible blocked signal for egress triage. The engine currently
// tags only the host, so absent fields read as unlisted; when the payload
// carries an explicit blocked flag or a verdict/reason naming a block, the
// banner names the denial instead of understating it as an allowlist miss.
interface EgressVerdictShape {
  egressBlocked?: unknown;
  egress_blocked?: unknown;
  egressDenied?: unknown;
  egress_denied?: unknown;
  egressVerdict?: unknown;
  egress_verdict?: unknown;
  egressReason?: unknown;
  egress_reason?: unknown;
}

// Reads the egress host from the wire payload.
export function resolveEgressHost(request: PermissionRequest): string | null {
  return request.egressHost ?? null;
}

// Server-stamped sandbox tier line. Absent or non-string reads as null so the tier line renders nothing.
export function resolveSandboxSummary(
  request: PermissionRequest,
): string | null {
  if (typeof request.sandboxSummary === "string") return request.sandboxSummary;
  return null;
}

// Reports whether an egress request was denied by an explicit block rather
// than parked as unlisted. Strict boolean flags win; verdict and reason
// strings count only when they name a block, so drifted text never flips
// the copy. Unknown shapes stay unlisted.
export function isEgressBlocked(request: PermissionRequest): boolean {
  const extra = request as PermissionRequest & EgressVerdictShape;
  const flags = [
    extra.egressBlocked,
    extra.egress_blocked,
    extra.egressDenied,
    extra.egress_denied,
  ];
  for (const flag of flags) {
    if (flag === true) return true;
  }
  const texts = [
    extra.egressVerdict,
    extra.egress_verdict,
    extra.egressReason,
    extra.egress_reason,
  ];
  for (const text of texts) {
    if (typeof text === "string" && text.toLowerCase().includes("block")) {
      return true;
    }
  }
  return false;
}

export default function InlineApprovalBanner({
  request,
  deciding,
  onDecide,
  menuPlacement = "auto",
}: InlineApprovalBannerProps) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [renderUp, setRenderUp] = useState(false);
  const [focusedIndex, setFocusedIndex] = useState(0);
  const [scopeOpen, setScopeOpen] = useState(false);
  const [scopeKind, setScopeKind] = useState<ScopeKind>("thisTarget");
  const [scopeEntries, setScopeEntries] = useState<string[]>([]);
  const [scopeDraft, setScopeDraft] = useState("");
  const [scopeSubdomains, setScopeSubdomains] = useState(false);
  // A scope only matters for a stored rule, so the popover opens on the
  // standing tier while every shared duration stays one pick away.
  const [scopeDuration, setScopeDuration] = useState<TrustDuration>("forever");
  const menuRef = useRef<HTMLDivElement | null>(null);
  const chevronRef = useRef<HTMLButtonElement | null>(null);
  const scopeKindRef = useRef<HTMLSelectElement | null>(null);
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([]);

  const fullArgs = request.input?.argumentsJSON ?? "";
  const visibleArgs = truncateArgs(fullArgs);

  // Position detection: if constrained below, render menu upwards so choices never clip.
  useEffect(() => {
    if (!menuOpen) return;
    if (menuPlacement === "up") {
      setRenderUp(true);
      return;
    }
    if (menuPlacement === "down") {
      setRenderUp(false);
      return;
    }
    const updatePosition = () => {
      const anchor = chevronRef.current;
      if (!anchor) return;
      const rect = anchor.getBoundingClientRect();
      const spaceBelow = window.innerHeight - rect.bottom;
      const spaceAbove = rect.top;
      // If space below is not enough for the full menu (~320px) and there's more space above,
      // render upward so it never clips into the bottom edge of the panel or screen.
      setRenderUp(spaceBelow < 320 && spaceAbove > spaceBelow);
    };
    updatePosition();
    window.addEventListener("resize", updatePosition);
    window.addEventListener("scroll", updatePosition, true);
    return () => {
      window.removeEventListener("resize", updatePosition);
      window.removeEventListener("scroll", updatePosition, true);
    };
  }, [menuOpen, menuPlacement]);

  // Dismiss the duration menu on outside pointer down so it never lingers
  // over the input after the user moves on; the parked turn stays decidable
  // by reopening the chevron. The scope popover rides the same dismissal so
  // neither layer outlives a click elsewhere.
  useEffect(() => {
    if (!menuOpen && !scopeOpen) return;
    function handlePointerDown(event: PointerEvent) {
      if (
        menuRef.current &&
        !menuRef.current.contains(event.target as Node)
      ) {
        setMenuOpen(false);
        setScopeOpen(false);
      }
    }
    document.addEventListener("pointerdown", handlePointerDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
    };
  }, [menuOpen, scopeOpen]);

  // Move focus into the menu on open so arrow-key users land on a choice
  // without an extra tab stop; closing returns focus to the chevron.
  useEffect(() => {
    if (menuOpen) {
      setFocusedIndex(0);
      itemRefs.current[0]?.focus();
    }
  }, [menuOpen]);

  // Same contract for the scope popover: focus lands on the kind selector and
  // Escape (handled on the popover) returns focus to the chevron.
  useEffect(() => {
    if (scopeOpen) {
      scopeKindRef.current?.focus();
    }
  }, [scopeOpen]);

  function closeMenu(returnFocus: boolean) {
    setMenuOpen(false);
    if (returnFocus) {
      chevronRef.current?.focus();
    }
  }

  function openScopePopover() {
    // Fresh popover per open so a stale entry can never ride the next
    // decision; the chevron menu closes because the popover replaces it.
    setMenuOpen(false);
    setScopeKind("thisTarget");
    setScopeEntries([]);
    setScopeDraft("");
    setScopeSubdomains(false);
    setScopeDuration("forever");
    setScopeOpen(true);
  }

  function closeScopePopover() {
    setScopeOpen(false);
    chevronRef.current?.focus();
  }

  const egressHost = resolveEgressHost(request);
  const isEgress = Boolean(egressHost);
  const egressBlocked = isEgress ? isEgressBlocked(request) : false;
  const sandboxSummary = resolveSandboxSummary(request);
  // The non-egress menu carries the quick options plus the scope-popover row.
  const currentOptionsCount = isEgress
    ? splitEgressOptions.length
    : splitAllowOptions.length + 1;
  const scopeIndex = splitAllowOptions.length;
  const scopeKindOption =
    scopeKindOptions.find((option) => option.value === scopeKind) ??
    scopeKindOptions[0];
  const pendingScope = buildInlineScope(
    scopeKind,
    scopeEntries,
    scopeSubdomains,
  );

  function handleMenuKeyDown(event: React.KeyboardEvent) {
    // Only the open menu owns these keys; the scope popover handles its own
    // Escape so arrow keys inside its controls stay native.
    if (!menuOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeMenu(true);
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      const next = (focusedIndex + 1) % currentOptionsCount;
      setFocusedIndex(next);
      itemRefs.current[next]?.focus();
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      const next =
        (focusedIndex - 1 + currentOptionsCount) %
        currentOptionsCount;
      setFocusedIndex(next);
      itemRefs.current[next]?.focus();
      return;
    }
    if (event.key === "Home") {
      event.preventDefault();
      setFocusedIndex(0);
      itemRefs.current[0]?.focus();
      return;
    }
    if (event.key === "End") {
      event.preventDefault();
      const last = currentOptionsCount - 1;
      setFocusedIndex(last);
      itemRefs.current[last]?.focus();
    }
  }

  function handlePickOption(option: SplitAllowOption) {
    // Chevron picks are Allow-only grants: the all-targets variants widen to
    // one tool-wide scope while the per-target picks let the engine resolve
    // the request's own target.
    setMenuOpen(false);
    onDecide(
      request.id,
      true,
      option.value,
      option.widen ? { kind: "tool" } : undefined,
    );
  }

  function handlePickEgressOption(option: SplitEgressOption) {
    // One unified payload per pick: the server reads the parked egress host
    // and maps the (approved, duration) pair onto its egress decision.
    setMenuOpen(false);
    onDecide(request.id, option.approved, option.value);
  }

  function handleAddScopeEntry() {
    const trimmed = scopeDraft.trim();
    if (!trimmed) return;
    setScopeEntries((previous) => [...previous, trimmed]);
    setScopeDraft("");
  }

  function handleRemoveScopeEntry(index: number) {
    setScopeEntries((previous) => previous.filter((_, at) => at !== index));
  }

  function handleSubmitScope() {
    // A blank entry set names no target, so the popover refuses to decide
    // rather than sending a scope that matches nothing.
    if (!pendingScope) return;
    setScopeOpen(false);
    onDecide(request.id, true, scopeDuration, pendingScope);
  }

  function handleScopeKeyDown(event: React.KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      // Stop propagation so the shared menu handler does not also run while
      // the popover owns the keyboard.
      event.stopPropagation();
      closeScopePopover();
    }
  }

  const isContinuation = request.toolName === "engine.continue";
  if (isContinuation) {
    return (
      <div
        className="card inline-approval-banner"
        data-testid={`inline-approval-${request.id}`}
      >
        <div className="inline-approval-header">
          <span className="badge approval-tool-badge">Continuation</span>
          <span className="approval-desc">
            {request.description || "The agent has completed its allocated tool rounds. Continue?"}
          </span>
        </div>

        <div className="inline-approval-actions">
          <button
            type="button"
            className="primary"
            disabled={deciding}
            onClick={() => onDecide(request.id, true, "thisTime")}
          >
            Continue
          </button>
          <button
            type="button"
            className="danger"
            disabled={deciding}
            onClick={() => onDecide(request.id, false, "thisTime")}
          >
            Stop
          </button>
          {deciding ? (
            <span className="text-xs muted inline-approval-deciding">
              Deciding…
            </span>
          ) : null}
        </div>
      </div>
    );
  }

  const isDesktopResume = request.toolName === "desktop.resume";
  if (isDesktopResume) {
    return (
      <div
        className="card inline-approval-banner"
        data-testid={`inline-approval-${request.id}`}
      >
        <div className="inline-approval-header">
          <span className="badge approval-tool-badge" style={{ backgroundColor: "#eab308", color: "#000" }}>Desktop Paused</span>
          <span className="approval-desc">
            {request.description || "Desktop automation paused because you moved the mouse. Resume agent control to capture a fresh screenshot and continue."}
          </span>
        </div>

        <div className="inline-approval-actions">
          <button
            type="button"
            className="primary"
            disabled={deciding}
            onClick={() => onDecide(request.id, true, "thisTime")}
          >
            Resume Control
          </button>
          <button
            type="button"
            className="danger"
            disabled={deciding}
            onClick={() => onDecide(request.id, false, "thisTime")}
          >
            Cancel Task
          </button>
          {deciding ? (
            <span className="text-xs muted inline-approval-deciding">
              Deciding…
            </span>
          ) : null}
        </div>
      </div>
    );
  }

  return (
    <div
      className="card inline-approval-banner"
      data-testid={`inline-approval-${request.id}`}
    >
      <div className="inline-approval-header">
        <span className="badge approval-tool-badge">{request.toolName}</span>
        {isEgress ? (
          <span
            className="badge approval-egress-badge"
            data-testid={`approval-egress-${request.id}`}
          >
            🌐 {egressHost}
          </span>
        ) : null}
        {request.assessment ? (
          // Fail-closed on unknown tiers: only the three engine-known
          // severities render a badge so a drifted value never guesses a
          // color or copies the wrong outcome tone.
          request.assessment.severity === "safe" ||
          request.assessment.severity === "moderate" ||
          request.assessment.severity === "dangerous" ? (
            <span
              className={`badge approval-severity-badge severity-${request.assessment.severity}`}
              data-testid={`approval-severity-${request.id}`}
            >
              {request.assessment.severity === "safe" && "🟢 Safe"}
              {request.assessment.severity === "moderate" && "🟡 State Change"}
              {request.assessment.severity === "dangerous" && "🔴 Dangerous"}
            </span>
          ) : null
        ) : (
          // Nil assessment means the background enrichment has not landed
          // yet: show the pending badge with a spinner instead of outcome
          // or warnings, while keeping Allow/Deny fully enabled so safety
          // checking never blocks the decision.
          <span
            className="badge approval-severity-badge severity-pending"
            data-testid={`approval-assessment-pending-${request.id}`}
          >
            <span
              className="approval-assessment-pending approval-assessment-pending-spinner"
              aria-hidden="true"
            />
            Checking safety…
          </span>
        )}
      </div>

      {isEgress ? (
        <div className="approval-narrative" style={{ color: "var(--text-muted)" }}>
          <span className="approval-section-label">Target host:</span>{" "}
          <code style={{ color: "var(--accent-purple, #a78bfa)" }}>{egressHost}</code>{" "}
          {egressBlocked ? "is blocked by policy." : "is not in allowlist."}
        </div>
      ) : null}

      {request.intent ? (
        <div className="approval-narrative approval-intent">
          <span className="approval-section-label">Why:</span> {request.intent}
        </div>
      ) : request.description && !request.assessment ? (
        <div className="approval-narrative approval-intent">
          {request.description}
        </div>
      ) : null}

      {request.assessment?.outcome ? (
        <div className="approval-narrative approval-outcome">
          <span className="approval-section-label">Expected outcome:</span>{" "}
          {request.assessment.outcome}
        </div>
      ) : null}

      <BashTierLine summary={sandboxSummary} />

      {request.assessment?.warnings && request.assessment.warnings.length > 0 ? (
        <ul className="approval-warnings">
          {request.assessment.warnings.map((w, idx) => (
            <li key={idx} className="approval-warning-item">
              ⚠️ {w}
            </li>
          ))}
        </ul>
      ) : null}

      {fullArgs ? (
        <details className="approval-args-details">
          <summary className="approval-args-summary">View arguments</summary>
          <pre
            className="inline-approval-args"
            title={fullArgs}
            aria-label={`Arguments for ${request.toolName}`}
          >
            {visibleArgs}
          </pre>
        </details>
      ) : null}

      <div className="inline-approval-actions">
        <div
          className="split-allow-group"
          ref={menuRef}
          onKeyDown={handleMenuKeyDown}
        >
          {isEgress ? (
            <>
              <button
                type="button"
                className="primary split-allow-main"
                disabled={deciding}
                onClick={() => onDecide(request.id, true, "thisTime")}
              >
                Allow Once
              </button>
              <button
                ref={chevronRef}
                type="button"
                className="primary split-allow-chevron"
                disabled={deciding}
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                aria-label={`Allow options for ${request.toolName} to ${egressHost}`}
                onClick={() => setMenuOpen((open) => !open)}
              >
                <span aria-hidden="true">▾</span>
              </button>
              {menuOpen && !deciding ? (
                <ul
                  className={`split-allow-menu${renderUp ? " split-allow-menu-up" : ""}`}
                  role="menu"
                  data-placement={renderUp ? "top" : "bottom"}
                >
                  {splitEgressOptions.map((option, index) => (
                    <li key={option.label} role="none">
                      {option.isDanger ? (
                        <div className="split-allow-menu-divider" />
                      ) : null}
                      <button
                        ref={(node) => {
                          itemRefs.current[index] = node;
                        }}
                        type="button"
                        role="menuitem"
                        className={`split-allow-menu-item${option.isDanger ? " split-allow-menu-item-danger" : ""}`}
                        onClick={() => handlePickEgressOption(option)}
                        onFocus={() => setFocusedIndex(index)}
                      >
                        {option.label}
                      </button>
                    </li>
                  ))}
                </ul>
              ) : null}
            </>
          ) : (
            <>
              <button
                type="button"
                className="primary split-allow-main"
                disabled={deciding}
                onClick={() => onDecide(request.id, true, "thisTime")}
              >
                Allow
              </button>
              <button
                ref={chevronRef}
                type="button"
                className="primary split-allow-chevron"
                disabled={deciding}
                aria-haspopup="menu"
                aria-expanded={menuOpen || scopeOpen}
                aria-label={`Allow options for ${request.toolName}`}
                onClick={() => {
                  // Reopening the menu replaces the popover so the two layers
                  // never stack over the same anchor.
                  setScopeOpen(false);
                  setMenuOpen((open) => !open);
                }}
              >
                <span aria-hidden="true">▾</span>
              </button>
              {menuOpen && !deciding ? (
                <ul
                  className={`split-allow-menu${renderUp ? " split-allow-menu-up" : ""}`}
                  role="menu"
                  data-placement={renderUp ? "top" : "bottom"}
                >
                  {splitAllowOptions.map((option, index) => (
                    <li key={`${option.value}-${option.widen}`} role="none">
                      <button
                        ref={(node) => {
                          itemRefs.current[index] = node;
                        }}
                        type="button"
                        role="menuitem"
                        className="split-allow-menu-item"
                        onClick={() => handlePickOption(option)}
                        onFocus={() => setFocusedIndex(index)}
                      >
                        {option.label}
                      </button>
                    </li>
                  ))}
                  <li role="none">
                    <div className="split-allow-menu-divider" />
                    <button
                      ref={(node) => {
                        itemRefs.current[scopeIndex] = node;
                      }}
                      type="button"
                      role="menuitem"
                      className="split-allow-menu-item"
                      onClick={openScopePopover}
                      onFocus={() => setFocusedIndex(scopeIndex)}
                    >
                      For these targets…
                    </button>
                  </li>
                </ul>
              ) : null}
              {scopeOpen && !deciding ? (
                <div
                  className={`split-allow-menu split-allow-scope-popover${renderUp ? " split-allow-menu-up" : ""}`}
                  role="dialog"
                  aria-label={`Choose scope for ${request.toolName}`}
                  data-testid={`inline-scope-${request.id}`}
                  data-placement={renderUp ? "top" : "bottom"}
                  onKeyDown={handleScopeKeyDown}
                >
                  <label className="approval-duration-label">
                    <span className="text-sm muted">Applies to:</span>
                    <select
                      ref={scopeKindRef}
                      aria-label={`Scope kind for ${request.toolName}`}
                      value={scopeKind}
                      onChange={(event) => {
                        const next = event.target.value;
                        setScopeKind(
                          scopeKindOptions.some((option) => option.value === next)
                            ? (next as ScopeKind)
                            : "thisTarget",
                        );
                        // Entries never carry across kinds: a recipient handle
                        // is not a path prefix, so a kind switch starts clean.
                        setScopeEntries([]);
                        setScopeDraft("");
                      }}
                    >
                      {scopeKindOptions.map((option) => (
                        <option key={option.value} value={option.value}>
                          {option.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  {scopeKind === "allTargets" ? (
                    <p className="text-xs muted inline-scope-note">
                      Covers every {request.toolName} call, whatever the
                      arguments say.
                    </p>
                  ) : scopeKindOption.multiple ? (
                    <>
                      {scopeEntries.length > 0 ? (
                        <ul className="inline-scope-entries">
                          {scopeEntries.map((entry, index) => (
                            <li
                              key={`${entry}-${index}`}
                              className="inline-scope-entry"
                            >
                              <span className="text-sm">{entry}</span>
                              <button
                                type="button"
                                className="split-allow-menu-item inline-scope-remove"
                                aria-label={`Remove ${entry}`}
                                onClick={() => handleRemoveScopeEntry(index)}
                              >
                                ✕
                              </button>
                            </li>
                          ))}
                        </ul>
                      ) : null}
                      <div className="inline-scope-add">
                        <input
                          aria-label={`Add ${scopeKindOption.label.toLowerCase()} for ${request.toolName}`}
                          value={scopeDraft}
                          onChange={(event) => setScopeDraft(event.target.value)}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") {
                              event.preventDefault();
                              handleAddScopeEntry();
                            }
                          }}
                        />
                        <button
                          type="button"
                          className="split-allow-menu-item"
                          onClick={handleAddScopeEntry}
                        >
                          Add
                        </button>
                      </div>
                    </>
                  ) : (
                    <input
                      className="inline-scope-single"
                      aria-label={`${scopeKindOption.label} for ${request.toolName}`}
                      value={scopeEntries[0] ?? ""}
                      onChange={(event) =>
                        setScopeEntries([event.target.value])
                      }
                    />
                  )}

                  {scopeKind === "hosts" ? (
                    <label className="approval-widen-toggle">
                      <input
                        type="checkbox"
                        aria-label={`Include subdomains of ${scopeEntries[0] ?? ""}`}
                        checked={scopeSubdomains}
                        onChange={(event) =>
                          setScopeSubdomains(event.target.checked)
                        }
                      />
                      <span className="text-sm muted">Include subdomains</span>
                    </label>
                  ) : null}

                  <label className="approval-duration-label">
                    <span className="text-sm muted">Duration:</span>
                    <select
                      aria-label={`Scope duration for ${request.toolName}`}
                      value={scopeDuration}
                      onChange={(event) => {
                        const next = event.target.value;
                        setScopeDuration(
                          isTrustDurationValue(next) ? next : "forever",
                        );
                      }}
                    >
                      {trustDurationOptions.map((option) => (
                        <option key={option.value} value={option.value}>
                          {option.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  <div className="inline-scope-actions">
                    <button
                      type="button"
                      className="primary"
                      disabled={!pendingScope}
                      onClick={handleSubmitScope}
                    >
                      Allow for these targets
                    </button>
                    <button
                      type="button"
                      className="split-allow-menu-item"
                      onClick={closeScopePopover}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              ) : null}
            </>
          )}
        </div>

        <button
          type="button"
          className="danger"
          disabled={deciding}
          onClick={() => onDecide(request.id, false, "thisTime")}
        >
          Deny
        </button>

        {deciding ? (
          <span className="text-xs muted inline-approval-deciding">
            Deciding…
          </span>
        ) : null}
      </div>
    </div>
  );
}
