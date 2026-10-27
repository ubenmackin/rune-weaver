// Rune Weaver Dashboard — Index Status phone/PWA layout contract (pipeline stepper, lanes, overflow guards).

import { describe, expect, it } from "vitest";
import indexingStyles from "../styles/indexing.css?raw";
import tabsStyles from "../styles/tabs.css?raw";

// Plain stylesheet imports resolve to empty under the test transform, so the
// raw text import pins the rules to their modular stylesheet owners.

// Returns the concatenated bodies of every `@media (max-width: Npx)` block so a
// rule is asserted inside the breakpoint that owns it, not anywhere in the file.
function mediaBlocks(css: string, width: number): string {
  const marker = `@media (max-width: ${width}px)`;
  let out = "";
  let from = 0;
  for (;;) {
    const start = css.indexOf(marker, from);
    if (start < 0) break;
    let depth = 0;
    let i = css.indexOf("{", start);
    const bodyStart = i + 1;
    for (; i < css.length; i++) {
      if (css[i] === "{") depth++;
      else if (css[i] === "}" && --depth === 0) break;
    }
    out += css.slice(bodyStart, i) + "\n";
    from = i;
  }
  return out;
}

describe("Index Status mobile layout", () => {
  it("stacks the pipeline into a vertical stepper that keeps the connector pipes", () => {
    const narrow = mediaBlocks(indexingStyles, 680);
    expect(narrow).toMatch(/\.index-pipeline-track\s*\{[^}]*flex-direction:\s*column/);
    expect(narrow).toMatch(/\.index-pipeline-connector\s*\{[^}]*height:\s*14px/);
    expect(narrow).toMatch(/animation-name:\s*indexPipeFlowVertical/);
    // Connectors must stay visible on phones so stage order stays readable.
    expect(narrow).not.toMatch(/\.index-pipeline-connector\s*\{[^}]*display:\s*none/);
    expect(indexingStyles).toMatch(/@keyframes\s+indexPipeFlowVertical/);
  });

  it("declares the stepper after the base pipeline rules so it wins the cascade", () => {
    const base = indexingStyles.indexOf(".index-pipeline-connector-flow {");
    const narrow = indexingStyles.indexOf("@media (max-width: 680px)");
    expect(base).toBeGreaterThan(-1);
    expect(narrow).toBeGreaterThan(base);
  });

  it("drops queue lanes to one column on phone widths", () => {
    expect(mediaBlocks(indexingStyles, 460)).toMatch(
      /\.index-queue-lanes-grid\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/,
    );
  });

  it("keeps long paths and denied guidance inside the card", () => {
    expect(indexingStyles).toMatch(/\.index-live-current\s*\{[^}]*text-overflow:\s*ellipsis/);
    expect(indexingStyles).toMatch(/\.index-live-current\s*\{[^}]*white-space:\s*nowrap/);
    expect(indexingStyles).toMatch(
      /\.index-source-pills\s+\.status-pill\s*\{[^}]*white-space:\s*normal/,
    );
  });

  it("tightens the Memory tab bar on phones without shrinking the touch height", () => {
    const phone = mediaBlocks(tabsStyles, 460);
    expect(phone).toMatch(/\.tab-bar-tab[\s\S]*?\{[^}]*white-space:\s*nowrap/);
    expect(phone).toMatch(/\.tab-bar-tab[\s\S]*?\{[^}]*font-size:\s*13px/);
    expect(phone).not.toMatch(/min-height/);
    expect(tabsStyles).toMatch(/\.tab-bar-tab\s*\{[^}]*min-height:\s*44px/);
  });
});
