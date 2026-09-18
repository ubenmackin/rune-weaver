// Rune Weaver Dashboard — Centralized diagnostic logger for renderer warnings.
// Single reporting path for unexpected session or flight states so production
// stays quiet while development keeps loud invariant reports; views report
// here instead of reaching for the console directly.

// Reports an unexpected renderer invariant without surfacing user copy: the
// production bundle stays quiet because these diagnostics aid debugging, not
// operator decisions, while development and test builds stay loud so lost
// turns and unowned frames surface during iteration.
export function logWarn(message: string, ...args: unknown[]): void {
  // The build mode gates output so the shipped bundle never writes to the
  // console in production; development and test keep the report loud.
  if (import.meta.env?.MODE === "production") return;
  console.warn(message, ...args);
}
