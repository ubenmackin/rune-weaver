// Rune Weaver Dashboard — main application shell and section navigation.
// Keeps chat mounted across tabs so in-flight turns and session state survive navigation, with a full-width sticky nav keeping health and notification badges visible.

import { useEffect, useState } from "react";
import { getHealth, type HealthResponse } from "./api";
import ApprovalsInbox from "./components/ApprovalsInbox";
import ChatView from "./components/ChatView";
import MemoryBrowser from "./components/MemoryBrowser";
import RunLogViewer from "./components/RunLogViewer";
import SchedulerManager from "./components/SchedulerManager";
import SettingsManager from "./components/SettingsManager";
import TopNav, { type Tab } from "./components/TopNav";
import { useWebNotifications } from "./hooks/useWebNotifications";

const VALID_TABS: Tab[] = ["chat", "approvals", "memory", "runs", "schedules", "settings"];

function getInitialTab(): Tab {
  if (typeof window === "undefined") return "chat";
  const hash = window.location.hash.replace("#", "").toLowerCase() as Tab;
  if (VALID_TABS.includes(hash)) return hash;
  const path = window.location.pathname.replace(/^\//, "").toLowerCase() as Tab;
  if (VALID_TABS.includes(path)) return path;
  return "chat";
}

export default function App() {
  const [tab, setTab] = useState<Tab>(getInitialTab);
  const [health, setHealth] = useState<HealthResponse | null>(null);

  const {
    notificationsEnabled,
    requestPermission,
    runsBadge,
    clearRunsBadge,
    approvalsBadge,
    clearApprovalsBadge,
  } = useWebNotifications();

  useEffect(() => {
    function handleHashChange() {
      const current = window.location.hash.replace("#", "").toLowerCase() as Tab;
      if (VALID_TABS.includes(current)) {
        setTab((previous) => (previous === current ? previous : current));
      }
    }
    window.addEventListener("hashchange", handleHashChange);
    return () => window.removeEventListener("hashchange", handleHashChange);
  }, []);

  useEffect(() => {
    let cancelled = false;
    getHealth()
      .then((response) => {
        if (!cancelled) setHealth(response);
      })
      .catch(() => {
        if (!cancelled) setHealth(null);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function handleSelectTab(selected: Tab) {
    setTab((previous) => (previous === selected ? previous : selected));
    // Writing the hash fires `hashchange`, which would set the same tab a
    // second time; guard the write so selecting the active tab (or an
    // already-synced hash) never triggers the redundant second update.
    if (typeof window !== "undefined" && window.location.hash !== `#${selected}`) {
      window.location.hash = selected;
    }
    if (selected === "runs") clearRunsBadge();
    if (selected === "approvals") clearApprovalsBadge();
  }

  return (
    <div className="app-root">
      {/* 100% Full-width sticky Top Navigation */}
      <TopNav
        currentTab={tab}
        onSelectTab={handleSelectTab}
        health={health}
        runsBadge={runsBadge}
        approvalsBadge={approvalsBadge}
        notificationsEnabled={notificationsEnabled}
        onRequestNotifications={requestPermission}
      />

      {/* Main Content Area */}
      <main className="app-main-content">
        <div className="app-container">
          {/* Chat tab is kept mounted so ongoing conversation and session state are preserved across navigation */}
          <div
            className="tab-panel-wrapper"
            style={{ display: tab === "chat" ? "block" : "none", height: tab === "chat" ? "100%" : undefined }}
            aria-hidden={tab !== "chat"}
          >
            <ChatView health={health} />
          </div>

          {tab === "approvals" ? <ApprovalsInbox /> : null}
          {tab === "memory" ? <MemoryBrowser /> : null}
          {tab === "runs" ? <RunLogViewer /> : null}
          {tab === "schedules" ? <SchedulerManager /> : null}
          {tab === "settings" ? <SettingsManager /> : null}
        </div>
      </main>
    </div>
  );
}
