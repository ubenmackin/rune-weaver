// Rune Weaver Dashboard — Shared portal modal for confirmations and detail views.

import { useEffect, useRef, type MouseEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";

interface ModalProps {
  // Accessible dialog name announced to assistive technology.
  label: string;
  // Dismissal for backdrop click and Escape; callers guard when an async
  // action (clearing, deleting) must block dismissal.
  onClose: () => void;
  // Dialog content including the modal-header, modal-body, and modal-footer
  // sections so each caller keeps its identical visuals.
  children: ReactNode;
  // Full container class list (for example "modal-container
  // session-delete-modal") so size variants stay with the caller.
  containerClassName?: string;
}

export default function Modal({
  label,
  onClose,
  children,
  containerClassName = "modal-container",
}: ModalProps) {
  // Focus the container on open via effect instead of autoFocus so focus
  // lands inside the dialog for keyboard users without stealing it on
  // unrelated rerenders.
  const containerRef = useRef<HTMLDivElement | null>(null);

  // Dismiss on Escape, matching every confirmation and detail dialog.
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        onClose();
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose]);

  // Move focus into the dialog when it opens for keyboard users.
  useEffect(() => {
    containerRef.current?.focus();
  }, []);

  // Portal to document.body so the dialog escapes stacking contexts.
  if (typeof document === "undefined") return null;

  return createPortal(
    <div
      className="modal-backdrop"
      onClick={onClose}
      role="dialog"
      aria-label={label}
      aria-modal="true"
    >
      <div
        ref={containerRef}
        tabIndex={-1}
        className={containerClassName}
        onClick={(event: MouseEvent) => event.stopPropagation()}
      >
        {children}
      </div>
    </div>,
    document.body,
  );
}
