// Rune Weaver Dashboard — Onboarding wizard shell with gating, skip persistence, and resume.
import { useCallback, useEffect, useState } from "react";
import { fetchJson } from "../../api/http";
import type { ProviderConfigData } from "../../api";
import {
  sanitizeSkippedSteps,
  skipOnboardingStep,
  type OnboardingStatus as ApiOnboardingStatus,
} from "../../api/onboarding";
import { useOnboardingStatus as useSharedOnboardingStatus } from "../../hooks/useOnboardingStatus";
import { WIZARD_STEPS, isSkipped, nextStep, type WizardStepId } from "./wizardState";
import BrainStep, { resolveBrainProviderSave, type BrainSelection } from "./BrainStep";
import PersonaStep, { type PersonaStepValue } from "./PersonaStep";
import ConnectStep from "./ConnectStep";
import ProtectStep from "./ProtectStep";
import { WizardFooterError } from "./WizardFooterError";
import {
  finishOnboardingWithVerifiedSeed,
  parseOnboardingStatus as parseSeedStatus,
  type OnboardingStatus as SeedStatus,
} from "./seedPrompt";

export interface GettingStartedWizardProps {
  initialSkippedSteps?: WizardStepId[];
  isStandalone?: boolean;
  onFinished?: () => void;
  onboardingStatus?: ApiOnboardingStatus | null;
  onOnboardingRefresh?: () => Promise<void>;
  onOnboardingComplete?: (seedPromptUsed: string) => Promise<void>;
  onOnboardingSkip?: (step: WizardStepId) => Promise<void>;
}

// Footer mirror bound keeps the bar to one compact line, ellipsis inclusive.
export const WIZARD_FOOTER_ERROR_MAX_LENGTH = 140;

// Overlong messages cut within the bound with an ellipsis; empty stays empty
// so the footer reserves space without rendering text.
export function truncateWizardFooterError(value: string | null | undefined): string {
  if (typeof value !== "string" || value.length === 0) return "";
  if (value.length <= WIZARD_FOOTER_ERROR_MAX_LENGTH) return value;
  return `${value.slice(0, WIZARD_FOOTER_ERROR_MAX_LENGTH - 1)}…`;
}

// Server snapshot is the single ack source; the checkbox never persists.
function toSeedStatus(value: ApiOnboardingStatus | null): SeedStatus | null {
  if (!value) return null;
  return {
    completedAt: value.completedAt,
    skippedSteps: [...value.skippedSteps],
    checklistDismissed: value.checklistDismissed,
    seedPromptUsed: value.seedPromptUsed,
    calendarStatus: value.calendarStatus,
    emailAccounts: value.emailAccounts.map((account) => ({
      address: account.address,
      fetchSucceeded: account.fetchSucceeded,
    })),
    indexEnabled: value.indexEnabled,
    indexWatermark: value.indexWatermark,
    personaSet: value.personaSet,
    policyAcked: value.policyAcked,
    pendingPermission: false,
    calendarReady: value.calendarReady,
    emailReady: value.emailReady,
    indexReady: value.indexReady,
  };
}

function readStandaloneMode(): boolean {
  if (typeof window === "undefined") return false;
  try {
    const params = new URLSearchParams(window.location.search);
    if (params.get("standalone") === "true") return true;
  } catch {
    return false;
  }
  return window.location.hash.includes("standalone=true");
}

function firstPendingStep(skipped: WizardStepId[]): WizardStepId | null {
  for (const step of WIZARD_STEPS) {
    if (!isSkipped(step, skipped)) return step;
  }
  return null;
}

