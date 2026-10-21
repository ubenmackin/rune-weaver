// Rune Weaver Dashboard — Onboarding brain provider form.
import { useCallback, useEffect, useRef } from "react";
import type { ProviderConfigData } from "../../api";
import { normalizeSecretKey } from "../StoreSecretModal";
import { KeychainBadge } from "./KeychainBadge";
import { BRAIN_SECRET_PROBE_PATTERN } from "./brainProbe";

export interface BrainProviderForm {
  providerName: string;
  providerType: string;
  model: string;
  serverURL: string;
  apiKeyEnv: string;
}

export interface BrainSelection {
  providerName: string;
  defaultProvider: string;
  fallbackProvider: string;
  providerType: string;
  model: string;
  serverURL: string;
  apiKeyEnv: string;
}

export interface BrainStepProps {
  value?: BrainProviderForm;
  onChange?: (patch: Partial<BrainProviderForm>) => void;
  testStatus?: "idle" | "testing" | "succeeded" | "failed";
  testDetail?: string | null;
  secretStored?: boolean;
  onStoreKey?: () => void;
  fieldError?: string | null;
}

export const BRAIN_PROVIDER_NAME_MAX_LENGTH = 64;
export const BRAIN_MODEL_MAX_LENGTH = 128;
export const BRAIN_API_KEY_ENV_MAX_LENGTH = 128;
export const BRAIN_SERVER_URL_MAX_LENGTH = 253;

export const BRAIN_PROVIDER_TYPE_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "", label: "Auto" },
  { value: "custom", label: "Custom" },
  { value: "openrouter", label: "OpenRouter" },
  { value: "openai", label: "OpenAI" },
  { value: "anthropic", label: "Anthropic" },
  { value: "gemini", label: "Gemini" },
  { value: "ollama", label: "Ollama" },
  { value: "mlx", label: "MLX" },
  { value: "lmstudio", label: "LM Studio" },
  { value: "llamacpp", label: "llama.cpp" },
  { value: "local", label: "Local" },
];

// Shared URL shape check keeps wizard test and save validation in sync.
export function isValidBrainServerURL(rawURL: string): boolean {
  const trimmed = (rawURL ?? "").trim();
  if (trimmed.length === 0) return true;
  if (trimmed.length > BRAIN_SERVER_URL_MAX_LENGTH) return false;
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return false;
  }
  return parsed.protocol === "http:" || parsed.protocol === "https:";
}

// Empty key means local no-auth provider, so only non-empty values need shape checks.
export function validateBrainProviderForm(form: BrainProviderForm): string | null {
  const name = (form.providerName ?? "").trim();
  if (name.length < 1 || name.length > BRAIN_PROVIDER_NAME_MAX_LENGTH) {
    return "Provider name must be 1 to 64 characters.";
  }
  // Unknown types stay server-valid (engine defaults them to OpenAICompatible),
  // so any trimmed value round-trips and the select preserves it via its
  // extra option instead of forcing a mutation on save.
  const model = (form.model ?? "").trim();
  if (model.length < 1 || model.length > BRAIN_MODEL_MAX_LENGTH) {
    return "Model must be 1 to 128 characters.";
  }
  const rawURL = (form.serverURL ?? "").trim();
  if (!isValidBrainServerURL(rawURL)) {
    return "Server URL must be an absolute http(s) URL up to 253 characters.";
  }
  const env = (form.apiKeyEnv ?? "").trim();
  if (env.length === 0) {
    return null;
  }
  if (env.length > BRAIN_API_KEY_ENV_MAX_LENGTH) {
    return "API Key Name must be empty or up to 128 characters: A-Z, 0-9, underscore, starting with a letter.";
  }
  if (!BRAIN_SECRET_PROBE_PATTERN.test(env)) {
    return "API Key Name must be empty or up to 128 characters: A-Z, 0-9, underscore, starting with a letter.";
  }
  return null;
}

