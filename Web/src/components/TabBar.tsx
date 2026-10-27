// Rune Weaver Dashboard — canonical tab bar surface shared by dashboard tab bars.

export interface TabBarEntry {
  key: string;
  label: string;
  count: number | null;
  testId?: string;
}

export interface TabBarProps {
  tabs: TabBarEntry[];
  activeKey: string;
  onSelect: (key: string) => void;
  ariaLabel: string;
  idPrefix: string;
  testIdPrefix?: string;
  // Per-tab panels derive ids from this prefix; a shared single panel names
  // panelId once so every tab controls the same node (panelId wins when set).
  panelIdPrefix?: string;
  panelId?: string;
}

export function TabBar({
  tabs,
  activeKey,
  onSelect,
  ariaLabel,
  idPrefix,
  testIdPrefix,
  panelIdPrefix = "panel",
  panelId,
}: TabBarProps) {
  // Unknown keys fall back to the first tab so selection never renders empty.
  const resolvedActiveKey = tabs.some((tab) => tab.key === activeKey)
    ? activeKey
    : (tabs[0]?.key ?? activeKey);

  return (
    <div className="tab-bar" role="tablist" aria-label={ariaLabel}>
      {tabs.map((tab) => {
        const id = `${idPrefix}-${tab.key}`;
        const isActive = tab.key === resolvedActiveKey;
        return (
          <button
            key={tab.key}
            type="button"
            className={isActive ? "tab-bar-tab active" : "tab-bar-tab"}
            role="tab"
            aria-selected={isActive}
            aria-controls={panelId ?? `${panelIdPrefix}-${tab.key}`}
            id={id}
            data-testid={tab.testId ?? (testIdPrefix ? `${testIdPrefix}-${tab.key}` : id)}
            onClick={() => onSelect(tab.key)}
          >
            {typeof tab.count === "number" ? `${tab.label} (${tab.count})` : tab.label}
          </button>
        );
      })}
    </div>
  );
}

export default TabBar;
