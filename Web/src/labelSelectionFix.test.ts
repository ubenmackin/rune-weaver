// Rune Weaver Dashboard — Label selection fix behavior coverage.
//
// Purpose: Pins the global capture-phase label interaction fix so text inputs,
// textareas, and selects never steal focus on label click while checkboxes and
// radios keep native toggle behavior. Guards the selection-preservation path
// that keeps user-highlighted label text copyable instead of jumping the caret.
//
// Scope: Vitest + jsdom coverage for `setupLabelSelectionFix` only; exercises
// label-to-control activation, direct-control passthrough, and selected-text
// preservation without touching engine, WebSocket, or approval flows.
//
// Architectural role: Regression net for the dashboard's single global label
// listener registered once at React entry; ensures HMR-safe attach/detach and
// standard HTML label semantics stay intact across settings and chat surfaces.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { setupLabelSelectionFix } from "./labelSelectionFix";

describe("setupLabelSelectionFix", () => {
  let cleanup: () => void;

  beforeEach(() => {
    document.body.innerHTML = "";
    cleanup = setupLabelSelectionFix();
  });

  afterEach(() => {
    cleanup();
    document.body.innerHTML = "";
  });

  it("prevents label click from activating text input", () => {
    document.body.innerHTML = `
      <div>
        <label id="test-label" for="test-input">Field Label</label>
        <input id="test-input" type="text" />
      </div>
    `;

    const label = document.getElementById("test-label")!;
    const clickEvent = new MouseEvent("click", { bubbles: true, cancelable: true });
    const notCancelled = label.dispatchEvent(clickEvent);

    expect(notCancelled).toBe(false);
    expect(clickEvent.defaultPrevented).toBe(true);
  });

  it("prevents label click from activating textarea", () => {
    document.body.innerHTML = `
      <div>
        <label id="test-label" for="test-area">Area Label</label>
        <textarea id="test-area"></textarea>
      </div>
    `;

    const label = document.getElementById("test-label")!;
    const clickEvent = new MouseEvent("click", { bubbles: true, cancelable: true });
    label.dispatchEvent(clickEvent);

    expect(clickEvent.defaultPrevented).toBe(true);
  });

  it("allows label click to activate checkbox when no text is selected", () => {
    document.body.innerHTML = `
      <label id="test-label">
        <input id="test-checkbox" type="checkbox" />
        <span>Enable feature</span>
      </label>
    `;

    const span = document.querySelector("span")!;
    const clickEvent = new MouseEvent("click", { bubbles: true, cancelable: true });
    span.dispatchEvent(clickEvent);

    expect(clickEvent.defaultPrevented).toBe(false);
  });

  it("prevents checkbox label click if user has text selected", () => {
    document.body.innerHTML = `
      <label id="test-label">
        <input id="test-checkbox" type="checkbox" />
        <span>Enable feature</span>
      </label>
    `;

    // Mock a selection anchored inside the clicked label, so the scoped gate
    // preserves it; a selection elsewhere must not block label activation.
    const span = document.querySelector("span")!;
    const originalGetSelection = window.getSelection;
    window.getSelection = () =>
      ({
        toString: () => "Enable feature",
        anchorNode: span.firstChild ?? span,
        focusNode: span.firstChild ?? span,
        containsNode: (node: Node) => node === document.getElementById("test-label"),
      } as unknown as Selection);

    try {
      const clickEvent = new MouseEvent("click", { bubbles: true, cancelable: true });
      span.dispatchEvent(clickEvent);

      expect(clickEvent.defaultPrevented).toBe(true);
    } finally {
      window.getSelection = originalGetSelection;
    }
  });

  it("allows checkbox label click when the selection is outside the label", () => {
    document.body.innerHTML = `
      <div id="outside">Chat transcript selection</div>
      <label id="test-label">
        <input id="test-checkbox" type="checkbox" />
        <span>Enable feature</span>
      </label>
    `;

    // Selection lives in unrelated chat content, so clicking the label must
    // still toggle the checkbox instead of preserving the distant selection.
    const outside = document.getElementById("outside")!;
    const originalGetSelection = window.getSelection;
    window.getSelection = () =>
      ({
        toString: () => "Chat transcript selection",
        anchorNode: outside.firstChild ?? outside,
        focusNode: outside.firstChild ?? outside,
        containsNode: () => false,
      } as unknown as Selection);

    try {
      const span = document.querySelector("span")!;
      const clickEvent = new MouseEvent("click", { bubbles: true, cancelable: true });
      span.dispatchEvent(clickEvent);

      expect(clickEvent.defaultPrevented).toBe(false);
    } finally {
      window.getSelection = originalGetSelection;
    }
  });

  it("does not prevent default on direct input click inside a label", () => {
    document.body.innerHTML = `
      <label id="test-label">
        <input id="test-input" type="text" />
      </label>
    `;

    const input = document.getElementById("test-input")!;
    const clickEvent = new MouseEvent("click", { bubbles: true, cancelable: true });
    input.dispatchEvent(clickEvent);

    expect(clickEvent.defaultPrevented).toBe(false);
  });
});
