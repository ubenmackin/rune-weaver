// Rune Weaver Dashboard — Fan-out worker configuration modal.

import React from "react";
import { AlertTriangleIcon, CloseIcon } from "../icons";
import Modal from "../Modal";
import { SwitchControl } from "./SwitchControl";

export interface FanoutConfigModalProps {
  isOpen: boolean;
  onClose: () => void;
  fanoutSaveLoading: boolean;
  fanoutModalError: string | null;
  fanoutMaxWorkers: number | string;
  setFanoutMaxWorkers: (val: number | "") => void;
  fanoutWorkerTimeoutSeconds: number | string;
  setFanoutWorkerTimeoutSeconds: (val: number | "") => void;
  fanoutFullTools: boolean;
  setFanoutFullTools: (val: boolean) => void;
  handleSaveFanoutConfig: () => Promise<void>;
}

export function FanoutConfigModal({
  isOpen,
  onClose,
  fanoutSaveLoading,
  fanoutModalError,
  fanoutMaxWorkers,
  setFanoutMaxWorkers,
  fanoutWorkerTimeoutSeconds,
  setFanoutWorkerTimeoutSeconds,
  fanoutFullTools,
  setFanoutFullTools,
  handleSaveFanoutConfig,
}: FanoutConfigModalProps): React.JSX.Element | null {
  if (!isOpen) return null;

  return (
    <Modal
      label="Configure Parallel Fan-Out"
      onClose={() => {
        if (!fanoutSaveLoading) onClose();
      }}
      containerClassName="modal-container"
    >
      <div className="modal-header">
        <h3>Configure Parallel Fan-Out</h3>
        <button
          type="button"
          className="icon-button"
          onClick={() => {
            if (!fanoutSaveLoading) onClose();
          }}
          disabled={fanoutSaveLoading}
          aria-label="Close"
        >
          <CloseIcon size={16} />
        </button>
      </div>
      <div className="modal-body fanout-modal-body">
        {fanoutModalError && (
          <div className="error-banner fanout-modal-error">
            <AlertTriangleIcon size={16} />
            <span>{fanoutModalError}</span>
          </div>
        )}

        <p className="muted text-sm fanout-modal-intro">
          Tune the parallel worker swarm for <code>fanout.run</code>. Workers
          fan out over caller-composed subtasks and merge through one
          reviewer pass; these knobs take effect without a restart.
        </p>

        <div className="form-row fanout-form-row">
          <div className="form-group flex-1 m-0">
            <label htmlFor="fanout-max-workers">
              Max workers
            </label>
            <input
              id="fanout-max-workers"
              type="number"
              min={1}
              max={8}
              step={1}
              className="input-field"
              value={fanoutMaxWorkers}
              onChange={(e) =>
                setFanoutMaxWorkers(
                  e.target.value === "" ? "" : Number(e.target.value)
                )
              }
              placeholder="2 (default)"
            />
            <span className="form-group-hint">
              Maximum workers running at once. Clearing the field saves 2.
            </span>
          </div>
          <div className="form-group flex-1 m-0">
            <label htmlFor="fanout-worker-timeout">
              Worker timeout (seconds)
            </label>
            <input
              id="fanout-worker-timeout"
              type="number"
              min={0}
              step={1}
              className="input-field"
              value={fanoutWorkerTimeoutSeconds}
              onChange={(e) =>
                setFanoutWorkerTimeoutSeconds(
                  e.target.value === "" ? "" : Number(e.target.value)
                )
              }
              placeholder="0 (unlimited)"
            />
            <span className="form-group-hint">
              0 = no timeout (recommended for local models). Clearing the field saves 0 (unlimited).
            </span>
          </div>
        </div>

        <div className="form-group checkbox-group mt-4">
          <SwitchControl
            testId="fanout-full-tools"
            checked={fanoutFullTools}
            onChange={(e) => setFanoutFullTools(e.target.checked)}
            label="Full tools"
            hint="Full tools"
          />
          <span className="form-group-hint">
            Lets workers call the full tool registry, not just read-only tools.
          </span>
        </div>
      </div>
      <div className="modal-footer">
        <button
          type="button"
          className="ghost"
          onClick={onClose}
          disabled={fanoutSaveLoading}
        >
          Cancel
        </button>
        <button
          type="button"
          className="primary"
          onClick={() => void handleSaveFanoutConfig()}
          disabled={fanoutSaveLoading}
        >
          {fanoutSaveLoading ? "Saving…" : "Save Configuration"}
        </button>
      </div>
    </Modal>
  );
}
