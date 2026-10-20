// Rune Weaver Dashboard — Shared Files write-posture form chrome for both section modes.
import {
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS,
} from "../../api";
import { CloseIcon } from "../icons";
import Modal from "../Modal";
import {
  FILES_WRITE_MODE_OPTIONS,
  type FilesWriteMode,
} from "./accessFilesRules";

// Closed write-mode vocabulary rendered as radios; the engine re-validates
// the same set on save so the form never offers a mode the server rejects.
export function FilesWriteModeRadios({
  writeMode,
  onChange,
}: {
  writeMode: FilesWriteMode;
  onChange: (next: string) => void;
}) {
  return (
    <div
      className="form-group"
      role="radiogroup"
      aria-label="Files write mode"
      style={{ marginBottom: "12px" }}
    >
      {FILES_WRITE_MODE_OPTIONS.map((option) => (
        <label
          key={option.value}
          className="toggle-label"
          style={{
            display: "flex",
            alignItems: "flex-start",
            gap: "8px",
            marginBottom: "10px",
            cursor: "pointer",
          }}
        >
          <input
            type="radio"
            name="filesWriteMode"
            value={option.value}
            checked={writeMode === option.value}
            onChange={() => onChange(option.value)}
          />
          <span style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
            <span>{option.label}</span>
            <span className="muted text-sm">{option.description}</span>
          </span>
        </label>
      ))}
    </div>
  );
}

// Single save row; the hint names the changed-only patch so untouched
// values survive a save that carries only the edited keys.
export function FilesSectionFooter({
  changed,
  advancedChanged,
  saveLoading,
  onSave,
}: {
  changed: boolean;
  advancedChanged: boolean;
  saveLoading: boolean;
  onSave: () => void;
}) {
  return (
    <div className="settings-footer">
      <span className="muted text-sm" data-testid="files-write-save-hint">
        {changed || advancedChanged
          ? "Unsaved changes — only the edited keys travel in the files patch."
          : "Only the edited keys travel; every untouched value survives."}
      </span>
      <button
        type="button"
        className="primary-button save-button"
        data-testid="files-write-save"
        onClick={onSave}
        disabled={saveLoading}
      >
        {saveLoading ? "Saving…" : "Save"}
      </button>
    </div>
  );
}

// Confirm-only resets; nothing writes until Save so a misclick never persists.
export function FilesResetModals({
  pendingResetDeny,
  pendingResetRoots,
  denyPatternCount,
  allowRootsCount,
  onCloseDeny,
  onConfirmDeny,
  onCloseRoots,
  onConfirmRoots,
}: {
  pendingResetDeny: boolean;
  pendingResetRoots: boolean;
  denyPatternCount: number;
  allowRootsCount: number;
  onCloseDeny: () => void;
  onConfirmDeny: () => void;
  onCloseRoots: () => void;
  onConfirmRoots: () => void;
}) {
  return (
    <>
      {pendingResetDeny ? (
        <Modal
          label="Confirm reset deny patterns"
          onClose={onCloseDeny}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Reset deny patterns?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={onCloseDeny}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will replace {denyPatternCount}{" "}
              {denyPatternCount === 1 ? "custom pattern" : "custom patterns"} with{" "}
              {DEFAULT_FILES_DENY_PATTERNS.length} defaults. This only updates the
              form — nothing is saved until you choose Save.
            </p>
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={onCloseDeny}>
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={onConfirmDeny}
              aria-label="Confirm reset deny patterns"
            >
              Reset to Defaults
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingResetRoots ? (
        <Modal
          label="Confirm reset allowed roots"
          onClose={onCloseRoots}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Reset allowed roots?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={onCloseRoots}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will replace {allowRootsCount}{" "}
              {allowRootsCount === 1 ? "custom root" : "custom roots"} with{" "}
              {DEFAULT_FILES_ALLOW_ROOTS.length}{" "}
              {DEFAULT_FILES_ALLOW_ROOTS.length === 1 ? "default" : "defaults"} (
              {DEFAULT_FILES_ALLOW_ROOTS.join(", ")}). This only updates the form —
              nothing is saved until you choose Save.
            </p>
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={onCloseRoots}>
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={onConfirmRoots}
              aria-label="Confirm reset allowed roots"
            >
              Reset Roots
            </button>
          </div>
        </Modal>
      ) : null}
    </>
  );
}
