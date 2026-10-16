// Rune Weaver Dashboard — Shared split-menu state machine for decision surfaces.

import { useEffect, useRef, useState } from "react";

// Refs and handlers one split Allow/Deny pair needs from the shared machine.
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

// One shared state machine per split Allow/Deny pair.
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
