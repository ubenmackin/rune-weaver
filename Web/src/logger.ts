// Rune Weaver Dashboard — Centralized diagnostic logger for renderer warnings.

export function logWarn(message: string, ...args: unknown[]): void {
  // The build mode gates output so the shipped bundle never writes to the
  // console in production; development and test keep the report loud.
  if (import.meta.env?.MODE === "production") return;
  console.warn(message, ...args);
}
