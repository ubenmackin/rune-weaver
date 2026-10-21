// Rune Weaver Dashboard — Onboarding protect step with optional acknowledgement.
import { goToSettings } from "./wizardSnooze";

export interface ProtectStepProps {
  policyAcked: boolean;
  onPolicyAckedChange?: (acked: boolean) => void;
}

export default function ProtectStep({
  policyAcked,
  onPolicyAckedChange,
}: ProtectStepProps) {
  return (
    <section
      className="onboarding-step protect-step"
      aria-label="How protection works"
      data-testid="protect-step"
    >
      <div className="onboarding-step-header">
        <h2 className="onboarding-step-title">Protect</h2>
        <p className="onboarding-step-subtitle">
          What Rune Weaver may do on your behalf.
        </p>
      </div>

      <ul className="protect-bullets muted text-sm">
        <li>Reads freely, writes ask first</li>
        <li>Allowlist-only network</li>
        <li>Secrets never in prompts</li>
      </ul>

      <p className="protect-settings-line onboarding-actions">
        {/* Snooze first so the gate never flashes the modal over Settings. */}
        <a
          className="ghost"
          href="#settings/access"
          onClick={(event) => {
            event.preventDefault();
            goToSettings("access");
          }}
        >
          Settings Access
        </a>
      </p>

      {typeof onPolicyAckedChange === "function" ? (
        <label className="form-group protect-ack-row">
          <input
            type="checkbox"
            checked={policyAcked}
            onChange={(event) => onPolicyAckedChange(event.target.checked)}
            aria-label="I understand writes need approval"
          />
          <span>I understand writes need approval</span>
        </label>
      ) : (
        <p className="form-group protect-ack-row" data-testid="protect-ack-status">
          <span className={policyAcked ? "succeeded-pill" : undefined}>
            {policyAcked ? "Policy verified" : "Policy review pending"}
          </span>
        </p>
      )}
    </section>
  );
}
