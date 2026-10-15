// Rune Weaver Dashboard — Shared split-menu state machine for decision surfaces.
//
// Purpose: one hook owns the open/dismiss/focus/keyboard behavior every split
// Allow/Deny pair renders, so the chat inline banner and the dashboard
// quick-action card keep identical menu semantics instead of drifting per
// call site. Outside pointer down dismisses both menus, opening moves focus
// to the first choice without an extra tab stop, ArrowUp/ArrowDown/Home/End
// walk the allow tiers with wrap-around, and Escape closes with focus
// returned to the owning chevron.
// Scope: the shared state machine only. Menu placement detection (the
// banner's render-up flip) and decision dispatch stay with the calling
// surface; the split-allow-* class structure stays owned by the stylesheet
// and the rendering components, so both surfaces keep one menu vocabulary.

import { useEffect, useRef, useState } from "react";

// Refs and handlers one split Allow/Deny pair needs from the shared machine.
// The group refs anchor the outside-pointer-down dismissal, the chevron refs
// receive returned focus, and the item refs receive programmatic focus while
// the keyboard flow walks the allow tiers.
export interface SplitMenuControls {
  allowOpen: boolean;
  denyOpen: boolean;
  allowGroupRef: React.MutableRefObject<HTMLDivElement | null>;
  denyGroupRef: React.MutableRefObject<HTMLDivElement | null>;
  allowChevronRef: React.MutableRefObject<HTMLButtonElement | null>;
  denyChevronRef: React.MutableRefObject<HTMLButtonElement | null>;
  allowItemRefs: React.MutableRefObject<Array<HTMLButtonElement | null>>;
  denyItemRef: React.MutableRefObject<HTMLButtonElement | null>;
  toggleAllow: () => void;
  toggleDeny: () => void;
  closeAllowMenu: (returnFocus: boolean) => void;
  closeDenyMenu: (returnFocus: boolean) => void;
  handleAllowMenuKeyDown: (event: React.KeyboardEvent) => void;
  handleDenyMenuKeyDown: (event: React.KeyboardEvent) => void;
  setFocusedIndex: (index: number) => void;
}

// One shared state machine per split Allow/Deny pair. `allowItemCount` is the
// live tier count for the request being decided — 7 shared durations for a
// plain request, 3 egress tiers for an egress-parked one — so wrap-around
// navigation follows the surface's own duration options.
export function useSplitMenu(allowItemCount: number): SplitMenuControls {
  const [allowOpen, setAllowOpen] = useState(false);
  const [denyOpen, setDenyOpen] = useState(false);
  const [focusedIndex, setFocusedIndex] = useState(0);
  const allowGroupRef = useRef<HTMLDivElement | null>(null);
  const denyGroupRef = useRef<HTMLDivElement | null>(null);
  const allowChevronRef = useRef<HTMLButtonElement | null>(null);
  const denyChevronRef = useRef<HTMLButtonElement | null>(null);
  const allowItemRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const denyItemRef = useRef<HTMLButtonElement | null>(null);

  // Dismiss open menus on outside pointer down so they never linger after the
  // user moves on; the parked turn stays decidable by reopening a chevron.
  useEffect(() => {
    if (!allowOpen && !denyOpen) return;
    function handlePointerDown(event: PointerEvent) {
      const inAllow =
        allowGroupRef.current &&
        allowGroupRef.current.contains(event.target as Node);
      const inDeny =
        denyGroupRef.current &&
        denyGroupRef.current.contains(event.target as Node);
      if (!inAllow && !inDeny) {
        setAllowOpen(false);
        setDenyOpen(false);
      }
    }
    document.addEventListener("pointerdown", handlePointerDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
    };
  }, [allowOpen, denyOpen]);

  // Move focus into the menu on open so arrow-key users land on a choice
  // without an extra tab stop; closing returns focus to the chevron.
  useEffect(() => {
    if (allowOpen) {
      setFocusedIndex(0);
      allowItemRefs.current[0]?.focus();
    }
  }, [allowOpen]);

  useEffect(() => {
    if (denyOpen) {
      denyItemRef.current?.focus();
    }
  }, [denyOpen]);

  function closeAllowMenu(returnFocus: boolean) {
    setAllowOpen(false);
    if (returnFocus) {
      allowChevronRef.current?.focus();
    }
  }

  function closeDenyMenu(returnFocus: boolean) {
    setDenyOpen(false);
    if (returnFocus) {
      denyChevronRef.current?.focus();
    }
  }

  // Opening one chevron closes the other, so at most one menu shows at a time.
  function toggleAllow() {
    setDenyOpen(false);
    setAllowOpen((open) => !open);
  }

  function toggleDeny() {
    setAllowOpen(false);
    setDenyOpen((open) => !open);
  }

  function handleAllowMenuKeyDown(event: React.KeyboardEvent) {
    if (!allowOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeAllowMenu(true);
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      const next = (focusedIndex + 1) % allowItemCount;
      setFocusedIndex(next);
      allowItemRefs.current[next]?.focus();
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      const next = (focusedIndex - 1 + allowItemCount) % allowItemCount;
      setFocusedIndex(next);
      allowItemRefs.current[next]?.focus();
      return;
    }
    if (event.key === "Home") {
      event.preventDefault();
      setFocusedIndex(0);
      allowItemRefs.current[0]?.focus();
      return;
    }
    if (event.key === "End") {
      event.preventDefault();
      const last = allowItemCount - 1;
      setFocusedIndex(last);
      allowItemRefs.current[last]?.focus();
    }
  }

  // The deny menu carries one standing item, so Escape is its whole keyboard
  // surface: close with focus returned to the deny chevron.
  function handleDenyMenuKeyDown(event: React.KeyboardEvent) {
    if (!denyOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeDenyMenu(true);
    }
  }

  return {
    allowOpen,
    denyOpen,
    allowGroupRef,
    denyGroupRef,
    allowChevronRef,
    denyChevronRef,
    allowItemRefs,
    denyItemRef,
    toggleAllow,
    toggleDeny,
    closeAllowMenu,
    closeDenyMenu,
    handleAllowMenuKeyDown,
    handleDenyMenuKeyDown,
    setFocusedIndex,
  };
}
