// Rune Weaver Dashboard — Desktop integration configuration modal.

import React from "react";
import { parseBlockedAppsText } from "../../api";
import { AlertTriangleIcon, CloseIcon } from "../icons";
import Modal from "../Modal";

export interface DesktopConfigModalProps {
  isOpen: boolean;
  onClose: () => void;
  desktopSaveLoading: boolean;
  desktopModalError: string | null;
  desktopMaxImageDimension: number | string;
  setDesktopMaxImageDimension: (val: number | "") => void;
  desktopJpegQuality: number | string;
  setDesktopJpegQuality: (val: number | "") => void;
  desktopBlockedAppsText: string;
  setDesktopBlockedAppsText: (val: string) => void;
  handleSaveDesktopConfig: () => Promise<void>;
}

export function DesktopConfigModal({
  isOpen,
  onClose,
  desktopSaveLoading,
  desktopModalError,
  desktopMaxImageDimension,
  setDesktopMaxImageDimension,
  desktopJpegQuality,
  setDesktopJpegQuality,
  desktopBlockedAppsText,
  setDesktopBlockedAppsText,
  handleSaveDesktopConfig,
}: DesktopConfigModalProps): React.JSX.Element | null {
  if (!isOpen) return null;

  return (
    <Modal
      label="Configure Desktop Integration"
      onClose={() => {
        if (!desktopSaveLoading) onClose();
      }}
      containerClassName="modal-container"
    >
      <div className="modal-header">
        <h3>Configure Desktop Integration</h3>
        <button
          type="button"
          className="icon-button"
          onClick={() => {
            if (!desktopSaveLoading) onClose();
          }}
          disabled={desktopSaveLoading}
          aria-label="Close"
        >
          <CloseIcon size={16} />
        </button>
      </div>
      <div className="modal-body desktop-config-body">
        {desktopModalError && (
          <div className="error-banner desktop-config-error">
            <AlertTriangleIcon size={16} />
            <span>{desktopModalError}</span>
          </div>
        )}

        <p className="muted text-sm desktop-config-intro">
          Configure screen capture resolution, vision downscaling, and application safety blocklists for desktop control.
        </p>

        {/* Section 1: Screen Capture & Vision */}
        <div className="desktop-config-section">
          <h4 className="desktop-config-heading">
            Screen Capture & Vision
          </h4>
          <div className="form-row desktop-config-form-row">
            <div className="form-group desktop-config-field">
              <label
                htmlFor="desktop-max-dimension"
                className="text-sm"
              >
                Max Image Dimension (px)
              </label>
              <input
                id="desktop-max-dimension"
                type="number"
                min={256}
                max={3840}
                step={1}
                className="input-field"
                value={desktopMaxImageDimension}
                onChange={(e) =>
                  setDesktopMaxImageDimension(
                    e.target.value === "" ? "" : Number(e.target.value)
                  )
                }
                placeholder="1280"
              />
              <span className="form-group-hint">
                Longest edge of the downscaled screenshot (256-3840).
              </span>
            </div>
            <div className="form-group desktop-config-field">
              <label
                htmlFor="desktop-jpeg-quality"
                className="text-sm"
              >
                JPEG Quality (0.1-1.0)
              </label>
              <input
                id="desktop-jpeg-quality"
                type="number"
                min={0.1}
                max={1.0}
                step={0.05}
                className="input-field"
                value={desktopJpegQuality}
                onChange={(e) =>
                  setDesktopJpegQuality(
                    e.target.value === "" ? "" : Number(e.target.value)
                  )
                }
                placeholder="0.75"
              />
              <span className="form-group-hint">
                In-memory JPEG quality for downscaled captures.
              </span>
            </div>
          </div>
        </div>

        {/* Section 2: Control & Safety Blocklist */}
        <div className="desktop-config-blocklist">
          <h4 className="desktop-config-heading">
            Control & Security Blocklist
          </h4>
          <div className="form-group desktop-config-blocklist-field">
            <label
              htmlFor="desktop-blocked-apps-textarea"
              className="text-sm desktop-config-blocked-label"
            >
              <span>
                Blocked Apps{" "}
                <span className="muted text-sm">
                  ({parseBlockedAppsText(desktopBlockedAppsText).length}{" "}
                  {parseBlockedAppsText(desktopBlockedAppsText).length === 1
                    ? "app"
                    : "apps"}
                  )
                </span>
              </span>
            </label>
            <textarea
              id="desktop-blocked-apps-textarea"
              className="input-field allowed-origins-textarea"
              value={desktopBlockedAppsText}
              onChange={(e) => setDesktopBlockedAppsText(e.target.value)}
              placeholder={"Terminal\nKeychain Access\n1Password"}
            />
            <span className="form-group-hint desktop-config-hint-block">
              One application name per line. Blocked targets refuse automated
              input before dispatch. Blank lines are ignored.
            </span>
          </div>
        </div>
      </div>
      <div className="modal-footer">
        <button
          type="button"
          className="ghost"
          onClick={onClose}
          disabled={desktopSaveLoading}
        >
          Cancel
        </button>
        <button
          type="button"
          className="primary"
          onClick={() => void handleSaveDesktopConfig()}
          disabled={desktopSaveLoading}
        >
          {desktopSaveLoading ? "Saving…" : "Save Configuration"}
        </button>
      </div>
    </Modal>
  );
}
