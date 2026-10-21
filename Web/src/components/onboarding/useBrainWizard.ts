// Rune Weaver Dashboard — Wizard-owned brain draft plus Keychain and save state.
import { useEffect, useRef, useState } from "react";
import { fetchJson } from "../../api/http";
import {
  ApiError,
  checkSecretStatus,
  updateSettings,
  type ProviderConfigData,
} from "../../api";
import { normalizeSecretKey } from "../StoreSecretModal";
import {
  BRAIN_API_KEY_ENV_MAX_LENGTH,
  formatBrainSaveError,
  isValidBrainServerURL,
  resolveBrainInitialForm,
  resolveBrainProviderSave,
  validateBrainProviderForm,
  type BrainProviderForm,
  type BrainSelection,
} from "./BrainStep";
import { BRAIN_SECRET_PROBE_PATTERN, probeBrainServer } from "./brainProbe";
import { nextStep, type WizardNextOptions } from "./wizardState";

export type BrainTestStatus = "idle" | "testing" | "succeeded" | "failed";

export interface UseBrainWizardOptions {
  standalone: boolean;
  hydrated: boolean;
  setStepError: (message: string | null) => void;
  setError: (message: string | null) => void;
}

// Single state owner stays the wizard shell; this hook only groups the
// draft plus connection, save, and Keychain fields behind one call site.
export function useBrainWizard(options: UseBrainWizardOptions) {
  const { standalone, hydrated, setStepError, setError } = options;
  const [brainSelection, setBrainSelection] = useState<BrainSelection | null>(null);
  const [brainProviders, setBrainProviders] = useState<
    Record<string, ProviderConfigData> | undefined
  >(undefined);
  const [brainDefaultProvider, setBrainDefaultProvider] = useState<string | undefined>(
    undefined,
  );
  const [brainProvidersError, setBrainProvidersError] = useState<string | null>(null);
  const [brainDraft, setBrainDraft] = useState<BrainProviderForm>(() => ({
    providerName: "",
    providerType: "",
    model: "",
    serverURL: "",
    apiKeyEnv: "",
  }));
  const [brainTestStatus, setBrainTestStatus] = useState<BrainTestStatus>("idle");
  const [brainTestDetail, setBrainTestDetail] = useState<string | null>(null);
  const [brainSaving, setBrainSaving] = useState(false);
  const [brainError, setBrainError] = useState<string | null>(null);
  const [brainSecretStatus, setBrainSecretStatus] = useState<Record<string, boolean>>({});
  const [brainSecretModalOpen, setBrainSecretModalOpen] = useState(false);
  const [brainSecretIsUpdate, setBrainSecretIsUpdate] = useState(false);
  const brainDirtyRef = useRef(false);
  const brainMountedRef = useRef(true);
  const brainTestAbortRef = useRef<AbortController | null>(null);

  // Mounted guard stops late probe results from landing after navigation.
  useEffect(() => {
    brainMountedRef.current = true;
    return () => {
      brainMountedRef.current = false;
      brainTestAbortRef.current?.abort();
    };
  }, []);

  // Provider list stays server-owned so a brain save spreads existing
  // entries instead of clobbering them with a single-entry dict.
  useEffect(() => {
    if (standalone) return;
    if (!hydrated) return;
    if (brainProviders !== undefined) return;
    let cancelled = false;
    void (async () => {
      try {
        const settings = await fetchJson<{
          providers?: Record<string, ProviderConfigData>;
          defaultProvider?: string;
        }>("/settings");
        if (cancelled) return;
        setBrainProviders(settings?.providers ?? {});
        setBrainDefaultProvider(
          typeof settings?.defaultProvider === "string" ? settings.defaultProvider : "",
        );
        setBrainProvidersError(null);
      } catch (err) {
        // Fail closed: leave the base undefined so save stays disabled
        // and surface the load failure instead of seeding an empty dict.
        if (!cancelled) {
          setBrainProvidersError(
            err instanceof Error ? err.message : "Failed to load providers.",
          );
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [standalone, hydrated, brainProviders]);

  // Late provider fetch must not clobber typed input: resync only while pristine.
  useEffect(() => {
    if (brainDirtyRef.current) return;
    if (brainProviders === undefined) return;
    const next = resolveBrainInitialForm(
      brainProviders,
      brainDefaultProvider,
      brainSelection?.apiKeyEnv,
    );
    setBrainDraft(next);
  }, [brainProviders, brainDefaultProvider, brainSelection]);

  // Badge resolves after a settled valid name so typing never spams Keychain.
  useEffect(() => {
    const key = normalizeSecretKey(brainDraft.apiKeyEnv);
    if (!key || key.length > BRAIN_API_KEY_ENV_MAX_LENGTH) return;
    if (!BRAIN_SECRET_PROBE_PATTERN.test(key)) return;
    let cancelled = false;
    const timer = setTimeout(() => {
      void checkSecretStatus([key])
        .then((status) => {
          if (!cancelled && status) {
            setBrainSecretStatus((prev) => ({ ...prev, [key]: status[key] === true }));
          }
        })
        .catch(() => {});
    }, 350);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [brainDraft.apiKeyEnv]);

  function handleBrainPatch(patch: Partial<BrainProviderForm>) {
    brainDirtyRef.current = true;
    setBrainDraft((prev) => ({ ...prev, ...patch }));
    // Any edit restarts verification so a stale pill never survives a rename.
    setBrainTestStatus("idle");
    setBrainTestDetail(null);
    setStepError(null);
  }

  function handleBrainStoreOpen() {
    const key = normalizeSecretKey(brainDraft.apiKeyEnv);
    if (!key) return;
    setBrainSecretIsUpdate(brainSecretStatus[key] === true);
    setBrainSecretModalOpen(true);
  }

  function handleBrainStoreClose() {
    setBrainSecretModalOpen(false);
  }

  function handleBrainStoreSuccess(key: string) {
    const normalized = normalizeSecretKey(key) || normalizeSecretKey(brainDraft.apiKeyEnv);
    if (normalized) {
      setBrainSecretStatus((prev) => ({ ...prev, [normalized]: true }));
    }
    setBrainTestStatus("idle");
    setBrainTestDetail(null);
    setStepError(null);
  }

  // Back navigation drops stale inline plus probe state so forward never replays it.
  function clearErrors() {
    setBrainError(null);
    setBrainTestStatus("idle");
    setBrainTestDetail(null);
    setStepError(null);
  }

  // Blank plus malformed URLs fail without probing; success needs reachability plus stored key.
  async function handleBrainTest() {
    const trimmedKey = normalizeSecretKey(brainDraft.apiKeyEnv);
    const trimmedURL = (brainDraft.serverURL ?? "").trim();
    if (!trimmedURL) {
      const detail = "Enter server URL first";
      setBrainTestStatus("failed");
      setBrainTestDetail(detail);
      setStepError(detail);
      return;
    }
    if (!isValidBrainServerURL(trimmedURL)) {
      const detail = "Server URL must be an absolute http(s) URL up to 253 characters.";
      setBrainTestStatus("failed");
      setBrainTestDetail(detail);
      setStepError(detail);
      return;
    }
    brainTestAbortRef.current?.abort();
    const controller = new AbortController();
    brainTestAbortRef.current = controller;
    setBrainTestStatus("testing");
    setBrainTestDetail(null);
    setStepError(null);
    let keyStored = true;
    if (trimmedKey) {
      try {
        const status = await checkSecretStatus([trimmedKey]);
        keyStored = status?.[trimmedKey] === true;
      } catch {
        keyStored = false;
      }
    }
    if (!brainMountedRef.current || controller.signal.aborted) return;
    const reachable = await probeBrainServer(trimmedURL, { signal: controller.signal });
    if (!brainMountedRef.current || controller.signal.aborted) return;
    if (reachable && keyStored) {
      setBrainTestStatus("succeeded");
      setBrainTestDetail(null);
      setStepError(null);
      return;
    }
    const parts: string[] = [];
    if (!reachable) parts.push("Server unreachable");
    if (trimmedKey && !keyStored) parts.push("Key not stored");
    const detail = parts.length > 0 ? parts.join(", ") : "Server unreachable";
    if (!brainMountedRef.current || controller.signal.aborted) return;
    setBrainTestStatus("failed");
    setBrainTestDetail(detail);
    setStepError(detail);
  }

  async function handleBrainNext(nextOptions: WizardNextOptions) {
    const { current, skipped, onAdvanced, onFinished } = nextOptions;
    const loading = brainProviders === undefined && !brainProvidersError;
    if (loading) {
      const message = "Providers are still loading. Wait, then retry.";
      setBrainError(message);
      setStepError(message);
      return;
    }
    if (brainProvidersError) {
      setBrainError(brainProvidersError);
      setStepError(brainProvidersError);
      return;
    }
    const problem = validateBrainProviderForm(brainDraft);
    if (problem) {
      setBrainError(problem);
      setStepError(problem);
      return;
    }
    setBrainSaving(true);
    setBrainError(null);
    setStepError(null);
    const payload = resolveBrainProviderSave(brainDraft, brainProviders);
    try {
      await updateSettings({
        defaultProvider: payload.defaultProvider,
        fallbackProvider: payload.fallbackProvider,
        providers: payload.providers,
      });
      const selection: BrainSelection = {
        providerName: payload.providerName,
        defaultProvider: payload.defaultProvider,
        fallbackProvider: payload.fallbackProvider,
        providerType: payload.providerType,
        model: payload.model,
        serverURL: payload.serverURL,
        apiKeyEnv: payload.apiKeyEnv,
      };
      setError(null);
      setStepError(null);
      setBrainError(null);
      setBrainSelection(selection);
      setBrainProviders(payload.providers);
      setBrainDefaultProvider(payload.defaultProvider);
      const next = nextStep(current, skipped);
      if (!next) {
        await onFinished();
        return;
      }
      onAdvanced(next);
    } catch (err) {
      // Friendly ConfigError text drops the status; plain 401 bodies reattach it.
      const saveLabel = (brainDraft.providerName ?? "").trim() || "Provider";
      const friendly = formatBrainSaveError(err, saveLabel);
      const raw =
        err instanceof Error
          ? err.message
          : typeof err === "string" && err.length > 0
            ? err
            : "Failed to save provider.";
      let detail: string;
      if (friendly !== raw) {
        detail = friendly;
      } else if (err instanceof ApiError && err.status === 401) {
        detail = raw.includes("401") ? raw : `401 ${raw}`;
      } else {
        detail = friendly;
      }
      setBrainError(detail);
      setStepError(detail);
    } finally {
      setBrainSaving(false);
    }
  }

  const brainLoading = brainProviders === undefined && !brainProvidersError;
  const brainTesting = brainTestStatus === "testing";
  const normalizedKey = normalizeSecretKey(brainDraft.apiKeyEnv);
  const secretStored = normalizedKey ? brainSecretStatus[normalizedKey] === true : false;
  const providerLabel = brainDraft.providerName.trim() || "Provider";
  const fieldError = brainError ?? brainProvidersError ?? null;
  const testFailure = brainTestStatus === "failed" ? brainTestDetail : null;

  return {
    draft: brainDraft,
    testStatus: brainTestStatus,
    testDetail: brainTestDetail,
    testFailure,
    saving: brainSaving,
    error: brainError,
    fieldError,
    providers: brainProviders,
    defaultProvider: brainDefaultProvider,
    providersError: brainProvidersError,
    loading: brainLoading,
    testing: brainTesting,
    secretStatus: brainSecretStatus,
    secretModalOpen: brainSecretModalOpen,
    secretIsUpdate: brainSecretIsUpdate,
    normalizedKey,
    secretStored,
    providerLabel,
    onPatch: handleBrainPatch,
    onStoreOpen: handleBrainStoreOpen,
    onStoreClose: handleBrainStoreClose,
    onStoreSuccess: handleBrainStoreSuccess,
    onTest: handleBrainTest,
    onNext: handleBrainNext,
    clearErrors,
  };
}
