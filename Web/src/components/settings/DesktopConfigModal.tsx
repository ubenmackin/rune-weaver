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
      <div className="modal-body" style={{ maxHeight: "70vh", overflowY: "auto" }}>
        {desktopModalError && (
          <div
            className="error-banner"
            style={{
              marginBottom: "14px",
              display: "flex",
              alignItems: "center",
              gap: "8px",
            }}
          >
            <AlertTriangleIcon size={16} />
            <span>{desktopModalError}</span>
          </div>
        )}

        <p className="muted text-sm" style={{ marginBottom: "16px" }}>
          Configure screen capture resolution, vision downscaling, and application safety blocklists for desktop control.
        </p>

        {/* Section 1: Screen Capture & Vision */}
        <div style={{ marginBottom: "20px" }}>
          <h4
            style={{
              fontSize: "0.9rem",
              margin: "0 0 10px 0",
              color: "var(--text-primary, #ffffff)",
            }}
          >
            Screen Capture & Vision
          </h4>
          <div
            className="form-row"
            style={{ display: "flex", gap: "10px", marginBottom: "4px" }}
          >
            <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
              <label
                htmlFor="desktop-max-dimension"
                style={{ fontSize: "0.82rem" }}
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
            <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
              <label
                htmlFor="desktop-jpeg-quality"
                style={{ fontSize: "0.82rem" }}
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
        <div
          style={{
            paddingTop: "14px",
            borderTop: "1px solid var(--border-color, #2d3748)",
          }}
        >
          <h4
            style={{
              fontSize: "0.9rem",
              margin: "0 0 10px 0",
              color: "var(--text-primary, #ffffff)",
            }}
          >
            Control & Security Blocklist
          </h4>
          <div className="form-group" style={{ marginBottom: "10px" }}>
            <label
              htmlFor="desktop-blocked-apps-textarea"
              style={{
                fontSize: "0.85rem",
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
              }}
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
            <span
              className="form-group-hint"
              style={{ marginTop: "4px", display: "block" }}
            >
              One application name per line. Blocked targets refuse automated
              input before dispatch. Blank lines are ignored.
            </span>
          </div>
        </div>
      </div>
      <div
        className="modal-footer"
        style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}
      >
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
