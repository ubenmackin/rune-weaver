// Rune Weaver Dashboard — Modals for Settings (token rotation, secret storage, prune, uninstall, active run guard).

import React from "react";
import { CheckIcon, CloseIcon } from "../icons";
import Modal from "../Modal";
import RuneMarketplaceModal from "../RuneMarketplaceModal";
import { StoreSecretModal } from "../StoreSecretModal";
import { SwitchControl } from "./SwitchControl";

export interface SettingsModalsProps {
  // Marketplace modal
  marketplaceOpen: boolean;
  setMarketplaceOpen: (open: boolean) => void;
  loadPluginsData: () => Promise<void>;

  // Workspace tmp prune confirmation
  pendingPruneWorkspace: boolean;
  pruningWorkspace: boolean;
  setPendingPruneWorkspace: (pending: boolean) => void;
  handleConfirmPruneWorkspace: () => Promise<void>;

  // Plugin uninstall confirmation
  pendingUninstallPlugin: { id: string; name: string } | null;
  updatingPluginId: string | null;
  cancelUninstallPlugin: () => void;
  confirmUninstallPlugin: () => Promise<void>;

  // Token rotation
  rotateConfirmStep: 0 | 1 | 2;
  setRotateConfirmStep: (step: 0 | 1 | 2) => void;
  rotating: boolean;
  handleConfirmRotate: () => Promise<void>;

  // New token reveal
  newToken: string | null;
  tokenSavedAck: boolean;
  setTokenSavedAck: (ack: boolean) => void;
  tokenCopyState: "idle" | "copied" | "failed";
  handleCopyNewToken: () => Promise<void>;
  handleDismissNewToken: () => void;

  // Active run guard modal
  showActiveGuard: boolean;
  saving: boolean;
  handleCancelGuard: () => void;
  handleConfirmGuardSave: () => Promise<void>;

  // Store secret modal
  secretModal: {
    isOpen: boolean;
    secretKey: string;
    title: string;
    isUpdate: boolean;
  } | null;
  setSecretModal: (modal: null) => void;
  handleSecretSaved: (key: string) => void;
}

