// Rune Weaver Dashboard — Shared advanced settings disclosure with changed-count trigger.

import { useCallback, useEffect, useRef, useState } from "react";

export interface AdvancedDisclosureProps {
  tabName: string;
  changedCount: number;
  children: React.ReactNode;
  summary?: string;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  testId?: string;
  validationError?: string | null;
  errorKeywords?: string[];
  onReset?: () => void;
  detailsRef?: React.Ref<HTMLDetailsElement>;
}

export function AdvancedDisclosure({
  tabName,
  changedCount,
  children,
  summary,
  open,
  defaultOpen = false,
  onOpenChange,
  testId,
  validationError = null,
  errorKeywords = [],
  onReset,
  detailsRef,
}: AdvancedDisclosureProps) {
  const [internalOpen, setInternalOpen] = useState(defaultOpen);
  const errorLinkRef = useRef<HTMLAnchorElement | null>(null);
  const isControlled = open !== undefined;
  const isOpen = isControlled ? (open as boolean) : internalOpen;

  const matchesError = useCallback(
    (message: string | null | undefined): boolean => {
      if (!message) return false;
      if (errorKeywords.length === 0) return true;
      const lowered = message.toLowerCase();
      return errorKeywords.some((kw) => lowered.includes(kw.toLowerCase()));
    },
    [errorKeywords]
  );

  const setOpen = useCallback(
    (next: boolean) => {
      if (isControlled) {
        onOpenChange?.(next);
      } else {
        setInternalOpen(next);
        onOpenChange?.(next);
      }
    },
    [isControlled, onOpenChange]
  );

  // Fail-closed: an error naming an advanced field forces the panel open so
  // the offending input is visible instead of failing silently behind a
  // collapsed disclosure.
  useEffect(() => {
    if (!validationError) return;
    if (matchesError(validationError) && !isOpen) {
      setOpen(true);
    }
  }, [validationError, isOpen, matchesError, setOpen]);

  useEffect(() => {
    if (isOpen && validationError && matchesError(validationError)) {
      errorLinkRef.current?.focus();
    }
  }, [isOpen, validationError, matchesError]);

  const slug =
    testId ?? `advanced-${tabName.toLowerCase().replace(/\s+/g, "-")}`;
  const chipText = summary ?? `${changedCount} advanced changed`;

  return (
    <div style={{ marginTop: "16px" }}>
      <details
        ref={detailsRef}
        data-testid={slug}
        open={isOpen}
        onToggle={(e) => {
          if (e.target !== e.currentTarget) return;
          setOpen(e.currentTarget.open);
        }}
      >
        <summary
          data-testid={`${slug}-trigger`}
          style={{ cursor: "pointer", fontWeight: 600 }}
        >
          Advanced {tabName} settings ({changedCount} changed)
        </summary>
        <div style={{ marginTop: "12px" }}>{children}</div>
        {isOpen && validationError && matchesError(validationError) ? (
          <p className="advanced-error" style={{ marginTop: "0.75rem" }}>
            <a
              href={`#${slug}-error`}
              id={`${slug}-error`}
              ref={errorLinkRef}
              data-testid={`${slug}-error`}
            >
              {validationError}
            </a>
          </p>
        ) : null}
        {isOpen && onReset ? (
          <div style={{ marginTop: "0.75rem" }}>
            <button
              type="button"
              className="ghost icon-text-btn"
              data-testid={`${slug}-reset`}
              onClick={onReset}
            >
              <span>Reset advanced</span>
            </button>
          </div>
        ) : null}
      </details>
      {!isOpen && changedCount > 0 ? (
        <span
          className="advanced-summary-chip"
          data-testid={`${slug}-chip`}
          style={{ marginLeft: "8px" }}
        >
          {chipText}
        </span>
      ) : null}
    </div>
  );
}

export default AdvancedDisclosure;
