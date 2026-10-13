// Rune Weaver Dashboard — Access settings pane shell.
//
// Purpose: Hosts the owner "what the agent is allowed to do" surface as a left
// section rail over the standing-rules, shell, network, credentials, and files
// editors. Rules is the landing section, and each section mounts only when
// selected so the pane never renders five surfaces at once. The rail keeps its
// selection across a section's own save so an owner mid-edit is not bounced
// back to Rules by a refetch.
// Scope: Section navigation plus lazily mounting the selected section, and
// translating an access deep link into a preselected, highlighted rule. Each
// mounted section owns its own data and its own save, so the shell navigates
// and highlights only and never second-guesses a section's state.
// Architectural role: the container the approvals inbox links to via
// `#settings?access=rules` and via a per-rule deep link; it mirrors the memory
// browser's hash-driven selection instead of introducing a router, and its
// rail folds into the grouped settings navigation.

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

export interface AccessPaneProps {
  // Section to open first. Defaults to Rules, the landing section; a deep link
  // that names a rule also lands on Rules so the highlight has a table to mark.
  initialSection?: AccessSectionKey;
}

export default function AccessPane({ initialSection = "rules" }: AccessPaneProps = {}) {
  const [section, setSection] = useState<AccessSectionKey>(initialSection);
  // Rule id a deep link asks to preselect and highlight, or null. Rules is the
  // only section a deep link targets, so the id only ever marks a Rules row.
  const [highlightRuleId, setHighlightRuleId] = useState<string | null>(() =>
    readAccessDeepLink(),
  );

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

  const activeEntry = ACCESS_SECTIONS.find((entry) => entry.key === section);

  // Lazily renders exactly the selected section. Rules receives the highlight;
  // the policy surface below owns both network and credentials behind its own
  // sub-tabs, so the Network and Credentials rail entries both mount it.
  const renderSection = useCallback(() => {
    switch (section) {
      case "rules":
        return <AccessRulesSection highlightRuleId={highlightRuleId} />;
      case "bash":
        return <AccessBashSection />;
      case "network":
      case "credentials":
        return <AccessNetworkSection />;
      case "files":
        return <AccessFilesSection />;
      default:
        return null;
    }
  }, [section, highlightRuleId]);

  return (
    <div className="access-pane" data-testid="access-pane">
      <nav className="access-rail" aria-label="Access sections">
        <ul className="access-rail-list">
          {ACCESS_SECTIONS.map((entry) => (
            <li key={entry.key}>
              <button
                type="button"
                className={`access-rail-item${section === entry.key ? " active" : ""}`}
                aria-current={section === entry.key ? "page" : undefined}
                data-testid={`access-rail-${entry.key}`}
                onClick={() => setSection(entry.key)}
              >
                {entry.label}
              </button>
            </li>
          ))}
        </ul>
      </nav>
      <div className="access-pane-body" role="region" aria-label={activeEntry?.label}>
        {renderSection()}
      </div>
    </div>
  );
}
