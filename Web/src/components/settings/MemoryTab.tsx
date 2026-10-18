// Rune Weaver Dashboard — Memory & Persistence tab pane.

import type { EmbeddingsStatusResponse } from "../../api";

export interface MemoryTabProps {
  memoryEmbeddingBackend: string;
  setMemoryEmbeddingBackend: (val: string) => void;
  embeddingsStatus: EmbeddingsStatusResponse | null;
  refreshEmbeddingsStatus: () => Promise<void>;
  embeddingsLoading: boolean;
  handleEnsureEmbeddings: () => Promise<void>;
  embeddingsActionBusy: boolean;
  memoryEpisodesDBPath: string;
  setMemoryEpisodesDBPath: (val: string) => void;
  memoryVectorDBPath: string;
  setMemoryVectorDBPath: (val: string) => void;
}

export function MemoryTab({
  memoryEmbeddingBackend,
  setMemoryEmbeddingBackend,
  embeddingsStatus,
  refreshEmbeddingsStatus,
  embeddingsLoading,
  handleEnsureEmbeddings,
  embeddingsActionBusy,
  memoryEpisodesDBPath,
  setMemoryEpisodesDBPath,
  memoryVectorDBPath,
  setMemoryVectorDBPath,
}: MemoryTabProps) {
  return (
    <div className="settings-section card">
      <div className="settings-section-title-group">
        <h3>Memory & Persistence</h3>
        <p className="settings-section-hint">
          Paths to long-term memory, episode history databases, and embedding backend.
        </p>
      </div>

      <div className="form-group">
        <label htmlFor="embedding-backend">Embedding Backend</label>
        <select
          id="embedding-backend"
          className="input-field"
          value={memoryEmbeddingBackend}
          onChange={(e) => setMemoryEmbeddingBackend(e.target.value)}
        >
          <option value="local">local (EmbeddingGemma 2)</option>
          <option value="provider">provider</option>
          <option value="none">none</option>
        </select>
        <span className="form-group-hint">
          Local runs EmbeddingGemma 2 on Apple Silicon Metal via llama.cpp for on-device 768-dim embeddings, provider uses the active chat model for embeddings via /v1/embeddings, and none stays keyword-only with no vectors.
        </span>
      </div>

      {memoryEmbeddingBackend === "local" && (
        <div className="card" style={{ marginTop: "1rem", padding: "1rem", background: "var(--card-bg-subtle, rgba(255,255,255,0.03))" }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "0.5rem" }}>
            <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
              <span style={{ fontWeight: 600 }}>Local Embedding Engine</span>
              {embeddingsStatus?.status === "ready" ? (
                <span className="badge badge-success" data-testid="embeddings-status-ready">Ready (Metal GPU)</span>
              ) : embeddingsStatus?.status === "downloading_binary" || embeddingsStatus?.status === "downloading_model" ? (
                <span className="badge badge-warning" data-testid="embeddings-status-downloading">
                  {embeddingsStatus.stage ?? "Downloading Assets…"}
                </span>
              ) : embeddingsStatus?.status === "starting" ? (
                <span className="badge badge-warning" data-testid="embeddings-status-starting">Starting…</span>
              ) : embeddingsStatus?.status === "error" ? (
                <span className="badge badge-error" data-testid="embeddings-status-error">Error</span>
              ) : (
                <span className="badge badge-muted" data-testid="embeddings-status-stopped">Stopped</span>
              )}
            </div>
            <div style={{ display: "flex", gap: "0.5rem" }}>
              <button
                type="button"
                className="btn btn-secondary btn-sm"
                onClick={() => void refreshEmbeddingsStatus()}
                disabled={embeddingsLoading}
                title="Refresh status"
              >
                {embeddingsLoading ? "Refreshing…" : "Refresh"}
              </button>
              {(!embeddingsStatus?.isRunning || embeddingsStatus?.status === "error") && (
                <button
                  type="button"
                  className="btn btn-primary btn-sm"
                  onClick={() => void handleEnsureEmbeddings()}
                  disabled={embeddingsActionBusy}
                  data-testid="embeddings-initialize-btn"
                >
                  {embeddingsActionBusy ? "Starting…" : embeddingsStatus?.status === "error" ? "Retry" : "Initialize"}
                </button>
              )}
            </div>
          </div>

          {embeddingsStatus?.error && (
            <p className="text-danger text-xs" style={{ margin: "0.5rem 0" }} data-testid="embeddings-error-msg">
              {embeddingsStatus.error}
            </p>
          )}

          <div className="text-xs muted" style={{ display: "grid", gridTemplateColumns: "auto 1fr", gap: "0.25rem 1rem", marginTop: "0.5rem" }}>
            <span>Model:</span>
            <span style={{ fontFamily: "monospace" }}>{embeddingsStatus?.model ?? "embeddinggemma-2-Q8_0.gguf"} (768 dimensions)</span>
            <span>Acceleration:</span>
            <span>{embeddingsStatus?.acceleration ?? "Apple Silicon Metal GPU"}</span>
            <span>Endpoint:</span>
            <span style={{ fontFamily: "monospace" }}>{embeddingsStatus?.endpoint ?? "~/.runeweaver/run/embedding.sock"}</span>
          </div>
        </div>
      )}

      <div className="form-group">
        <label htmlFor="episodes-path">Episodes SQLite Database Path</label>
        <input
          id="episodes-path"
          type="text"
          className="input-field"
          value={memoryEpisodesDBPath}
          onChange={(e) => setMemoryEpisodesDBPath(e.target.value)}
          required
        />
      </div>

      <div className="form-group">
        <label htmlFor="vector-path">Vector Storage Path</label>
        <input
          id="vector-path"
          type="text"
          className="input-field"
          value={memoryVectorDBPath}
          onChange={(e) => setMemoryVectorDBPath(e.target.value)}
          required
        />
      </div>
    </div>
  );
}

export default MemoryTab;
