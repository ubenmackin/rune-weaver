// Rune Weaver Dashboard — Onboarding wizard shell with gating, skip persistence, and resume.
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchJson } from "../../api/http";
import {
  sanitizeSkippedSteps,
  skipOnboardingStep,
  type OnboardingStatus as ApiOnboardingStatus,
} from "../../api/onboarding";
import { useOnboardingStatus as useSharedOnboardingStatus } from "../../hooks/useOnboardingStatus";
import { WIZARD_STEPS, nextStep, type WizardStepId } from "./wizardState";
import BrainStep from "./BrainStep";
import PersonaStep, { type PersonaStepValue } from "./PersonaStep";
import ConnectStep from "./ConnectStep";
import ProtectStep from "./ProtectStep";
import { StoreSecretModal } from "../StoreSecretModal";
import {
  finishOnboardingWithVerifiedSeed,
  parseOnboardingStatus as parseSeedStatus,
  type OnboardingStatus as SeedStatus,
} from "./seedPrompt";
import {
  firstPendingStep,
  readStandaloneMode,
  toSeedStatus,
} from "./wizardHelpers";
import { useBrainWizard } from "./useBrainWizard";
import {
  AllSkippedFooter,
  BrainWizardFooter,
  WizardStepFooter,
} from "./wizardFooters";

export interface GettingStartedWizardProps {
  initialSkippedSteps?: WizardStepId[];
  isStandalone?: boolean;
  onFinished?: () => void;
  onboardingStatus?: ApiOnboardingStatus | null;
  onOnboardingRefresh?: () => Promise<void>;
  onOnboardingComplete?: (seedPromptUsed: string) => Promise<void>;
  onOnboardingSkip?: (step: WizardStepId) => Promise<void>;
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
  const [personaValue, setPersonaValue] = useState<PersonaStepValue | null>(null);
  const [internalSeedStatus, setInternalSeedStatus] = useState<SeedStatus | null>(null);
  const [seedLoading, setSeedLoading] = useState(false);
  const [seedError, setSeedError] = useState<string | null>(null);

  // Wizard-owned brain draft plus connection, save, and Keychain state.
  const brain = useBrainWizard({ standalone, hydrated, setStepError, setError });

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

  // Server-derived ack; no local checkbox persists across the gate.
  const seedStatus: SeedStatus | null = hasExternal
    ? toSeedStatus(onboardingStatus ?? null)
    : (internalSeedStatus ?? (shared.status ? toSeedStatus(shared.status) : null));
  const effectiveSeedLoading = hasExternal ? false : seedLoading;
  const effectiveSeedError = hasExternal ? null : seedError;

  // Inline banners are the single error source; each focuses on appearance.
  const wizardErrorRef = useRef<HTMLParagraphElement>(null);
  const wizardStepErrorRef = useRef<HTMLParagraphElement>(null);
  const wizardSeedErrorRef = useRef<HTMLParagraphElement>(null);

  useEffect(() => {
    if (error) {
      wizardErrorRef.current?.scrollIntoView({ block: "nearest" });
      wizardErrorRef.current?.focus({ preventScroll: true });
    }
  }, [error]);

  useEffect(() => {
    if (stepError) {
      wizardStepErrorRef.current?.scrollIntoView({ block: "nearest" });
      wizardStepErrorRef.current?.focus({ preventScroll: true });
    }
  }, [stepError, current]);

  useEffect(() => {
    if (effectiveSeedError) {
      wizardSeedErrorRef.current?.scrollIntoView({ block: "nearest" });
      wizardSeedErrorRef.current?.focus({ preventScroll: true });
    }
  }, [effectiveSeedError, current]);

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
        goal: personaValue?.goal ?? null,
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
          goal: personaValue?.goal ?? null,
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
          goal: personaValue?.goal ?? null,
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

  function handleBrainNext() {
    void brain.onNext({
      current,
      skipped,
      onAdvanced: (next) => {
        setHistory((prev) => [...prev, next]);
        setCurrent(next);
      },
      onFinished: handleFinish,
    });
  }

  // Inline step errors are the single source of truth.
  const inlineStepError = current !== "brain" ? stepError : null;
  const inlineSeedError = current !== "connect" ? effectiveSeedError : null;
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
            {error ? (
              <p
                ref={wizardErrorRef}
                tabIndex={-1}
                data-testid="wizard-error"
                role="alert"
                className="error-banner"
              >
                {error}
              </p>
            ) : null}
            {stepError ? (
              <p
                ref={wizardStepErrorRef}
                tabIndex={-1}
                data-testid="wizard-step-error"
                role="alert"
                className="error-banner"
              >
                {stepError}
              </p>
            ) : null}
            {effectiveSeedError ? (
              <p
                ref={wizardSeedErrorRef}
                tabIndex={-1}
                data-testid="wizard-seed-error"
                role="alert"
                className="error-banner"
              >
                {effectiveSeedError}
              </p>
            ) : null}
            <div className="wizard-step">
              <h4>Everything is deferred</h4>
              <p className="muted">Every step is skipped. Finish to close onboarding.</p>
            </div>
          </div>
          <AllSkippedFooter
            canBack={history.length > 1}
            busy={busy}
            onBack={handleBack}
            onFinish={() => void handleFinish()}
          />
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
          {error ? (
            <p
              ref={wizardErrorRef}
              tabIndex={-1}
              data-testid="wizard-error"
              role="alert"
              className="error-banner"
            >
              {error}
            </p>
          ) : null}
          {inlineStepError ? (
            <p
              ref={wizardStepErrorRef}
              tabIndex={-1}
              data-testid="wizard-step-error"
              role="alert"
              className="error-banner"
            >
              {inlineStepError}
            </p>
          ) : null}
          {inlineSeedError ? (
            <p
              ref={wizardSeedErrorRef}
              tabIndex={-1}
              data-testid="wizard-seed-error"
              role="alert"
              className="error-banner"
            >
              {inlineSeedError}
            </p>
          ) : null}
          {current === "brain" ? (
            <>
              {brain.loading ? (
                <p className="muted" data-testid="brain-loading">
                  Loading providers…
                </p>
              ) : null}
              <BrainStep
                value={brain.draft}
                onChange={brain.onPatch}
                testStatus={brain.testStatus}
                testDetail={brain.testDetail}
                secretStored={brain.secretStored}
                onStoreKey={brain.onStoreOpen}
                fieldError={brain.fieldError}
              />
              <StoreSecretModal
                isOpen={brain.secretModalOpen}
                secretKey={brain.normalizedKey}
                title={
                  brain.secretIsUpdate
                    ? `Update API Key for ${brain.providerLabel} in Keychain`
                    : `Store API Key for ${brain.providerLabel} to Keychain`
                }
                isUpdate={brain.secretIsUpdate}
                onClose={brain.onStoreClose}
                onSuccess={brain.onStoreSuccess}
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
              goal={personaValue?.goal ?? null}
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

        {current === "brain" ? (
          <BrainWizardFooter
            canBack={history.length > 1}
            busy={busy}
            testing={brain.testing}
            saving={brain.saving}
            loading={brain.loading}
            hasProvidersError={!!brain.providersError}
            onBack={handleBack}
            onTest={() => void brain.onTest()}
            onNext={handleBrainNext}
            onSkip={() => void handleSkip()}
          />
        ) : (
          <WizardStepFooter
            showBack={showWizardBack}
            showNext={showWizardNext}
            busy={busy}
            onBack={handleBack}
            onSkip={() => void handleSkip()}
            onNext={handleNext}
          />
        )}
      </div>
    </div>
  );
}
