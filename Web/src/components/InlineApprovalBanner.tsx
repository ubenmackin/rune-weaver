// Rune Weaver Dashboard — Inline session approval banner row for the chat view.

import { useEffect, useRef, useState } from "react";
import {
  trustDurationOptions,
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
  ) => void;
}

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

  function handleMenuKeyDown(event: React.KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      closeMenu(true);
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      const next = (focusedIndex + 1) % splitAllowOptions.length;
      setFocusedIndex(next);
      itemRefs.current[next]?.focus();
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      const next =
        (focusedIndex - 1 + splitAllowOptions.length) %
        splitAllowOptions.length;
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
      const last = splitAllowOptions.length - 1;
      setFocusedIndex(last);
      itemRefs.current[last]?.focus();
    }
  }

  function handlePickOption(option: SplitAllowOption) {
    // Chevron picks are Allow-only grants; Deny always records nothing.
    setMenuOpen(false);
    onDecide(request.id, true, option.value, option.widen);
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
        {request.description ? (
          <span className="approval-desc">{request.description}</span>
        ) : null}
      </div>

      {fullArgs ? (
        <pre
          className="inline-approval-args"
          title={fullArgs}
          aria-label={`Arguments for ${request.toolName}`}
        >
          {visibleArgs}
        </pre>
      ) : null}

      <div className="inline-approval-actions">
        <div
          className="split-allow-group"
          ref={menuRef}
          onKeyDown={handleMenuKeyDown}
        >
          {/* Split allow: the main face is the one-click path and always
              stays a single-use grant, while the chevron exposes graduated
              trust without adding a second full-width control. */}
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
        </div>

        {/* Deny records nothing: always send a one-shot marker since
            durations apply to Allow grants only. */}
        <button
          type="button"
          className="danger"
          disabled={deciding}
          onClick={() => onDecide(request.id, false, "thisTime", false)}
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
