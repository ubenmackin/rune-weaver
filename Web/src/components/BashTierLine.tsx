// Rune Weaver Dashboard — Verbatim bash sandbox tier line for approval cards.
//
// Purpose: render the server-stamped sandbox summary verbatim beneath Expected outcome with no recomputation.
// Scope: falsy summaries render nothing with no layout gap; truthy summaries render one tier div verbatim.
// Architectural role: presentational leaf owned by the inline approval banner, reading stamped bytes only.

export function BashTierLine({
  summary,
}: {
  summary: string | null | undefined;
}) {
  if (!summary) return null;
  return (
    <div className="approval-narrative approval-tier" data-testid="bash-tier-line">
      {summary}
    </div>
  );
}

export default BashTierLine;
