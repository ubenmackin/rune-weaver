// Managed browser Python provision stages stay in lockstep with the engine.
// Pins the dashboard stage copy to the engine provision wording so a rename on
// either side fails loudly instead of silently relabeling the Preparing line.

import { describe, expect, it } from "vitest";
import {
  BROWSER_PYTHON_STAGE_COPY,
  browserStageCopy,
  isBrowserLongStage,
} from "./SettingsManager";

describe("browser python stage copy", () => {
  it("mirrors the engine provision copy for every stage", () => {
    // Single source of truth lives beside the engine stages; this table must
    // match it exactly so health polls and boot lines name the same step.
    expect(BROWSER_PYTHON_STAGE_COPY).toEqual({
      resolving: "Finding system Python",
      creating: "Creating managed browser environment",
      installing: "Installing Playwright package",
      browsers: "Installing Chromium browser",
    });
  });

  it("maps every stage to copy with drift degrading to Preparing", () => {
    expect(browserStageCopy("resolving")).toBe("Finding system Python");
    expect(browserStageCopy("creating")).toBe(
      "Creating managed browser environment",
    );
    expect(browserStageCopy("installing")).toBe("Installing Playwright package");
    expect(browserStageCopy("browsers")).toBe("Installing Chromium browser");
    expect(browserStageCopy("unknown-step")).toBe("Preparing");
    expect(browserStageCopy("")).toBe("Preparing");
    expect(browserStageCopy(null)).toBe("Preparing");
    expect(browserStageCopy(undefined)).toBe("Preparing");
  });

  it("suspends the cap only during minutes-budget downloads", () => {
    // Pip and Chromium fetches run minutes, so the hung-provision cap waits
    // through them while faster steps still trip it.
    expect(isBrowserLongStage("installing")).toBe(true);
    expect(isBrowserLongStage("browsers")).toBe(true);
    expect(isBrowserLongStage("resolving")).toBe(false);
    expect(isBrowserLongStage("creating")).toBe(false);
    expect(isBrowserLongStage(null)).toBe(false);
  });
});
