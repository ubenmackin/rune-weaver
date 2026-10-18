// Rune Weaver Dashboard — Tools registry, discovery, and workspace API.
import { fetchJson } from "./http";


export interface ToolInfo {
  name: string;
  description: string;
  permissionLevel: string;
  inputSchema: string;
  isEnabled: boolean;
  isBuiltIn: boolean;
  pluginID?: string | null;
  source: string;
  integrityStatus: string;
  hasConfig?: boolean;
}

export interface ToolsResponse {
  tools: ToolInfo[];
}

export function getTools(): Promise<ToolsResponse> {
  return fetchJson<ToolsResponse>("/tools");
}

// Toggles one registered tool without touching siblings: the engine persists the flag before
// mutating the live bus, so a builtin and a plugin tool with similar prefixes never share fate and
// per-tool granularity (email.read vs email.attachment) stays intact across restarts.
export function updateToolState(name: string, enabled: boolean): Promise<ToolInfo> {
  return fetchJson<ToolInfo>(`/tools/${encodeURIComponent(name)}/state`, {
    method: "POST",
    body: JSON.stringify({ enabled }),
  });
}

export interface PluginSummary {
  id: string;
  name: string;
  version: string;
  author?: string | null;
  description: string;
  runtime: string;
  source: string;
  status: "discovered" | "enabled" | "disabled" | "tampered";
  isEnabled: boolean;
  integrityHash?: string | null;
  tools: ToolInfo[];
  permissionOverrides: Record<string, string>;
  discoveredAt: string;
  updatedAt: string;
}

export interface PluginsResponse {
  plugins: PluginSummary[];
}

export interface UpdatePluginStateRequest {
  action: "enable" | "disable" | "override_permission" | "clear_override";
  toolName?: string;
  permissionLevel?: "readOnly" | "requiresApproval";
}

export interface MarketplacePluginItem {
  id: string;
  name: string;
  version: string;
  author: string;
  description: string;
  downloadURL: string;
  tags: string[];
  runtime: string;
  declaredTools: string[];
  isInstalled: boolean;
}

export interface MarketplaceResponse {
  items: MarketplacePluginItem[];
}

export interface InstallMarketplacePluginRequest {
  id: string;
  // Optional display provenance carried alongside the install.
  downloadURL?: string;
}

export function getPlugins(): Promise<PluginsResponse> {
  return fetchJson<PluginsResponse>("/plugins");
}

export function getPlugin(id: string): Promise<PluginSummary> {
  return fetchJson<PluginSummary>(`/plugins/${encodeURIComponent(id)}`);
}

