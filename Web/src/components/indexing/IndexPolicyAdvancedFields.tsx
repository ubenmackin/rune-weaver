// Rune Weaver Dashboard — Advanced policy controls (vector cap, excludes, denied mailboxes, mail window, icloud).
import {
  INDEX_ICLOUD_EVICTIONS,
  INDEX_MAIL_VECTOR_WINDOWS,
  type IndexConfigData,
} from "../../api";

interface IndexPolicyAdvancedFieldsProps {
  config: IndexConfigData;
  vectorCap: number;
  vectorCapMax: number;
  excludeText: string;
  mailboxDenyText: string;
  updateConfig: (patch: Partial<IndexConfigData>) => void;
  setExcludeText: (value: string) => void;
  setMailboxDenyText: (value: string) => void;
}

export default function IndexPolicyAdvancedFields({
  config,
  vectorCap,
  vectorCapMax,
  excludeText,
  mailboxDenyText,
  updateConfig,
  setExcludeText,
  setMailboxDenyText,
}: IndexPolicyAdvancedFieldsProps) {
  return (
    <>
              {/* Per-document vector chunk cap: bounds embedding work so one text-dense document
                  cannot fan an outsized batch. Chunks beyond the cap stay keyword-searchable, so a
                  capped document remains fully findable; persisted only on Save like the others. */}
              <div className="form-group" style={{ marginTop: 12 }}>
                <label htmlFor="index-vector-cap">
                  Max vector chunks per document
                </label>
                <div className="row">
                  <button
                    type="button"
                    className="ghost"
                    aria-label="Decrease vector cap"
                    disabled={vectorCap <= 1}
                    onClick={() =>
                      updateConfig({
                        maxVectorChunksPerDocument: Math.max(1, vectorCap - 1),
                      })
                    }
                  >
                    <span aria-hidden="true">−</span>
                  </button>
                  <input
                    id="index-vector-cap"
                    type="number"
                    className="input-field"
                    min={1}
                    max={vectorCapMax}
                    value={vectorCap}
                    onChange={(event) => {
                      const parsed = Number(event.target.value);
                      if (!Number.isFinite(parsed)) return;
                      updateConfig({
                        maxVectorChunksPerDocument: Math.min(
                          vectorCapMax,
                          Math.max(1, Math.floor(parsed)),
                        ),
                      });
                    }}
                  />
                  <button
                    type="button"
                    className="ghost"
                    aria-label="Increase vector cap"
                    disabled={vectorCap >= vectorCapMax}
                    onClick={() =>
                      updateConfig({
                        maxVectorChunksPerDocument: Math.min(
                          vectorCapMax,
                          vectorCap + 1,
                        ),
                      })
                    }
                  >
                    <span aria-hidden="true">+</span>
                  </button>
                </div>
                <p className="muted text-xs">
                  Chunks beyond the cap stay keyword-only (1–4096).
                </p>
              </div>
      
              <div className="form-group">
                <label htmlFor="index-excludes">Exclude patterns (one glob per line)</label>
                <textarea
                  id="index-excludes"
                  aria-label="Exclude patterns"
                  rows={6}
                  value={excludeText}
                  onChange={(event) => setExcludeText(event.target.value)}
                />
                <p className="muted text-xs">
                  Directories and patterns skipped during a file scan.
                </p>
              </div>
      
              <div className="form-group">
                <label htmlFor="index-mailbox-deny">Denied mailboxes (one glob per line)</label>
                <textarea
                  id="index-mailbox-deny"
                  aria-label="Denied mailboxes"
                  rows={4}
                  value={mailboxDenyText}
                  onChange={(event) => setMailboxDenyText(event.target.value)}
                />
                <p className="muted text-xs">
                  Trash-class mailboxes skipped without dialing. Denied mail retires
                  on the next complete run; clearing a name re-indexes it from scratch.
                </p>
              </div>
      
              <div className="form-row">
                <div className="form-group flex-1">
                  <label htmlFor="index-mail-window">Mail vector window</label>
                  <select
                    id="index-mail-window"
                    className="input-field"
                    value={config.mailVectorWindow}
                    onChange={(event) =>
                      updateConfig({ mailVectorWindow: event.target.value })
                    }
                  >
                    {INDEX_MAIL_VECTOR_WINDOWS.map((window) => (
                      <option key={window} value={window}>
                        {window === "all" ? "All mail" : window}
                      </option>
                    ))}
                  </select>
                </div>
      
                <div className="form-group flex-1">
                  <label htmlFor="index-icloud">iCloud files with evicted bytes</label>
                  <select
                    id="index-icloud"
                    className="input-field"
                    value={config.iCloudEvicted}
                    onChange={(event) =>
                      updateConfig({ iCloudEvicted: event.target.value })
                    }
                  >
                    {INDEX_ICLOUD_EVICTIONS.map((policy) => (
                      <option key={policy} value={policy}>
                        {policy === "skip" ? "Skip (never download)" : "Download"}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
      
              <p className="muted text-sm index-attachment-cap">
                Attachment / file size cap: {config.maxFileMB} MB per file.
              </p>
      
    </>
  );
}
