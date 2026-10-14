// Rune Weaver Dashboard — Access deep-link reader for the access pane.
//
// Purpose: Reads the `access` hash-query parameter so a link from the
// approvals inbox (its "Manage standing rules" link) or any external source can
// preselect and highlight one standing rule in the access pane. It mirrors the
// memory browser's hash reader by looking in both the location hash and the
// query string, so the deep link resolve works whether it rides the settings
// hash (for example `#settings?access=<id>`) or a bare query (`?access=<id>`).
// Scope: Parsing the deep link only. Which rule is highlighted on the page,
// which section is selected, and the rule data itself stay with their owners;
// this file answers one question — which rule id a link names — plus the raw
// `access` value behind it, so the settings shell can detect a bare section
// link without re-running the URLSearchParams loop itself.
// Architectural role: the single reader of the access deep link, so the pane
// shell and the Rules section agree on the targeted rule instead of each
// re-parsing the URL and drifting on the query spelling.

// Value that opens the Rules section without naming a specific rule, matching
// what the approvals inbox link sends. The Rules section is the pane's landing
// section, so this token selects nothing to highlight.
export const ACCESS_RULES_SECTION_TOKEN = "rules";

// Extracts the `access` query value from a location string that may carry its
// query on the hash, on the search, or on both. Returns the first value found,
// or null when neither carries the parameter. URLSearchParams decodes
// percent-encoding so an encoded rule id resolves to its real spelling. This
// is the single owner of the raw `access` extraction across hash and search;
// callers that only need the targeted rule id should use readAccessDeepLink.
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

// Resolves the rule id a deep link asks to preselect and highlight, or null
// when no link targets a specific rule. The bare section token opens the Rules
// section without a highlight; any other non-blank value names the rule to
// highlight. Case is preserved so a case-sensitive rule id round-trips.
export function readAccessDeepLink(): string | null {
  const value = readAccessParamValue()?.trim();
  if (!value) return null;
  if (value === ACCESS_RULES_SECTION_TOKEN) return null;
  return value;
}