export function rescanPlugins(): Promise<PluginsResponse> {
  return fetchJson<PluginsResponse>("/plugins/rescan", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

export function updatePluginState(
  id: string,
  request: UpdatePluginStateRequest,
): Promise<PluginSummary> {
  return fetchJson<PluginSummary>(`/plugins/${encodeURIComponent(id)}/state`, {
    method: "POST",
    body: JSON.stringify(request),
  });
}

export function uninstallPlugin(id: string): Promise<void> {
  return fetchJson<void>(`/plugins/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
}

export function getMarketplacePlugins(): Promise<MarketplaceResponse> {
  return fetchJson<MarketplaceResponse>("/marketplace/plugins");
}

export function installMarketplacePlugin(
  request: InstallMarketplacePluginRequest,
): Promise<PluginSummary> {
  return fetchJson<PluginSummary>("/marketplace/install", {
    method: "POST",
    body: JSON.stringify(request),
  });
}

export interface SecretListResponse {
  keys: string[];
}

export async function listSecretKeys(): Promise<string[]> {
  const response = await fetchJson<SecretListResponse>("/settings/secrets");
  const keys = Array.isArray(response?.keys)
    ? response.keys.filter((entry): entry is string => typeof entry === "string")
    : [];
  return [...keys].sort((a, b) => a.localeCompare(b));
}

export interface SecretStatusResponse {
  status: Record<string, boolean>;
}

export function storeSecret(key: string, secret: string): Promise<void> {
  return fetchJson<void>("/settings/secrets", {
    method: "POST",
    body: JSON.stringify({ key, secret }),
  });
}

export async function checkSecretStatus(
  keys: string[],
): Promise<Record<string, boolean>> {
  if (keys.length === 0) return {};
  const response = await fetchJson<SecretStatusResponse>(
    "/settings/secrets/status",
    {
      method: "POST",
      body: JSON.stringify({ keys }),
    },
  );
  return response?.status ?? {};
}

export function deleteSecret(key: string): Promise<void> {
  return fetchJson<void>(`/settings/secrets/${encodeURIComponent(key)}`, {
    method: "DELETE",
  });
}

export interface StagedFile {
  path: string;
  stagingPath: string;
  diff: string;
  additions: number;
  deletions: number;
  updatedAt?: string;
}

export interface StagedFilesResponse {
  files: StagedFile[];
}

export interface FileActionResponse {
  status: string;
  count?: number;
}

export async function getStagedFiles(path?: string): Promise<StagedFilesResponse> {
  const url = path ? `/files/staged?path=${encodeURIComponent(path)}` : "/files/staged";
  return fetchJson<StagedFilesResponse>(url);
}

// Accepts one staged file (or all when `all` is true). The optional signal
// lets inline review cards bound the request with a client-side timeout so a
// hung engine walk cannot leave the card in a perpetual loading state.
export async function acceptStagedFile(path?: string, all?: boolean, signal?: AbortSignal): Promise<FileActionResponse> {
  return fetchJson<FileActionResponse>("/files/accept", {
    method: "POST",
    body: JSON.stringify({ path, all }),
    signal,
  });
}

// Discards one staged file (or all when `all` is true). Mirrors the accept
// timeout contract above so discard cards share the same abort behavior.
export async function discardStagedFile(path?: string, all?: boolean, signal?: AbortSignal): Promise<FileActionResponse> {
  return fetchJson<FileActionResponse>("/files/discard", {
    method: "POST",
    body: JSON.stringify({ path, all }),
    signal,
  });
}

// Accepts one live write review: the live bytes stay as written and the
// rollback copy is cleared. Mirrors the staged accept timeout contract so an
// inline card can bound the request with a client-side abort signal.
export async function acceptLiveReview(
  path: string,
  signal?: AbortSignal,
): Promise<FileActionResponse> {
  return fetchJson<FileActionResponse>("/files/live-accept", {
    method: "POST",
    body: JSON.stringify({ path }),
    signal,
  });
}

// Declines one live write review: the engine restores the rollback copy when the review owns one
// and deletes the created file otherwise.
export async function declineLiveReview(
  path: string,
  signal?: AbortSignal,
): Promise<FileActionResponse> {
  return fetchJson<FileActionResponse>("/files/live-decline", {
    method: "POST",
    body: JSON.stringify({ path }),
    signal,
  });
}

// Review states shared with the engine's durable review ledger.
export type FileReviewState =
  | "pending"
  | "accepted"
  | "discarded"
  | "superseded"
  | "reverted"
  | "unknown";

// Both ledger maps of the batch review-status response, keyed by live path. A
// rendered surface hands this shape down to its cards so every card reads its
// own posture from one shared response instead of issuing its own request.
export interface FileReviewStates {
  stagedStates: Record<string, FileReviewState>;
  liveStates: Record<string, FileReviewState>;
}

// Batch-hydrates review posture for the given live paths in one round trip.
export async function getFileReviewStates(
  paths: string[],
  signal?: AbortSignal,
): Promise<FileReviewStates> {
  const response = await fetchJson<{
    stagedStates?: Record<string, FileReviewState>;
    liveStates?: Record<string, FileReviewState>;
  }>("/files/review-status", {
    method: "POST",
    body: JSON.stringify({ paths }),
    signal,
  });
  return {
    stagedStates: response?.stagedStates ?? {},
    liveStates: response?.liveStates ?? {},
  };
}

// Agent scratch workspace
// ---------------------------------------------------------------------------

// Bounded usage snapshot for `GET /workspace/usage`. Quotas ride along so the
// dashboard renders both bars from one fetch; `truncated` marks the walk as a
// lower bound when the tree outgrew the entry cap.
export interface WorkspaceUsageResponse {
  bytes: number;
  files: number;
  truncated: boolean;
  quotaMB: number;
  quotaFiles: number;
}

// Prune receipt for `POST /workspace/tmp/prune`. Counts top-level `tmp/`
// entries removed; a fresh workspace prunes to zero without an error.
export interface WorkspacePruneResponse {
  removed: number;
}



// Human byte tally shared by the quota bar and prune receipts.
export function formatWorkspaceBytes(bytes: unknown): string {
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = Math.floor(bytes);
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const rounded = unit === 0 ? String(Math.round(value)) : value.toFixed(1);
  return `${rounded} ${units[unit]}`;
}

// Whole-percent quota fill for the usage bar. Clamps so a drifted over-quota
// walk fills the track instead of overflowing it; a non-positive quota
// degrades to 0 rather than dividing by zero.
export function workspaceQuotaPercent(used: unknown, quota: unknown): number {
  if (
    typeof used !== "number" ||
    typeof quota !== "number" ||
    !Number.isFinite(used) ||
    !Number.isFinite(quota) ||
    quota <= 0
  ) {
    return 0;
  }
  const percent = (used / quota) * 100;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

// Reads bounded scratch usage with quotas for the dashboard bars. A missing
// workspace reads as an honest empty snapshot server-side, so the viewer
// renders zero instead of an error; a walk failure surfaces as ApiError.
export function getWorkspaceUsage(): Promise<WorkspaceUsageResponse> {
  return fetchJson<WorkspaceUsageResponse>("/workspace/usage");
}

// Clears expired `tmp/` entries. Missing `tmp/` prunes to zero rather than
// failing, so a fresh workspace resolves normally; the receipt names the
// removed top-level entries.
export function pruneWorkspaceTmp(): Promise<WorkspacePruneResponse> {
  return fetchJson<WorkspacePruneResponse>("/workspace/tmp/prune", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Machine status for `GET /workspace/machine`. Mirrors the engine
// WorkspaceMachineResponse so the dashboard control reads live state.
export interface WorkspaceMachineResponse {
  exists: boolean;
  running: boolean;
  image: string;
  configMatch: boolean | null;
}

// Reads the persistent workspace machine status for the Tools-tab control.
export function getWorkspaceMachine(): Promise<WorkspaceMachineResponse> {
  return fetchJson<WorkspaceMachineResponse>("/workspace/machine");
}

// Stops the machine container without removing it.
export function stopWorkspaceMachine(): Promise<WorkspaceMachineResponse> {
  return fetchJson<WorkspaceMachineResponse>("/workspace/machine/stop", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Stops plus removes the machine so the next call recreates it.
export function recycleWorkspaceMachine(): Promise<WorkspaceMachineResponse> {
  return fetchJson<WorkspaceMachineResponse>("/workspace/machine/recycle", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

export interface EmbeddingsStatusResponse {
  backend: string;
  status: "idle" | "downloading_binary" | "downloading_model" | "starting" | "ready" | "error";
  stage?: string | null;
  model: string;
  dimensions: number;
  acceleration: string;
  endpoint: string;
  isRunning: boolean;
  error?: string | null;
}

export function getEmbeddingsStatus(): Promise<EmbeddingsStatusResponse> {
  return fetchJson<EmbeddingsStatusResponse>("/embeddings/status");
}

export function ensureEmbeddings(): Promise<EmbeddingsStatusResponse> {
  return fetchJson<EmbeddingsStatusResponse>("/embeddings/ensure", {
    method: "POST",
    body: JSON.stringify({}),
  });
}

