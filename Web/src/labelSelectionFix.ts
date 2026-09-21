// Rune Weaver Dashboard — Global label interaction fix for text selection.
//
// Purpose: In standard HTML, clicking or selecting text inside a `<label>` element
// triggers the browser's default label activation algorithm, focusing or clicking
// the associated form control. For text inputs, textareas, and selects, this causes
// the caret to jump into the input field and destroys any text selection, making it
// impossible for users to highlight and copy field labels.
//
// This helper attaches a global capture-phase listener:
// 1. If text is selected on the label, prevents default so the selection remains intact for copying.
// 2. If the associated control is a text input, textarea, or select, prevents default label activation
//    so clicks, double-clicks, and drag-selections never jump focus into the input.
// 3. Checkboxes and radio buttons preserve standard click-to-toggle behavior (unless text was selected).
// 4. Direct clicks on inputs, textareas, buttons, and selects inside a label are never intercepted.

export function setupLabelSelectionFix(): () => void {
  if (typeof document === "undefined" || typeof window === "undefined") {
    return () => {};
  }

  const handleClick = (event: MouseEvent) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    // Direct clicks on interactive controls inside a label should always function normally.
    if (
      target instanceof HTMLInputElement ||
      target instanceof HTMLTextAreaElement ||
      target instanceof HTMLSelectElement ||
      target instanceof HTMLButtonElement
    ) {
      return;
    }

    const label = target.closest("label");
    if (!label) return;

    // 1. If text selected inside this label, prevent activation so the selection
    // stays intact for copying. Scoped to this label on purpose: a selection
    // elsewhere on the page (e.g. chat transcript) must not block label clicks.
    const selection = window.getSelection();
    if (selection && selection.toString().trim().length > 0) {
      const anchorInside =
        !!selection.anchorNode &&
        (selection.anchorNode === label || label.contains(selection.anchorNode));
      const focusInside =
        !!selection.focusNode &&
        (selection.focusNode === label || label.contains(selection.focusNode));
      const containsLabel =
        typeof selection.containsNode === "function" &&
        selection.containsNode(label, true);
      if (anchorInside || focusInside || containsLabel) {
        event.preventDefault();
        return;
      }
    }

    // 2. Identify the target control
    let control: HTMLElement | null = null;
    // Real DOM attribute is `for`; `htmlFor` is only the React prop / IDL name
    // and never appears via getAttribute, so a single lookup suffices.
    const htmlFor = label.getAttribute("for");
    if (htmlFor) {
      control = document.getElementById(htmlFor);
    } else {
      control = label.querySelector("input, textarea, select");
    }

    if (!control) return;

    // 3. For textareas and selects, prevent label clicks from stealing focus.
    if (control instanceof HTMLTextAreaElement || control instanceof HTMLSelectElement) {
      event.preventDefault();
      return;
    }

    // 4. For text-like inputs, prevent label clicks from stealing focus.
    if (control instanceof HTMLInputElement) {
      const type = (control.type || "text").toLowerCase();
      if (type !== "checkbox" && type !== "radio" && type !== "file") {
        event.preventDefault();
        return;
      }
    }
  };

  document.addEventListener("click", handleClick, true);
  return () => {
    document.removeEventListener("click", handleClick, true);
  };
}
