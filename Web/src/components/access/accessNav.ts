// Rune Weaver Dashboard — Access deep-link reader for the access pane.

export const ACCESS_RULES_SECTION_TOKEN = "rules";

// Extracts the `access` query value from a location string that may carry its query on the hash, on
// the search, or on both. Returns the first value found, or null when neither carries the parameter.
export function readAccessParamValue(): string | null {
  if (typeof window === "undefined") return null;
  const sources = [window.location.hash, window.location.search];
  for (const source of sources) {
    const queryStart = source.indexOf("?");
    if (queryStart === -1) continue;
    const params = new URLSearchParams(source.slice(queryStart + 1));
    const value = params.get("access");
    if (value !== null) return value;
  }
  return null;
}

// Resolves the rule id a deep link asks to preselect and highlight, or null when no link targets a
// specific rule.
export function readAccessDeepLink(): string | null {
  const value = readAccessParamValue()?.trim();
  if (!value) return null;
  if (value === ACCESS_RULES_SECTION_TOKEN) return null;
  return value;
}