export default function GettingStartedWizard({
  initialSkippedSteps,
  isStandalone,
  onFinished,
  onboardingStatus,
  onOnboardingRefresh,
  onOnboardingComplete,
  onOnboardingSkip,
}: GettingStartedWizardProps) {
  const standalone = isStandalone ?? readStandaloneMode();
  // App-owned status is the single live source when injected; the shared
  // hook stays as the isolated fallback so tests still render alone.
  const hasExternal = onboardingStatus !== undefined;
  const shouldFetch = !hasExternal && initialSkippedSteps === undefined && !standalone;
  const shared = useSharedOnboardingStatus({ disabled: !shouldFetch });

  const [skipped, setSkipped] = useState<WizardStepId[]>(() => {
    if (onboardingStatus) return sanitizeSkippedSteps(onboardingStatus.skippedSteps);
    if (initialSkippedSteps === undefined) return [];
    return sanitizeSkippedSteps(initialSkippedSteps);
  });
  const [current, setCurrent] = useState<WizardStepId>(() => {
    if (onboardingStatus) return firstPendingStep(sanitizeSkippedSteps(onboardingStatus.skippedSteps)) ?? WIZARD_STEPS[0];
    if (initialSkippedSteps === undefined) return WIZARD_STEPS[0];
    return firstPendingStep(sanitizeSkippedSteps(initialSkippedSteps)) ?? WIZARD_STEPS[0];
  });
  const [history, setHistory] = useState<WizardStepId[]>(() => {
    if (onboardingStatus) return [firstPendingStep(sanitizeSkippedSteps(onboardingStatus.skippedSteps)) ?? WIZARD_STEPS[0]];
    if (initialSkippedSteps === undefined) return [WIZARD_STEPS[0]];
    return [firstPendingStep(sanitizeSkippedSteps(initialSkippedSteps)) ?? WIZARD_STEPS[0]];
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [stepError, setStepError] = useState<string | null>(null);
  const [hydrated, setHydrated] = useState(() => {
    if (onboardingStatus !== undefined) return onboardingStatus !== null;
    return initialSkippedSteps !== undefined;
  });
  const [brainSelection, setBrainSelection] = useState<BrainSelection | null>(null);
  const [brainProviders, setBrainProviders] = useState<
    Record<string, ProviderConfigData> | undefined
  >(undefined);
  const [brainDefaultProvider, setBrainDefaultProvider] = useState<string | undefined>(
    undefined,
  );
  const [brainProvidersError, setBrainProvidersError] = useState<string | null>(null);
  const [personaValue, setPersonaValue] = useState<PersonaStepValue | null>(null);
  const [internalSeedStatus, setInternalSeedStatus] = useState<SeedStatus | null>(null);
  const [seedLoading, setSeedLoading] = useState(false);
  const [seedError, setSeedError] = useState<string | null>(null);

  // Late server snapshot seeds the shell once so reload resumes at the first
  // incomplete step instead of restarting at the beginning.
  useEffect(() => {
    if (hydrated) return;
    if (hasExternal) {
      if (!onboardingStatus) return;
      const clean = sanitizeSkippedSteps(onboardingStatus.skippedSteps);
      const first = firstPendingStep(clean);
      setSkipped(clean);
      if (!first) {
        setHydrated(true);
        return;
      }
      setCurrent(first);
      setHistory([first]);
      setHydrated(true);
      return;
    }
    if (initialSkippedSteps !== undefined) return;
    if (shared.isLoading || !shared.status) return;
    const clean = sanitizeSkippedSteps(shared.status.skippedSteps);
    const first = firstPendingStep(clean);
    setSkipped(clean);
    if (!first) {
      setHydrated(true);
      return;
    }
    setCurrent(first);
    setHistory([first]);
    setHydrated(true);
  }, [hydrated, hasExternal, onboardingStatus, initialSkippedSteps, shared.isLoading, shared.status]);

  const reloadInternalSeed = useCallback(async () => {
    if (standalone) return;
    setSeedLoading(true);
    setSeedError(null);
    try {
      const raw = await fetchJson<unknown>("/onboarding/status");
      setInternalSeedStatus(parseSeedStatus(raw));
    } catch (err) {
      setSeedError(err instanceof Error ? err.message : "Failed to load status");
    } finally {
      setSeedLoading(false);
    }
  }, [standalone]);

  const reloadSeed = useCallback(async () => {
    if (standalone) return;
    // Single source: App refresh converges every surface at once.
    if (hasExternal) {
      try {
        await onOnboardingRefresh?.();
      } catch (err) {
        setSeedError(err instanceof Error ? err.message : "Failed to load status");
      }
      return;
    }
    await reloadInternalSeed();
  }, [standalone, hasExternal, onOnboardingRefresh, reloadInternalSeed]);

  useEffect(() => {
    if (standalone || hasExternal) return;
    if (initialSkippedSteps !== undefined) return;
    if (!hydrated) return;
    void reloadSeed();
  }, [standalone, hasExternal, initialSkippedSteps, hydrated, reloadSeed]);

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

  // Server-derived ack; no local checkbox persists across the gate.
  const seedStatus: SeedStatus | null = hasExternal
    ? toSeedStatus(onboardingStatus ?? null)
    : (internalSeedStatus ?? (shared.status ? toSeedStatus(shared.status) : null));
  const effectiveSeedLoading = hasExternal ? false : seedLoading;
  const effectiveSeedError = hasExternal ? null : seedError;

  if (standalone) return null;
  if (!hydrated) return null;
  if (!WIZARD_STEPS.includes(current)) return null;

  const allSkipped = firstPendingStep(skipped) === null && skipped.length >= WIZARD_STEPS.length;
  const index = WIZARD_STEPS.indexOf(current);
  const total = WIZARD_STEPS.length;

  function handleBack() {
    if (history.length <= 1) return;
    const nextHistory = history.slice(0, -1);
    setHistory(nextHistory);
    setCurrent(nextHistory[nextHistory.length - 1]);
    setStepError(null);
  }

  function handleBrainError(message: string | null) {
    setStepError(message);
  }

  function advanceFrom(step: WizardStepId, skippedAfter: WizardStepId[]) {
    const next = nextStep(step, skippedAfter);
    if (!next) {
      void handleFinish();
      return;
    }
    setStepError(null);
    setHistory((prev) => [...prev, next]);
    setCurrent(next);
  }

  function handleBrainNext(selection: BrainSelection) {
    setError(null);
    setStepError(null);
    setBrainSelection(selection);
    const resolved = resolveBrainProviderSave(selection, brainProviders);
    setBrainProviders(resolved.providers);
    setBrainDefaultProvider(resolved.defaultProvider);
    advanceFrom(current, skipped);
  }

  function handlePersonaNext(value: PersonaStepValue) {
    setError(null);
    setStepError(null);
    setPersonaValue(value);
    advanceFrom(current, skipped);
  }

  function handleNext() {
    setError(null);
    setStepError(null);
    advanceFrom(current, skipped);
  }

  async function handleFinish() {
    setError(null);
    setStepError(null);
    setBusy(true);
    try {
      // Single finish flow owns the verified seed plus demo and completion.
      await finishOnboardingWithVerifiedSeed({
        status: seedStatus,
        complete: onOnboardingComplete,
      });
      onFinished?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to finish onboarding");
    } finally {
      setBusy(false);
    }
  }

  async function handleSkip() {
    setError(null);
    setStepError(null);
    setBusy(true);
    try {
      if (onOnboardingSkip) await onOnboardingSkip(current);
      else await skipOnboardingStep(current);
      const updated = skipped.includes(current) ? skipped : [...skipped, current];
      setSkipped(updated);
      const next = nextStep(current, updated);
      if (next) {
        setHistory((prev) => [...prev, next]);
        setCurrent(next);
      } else {
        await finishOnboardingWithVerifiedSeed({
          status: seedStatus,
          complete: onOnboardingComplete,
        });
        onFinished?.();
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to skip this step");
    } finally {
      setBusy(false);
    }
  }

  async function handleSkipCalendarDetour() {
    setError(null);
    setStepError(null);
    setBusy(true);
    try {
      // Calendar detour always records connect skip so reload resumes past it.
      if (onOnboardingSkip) await onOnboardingSkip("connect");
      else await skipOnboardingStep("connect");
      const updated = skipped.includes("connect") ? skipped : [...skipped, "connect" as WizardStepId];
      setSkipped(updated);
      const next = nextStep("connect", updated);
      if (next) {
        setHistory((prev) => [...prev, next]);
        setCurrent(next);
      } else {
        await finishOnboardingWithVerifiedSeed({
          status: seedStatus,
          complete: onOnboardingComplete,
        });
        onFinished?.();
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to skip this step");
    } finally {
      setBusy(false);
    }
  }

  // Every step skipped leaves no pending content: offer explicit completion
  // instead of unmounting while the row is still incomplete.
  // Inline step errors stay source of truth; the footer only mirrors them.
  // Brain test failures arrive via onError into stepError, so the mirror covers them.
  const footerSource = error ?? stepError ?? brainProvidersError ?? effectiveSeedError ?? null;
  const footerErrorText = truncateWizardFooterError(footerSource);
  if (allSkipped) {
    return (
      <div className="modal-backdrop" role="dialog" aria-modal="true" aria-label="Getting started">
        <div className="modal-container wizard-modal" data-testid="getting-started-wizard">
          <div className="modal-header">
            <div>
              <h3>Getting started</h3>
              <span className="wizard-step-indicator" data-testid="wizard-progress">
                Step {total} of {total}: ready
              </span>
            </div>
          </div>
          <div className="wizard-progress-track">
            <div className="wizard-progress-bar" style={{ width: "100%" }} />
          </div>
          <div className="modal-body wizard-body">
            {error ? <div className="error-banner">{error}</div> : null}
            <div className="wizard-step">
              <h4>Everything is deferred</h4>
              <p className="muted">Every step is skipped. Finish to close onboarding.</p>
            </div>
          </div>
          <div className="modal-footer wizard-footer">
            <div className="wizard-footer-left">
              {history.length > 1 ? (
                <button type="button" className="ghost" onClick={handleBack} disabled={busy}>
                  Back
                </button>
              ) : (
                <span />
              )}
            </div>
            <div className="wizard-footer-right">
              <WizardFooterError text={footerErrorText} />
              <button
                type="button"
                className="primary"
                onClick={() => void handleFinish()}
                disabled={busy}
              >
                Finish
              </button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  const showWizardBack = (current === "connect" || current === "protect") && history.length > 1;
  const showWizardNext = current === "connect";

  return (
    <div className="modal-backdrop" role="dialog" aria-modal="true" aria-label="Getting started">
      <div className="modal-container wizard-modal" data-testid="getting-started-wizard">
        <div className="modal-header">
          <div>
            <h3>Getting started</h3>
            <span className="wizard-step-indicator" data-testid="wizard-progress">
              Step {index + 1} of {total}: {current}
            </span>
          </div>
        </div>

        <div className="wizard-progress-track">
          <div
            className="wizard-progress-bar"
            style={{ width: `${((index + 1) / total) * 100}%` }}
          />
        </div>

        <div className="modal-body wizard-body">
          {error ? <div className="error-banner">{error}</div> : null}
          {current === "brain" ? (
            <>
              {brainProviders === undefined && !brainProvidersError ? (
                <p className="muted" data-testid="brain-loading">
                  Loading providers…
                </p>
              ) : null}
              <BrainStep
                initialProviders={brainProviders}
                initialDefaultProvider={
                  brainDefaultProvider ?? brainSelection?.defaultProvider ?? ""
                }
                initialApiKeyEnv={brainSelection?.apiKeyEnv}
                isLoading={brainProviders === undefined && !brainProvidersError}
                loadError={brainProvidersError}
                onBack={history.length > 1 ? handleBack : undefined}
                onNext={handleBrainNext}
                onError={handleBrainError}
              />
            </>
          ) : null}
          {current === "persona" ? (
            <PersonaStep
              initialAssistantName={personaValue?.assistantName ?? ""}
              initialUserName={personaValue?.userName ?? ""}
              initialGoal={personaValue?.goal ?? ""}
              onBack={handleBack}
              onNext={handlePersonaNext}
            />
          ) : null}
          {current === "connect" ? (
            <ConnectStep
              status={seedStatus}
              loading={effectiveSeedLoading}
              error={effectiveSeedError}
              refresh={reloadSeed}
              onSkipCalendar={() => void handleSkipCalendarDetour()}
              skipping={busy}
            />
          ) : null}
          {current === "protect" ? (
            <ProtectStep
              policyAcked={seedStatus?.policyAcked ?? false}
              onFinish={() => void handleFinish()}
              finishing={busy}
            />
          ) : null}
        </div>

        <div className="modal-footer wizard-footer">
          <div className="wizard-footer-left">
            {showWizardBack ? (
              <button type="button" className="ghost" onClick={handleBack} disabled={busy}>
                Back
              </button>
            ) : (
              <span />
            )}
          </div>
          <div className="wizard-footer-right">
            <WizardFooterError text={footerErrorText} />
            <button
              type="button"
              className="ghost"
              onClick={() => void handleSkip()}
              disabled={busy}
            >
              Skip for now
            </button>
            {showWizardNext ? (
              <button type="button" className="primary" onClick={handleNext} disabled={busy}>
                Next
              </button>
            ) : null}
          </div>
        </div>
      </div>
    </div>
  );
}
