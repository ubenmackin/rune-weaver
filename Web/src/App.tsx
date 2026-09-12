// Rune Weaver Dashboard — main application shell and section navigation.

import { useEffect, useState } from "react";
import { getHealth, type HealthResponse } from "./api";
import ApprovalsInbox from "./components/ApprovalsInbox";
import ChatView from "./components/ChatView";
import MemoryBrowser from "./components/MemoryBrowser";
import RunLogViewer from "./components/RunLogViewer";
import SchedulerManager from "./components/SchedulerManager";

type Tab = "chat" | "approvals" | "memory" | "runs" | "schedules";

const tabs: Array<{ id: Tab; label: string }> = [
  { id: "chat", label: "Chat" },
  { id: "approvals", label: "Approvals" },
  { id: "memory", label: "Memory" },
  { id: "runs", label: "Runs" },
  { id: "schedules", label: "Schedules" },
];

export default function App() {
  const [tab, setTab] = useState<Tab>("chat");
  const [health, setHealth] = useState<HealthResponse | null>(null);

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

  return (
    <div className="app-shell">
      <header className="app-header">
        <h1>Rune Weaver</h1>
        <span className="health-badge">
          {health ? `${health.engine} · v${health.version}` : "connecting…"}
        </span>
      </header>
      <nav className="tab-bar" aria-label="Dashboard sections">
        {tabs.map((entry) => (
          <button
            key={entry.id}
            type="button"
            aria-selected={tab === entry.id}
            onClick={() => setTab(entry.id)}
          >
            {entry.label}
          </button>
        ))}
      </nav>
      {tab === "chat" ? <ChatView /> : null}
      {tab === "approvals" ? <ApprovalsInbox /> : null}
      {tab === "memory" ? <MemoryBrowser /> : null}
      {tab === "runs" ? <RunLogViewer /> : null}
      {tab === "schedules" ? <SchedulerManager /> : null}
    </div>
  );
}
