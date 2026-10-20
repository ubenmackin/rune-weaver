// Rune Weaver Dashboard — Wizard footer error mirror.
export function WizardFooterError({ text }: { text: string }) {
  return (
    <span
      data-testid="wizard-footer-error"
      role={text ? "alert" : undefined}
      aria-hidden={text ? undefined : true}
      className="wizard-footer-error"
    >
      {text}
    </span>
  );
}

export default WizardFooterError;