// Builds the single-provider save payload: existing entries survive by
// spread while the trimmed form owns the new default with an empty fallback.
export function resolveBrainProviderSave(
  form: BrainProviderForm,
  existing?: Record<string, ProviderConfigData>,
): {
  defaultProvider: string;
  fallbackProvider: string;
  providers: Record<string, ProviderConfigData>;
  providerName: string;
  providerType: string;
  model: string;
  serverURL: string;
  apiKeyEnv: string;
} {
  const providerName = (form.providerName ?? "").trim();
  const providerType = (form.providerType ?? "").trim();
  const model = (form.model ?? "").trim();
  const serverURL = (form.serverURL ?? "").trim();
  const apiKeyEnv = (form.apiKeyEnv ?? "").trim();
  const base: Record<string, ProviderConfigData> = { ...(existing ?? {}) };
  const prev = base[providerName] ?? { enabled: true };
  return {
    defaultProvider: providerName,
    fallbackProvider: "",
    providers: {
      ...base,
      [providerName]: {
        ...prev,
        enabled: true,
        model,
        serverURL,
        apiKeyEnv,
        providerType,
      },
    },
    providerName,
    providerType,
    model,
    serverURL,
    apiKeyEnv,
  };
}

// Server-owned prefill: default entry wins, single-entry installs fall
// back to that lone provider, otherwise start blank for a new entry.
// Unknown defaults fall through to the single-entry then blank rules.
export function resolveBrainInitialForm(
  providers?: Record<string, ProviderConfigData>,
  defaultProvider?: string,
  legacyApiKeyEnv?: string,
): BrainProviderForm {
  const legacyEnv = (legacyApiKeyEnv ?? "").trim();
  const entries = Object.entries(providers ?? {});
  const trimmedDefault = (defaultProvider ?? "").trim();
  const defaultEntry =
    trimmedDefault.length > 0 ? (providers ?? {})[trimmedDefault] : undefined;
  const singleEntry = entries.length === 1 ? entries[0] : undefined;
  const chosen = defaultEntry
    ? ([trimmedDefault, defaultEntry] as const)
    : singleEntry;
  if (!chosen) {
    return {
      providerName: "",
      providerType: "",
      model: "",
      serverURL: "",
      apiKeyEnv: legacyEnv,
    };
  }
  const [providerName, config] = chosen;
  // Empty selects Auto, so a stored auto sentinel collapses to empty.
  const rawType = (config.providerType ?? "").trim();
  return {
    providerName,
    providerType: rawType.toLowerCase() === "auto" ? "" : rawType,
    model: config.model ?? "",
    serverURL: config.serverURL ?? "",
    apiKeyEnv: config.apiKeyEnv ?? "",
  };
}

