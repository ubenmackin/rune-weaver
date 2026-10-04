// Rune Weaver Dashboard — Executive Control Center & Mission Overview.
//
// Transforms RuneWeaver from a passive chat bot into an autonomous executive
// assistant. Shows the operator:
// 1. What needs your action (approvals, blocked goals)?
// 2. What we should focus on today (proactive ideas radar)?
// 3. What is working right now (live task trees & tools in flight)?
// 4. Goals momentum & step progress with 1-click advance?
// 5. Upcoming schedule cadence and recent executive report cards?

import { useState } from "react";
import type { HealthResponse, RunLogEntry } from "../api";
import type { Tab } from "./TopNav";
import DashboardPromptBar from "./dashboard/DashboardPromptBar";
import MorningRecommendations from "./dashboard/MorningRecommendations";
import NeedsActionQueue from "./dashboard/NeedsActionQueue";
import WorkingNowStream from "./dashboard/WorkingNowStream";
import GoalsCockpit from "./dashboard/GoalsCockpit";
import UpcomingSchedules from "./dashboard/UpcomingSchedules";
import RecentReports from "./dashboard/RecentReports";
import SystemPulseCard from "./dashboard/SystemPulseCard";
import RunDetailModal from "./RunDetailModal";

export interface DashboardViewProps {
  health: HealthResponse | null;
  stagedFilesCount?: number;
  onOpenStagedDrawer?: () => void;
  onSelectTab: (tab: Tab) => void;
  onOpenChatWithPrompt?: (prompt: string) => void;
  onOpenSession?: (sessionId: string) => void;
}

function getGreeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

export default function DashboardView({
  health,
  stagedFilesCount = 0,
  onOpenStagedDrawer,
  onSelectTab,
  onOpenChatWithPrompt,
  onOpenSession,
}: DashboardViewProps) {
  const [inspectedRun, setInspectedRun] = useState<RunLogEntry | null>(null);
  const [goalsRefreshTrigger, setGoalsRefreshTrigger] = useState(0);
  const greeting = getGreeting();

  function handlePromptSubmit(prompt: string) {
    if (onOpenChatWithPrompt) {
      onOpenChatWithPrompt(prompt);
    } else {
      onSelectTab("chat");
    }
  }

  function handleOpenSession(sessionId: string) {
    if (onOpenSession) {
      onOpenSession(sessionId);
    } else {
      localStorage.setItem("rw_active_session_id", sessionId);
      onSelectTab("chat");
    }
  }

  return (
    <div className="dashboard-root" role="region" aria-label="Executive Operations Dashboard">
      {/* Executive Welcome & Command Bar */}
      <header className="dashboard-hero-header">
        <div className="dashboard-greeting-row">
          <div className="dashboard-greeting-text">
            <h1 className="dashboard-greeting-title">{greeting}, Operator</h1>
            <p className="dashboard-greeting-subtitle">
              Here is your daily operations overview, proactive radar, and autonomous work progress.
            </p>
          </div>
        </div>

        <DashboardPromptBar onSubmitPrompt={handlePromptSubmit} />
      </header>

      {/* Proactive Radar (Morning Recommendations Banner) */}
      <MorningRecommendations
        onOpenChatWithIdea={(prompt) => handlePromptSubmit(prompt)}
        onIdeaAccepted={() => setGoalsRefreshTrigger((k) => k + 1)}
      />

      {/* Responsive Workstream & Cockpit Grid */}
      <div className="dashboard-main-grid">
        {/* Left Column: Primary Workstream (Approvals, Working Now, Recent Reports) */}
        <div className="dashboard-stream-column">
          <NeedsActionQueue
            onOpenSession={handleOpenSession}
            onOpenGoals={() => onSelectTab("goals")}
          />

          <WorkingNowStream
            onOpenSession={handleOpenSession}
          />

          <RecentReports
            onOpenRuns={() => onSelectTab("runs")}
            onInspectRun={(run) => setInspectedRun(run)}
            onOpenSession={handleOpenSession}
          />
        </div>

        {/* Right Column: Side Cockpit (Telemetry, Goals Momentum, Upcoming Schedules) */}
        <div className="dashboard-cockpit-column">
          <SystemPulseCard
            health={health}
            stagedFilesCount={stagedFilesCount}
            onOpenStagedDrawer={onOpenStagedDrawer}
            onOpenSettings={() => onSelectTab("settings")}
          />

          <GoalsCockpit
            refreshTrigger={goalsRefreshTrigger}
            onOpenGoals={() => onSelectTab("goals")}
            onOpenGoalDetail={() => onSelectTab("goals")}
          />

          <UpcomingSchedules
            onOpenSchedules={() => onSelectTab("schedules")}
          />
        </div>
      </div>

      {/* Run Inspection Modal */}
      {inspectedRun && (
        <RunDetailModal
          run={inspectedRun}
          onClose={() => setInspectedRun(null)}
        />
      )}
    </div>
  );
}
