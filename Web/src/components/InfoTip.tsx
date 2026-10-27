// Rune Weaver Dashboard — Universal help infotip with viewport-aware bubble.

import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { InfoIcon } from "./icons";

interface InfoTipProps {
  text: string;
  label?: string;
}

export default function InfoTip({ text, label }: InfoTipProps) {
  const [open, setOpen] = useState(false);
  const [placement, setPlacement] = useState<"below" | "above">("below");
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const rawId = useId();
  const bubbleId = `infotip-${rawId.replace(/:/g, "")}`;

  useEffect(() => {
    if (!open) return;
    function updatePlacement() {
      const anchor = triggerRef.current;
      if (!anchor) return;
      const rect = anchor.getBoundingClientRect();
      // Assume a typical bubble height so near-bottom anchors flip
      // instead of clipping when the layout is collapsed.
      const bubbleHeight = 120;
      const gap = 8;
      const spaceBelow = window.innerHeight - rect.bottom;
      const spaceAbove = rect.top;
      setPlacement(
        spaceBelow < bubbleHeight + gap && spaceAbove > spaceBelow
          ? "above"
          : "below",
      );
    }
    updatePlacement();
    window.addEventListener("resize", updatePlacement);
    window.addEventListener("scroll", updatePlacement, true);
    return () => {
      window.removeEventListener("resize", updatePlacement);
      window.removeEventListener("scroll", updatePlacement, true);
    };
  }, [open, text]);

  useEffect(() => {
    if (!open) return;
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node | null;
      if (target && triggerRef.current?.contains(target)) return;
      if (target && document.getElementById(bubbleId)?.contains(target)) return;
      setOpen(false);
    }
    document.addEventListener("keydown", handleKeyDown);
    document.addEventListener("pointerdown", handlePointerDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      document.removeEventListener("pointerdown", handlePointerDown);
    };
  }, [open, bubbleId]);

  // Bubble portals to document.body so overflow ancestors (wizard
  // body, rule rows) never clip it; CSS anchor positioning pins it.
  const bubble = open ? (
    <span
      id={bubbleId}
      role="tooltip"
      data-placement={placement}
      className={`infotip-bubble infotip-bubble--${placement}`}
    >
      {text}
    </span>
  ) : null;

  return (
    <span className="infotip">
      <button
        ref={triggerRef}
        type="button"
        className="infotip-trigger"
        data-open={open ? "true" : undefined}
        aria-label={label ?? "More information"}
        aria-describedby={open ? bubbleId : undefined}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onClick={() => setOpen((value) => !value)}
      >
        <InfoIcon size={12} />
      </button>
      {typeof document !== "undefined" && bubble
        ? createPortal(bubble, document.body)
        : null}
    </span>
  );
}
