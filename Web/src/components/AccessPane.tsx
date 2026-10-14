// Rune Weaver Dashboard — Access settings pane shell.
//
// Purpose: Hosts the owner "what the agent is allowed to do" surface as a
// full-width underline tab bar over the standing-rules, shell, network,
// credentials, and files editors. Rules is the landing section, and each
// section mounts only when selected so the pane never renders five surfaces at
// once. The bar keeps its selection across a section's own save so an owner
// mid-edit is not bounced back to Rules by a refetch.
// Scope: Section navigation plus lazily mounting the selected section, and
// translating an access deep link into a preselected, highlighted rule. The
// hash itself is read by accessNav's readAccessDeepLink, so this shell follows
// that reader's verdict and never re-parses the query spelling. Each mounted
// section owns its own data and its own save, so the shell navigates and
// highlights only and never second-guesses a section's state.
// Architectural role: the container the approvals inbox links to via
// `#settings?access=rules` and via a per-rule deep link; it mirrors the memory
// browser's hash-driven selection instead of introducing a router, and its
// underline tab bar folds into the grouped settings navigation.

import { useCallback, useEffect, useState } from "react";
import { AccessBashSection } from "./access/AccessBashSection";
import { AccessFilesSection } from "./access/AccessFilesSection";
import { AccessNetworkSection } from "./access/AccessNetworkSection";
import { AccessRulesSection } from "./access/AccessRulesSection";
import { readAccessDeepLink } from "./access/accessNav";

type AccessSectionKey = "rules" | "bash" | "network" | "credentials" | "files";

interface AccessSectionEntry {
  key: AccessSectionKey;
  label: string;
}

// The rail order is fixed; Rules leads because it is the landing section and
// the target of the approvals-inbox deep link.
const ACCESS_SECTIONS: AccessSectionEntry[] = [
  { key: "rules", label: "Rules" },
  { key: "bash", label: "Bash & Shell" },
  { key: "network", label: "Network" },
  { key: "credentials", label: "Credentials" },
  { key: "files", label: "Files" },
];

// One tabpanel rides every tab, because only the selected section mounts. The
// shared id keeps the tab-to-panel wiring valid while the pane swaps bodies.
const ACCESS_PANEL_ID = "access-panel";

export interface AccessPaneProps {
  // Section to open first. Defaults to Rules, the landing section; a deep link
  // that names a rule also lands on Rules so the highlight has a table to mark.
  initialSection?: AccessSectionKey;
}

// Fail-closed section guard: an unknown id never blanks the pane.
function isAccessSectionKey(value: unknown): value is AccessSectionKey {
  return (
    value === "rules" ||
    value === "bash" ||
    value === "network" ||
    value === "credentials" ||
    value === "files"
  );
}

export default function AccessPane({ initialSection = "rules" }: AccessPaneProps = {}) {
  // One read of the deep link feeds both states below, so the highlight and
  // the landing section can never derive from two different reads of the URL.
  const [deepLinkRuleId] = useState<string | null>(readAccessDeepLink);
  // Rule id a deep link asks to preselect and highlight, or null. Rules is the
  // only section a deep link targets, so the id only ever marks a Rules row.
  const [highlightRuleId, setHighlightRuleId] = useState<string | null>(deepLinkRuleId);
  const [section, setSection] = useState<AccessSectionKey>(() => {
    // A named-rule link lands on Rules even when the caller asked for another
    // section, so the highlight always has a table to mark.
    if (deepLinkRuleId) return "rules";
    return isAccessSectionKey(initialSection) ? initialSection : "rules";
  });

  // Follows deep links that arrive while the pane is open, mirroring the memory
  // browser's hash/popstate sync. A link that names a rule re-lands on Rules
  // and marks that rule; a bare token clears the highlight without moving.
  useEffect(() => {
    function syncFromUrl() {
      const ruleId = readAccessDeepLink();
      setHighlightRuleId(ruleId);
      if (ruleId) setSection("rules");
    }
    window.addEventListener("hashchange", syncFromUrl);
    window.addEventListener("popstate", syncFromUrl);
    return () => {
      window.removeEventListener("hashchange", syncFromUrl);
      window.removeEventListener("popstate", syncFromUrl);
    };
  }, []);

  // Lazily renders exactly the selected section. Rules receives the highlight;
  // the policy surface below owns both network and credentials behind its own
  // sub-tabs, so the Network and Credentials rail entries both mount it.
  // `section` is narrowed by the fail-closed guard on entry, so the trailing
  // fallback is defensive only and still lands on Rules rather than blanking.
  const renderSection = useCallback(() => {
    switch (section) {
      case "rules":
        return <AccessRulesSection highlightRuleId={highlightRuleId} />;
      case "bash":
        return <AccessBashSection />;
      case "network":
        return <AccessNetworkSection activeView="network" />;
      case "credentials":
        return <AccessNetworkSection activeView="credentials" />;
      case "files":
        return <AccessFilesSection />;
      default:
        return <AccessRulesSection highlightRuleId={highlightRuleId} />;
    }
  }, [section, highlightRuleId]);

  return (
    <div className="access-pane" data-testid="access-pane">
      <div className="access-tabs" role="tablist" aria-label="Access views">
        {ACCESS_SECTIONS.map((entry) => (
          <button
            key={entry.key}
            id={`access-tab-${entry.key}`}
            type="button"
            role="tab"
            className={`access-tab${section === entry.key ? " active" : ""}`}
            aria-selected={section === entry.key}
            aria-controls={ACCESS_PANEL_ID}
            data-testid={`access-tab-${entry.key}`}
            onClick={() => setSection(entry.key)}
          >
            <span>{entry.label}</span>
          </button>
        ))}
      </div>
      <div
        className="access-pane-body"
        id={ACCESS_PANEL_ID}
        role="tabpanel"
        aria-labelledby={`access-tab-${section}`}
      >
        {renderSection()}
      </div>
    </div>
  );
}
