// Rune Weaver Dashboard — Inline session approval banner row for the chat view.

import { useEffect, useState } from "react";
import {
  type PermissionRequest,
  type TrustDuration,
} from "../api";
import { durationOptionsFor } from "../approvalsShared";
import { useSplitMenu } from "../useSplitMenu";
import BashTierLine from "./BashTierLine";

export interface InlineApprovalBannerProps {
  request: PermissionRequest;
  deciding: boolean;
  onDecide: (id: string, approved: boolean, duration: TrustDuration) => void;
  menuPlacement?: "auto" | "up" | "down";
}

// Keep inline rows compact: full arguments stay on `title` while the visible
// line truncates, so a large tool payload cannot stretch the chat footer.
const MAX_INLINE_ARGS_CHARS = 280;

// One-shot (coerced-tool) requests resolve a single parked batch: any durable tier coerces to
// thisTime and mints no rule, so a standing deny on one is a dead vote.
const ONE_SHOT_TOOL_NAMES: ReadonlySet<string> = new Set([
  "engine.continue",
  "question.ask",
  "desktop.resume",
  "behavior.brake",
]);

function truncateArgs(value: string): string {
  if (value.length <= MAX_INLINE_ARGS_CHARS) return value;
  return `${value.slice(0, MAX_INLINE_ARGS_CHARS)}…`;
}

// Forward-compatible blocked signal for egress triage.
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

// Reports whether an egress request was denied by an explicit block rather than parked as unlisted.
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
  const [renderUp, setRenderUp] = useState(false);
  // Duration-only quick surfaces: the chevron lists exactly the shared tiers
  // for this request — 7 for plain, 3 for egress-parked — and sends no scope,
  // so the server resolves the request's own target.
  const allowOptions = durationOptionsFor(request);
  // Shared split-menu machine: open state, outside-pointer-down dismissal, focus-on-open, and the
  // allow/deny keyboard flow come from the hook both decision surfaces consume, so the chat banner
  // and dashboard card cannot drift apart.
  const {
    allowOpen: menuOpen,
    denyOpen: denyMenuOpen,
    allowGroupRef: menuRef,
    denyGroupRef: denyMenuRef,
    allowChevronRef: chevronRef,
    denyChevronRef,
    allowItemRefs: itemRefs,
    denyItemRef,
    toggleAllow,
    toggleDeny,
    closeAllowMenu,
    closeDenyMenu,
    handleAllowMenuKeyDown,
    handleDenyMenuKeyDown,
    setFocusedIndex,
  } = useSplitMenu(allowOptions.length);

  const fullArgs = request.input?.argumentsJSON ?? "";
  const visibleArgs = truncateArgs(fullArgs);

  // Position detection: if constrained below, render menus upwards so choices never clip.
  const anyMenuOpen = menuOpen || denyMenuOpen;
  useEffect(() => {
    if (!anyMenuOpen) return;
    if (menuPlacement === "up") {
      setRenderUp(true);
      return;
    }
    if (menuPlacement === "down") {
      setRenderUp(false);
      return;
    }
    const updatePosition = () => {
      const anchor = (menuOpen ? chevronRef.current : denyChevronRef.current) ?? chevronRef.current;
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
  }, [anyMenuOpen, menuOpen, menuPlacement]);

  const egressHost = resolveEgressHost(request);
  const isEgress = Boolean(egressHost);
  const egressBlocked = isEgress ? isEgressBlocked(request) : false;
  const sandboxSummary = resolveSandboxSummary(request);
  // A one-shot request can only deny once: its durable tier coerces to thisTime inside the shared
  // decision contract and mints no rule, so the standing-deny chevron stays off the generic banner
  // entirely, matching the dashboard card.
  const isOneShot = ONE_SHOT_TOOL_NAMES.has(request.toolName);

  function handlePickAllow(value: TrustDuration) {
    closeAllowMenu(false);
    onDecide(request.id, true, value);
  }

  function handlePickDenyAlways() {
    closeDenyMenu(false);
    onDecide(request.id, false, "forever");
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
          // Nil assessment means the background enrichment has not landed yet: show the pending
          // badge with a spinner instead of outcome or warnings, while keeping Allow/Deny fully
          // enabled so safety checking never blocks the decision.
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
          onKeyDown={handleAllowMenuKeyDown}
        >
          <button
            type="button"
            className="primary split-allow-main"
            disabled={deciding}
            onClick={() => onDecide(request.id, true, "thisTime")}
          >
            {isEgress ? "Allow Once" : "Allow"}
          </button>
          <button
            ref={chevronRef}
            type="button"
            className="primary split-allow-chevron"
            disabled={deciding}
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            aria-label={
              isEgress
                ? `Allow options for ${request.toolName} to ${egressHost}`
                : `Allow options for ${request.toolName}`
            }
            onClick={toggleAllow}
          >
            <span aria-hidden="true">▾</span>
          </button>
          {menuOpen && !deciding ? (
            <ul
              className={`split-allow-menu${renderUp ? " split-allow-menu-up" : ""}`}
              role="menu"
              data-placement={renderUp ? "top" : "bottom"}
            >
              {allowOptions.map((option, index) => (
                <li key={option.value} role="none">
                  <button
                    ref={(node) => {
                      itemRefs.current[index] = node;
                    }}
                    type="button"
                    role="menuitem"
                    className="split-allow-menu-item"
                    onClick={() => handlePickAllow(option.value)}
                    onFocus={() => setFocusedIndex(index)}
                  >
                    {option.label}
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
        </div>

        <div
          className="split-deny-group"
          ref={denyMenuRef}
          onKeyDown={handleDenyMenuKeyDown}
        >
          <button
            type="button"
            className="danger split-deny-main"
            disabled={deciding}
            onClick={() => onDecide(request.id, false, "thisTime")}
          >
            Deny
          </button>
          {!isOneShot ? (
            <button
              ref={denyChevronRef}
              type="button"
              className="danger split-deny-chevron"
              disabled={deciding}
              aria-haspopup="menu"
              aria-expanded={denyMenuOpen}
              aria-label={
                isEgress
                  ? `Deny options for ${request.toolName} to ${egressHost}`
                  : `Deny options for ${request.toolName}`
              }
              onClick={toggleDeny}
            >
              <span aria-hidden="true">▾</span>
            </button>
          ) : null}
          {denyMenuOpen && !deciding && !isOneShot ? (
            <ul
              className={`split-allow-menu${renderUp ? " split-allow-menu-up" : ""}`}
              role="menu"
              data-placement={renderUp ? "top" : "bottom"}
            >
              <li role="none">
                <button
                  ref={denyItemRef}
                  type="button"
                  role="menuitem"
                  className="split-allow-menu-item split-allow-menu-item-danger"
                  onClick={handlePickDenyAlways}
                >
                  Deny always
                </button>
              </li>
            </ul>
          ) : null}
        </div>

        <a
          className="ghost icon-text-btn"
          href="#settings?access=rules"
          title="Standing rules live in Settings → Access"
        >
          <span>Manage standing rules</span>
        </a>

        {deciding ? (
          <span className="text-xs muted inline-approval-deciding">
            Deciding…
          </span>
        ) : null}
      </div>
    </div>
  );
}
