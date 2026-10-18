// Rune Weaver Dashboard — Architectural file size and line count budget enforcement.
// Mirrors the SwiftLint limits: 1,000-line production sources and tests, 600-line components.

// @ts-expect-error node builtin without @types/node; test-only probe.
import { readdirSync, readFileSync, statSync } from "node:fs";
// @ts-expect-error node builtin without @types/node; test-only probe.
import { relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";

declare const process: { cwd: () => string };

const COMPONENT_LINE_BUDGET = 600;
const SOURCE_LINE_BUDGET = 1000;
const TEST_LINE_BUDGET = 1000;

// Maximum line counts permitted for legacy files that exceed standard budgets.
// Adding new entries here is discouraged; when refactoring existing files down,
// ratchet these numbers downward.
const LEGACY_LINE_RATCHET: Record<string, number> = {
  // Stylesheet
  "src/styles.css": 50,

  // Services & Models
  "src/api.ts": 50,

  // Components (target budget <= 600)
  "src/components/EventRuleBuilder.tsx": 660,
  "src/components/access/AccessCredentialsSection.tsx": 675,
  "src/components/access/AccessBashSection.tsx": 765,
  "src/components/dashboard/NeedsActionQueue.tsx": 765,
  "src/components/SchedulerManager.tsx": 805,
  "src/components/RunLogViewer.tsx": 865,
  "src/components/TopNav.tsx": 945,
  "src/components/icons.tsx": 950,
  "src/components/ScheduleWizardModal.tsx": 970,
  "src/components/access/AccessFilesSection.tsx": 1005,
  "src/components/ToolActionRow.tsx": 1075,
  "src/components/SessionSidebar.tsx": 1075,
  "src/components/ApprovalsInbox.tsx": 1080,
  "src/components/GoalsManager.tsx": 1150,
  "src/components/PolicyBindingModal.tsx": 1155,
  "src/components/access/AccessRulesSection.tsx": 1175,
  "src/components/MemoryBrowser.tsx": 1565,
  "src/components/access/AccessNetworkSection.tsx": 1565,
  "src/components/IndexingPanel.tsx": 200,
  "src/components/ChatView.tsx": 260,
  "src/components/SettingsManager.tsx": 580,

  // Legacy Test Suites (target budget <= 1000)
  "src/components/DashboardView.test.tsx": 1095,
  "src/components/DiffCard.test.tsx": 1170,
  "src/components/TopNav.test.tsx": 1170,
  "src/components/ApprovalsInbox.test.tsx": 1585,
  "src/components/MemoryBrowser.test.tsx": 2175,
  "src/api.test.ts": 2350,
  "src/components/SettingsManager.test.tsx": 4790,
  "src/components/IndexingPanel.test.tsx": 4950,
  "src/components/ChatView.test.tsx": 5455,
};

function collectSourceFiles(dir: string, baseDir: string): string[] {
  const results: string[] = [];
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".") || entry === "node_modules" || entry === "dist") {
      continue;
    }
    const fullPath = resolve(dir, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      results.push(...collectSourceFiles(fullPath, baseDir));
    } else if (
      (entry.endsWith(".ts") || entry.endsWith(".tsx") || entry.endsWith(".css")) &&
      !entry.endsWith(".d.ts")
    ) {
      results.push(relative(baseDir, fullPath));
    }
  }
  return results;
}

function countLines(filePath: string): number {
  const content = readFileSync(filePath, "utf8");
  if (!content) return 0;
  return content.split("\n").length;
}

describe("Web source file line count budgets", () => {
  const srcRoot = resolve(process.cwd(), "src");
  const files = collectSourceFiles(srcRoot, process.cwd());

  it("discovers all source files under src/", () => {
    expect(files.length).toBeGreaterThan(40);
  });

  files.forEach((file) => {
    const isTest = file.endsWith(".test.ts") || file.endsWith(".test.tsx");
    const isComponent = file.startsWith("src/components/") && file.endsWith(".tsx") && !isTest;
    const isLegacy = file in LEGACY_LINE_RATCHET;

    const allowedBudget = isLegacy
      ? LEGACY_LINE_RATCHET[file]
      : isComponent
        ? COMPONENT_LINE_BUDGET
        : isTest
          ? TEST_LINE_BUDGET
          : SOURCE_LINE_BUDGET;

    it(`${file} is within line budget (budget: ${allowedBudget})`, () => {
      const fullPath = resolve(process.cwd(), file);
      const lines = countLines(fullPath);

      if (isLegacy) {
        expect(
          lines,
          `Legacy file ${file} has ${lines} lines, exceeding its ratchet limit of ${allowedBudget}. Do not expand legacy oversized files.`,
        ).toBeLessThanOrEqual(allowedBudget);
      } else {
        expect(
          lines,
          `File ${file} has ${lines} lines, exceeding the budget limit of ${allowedBudget}. Split large files into focused helpers or components.`,
        ).toBeLessThanOrEqual(allowedBudget);
      }
    });
  });
});
