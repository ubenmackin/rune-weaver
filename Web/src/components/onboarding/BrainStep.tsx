// Rune Weaver Dashboard — Onboarding brain provider form.
import { useEffect, useRef, useState } from "react";
import {
  ApiError,
  checkSecretStatus,
  updateSettings,
  type ProviderConfigData,
} from "../../api";
import { KNOWN_PROVIDER_TYPES } from "../../api/settings-types";

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
  initialProviders?: Record<string, ProviderConfigData>;
  initialDefaultProvider?: string;
  initialApiKeyEnv?: string;
  isLoading?: boolean;
  loadError?: string | null;
  onBack?: () => void;
  onNext?: (selection: BrainSelection) => void;
}

export const BRAIN_PROVIDER_NAME_MAX_LENGTH = 64;
export const BRAIN_MODEL_MAX_LENGTH = 128;
export const BRAIN_API_KEY_ENV_MAX_LENGTH = 128;
export const BRAIN_SERVER_URL_MAX_LENGTH = 253;

export const BRAIN_KNOWN_PROVIDER_TYPES: readonly string[] = KNOWN_PROVIDER_TYPES;

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

const BRAIN_API_KEY_ENV_PATTERN = /^[A-Z][A-Z0-9_]*$/;

// Fail-closed client bounds: trimmed values stay inside length plus shape
// limits before any network write happens.
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
  if (rawURL.length > 0) {
    if (rawURL.length > BRAIN_SERVER_URL_MAX_LENGTH) {
      return "Server URL must be an absolute http(s) URL up to 253 characters.";
    }
    let parsed: URL;
    try {
      parsed = new URL(rawURL);
    } catch {
      return "Server URL must be an absolute http(s) URL up to 253 characters.";
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return "Server URL must be an absolute http(s) URL up to 253 characters.";
    }
  }
  const env = (form.apiKeyEnv ?? "").trim();
  if (env.length < 1 || env.length > BRAIN_API_KEY_ENV_MAX_LENGTH) {
    return "API key env must be 1 to 128 characters: A-Z, 0-9, underscore, starting with a letter.";
  }
  if (!BRAIN_API_KEY_ENV_PATTERN.test(env)) {
    return "API key env must be 1 to 128 characters: A-Z, 0-9, underscore, starting with a letter.";
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

function resolveBrainInitialForm(
  initialProviders: Record<string, ProviderConfigData> | undefined,
  initialDefaultProvider: string | undefined,
  legacyApiKeyEnv: string | undefined,
): BrainProviderForm {
  const entries = initialProviders ?? {};
  const key = (initialDefaultProvider ?? "").trim();
  if (key && Object.prototype.hasOwnProperty.call(entries, key)) {
    const entry = entries[key];
    const rawType =
      typeof entry.providerType === "string" ? entry.providerType.trim() : "";
    const normalizedType = rawType === "auto" ? "" : rawType;
    return {
      providerName: key,
      providerType: normalizedType,
      model: typeof entry.model === "string" ? entry.model : "",
      serverURL: typeof entry.serverURL === "string" ? entry.serverURL : "",
      apiKeyEnv: typeof entry.apiKeyEnv === "string" ? entry.apiKeyEnv : "",
    };
  }
  const legacyEnv = (legacyApiKeyEnv ?? "").trim();
  return {
    providerName: "",
    providerType: "",
    model: "",
    serverURL: "",
    apiKeyEnv: legacyEnv,
  };
}

export function BrainStep({
  initialProviders,
  initialDefaultProvider,
  initialApiKeyEnv = "",
  isLoading = false,
  loadError = null,
  onBack,
  onNext,
}: BrainStepProps) {
  const effectiveProviders = initialProviders ?? {};
  const effectiveDefault = initialDefaultProvider ?? "";
  const [initialForm] = useState<BrainProviderForm>(() =>
    resolveBrainInitialForm(effectiveProviders, effectiveDefault, initialApiKeyEnv),
  );
  const [providerName, setProviderName] = useState(initialForm.providerName);
  const [providerType, setProviderType] = useState(initialForm.providerType);
  const [model, setModel] = useState(initialForm.model);
  const [serverURL, setServerURL] = useState(initialForm.serverURL);
  const [apiKeyEnv, setApiKeyEnv] = useState(initialForm.apiKeyEnv);
  const [testStatus, setTestStatus] = useState<"idle" | "testing" | "granted" | "failed">("idle");
  const [testDetail, setTestDetail] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const dirtyRef = useRef(false);

  // Late fetch must not clobber typed input: resync only while pristine.
  useEffect(() => {
    if (dirtyRef.current) return;
    const next = resolveBrainInitialForm(
      initialProviders,
      effectiveDefault,
      initialApiKeyEnv,
    );
    setProviderName(next.providerName);
    setProviderType(next.providerType);
    setModel(next.model);
    setServerURL(next.serverURL);
    setApiKeyEnv(next.apiKeyEnv);
  }, [initialProviders, effectiveDefault, initialApiKeyEnv]);

  // Presence probe against the Keychain status endpoint; a missing key
  // reports inline and never advances the wizard on its own.
  async function handleTestConnection() {
    const trimmed = apiKeyEnv.trim();
    if (!trimmed) {
      setTestStatus("failed");
      setTestDetail("Enter env var name first.");
      return;
    }
    setTestStatus("testing");
    setTestDetail(null);
    try {
      const status = await checkSecretStatus([trimmed]);
      if (status && status[trimmed] === true) {
        setTestStatus("granted");
      } else {
        setTestStatus("failed");
        setTestDetail("Key not found in Keychain. Store it, then retry.");
      }
    } catch (err) {
      setTestStatus("failed");
      setTestDetail(err instanceof Error ? err.message : "Connection test failed. Retry.");
    }
  }

  async function handleNext() {
    if (isLoading) {
      setError("Providers are still loading. Wait, then retry.");
      return;
    }
    if (loadError) {
      setError(loadError);
      return;
    }
    const problem = validateBrainProviderForm({
      providerName,
      providerType,
      model,
      serverURL,
      apiKeyEnv,
    });
    if (problem) {
      setError(problem);
      return;
    }
    setSaving(true);
    setError(null);
    const payload = resolveBrainProviderSave(
      { providerName, providerType, model, serverURL, apiKeyEnv },
      effectiveProviders,
    );
    try {
      await updateSettings({
        defaultProvider: payload.defaultProvider,
        fallbackProvider: payload.fallbackProvider,
        providers: payload.providers,
      });
      onNext?.({
        providerName: payload.providerName,
        defaultProvider: payload.defaultProvider,
        fallbackProvider: payload.fallbackProvider,
        providerType: payload.providerType,
        model: payload.model,
        serverURL: payload.serverURL,
        apiKeyEnv: payload.apiKeyEnv,
      });
    } catch (err) {
      // Plain-text bodies drop the status from the message, so reattach
      // the code for an honest unauthenticated notice.
      if (err instanceof ApiError && err.status) {
        const detail = err.message.includes(String(err.status))
          ? err.message
          : `${err.status} ${err.message}`;
        setError(detail);
      } else {
        setError(err instanceof Error ? err.message : "Failed to save provider.");
      }
    } finally {
      setSaving(false);
    }
  }

  const testing = testStatus === "testing";
  const saveBlocked = saving || testing || isLoading || !!loadError;
  const showUnknownType =
    providerType !== "" &&
    !BRAIN_PROVIDER_TYPE_OPTIONS.some((option) => option.value === providerType);

  return (
    <section className="onboarding-step" data-testid="brain-step" aria-label="Choose your brain">
      <h2>Choose your brain</h2>
      <p className="onboarding-step-subtitle">Local-first by default. Cloud is an opt-in fallback.</p>
      <div className="form-group">
        <label htmlFor="brain-provider-name">Provider name</label>
        <input
          id="brain-provider-name"
          data-testid="brain-provider-name"
          className="input-field"
          type="text"
          value={providerName}
          maxLength={BRAIN_PROVIDER_NAME_MAX_LENGTH}
          onChange={(e) => {
            dirtyRef.current = true;
            setProviderName(e.target.value);
          }}
          placeholder="e.g. my-provider"
        />
      </div>
      <div className="form-group">
        <label htmlFor="brain-provider-type">Provider Type</label>
        <select
          id="brain-provider-type"
          data-testid="brain-provider-type"
          className="input-field"
          value={providerType}
          onChange={(e) => {
            dirtyRef.current = true;
            setProviderType(e.target.value);
          }}
        >
          {BRAIN_PROVIDER_TYPE_OPTIONS.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
          {showUnknownType ? <option value={providerType}>{providerType}</option> : null}
        </select>
      </div>
      <div className="form-group">
        <label htmlFor="brain-model">Model</label>
        <input
          id="brain-model"
          data-testid="brain-model"
          className="input-field"
          type="text"
          value={model}
          maxLength={BRAIN_MODEL_MAX_LENGTH}
          onChange={(e) => {
            dirtyRef.current = true;
            setModel(e.target.value);
          }}
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
          value={serverURL}
          maxLength={BRAIN_SERVER_URL_MAX_LENGTH}
          onChange={(e) => {
            dirtyRef.current = true;
            setServerURL(e.target.value);
          }}
          placeholder="https://openrouter.ai/api/v1"
        />
      </div>
      <div className="form-group">
        <label htmlFor="brain-api-key-env">API key env</label>
        <input
          id="brain-api-key-env"
          data-testid="brain-api-key-env"
          className="input-field"
          type="text"
          value={apiKeyEnv}
          maxLength={BRAIN_API_KEY_ENV_MAX_LENGTH}
          onChange={(e) => {
            dirtyRef.current = true;
            setApiKeyEnv(e.target.value);
            setTestStatus("idle");
            setTestDetail(null);
          }}
          placeholder="e.g. OPENROUTER_API_KEY"
        />
        <p className="muted text-sm">Stored in macOS Keychain under com.runeweaver.secrets, never in the config file.</p>
      </div>
      <div className="onboarding-actions">
        <button
          type="button"
          className="ghost"
          data-testid="brain-test-connection"
          disabled={testing || saving}
          onClick={() => void handleTestConnection()}
        >
          {testing ? "Testing…" : "Test connection"}
        </button>
      </div>
      <p
        data-testid="brain-test-status"
        role="status"
        className={testStatus === "failed" ? "error-banner" : testStatus === "granted" ? "granted-pill" : undefined}
      >
        {testStatus === "granted"
          ? "granted"
          : testStatus === "failed"
            ? `failed${testDetail ? ` — ${testDetail}` : ""}`
            : testing
              ? "testing…"
              : ""}
      </p>
      {loadError ? (
        <p data-testid="brain-load-error" role="alert" className="error-banner">
          {loadError}
        </p>
      ) : null}
      {error ? (
        <p data-testid="brain-error" role="alert" className="error-banner">
          {error}
        </p>
      ) : null}
      <div className="onboarding-actions">
        {onBack ? (
          <button type="button" className="ghost" data-testid="brain-back" onClick={onBack}>
            Back
          </button>
        ) : null}
        <button
          type="button"
          className="primary"
          data-testid="brain-next"
          disabled={saveBlocked}
          onClick={() => void handleNext()}
        >
          {saving ? "Saving…" : testing ? "Testing…" : isLoading ? "Loading…" : "Next"}
        </button>
      </div>
    </section>
  );
}

export default BrainStep;
