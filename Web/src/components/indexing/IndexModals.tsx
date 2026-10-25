// Rune Weaver Dashboard — Prune and Reset confirmation modals for the index.
import Modal from "../Modal";

interface IndexModalsProps {
  pendingPrune: boolean;
  pendingRebuild: boolean;
  action: "run" | "prune" | "reset" | "reclaim" | null;
  pruneBefore: string;
  pruneError: string | null;
  resetError: string | null;
  onClosePrune: () => void;
  onCloseRebuild: () => void;
  onChangePruneBefore: (value: string) => void;
  onConfirmPrune: () => void;
  onConfirmRebuild: () => void;
}

export default function IndexModals({
  pendingPrune,
  pendingRebuild,
  action,
  pruneBefore,
  pruneError,
  resetError,
  onClosePrune,
  onCloseRebuild,
  onChangePruneBefore,
  onConfirmPrune,
  onConfirmRebuild,
}: IndexModalsProps) {
  return (
    <>
      {pendingPrune ? (
        <Modal
          label="Confirm prune index"
          onClose={() => {
            if (action === "prune") return;
            onClosePrune();
          }}
          containerClassName="modal-container index-prune-modal"
        >
          <div className="modal-header">
            <h3>Prune the index?</h3>
          </div>
          <div className="modal-body">
            <p className="muted m-0">
              This removes documents indexed before the cutoff date you choose.
              Stored chunks for those documents are deleted and cannot be
              recovered. Intact documents are untouched.
            </p>
            <div className="form-group mt-3">
              <label htmlFor="index-prune-before">Cutoff date</label>
              <input
                id="index-prune-before"
                type="date"
                className="input-field"
                value={pruneBefore}
                onChange={(event) => {
                  onChangePruneBefore(event.target.value);
                }}
              />
              {pruneError ? <p className="error">{pruneError}</p> : null}
            </div>
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={onClosePrune}>
              Cancel
            </button>
                  <button
                    type="button"
                    className="primary"
                    aria-label="Confirm prune index"
                    onClick={onConfirmPrune}
                  >
                    Prune
                  </button>
                </div>
              </Modal>
            ) : null}
      
            {pendingRebuild ? (
              <Modal
                label="Confirm reset index"
                onClose={() => {
                  if (action === "reset") return;
                  onCloseRebuild();
                }}
                containerClassName="modal-container index-reset-modal"
              >
                <div className="modal-header">
                  <h3>Reset the index?</h3>
                </div>
                <div className="modal-body">
                  <p className="muted m-0">
                    This clears every indexed document and chunk. The next run rebuilds
                    the index from scratch. This cannot be undone.
                  </p>
                  {resetError ? <p className="error">{resetError}</p> : null}
                </div>
                <div className="modal-footer">
                  <button
                    type="button"
                    className="ghost"
                    onClick={onCloseRebuild}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="danger"
                    aria-label="Confirm reset index"
                    onClick={onConfirmRebuild}
                  >
                    Reset
                  </button>
                </div>
              </Modal>
            ) : null}
    </>
  );
}
