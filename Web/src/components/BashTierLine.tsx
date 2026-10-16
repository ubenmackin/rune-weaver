// Rune Weaver Dashboard — Verbatim bash sandbox tier line for approval cards.

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
