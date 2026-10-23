// Rune Weaver Dashboard — Parity guard for the shared widening suffixes.

import { describe, expect, it } from "vitest";

// The Node builtin the test-only probes reach for is declared locally,
// matching the config coverage ledger guard.
declare const process: { cwd: () => string };

async function readText(candidates: string[]): Promise<string> {
  const { readFileSync } = (await import(
    // @ts-expect-error node builtin without @types/node; test-only probe.
    "node:fs"
  )) as { readFileSync: (path: string, encoding: string) => string };
  const { resolve } = (await import(
    // @ts-expect-error node builtin without @types/node; test-only probe.
    "node:path"
  )) as { resolve: (...segments: string[]) => string };
  for (const candidate of candidates) {
    try {
      return readFileSync(resolve(process.cwd(), candidate), "utf8");
    } catch {
      continue;
    }
  }
  throw new Error(`Sources unavailable for ${candidates.join(", ")}`);
}

function extractSuffixSet(text: string, anchor: string): Set<string> {
  const start = text.indexOf(anchor);
  if (start === -1) return new Set();
  const endMarkers = ["\n    ]", "\n]);", "\n];"];
  let end = -1;
  for (const marker of endMarkers) {
    const at = text.indexOf(marker, start);
    if (at !== -1 && (end === -1 || at < end)) end = at;
  }
  const block = end === -1 ? text.slice(start) : text.slice(start, end);
  const hosts = new Set<string>();
  const pattern = /"([a-z0-9.-]+\.[a-z]{2,})"/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(block)) !== null) {
    hosts.add(match[1].toLowerCase());
  }
  return hosts;
}

describe("egressSuffixParity", () => {
  it("pins the dashboard mirror equal to the Core single source", async () => {
    const core = await readText([
      "../Sources/RuneWeaverCore/EgressWideningPolicy.swift",
      "Sources/RuneWeaverCore/EgressWideningPolicy.swift",
    ]);
    const dashboard = await readText([
      "src/approvalsShared.ts",
      "Web/src/approvalsShared.ts",
    ]);
    const coreHosts = extractSuffixSet(core, "multiPartPublicSuffixes");
    const dashboardHosts = extractSuffixSet(dashboard, "MULTI_PART_PUBLIC_SUFFIXES");
    expect(coreHosts.size).toBeGreaterThan(0);
    expect(dashboardHosts.size).toBeGreaterThan(0);
    expect([...dashboardHosts].sort()).toEqual([...coreHosts].sort());
  });

  it("keeps the Swift widening guards single-sourced on Core", async () => {
    const server = await readText([
      "../Sources/RuneWeaverServer/ServerApprovalRoutes.swift",
      "Sources/RuneWeaverServer/ServerApprovalRoutes.swift",
    ]);
    const supervisor = await readText([
      "../Sources/RuneWeaverTools/OutboundEgressSupervisor.swift",
      "Sources/RuneWeaverTools/OutboundEgressSupervisor.swift",
    ]);
    const accessRule = await readText([
      "../Sources/RuneWeaverCore/AccessRule.swift",
      "Sources/RuneWeaverCore/AccessRule.swift",
    ]);
    for (const text of [server, supervisor, accessRule]) {
      expect(text).toContain("EgressWideningPolicy");
    }
    expect(server).not.toContain("multiPartPublicSuffixes: Set");
    expect(supervisor).not.toContain("nonWidenableScopeSuffixes");
    expect(accessRule).not.toContain("nonWidenableScopeSuffixes");
  });
});