export function BrainStep({
  value = { providerName: "", providerType: "", model: "", serverURL: "", apiKeyEnv: "" },
  onChange = () => {},
  testStatus = "idle",
  testDetail = null,
  secretStored = false,
  onStoreKey = () => {},
  fieldError = null,
}: BrainStepProps) {
  const errorRef = useRef<HTMLParagraphElement>(null);
  const testStatusRef = useRef<HTMLParagraphElement>(null);

  // Failures scroll into view then focus after paint, unless the owner
  // already moved into a field to correct it — never yank focus mid-edit.
  const focusNode = useCallback((ref: { current: HTMLParagraphElement | null }) => {
    const run = () => {
      const target = ref.current;
      if (!target) return;
      if (typeof target.scrollIntoView === "function") {
        target.scrollIntoView({ block: "nearest" });
      }
      const active = document.activeElement as HTMLElement | null;
      const editing =
        !!active &&
        active !== target &&
        (active.tagName === "INPUT" ||
          active.tagName === "TEXTAREA" ||
          active.tagName === "SELECT" ||
          active.isContentEditable);
      if (editing) return;
      target.focus({ preventScroll: true });
    };
    // Timeout lets React commit before focusing when tests stub rAF sync.
    const defer = () => setTimeout(run, 0);
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(defer);
    } else {
      defer();
    }
  }, []);

  // Inline failure surfaces where the form lives.
  useEffect(() => {
    if (fieldError) focusNode(errorRef);
  }, [fieldError, focusNode]);

  // Test failure shares the same focusing posture as validation failures.
  useEffect(() => {
    if (testStatus === "failed") focusNode(testStatusRef);
  }, [testStatus, testDetail, focusNode]);

  const normalizedKey = normalizeSecretKey(value.apiKeyEnv);
  const showKeychain = normalizedKey.length > 0;
  const isStored = secretStored === true;
  const showUnknownType =
    value.providerType !== "" &&
    !BRAIN_PROVIDER_TYPE_OPTIONS.some((option) => option.value === value.providerType);

  return (
    <section className="onboarding-step" data-testid="brain-step" aria-label="Choose your brain">
      <h2>Choose your brain</h2>
      <p className="onboarding-step-subtitle">Local-first by default. Cloud is an opt-in fallback.</p>
      <div className="form-row">
        <div className="form-group flex-1">
          <label htmlFor="brain-provider-name">Provider name</label>
          <input
            id="brain-provider-name"
            data-testid="brain-provider-name"
            className="input-field"
            type="text"
            value={value.providerName}
            maxLength={BRAIN_PROVIDER_NAME_MAX_LENGTH}
            onChange={(e) => onChange({ providerName: e.target.value })}
            placeholder="e.g. my-provider"
          />
        </div>
        <div className="form-group flex-1">
          <label htmlFor="brain-provider-type">Provider Type</label>
          <select
            id="brain-provider-type"
            data-testid="brain-provider-type"
            className="input-field"
            value={value.providerType}
            onChange={(e) => onChange({ providerType: e.target.value })}
          >
            {BRAIN_PROVIDER_TYPE_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
            {showUnknownType ? <option value={value.providerType}>{value.providerType}</option> : null}
          </select>
        </div>
      </div>
      <div className="form-group">
        <label htmlFor="brain-model">Model</label>
        <input
          id="brain-model"
          data-testid="brain-model"
          className="input-field"
          type="text"
          value={value.model}
          maxLength={BRAIN_MODEL_MAX_LENGTH}
          onChange={(e) => onChange({ model: e.target.value })}
          placeholder="e.g. gemma-4-9b"
        />
      </div>
      <div className="form-group">
        <label htmlFor="brain-server-url">Server URL</label>
        <input
          id="brain-server-url"
          data-testid="brain-server-url"
          className="input-field"
          type="text"
          value={value.serverURL}
          maxLength={BRAIN_SERVER_URL_MAX_LENGTH}
          onChange={(e) => onChange({ serverURL: e.target.value })}
          placeholder="https://openrouter.ai/api/v1"
        />
      </div>
      <div className="form-group">
        <div className="keychain-row">
          <label htmlFor="brain-api-key-env">API Key Name - Optional</label>
          {showKeychain ? (
            <KeychainBadge isStored={isStored} keyEnv={normalizedKey} onStore={onStoreKey} />
          ) : null}
        </div>
        <input
          id="brain-api-key-env"
          data-testid="brain-api-key-env"
          className="input-field"
          type="text"
          value={value.apiKeyEnv}
          maxLength={BRAIN_API_KEY_ENV_MAX_LENGTH}
          onChange={(e) => onChange({ apiKeyEnv: e.target.value })}
          placeholder="e.g. OPENROUTER_API_KEY"
        />
      </div>
      {testStatus !== "idle" ? (
        <p
          ref={testStatusRef}
          tabIndex={-1}
          data-testid="brain-test-status"
          role={testStatus === "failed" ? "alert" : "status"}
          className={
            testStatus === "failed"
              ? "error-banner"
              : testStatus === "succeeded"
                ? "succeeded-pill"
                : undefined
          }
        >
          {testStatus === "succeeded"
            ? `Succeeded${testDetail ? `: ${testDetail}` : ""}`
            : testStatus === "failed"
              ? `Failed to connect${testDetail ? `: ${testDetail}` : ""}`
              : "Testing…"}
        </p>
      ) : null}
      {fieldError ? (
        <p ref={errorRef} tabIndex={-1} data-testid="brain-error" role="alert" className="error-banner">
          {fieldError}
        </p>
      ) : null}
    </section>
  );
}

export default BrainStep;
