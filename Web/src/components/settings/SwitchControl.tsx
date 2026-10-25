// Rune Weaver Dashboard — shared settings switch control: the one boolean toggle
// for settings panes and settings-owned modals. It mirrors the canonical tool-row
// markup (tools.css .tool-switch rules) so every switch in the dashboard area
// renders identically: a visually hidden native checkbox overlaid on the
// track/thumb pair, keeping real checkbox keyboard semantics under a switch role.

import type { ChangeEvent } from "react";

export interface SwitchControlProps {
  // Controlled checked state; the track renders it as data-on.
  checked: boolean;
  // The raw input event is forwarded so callers keep their existing
  // `event.target.checked` handlers unchanged across the migration.
  onChange: (event: ChangeEvent<HTMLInputElement>) => void;
  // Accessible name for the switch, applied to the input's aria-label.
  label: string;
  // Optional visible text after the track (row label or state text).
  hint?: string;
  disabled?: boolean;
  // Rendered as both id and data-testid so callers holding only an id or only
  // a testid preserve it through one prop.
  testId?: string;
}

export function SwitchControl({
  checked,
  onChange,
  label,
  hint,
  disabled = false,
  testId,
}: SwitchControlProps) {
  return (
    <label className="toggle-label tool-switch">
      <input
        type="checkbox"
        role="switch"
        className="tool-switch-input"
        aria-label={label}
        aria-checked={checked}
        checked={checked}
        onChange={onChange}
        disabled={disabled}
        id={testId}
        data-testid={testId}
      />
      <span
        className="tool-switch-track"
        data-on={checked ? "true" : "false"}
        aria-hidden="true"
      >
        <span className="tool-switch-thumb" />
      </span>
      {hint ? <span className="tool-switch-state">{hint}</span> : null}
    </label>
  );
}

export default SwitchControl;
