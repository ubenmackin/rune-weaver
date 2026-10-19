// Rune Weaver Dashboard — Onboarding brain provider choice step.
import { useState } from "react";
import {
  checkSecretStatus,
  updateSettings,
  type ProviderConfigData,
} from "../../api";

export type BrainProviderChoice = "local" | "cloud";

export interface BrainSelection {
  choice: BrainProviderChoice;
  defaultProvider: string;
  fallbackProvider: string;
  apiKeyEnv: string;
}

export interface BrainStepProps {
  initialChoice?: BrainProviderChoice;
  initialApiKeyEnv?: string;
  providers?: Record<string, ProviderConfigData>;
  onBack?: () => void;
  onNext?: (selection: BrainSelection) => void;
}

export const BRAIN_LOCAL_PROVIDER = "mlx";
export const BRAIN_CLOUD_PROVIDER = "openrouter";
export const BRAIN_LOCAL_MODEL = "gemma-4-9b";
export const BRAIN_DEFAULT_API_KEY_ENV = "OPENROUTER_API_KEY";

// Maps the radio choice onto the stored routing pair without introducing
// a new config key: local-first keeps cloud as fallback and vice versa.
export function resolveBrainSavePayload(
  choice: BrainProviderChoice,
  apiKeyEnv: string,
  existing?: Record<string, ProviderConfigData>,
): { defaultProvider: string; fallbackProvider: string; providers: Record<string, ProviderConfigData>; apiKeyEnv: string } {
  const trimmedEnv = (apiKeyEnv ?? "").trim() || BRAIN_DEFAULT_API_KEY_ENV;
  const defaultProvider = choice === "cloud" ? BRAIN_CLOUD_PROVIDER : BRAIN_LOCAL_PROVIDER;
  const fallbackProvider = choice === "cloud" ? BRAIN_LOCAL_PROVIDER : BRAIN_CLOUD_PROVIDER;
  const base: Record<string, ProviderConfigData> = { ...(existing ?? {}) };
  const mlxPrev = base[BRAIN_LOCAL_PROVIDER] ?? { enabled: true };
  const cloudPrev = base[BRAIN_CLOUD_PROVIDER] ?? { enabled: true };
  const mlxModel =
    typeof mlxPrev.model === "string" && mlxPrev.model.trim()
      ? mlxPrev.model
      : BRAIN_LOCAL_MODEL;
  const storedCloudEnv =
    typeof cloudPrev.apiKeyEnv === "string" && cloudPrev.apiKeyEnv.trim()
      ? cloudPrev.apiKeyEnv.trim()
      : trimmedEnv;
  // Fresh cloud input wins over the stored spelling; local keeps stored.
  const cloudEnv = choice === "cloud" ? trimmedEnv : storedCloudEnv;
  return {
    defaultProvider,
    fallbackProvider,
    apiKeyEnv: cloudEnv,
    providers: {
      ...base,
      [BRAIN_LOCAL_PROVIDER]: { ...mlxPrev, enabled: true, model: mlxModel },
      [BRAIN_CLOUD_PROVIDER]: { ...cloudPrev, enabled: true, apiKeyEnv: cloudEnv },
    },
  };
}

export function BrainStep({
  initialChoice = "local",
  initialApiKeyEnv = BRAIN_DEFAULT_API_KEY_ENV,
  providers,
  onBack,
  onNext,
}: BrainStepProps) {
  const [choice, setChoice] = useState<BrainProviderChoice>(initialChoice);
  const [apiKeyEnv, setApiKeyEnv] = useState(initialApiKeyEnv);
  const [expanded, setExpanded] = useState(initialChoice === "cloud");
  const [testStatus, setTestStatus] = useState<"idle" | "testing" | "granted" | "failed">("idle");
  const [testDetail, setTestDetail] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  function handleChoice(next: BrainProviderChoice) {
    setChoice(next);
    // Choosing cloud reveals its key field so the secret never hides behind a collapsed row.
    if (next === "cloud") setExpanded(true);
  }

  // Presence probe against the Keychain status endpoint; a missing key
  // reports inline and never advances the wizard on its own.
  async function handleTestConnection() {
    const trimmed = apiKeyEnv.trim();
    if (!trimmed) {
      setTestStatus("failed");
      setTestDetail("Enter an env var name first.");
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
    setSaving(true);
    setSaveError(null);
    const payload = resolveBrainSavePayload(choice, apiKeyEnv, providers);
    try {
      await updateSettings({
        defaultProvider: payload.defaultProvider,
        fallbackProvider: payload.fallbackProvider,
        providers: payload.providers,
      });
      onNext?.({
        choice,
        defaultProvider: payload.defaultProvider,
        fallbackProvider: payload.fallbackProvider,
        apiKeyEnv: payload.apiKeyEnv,
      });
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : "Failed to save provider choice.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="onboarding-step" data-testid="brain-step" aria-label="Choose your brain">
      <h2>Choose your brain</h2>
      <p>Local-first by default. Cloud is an opt-in fallback.</p>
      <div role="radiogroup" aria-label="Brain provider">
        <label>
          <input
            type="radio"
            name="brain-provider"
            value="local"
            checked={choice === "local"}
            onChange={() => handleChoice("local")}
          />
          Local MLX gemma-4-9b
        </label>
        <label>
          <input
            type="radio"
            name="brain-provider"
            value="cloud"
            checked={choice === "cloud"}
            onChange={() => handleChoice("cloud")}
          />
          Cloud openrouter
        </label>
      </div>
      <button
        type="button"
        data-testid="cloud-expander"
        aria-expanded={expanded}
        onClick={() => setExpanded((prev) => !prev)}
      >
        Use a cloud model
      </button>
      {expanded ? (
        <div data-testid="cloud-config">
          <label htmlFor="brain-api-key-env">API key env</label>
          <input
            id="brain-api-key-env"
            data-testid="brain-api-key-env"
            type="text"
            value={apiKeyEnv}
            onChange={(e) => {
              setApiKeyEnv(e.target.value);
              setTestStatus("idle");
              setTestDetail(null);
            }}
            placeholder={BRAIN_DEFAULT_API_KEY_ENV}
          />
          <p>Stored in macOS Keychain under com.runeweaver.secrets, never in the config file.</p>
          <button
            type="button"
            data-testid="brain-test-connection"
            disabled={testStatus === "testing"}
            onClick={() => void handleTestConnection()}
          >
            {testStatus === "testing" ? "Testing…" : "Test connection"}
          </button>
          <p data-testid="brain-test-status" role="status">
            {testStatus === "granted"
              ? "granted"
              : testStatus === "failed"
                ? `failed${testDetail ? ` — ${testDetail}` : ""}`
                : testStatus === "testing"
                  ? "testing…"
                  : ""}
          </p>
        </div>
      ) : null}
      {saveError ? (
        <p data-testid="brain-save-error" role="alert">
          {saveError}
        </p>
      ) : null}
      <div>
        {onBack ? (
          <button type="button" data-testid="brain-back" onClick={onBack}>
            Back
          </button>
        ) : null}
        <button type="button" data-testid="brain-next" disabled={saving} onClick={() => void handleNext()}>
          {saving ? "Saving…" : "Next"}
        </button>
      </div>
    </section>
  );
}

export default BrainStep;
