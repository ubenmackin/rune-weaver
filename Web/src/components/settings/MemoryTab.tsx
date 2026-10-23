// Rune Weaver Dashboard — Memory & Persistence tab pane.

import { useState } from "react";
import type { EmbeddingsStatusResponse } from "../../api";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import {
  DEFAULT_MEMORY_RECALL_AUTO_LIMIT,
  DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER,
  DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT,
} from "./settingsAdvancedCounts";

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
  memoryRecallAutoLimit?: number | string;
  setMemoryRecallAutoLimit?: (val: number | string) => void;
  memoryRecallDocPoolMultiplier?: number | string;
  setMemoryRecallDocPoolMultiplier?: (val: number | string) => void;
  memoryRecallEpisodicWeight?: number | string;
  setMemoryRecallEpisodicWeight?: (val: number | string) => void;
  validationError?: string | null;
}

function matchesAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return (
    lowered.includes("docpool") ||
    lowered.includes("doc_pool") ||
    lowered.includes("episodic") ||
    lowered.includes("embeddingbackend") ||
    lowered.includes("embedding_backend") ||
    lowered.includes("recall")
  );
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
  memoryRecallAutoLimit = DEFAULT_MEMORY_RECALL_AUTO_LIMIT,
  setMemoryRecallAutoLimit,
  memoryRecallDocPoolMultiplier = DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER,
  setMemoryRecallDocPoolMultiplier,
  memoryRecallEpisodicWeight = DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT,
  setMemoryRecallEpisodicWeight,
  validationError,
}: MemoryTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const advancedError = matchesAdvancedError(validationError)
    ? validationError
    : null;

  const handleResetAdvanced = () => {
    setMemoryRecallAutoLimit?.(DEFAULT_MEMORY_RECALL_AUTO_LIMIT);
    setMemoryRecallDocPoolMultiplier?.(
      DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER
    );
    setMemoryRecallEpisodicWeight?.(DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT);
  };

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

      <AdvancedDisclosure
        tabName="Memory"
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        validationError={advancedError}
        onReset={handleResetAdvanced}
      >
        <div className="form-group">
          <label htmlFor="recall-auto-limit">Recall Limit</label>
          <input
            id="recall-auto-limit"
            type="range"
            className="input-field"
            min={1}
            max={50}
            step={1}
            value={Number(memoryRecallAutoLimit) || DEFAULT_MEMORY_RECALL_AUTO_LIMIT}
            onChange={(e) =>
              setMemoryRecallAutoLimit?.(Number(e.target.value))
            }
          />
          <span className="form-group-hint">
            Maximum hits injected as system context per turn ({String(memoryRecallAutoLimit)}). Recall depth lives here with the other recall knobs.
          </span>
        </div>
        <div className="form-row" style={{ marginTop: "1rem" }}>
          <div className="form-group flex-1">
            <label htmlFor="recall-doc-pool">Document Pool Multiplier</label>
            <input
              id="recall-doc-pool"
              type="number"
              className="input-field"
              min={1}
              max={8}
              step={1}
              value={memoryRecallDocPoolMultiplier}
              onChange={(e) =>
                setMemoryRecallDocPoolMultiplier?.(
                  e.target.value === "" ? "" : Number(e.target.value)
                )
              }
              placeholder="4"
            />
            <span className="form-group-hint">
              Widening factor for the document candidate pool (1–8).
            </span>
          </div>
          <div className="form-group flex-1">
            <label htmlFor="recall-episodic-weight">Episodic Weight</label>
            <input
              id="recall-episodic-weight"
              type="number"
              className="input-field"
              min={0}
              max={1}
              step={0.05}
              value={memoryRecallEpisodicWeight}
              onChange={(e) =>
                setMemoryRecallEpisodicWeight?.(
                  e.target.value === "" ? "" : Number(e.target.value)
                )
              }
              placeholder="0.25"
            />
            <span className="form-group-hint">
              Weight mapping episodic rank scores onto the shared scale (0–1).
            </span>
          </div>
        </div>
      </AdvancedDisclosure>
    </div>
  );
}

export default MemoryTab;
