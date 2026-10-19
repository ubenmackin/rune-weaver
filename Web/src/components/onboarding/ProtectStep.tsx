// Rune Weaver Dashboard — Onboarding protect step with optional acknowledgement.

export interface ProtectStepProps {
  policyAcked: boolean;
  onPolicyAckedChange?: (acked: boolean) => void;
  onFinish: () => void | Promise<void>;
  finishing?: boolean;
}

export default function ProtectStep({
  policyAcked,
  onPolicyAckedChange,
  onFinish,
  finishing = false,
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

      <ul className="protect-bullets">
        <li>Reads freely, writes ask first</li>
        <li>Allowlist-only network</li>
        <li>Secrets never in prompts</li>
      </ul>

      <p className="protect-settings-line">
        <a className="btn-link" href="#settings/access">
          Settings Access
        </a>
      </p>

      {typeof onPolicyAckedChange === "function" ? (
        <label className="protect-ack-row">
          <input
            type="checkbox"
            checked={policyAcked}
            onChange={(event) => onPolicyAckedChange(event.target.checked)}
            aria-label="I understand writes need approval"
            disabled={finishing}
          />
          <span>I understand writes need approval</span>
        </label>
      ) : (
        <p className="protect-ack-row" data-testid="protect-ack-status">
          <span>{policyAcked ? "Policy verified" : "Policy review pending"}</span>
        </p>
      )}

      <div className="protect-actions">
        <button
          type="button"
          className="btn btn-primary protect-finish-btn"
          onClick={() => void onFinish()}
          disabled={finishing}
        >
          {finishing ? "Finishing…" : "Finish"}
        </button>
      </div>
    </section>
  );
}
