// Rune Weaver Dashboard — Shared advanced settings disclosure.

import { useCallback, useEffect, useRef, useState } from "react";

export interface AdvancedDisclosureProps {
  tabName: string;
  children: React.ReactNode;
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
  children,
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

  const matchesError = useCallback(
    (message: string | null | undefined): boolean => {
      if (!message) return false;
      if (errorKeywords.length === 0) return true;
      const lowered = message.toLowerCase();
      return errorKeywords.some((kw) => lowered.includes(kw.toLowerCase()));
    },
    [errorKeywords]
  );

  const isControlled = open !== undefined;
  // Controlled panels stay shut on matching errors when the parent lags,
  // so derive force-open for an immediate render plus the state push.
  const forceOpen = validationError != null && matchesError(validationError);
  const isOpen = isControlled
    ? ((open as boolean) || forceOpen)
    : (internalOpen || forceOpen);

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
    if (!matchesError(validationError)) return;
    if (isControlled) {
      if (!(open as boolean)) setOpen(true);
    } else if (!internalOpen) {
      setOpen(true);
    }
  }, [validationError, open, internalOpen, isControlled, matchesError, setOpen]);

  useEffect(() => {
    if (isOpen && validationError && matchesError(validationError)) {
      errorLinkRef.current?.focus();
    }
  }, [isOpen, validationError, matchesError]);

  const slug =
    testId ?? `advanced-${tabName.toLowerCase().replace(/\s+/g, "-")}`;

  return (
    <div className="mt-4">
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
          className="advanced-disclosure-trigger"
        >
          Advanced {tabName} settings
        </summary>
        <div className="mt-3">{children}</div>
        {isOpen && validationError && matchesError(validationError) ? (
          <p className="advanced-error mt-3">
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
          <div className="mt-3">
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
    </div>
  );
}

export default AdvancedDisclosure;