export function SettingsModals({
  marketplaceOpen,
  setMarketplaceOpen,
  loadPluginsData,
  pendingPruneWorkspace,
  pruningWorkspace,
  setPendingPruneWorkspace,
  handleConfirmPruneWorkspace,
  pendingUninstallPlugin,
  updatingPluginId,
  cancelUninstallPlugin,
  confirmUninstallPlugin,
  rotateConfirmStep,
  setRotateConfirmStep,
  rotating,
  handleConfirmRotate,
  newToken,
  tokenSavedAck,
  setTokenSavedAck,
  tokenCopyState,
  handleCopyNewToken,
  handleDismissNewToken,
  showActiveGuard,
  saving,
  handleCancelGuard,
  handleConfirmGuardSave,
  secretModal,
  setSecretModal,
  handleSecretSaved,
}: SettingsModalsProps): React.JSX.Element {
  return (
    <>
      <RuneMarketplaceModal
        isOpen={marketplaceOpen}
        onClose={() => setMarketplaceOpen(false)}
        onPluginInstalled={() => {
          void loadPluginsData();
        }}
      />

      {/* Workspace tmp prune confirmation via the shared modal: pruning
          deletes expired tmp/ entries and cannot be undone, so an explicit
          confirm stands between the button and the POST. */}
      {pendingPruneWorkspace ? (
        <Modal
          label="Confirm prune workspace tmp"
          onClose={() => {
            if (pruningWorkspace) return;
            setPendingPruneWorkspace(false);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Prune workspace tmp?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setPendingPruneWorkspace(false)}
              disabled={pruningWorkspace}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This deletes expired entries under workspace/tmp/. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setPendingPruneWorkspace(false)}
              disabled={pruningWorkspace}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void handleConfirmPruneWorkspace()}
              disabled={pruningWorkspace}
              aria-label="Confirm prune workspace tmp"
            >
              {pruningWorkspace ? "Pruning…" : "Prune tmp"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Persisted plugin uninstall confirmation via the shared modal. */}
      {pendingUninstallPlugin ? (
        <Modal
          label="Confirm uninstall plugin"
          onClose={() => {
            if (updatingPluginId === pendingUninstallPlugin.id) return;
            cancelUninstallPlugin();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Uninstall rune?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelUninstallPlugin}
              disabled={updatingPluginId === pendingUninstallPlugin.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This will permanently uninstall and remove &lsquo;
              {pendingUninstallPlugin.name}&rsquo;. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelUninstallPlugin}
              disabled={updatingPluginId === pendingUninstallPlugin.id}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmUninstallPlugin()}
              disabled={updatingPluginId === pendingUninstallPlugin.id}
              aria-label="Confirm uninstall plugin"
            >
              {updatingPluginId === pendingUninstallPlugin.id
                ? "Uninstalling…"
                : "Uninstall"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Rotate confirmation step one: name the blast radius (every other device
          signed out immediately) before anything is minted. */}
      {rotateConfirmStep === 1 ? (
        <Modal
          label="Confirm token rotation"
          onClose={() => {
            if (rotating) return;
            setRotateConfirmStep(0);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Rotate owner token?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              Rotating the owner token invalidates the current token immediately
              and signs out every other device. This device adopts the new token.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => setRotateConfirmStep(2)}
              disabled={rotating}
            >
              Continue
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Rotate confirmation step two: the final gate, spelling out the one-time
          reveal and the CLI recovery path so the consequence is explicit before
          the irreversible call. */}
      {rotateConfirmStep === 2 ? (
        <Modal
          label="Confirm token rotation again"
          onClose={() => {
            if (rotating) return;
            setRotateConfirmStep(0);
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Rotate now?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              This is the final confirmation. The new token is shown once and
              cannot be retrieved again from the dashboard. Save it before
              dismissing; if you lose it, re-mint one on the Mac Studio with
              <code> rune-weaver auth token rotate</code>.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={() => setRotateConfirmStep(0)}
              disabled={rotating}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void handleConfirmRotate()}
              disabled={rotating}
              aria-label="Confirm rotate token"
            >
              {rotating ? "Rotating…" : "Rotate token now"}
            </button>
          </div>
        </Modal>
      ) : null}

      {/* One-time token reveal. Dismissal is gated on the saved acknowledgement
          because the value cannot be fetched again; backdrop click and Escape
          share the same guard so a stray interaction cannot discard it. */}
      {newToken ? (
        <Modal
          label="New owner token"
          onClose={() => {
            if (!tokenSavedAck) return;
            handleDismissNewToken();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Save your new token</h3>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ marginTop: 0 }}>
              This is the only time the new token is shown. Store it somewhere
              safe now; every other device has already been signed out.
            </p>
            <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
              <code
                data-testid="new-token"
                style={{
                  flex: 1,
                  wordBreak: "break-all",
                  padding: "8px 10px",
                  borderRadius: "6px",
                  background: "var(--bg-secondary, #10131a)",
                  border: "1px solid var(--border-color, #2d3748)",
                }}
              >
                {newToken}
              </code>
              <button
                type="button"
                className="ghost icon-text-btn"
                onClick={() => void handleCopyNewToken()}
              >
                {tokenCopyState === "copied" ? <CheckIcon size={14} /> : null}
                <span>
                  {tokenCopyState === "copied"
                    ? "Copied"
                    : tokenCopyState === "failed"
                      ? "Copy failed"
                      : "Copy"}
                </span>
              </button>
            </div>
            <div style={{ marginTop: "14px", display: "flex", alignItems: "center" }}>
              <SwitchControl
                checked={tokenSavedAck}
                onChange={(event) => setTokenSavedAck(event.target.checked)}
                label="I have saved this token and understand it will not be shown again."
                hint="I have saved this token and understand it will not be shown again."
              />
            </div>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="primary"
              onClick={handleDismissNewToken}
              disabled={!tokenSavedAck}
            >
              Done
            </button>
          </div>
        </Modal>
      ) : null}

      {/* Active-run guard: saving while a chat turn, tool call, or scheduler
          run is in flight cancels that work, so the operator confirms first.
          Parked approvals never trigger this path. Cancel aborts the PUT;
          Continue saves and hot-reloads. */}
      {showActiveGuard ? (
        <Modal
          label="Confirm save during active run"
          onClose={handleCancelGuard}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Save while work is running?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={handleCancelGuard}
              disabled={saving}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              If you continue, in progress chats will be cancelled. Do you want to continue?
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={handleCancelGuard}
              disabled={saving}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void handleConfirmGuardSave()}
              disabled={saving}
            >
              {saving ? "Saving…" : "Continue"}
            </button>
          </div>
        </Modal>
      ) : null}

      {secretModal && secretModal.isOpen && (
        <StoreSecretModal
          isOpen={secretModal.isOpen}
          secretKey={secretModal.secretKey}
          title={secretModal.title}
          isUpdate={secretModal.isUpdate}
          onClose={() => setSecretModal(null)}
          onSuccess={handleSecretSaved}
        />
      )}
    </>
  );
}
