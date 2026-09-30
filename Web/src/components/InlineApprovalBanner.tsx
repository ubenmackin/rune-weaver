// Rune Weaver Dashboard — Inline session approval banner row for the chat view.

import { useEffect, useRef, useState } from "react";
import {
  trustDurationOptions,
  type EgressDecisionTier,
  type PermissionRequest,
  type TrustDuration,
} from "../api";

export interface InlineApprovalBannerProps {
  request: PermissionRequest;
  deciding: boolean;
  onDecide: (
    id: string,
    approved: boolean,
    duration: TrustDuration,
    widen?: boolean,
    egressDecision?: EgressDecisionTier,
  ) => void;
}

export interface SplitEgressOption {
  value: TrustDuration;
  label: string;
  tier: EgressDecisionTier;
  approved: boolean;
  isDanger?: boolean;
}

export const splitEgressOptions: SplitEgressOption[] = [
  { value: "thisTime", label: "Allow Once", tier: "allowOnce", approved: true },
  { value: "thisTime", label: "Allow During Session", tier: "allowSession", approved: true },
  { value: "forever", label: "Always Allow", tier: "alwaysAllow", approved: true },
  { value: "forever", label: "Deny Always", tier: "denyAlways", approved: false, isDanger: true },
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

// Reads the egress host across both wire spellings. Both fields are typed on
// the shared request, so the fallback needs no cast and stays null when
// neither spelling carries a host.
export function resolveEgressHost(request: PermissionRequest): string | null {
  return request.egressHost ?? request.egress_host ?? null;
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
}: InlineApprovalBannerProps) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [focusedIndex, setFocusedIndex] = useState(0);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const chevronRef = useRef<HTMLButtonElement | null>(null);
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([]);

  const fullArgs = request.input?.argumentsJSON ?? "";
  const visibleArgs = truncateArgs(fullArgs);

  // Dismiss the duration menu on outside pointer down so it never lingers
  // over the input after the user moves on; the parked turn stays decidable
  // by reopening the chevron.
  useEffect(() => {
    if (!menuOpen) return;
    function handlePointerDown(event: PointerEvent) {
      if (
        menuRef.current &&
        !menuRef.current.contains(event.target as Node)
      ) {
        setMenuOpen(false);
      }
    }
    document.addEventListener("pointerdown", handlePointerDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
    };
  }, [menuOpen]);

  // Move focus into the menu on open so arrow-key users land on a choice
  // without an extra tab stop; closing returns focus to the chevron.
  useEffect(() => {
    if (menuOpen) {
      setFocusedIndex(0);
      itemRefs.current[0]?.focus();
    }
  }, [menuOpen]);

  function closeMenu(returnFocus: boolean) {
    setMenuOpen(false);
    if (returnFocus) {
      chevronRef.current?.focus();
    }
  }

  const egressHost = resolveEgressHost(request);
  const isEgress = Boolean(egressHost);
  const egressBlocked = isEgress ? isEgressBlocked(request) : false;
  const currentOptionsCount = isEgress
    ? splitEgressOptions.length
    : splitAllowOptions.length;

  function handleMenuKeyDown(event: React.KeyboardEvent) {
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
    // Chevron picks are Allow-only grants; Deny always records nothing.
    setMenuOpen(false);
    onDecide(request.id, true, option.value, option.widen);
  }

  function handlePickEgressOption(option: SplitEgressOption) {
    setMenuOpen(false);
    onDecide(request.id, option.approved, option.value, false, option.tier);
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
            onClick={() => onDecide(request.id, true, "thisTime", false)}
          >
            Continue
          </button>
          <button
            type="button"
            className="danger"
            disabled={deciding}
            onClick={() => onDecide(request.id, false, "thisTime", false)}
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
                onClick={() =>
                  onDecide(request.id, true, "thisTime", false, "allowOnce")
                }
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
                <ul className="split-allow-menu" role="menu">
                  {splitEgressOptions.map((option, index) => (
                    <li key={option.tier} role="none">
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
                onClick={() => onDecide(request.id, true, "thisTime", false)}
              >
                Allow
              </button>
              <button
                ref={chevronRef}
                type="button"
                className="primary split-allow-chevron"
                disabled={deciding}
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                aria-label={`Allow options for ${request.toolName}`}
                onClick={() => setMenuOpen((open) => !open)}
              >
                <span aria-hidden="true">▾</span>
              </button>
              {menuOpen && !deciding ? (
                <ul className="split-allow-menu" role="menu">
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
                </ul>
              ) : null}
            </>
          )}
        </div>

        <button
          type="button"
          className="danger"
          disabled={deciding}
          onClick={() =>
            isEgress
              ? onDecide(request.id, false, "thisTime", false, "deny")
              : onDecide(request.id, false, "thisTime", false)
          }
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
