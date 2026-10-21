// Rune Weaver Dashboard — Onboarding wizard footer shells.
import type { ReactNode } from "react";

// Shared shell keeps the modal footer layout in one place.
export function WizardFooterShell({
  left,
  children,
}: {
  left: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="modal-footer wizard-footer">
      <div className="wizard-footer-left">{left ?? <span />}</div>
      <div className="wizard-footer-right">
        {children}
      </div>
    </div>
  );
}

export interface BrainWizardFooterProps {
  canBack: boolean;
  busy: boolean;
  testing: boolean;
  saving: boolean;
  loading: boolean;
  hasProvidersError: boolean;
  onBack: () => void;
  onTest: () => void;
  onNext: () => void;
  onSkip: () => void;
}

// Single footer owner stays the wizard shell; this only groups the
// Back plus Test plus Next buttons behind one call site.
export function BrainWizardFooter({
  canBack,
  busy,
  testing,
  saving,
  loading,
  hasProvidersError,
  onBack,
  onTest,
  onNext,
  onSkip,
}: BrainWizardFooterProps) {
  const nextBusy = testing || saving || loading || busy;
  return (
    <WizardFooterShell
      left={
        canBack ? (
          <button
            type="button"
            className="ghost"
            data-testid="brain-back"
            onClick={onBack}
            disabled={nextBusy}
          >
            Back
          </button>
        ) : (
          <span />
        )
      }
    >
      <button
        type="button"
        className="ghost"
        data-testid="brain-test-connection"
        disabled={testing || saving || loading || busy || hasProvidersError}
        onClick={onTest}
      >
        {testing ? "Testing…" : "Test connection"}
      </button>
      <button
        type="button"
        className="primary"
        data-testid="brain-next"
        disabled={nextBusy || hasProvidersError}
        onClick={onNext}
      >
        {saving ? "Saving…" : testing ? "Testing…" : loading ? "Loading…" : "Next"}
      </button>
      <button type="button" className="ghost" onClick={onSkip} disabled={nextBusy}>
        Skip for now
      </button>
    </WizardFooterShell>
  );
}

export interface WizardStepFooterProps {
  showBack: boolean;
  showNext: boolean;
  busy: boolean;
  onBack: () => void;
  onSkip: () => void;
  onNext: () => void;
}

// Non-brain steps share one footer so Back plus Skip plus Next stay together.
export function WizardStepFooter({
  showBack,
  showNext,
  busy,
  onBack,
  onSkip,
  onNext,
}: WizardStepFooterProps) {
  return (
    <WizardFooterShell
      left={
        showBack ? (
          <button type="button" className="ghost" onClick={onBack} disabled={busy}>
            Back
          </button>
        ) : (
          <span />
        )
      }
    >
      <button type="button" className="ghost" onClick={onSkip} disabled={busy}>
        Skip for now
      </button>
      {showNext ? (
        <button type="button" className="primary" onClick={onNext} disabled={busy}>
          Next
        </button>
      ) : null}
    </WizardFooterShell>
  );
}

export interface AllSkippedFooterProps {
  canBack: boolean;
  busy: boolean;
  onBack: () => void;
  onFinish: () => void;
}

// Deferred-everything path keeps explicit Finish instead of unmounting.
export function AllSkippedFooter({
  canBack,
  busy,
  onBack,
  onFinish,
}: AllSkippedFooterProps) {
  return (
    <WizardFooterShell
      left={
        canBack ? (
          <button type="button" className="ghost" onClick={onBack} disabled={busy}>
            Back
          </button>
        ) : (
          <span />
        )
      }
    >
      <button type="button" className="primary" onClick={onFinish} disabled={busy}>
        Finish
      </button>
    </WizardFooterShell>
  );
}
