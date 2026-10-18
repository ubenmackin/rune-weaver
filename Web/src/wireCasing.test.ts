// Rune Weaver Dashboard — Wire API casing contract test.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_BASH_CONFIG,
  DEFAULT_CONTAINERS_CONFIG,
  DEFAULT_DESKTOP_CONFIG,
  DEFAULT_FANOUT_CONFIG,
  DEFAULT_INDEX_CONFIG,
  DEFAULT_WORKSPACE_CONFIG,
} from "./api";

declare const process: { cwd: () => string };

function assertNoSnakeCaseKeys(obj: unknown, path = "$"): void {
  if (obj === null || typeof obj !== "object") {
    return;
  }
  if (Array.isArray(obj)) {
    obj.forEach((item, index) => assertNoSnakeCaseKeys(item, `${path}[${index}]`));
    return;
  }
  for (const [key, value] of Object.entries(obj)) {
    const currentPath = `${path}.${key}`;
    expect(key, `Found snake_case key '${key}' at '${currentPath}'`).not.toMatch(/^[a-z0-9]+_[a-z0-9_]+$/i);
    assertNoSnakeCaseKeys(value, currentPath);
  }
}

describe("Wire API Casing Contract (Web)", () => {
  it("enforces camelCase keys on default configuration objects", () => {
    assertNoSnakeCaseKeys(DEFAULT_CONTAINERS_CONFIG, "DEFAULT_CONTAINERS_CONFIG");
    assertNoSnakeCaseKeys(DEFAULT_BASH_CONFIG, "DEFAULT_BASH_CONFIG");
    assertNoSnakeCaseKeys(DEFAULT_DESKTOP_CONFIG, "DEFAULT_DESKTOP_CONFIG");
    assertNoSnakeCaseKeys(DEFAULT_FANOUT_CONFIG, "DEFAULT_FANOUT_CONFIG");
    assertNoSnakeCaseKeys(DEFAULT_INDEX_CONFIG, "DEFAULT_INDEX_CONFIG");
    assertNoSnakeCaseKeys(DEFAULT_WORKSPACE_CONFIG, "DEFAULT_WORKSPACE_CONFIG");
  });

  it("verifies api.ts interface and type definitions contain no snake_case properties", async () => {
    const { existsSync, readdirSync, readFileSync } = (await import(
      // @ts-expect-error node builtin without @types/node; test-only probe.
      "node:fs"
    )) as {
      existsSync: (path: string) => boolean;
      readdirSync: (path: string) => string[];
      readFileSync: (path: string, encoding: string) => string;
    };
    const { resolve } = (await import(
      // @ts-expect-error node builtin without @types/node; test-only probe.
      "node:path"
    )) as {
      resolve: (...paths: string[]) => string;
    };

    const cwd = typeof process !== "undefined" && typeof process.cwd === "function" ? process.cwd() : "";
    const apiPath = resolve(cwd, "src/api.ts");
    const apiDir = resolve(cwd, "src/api");
    const filesToScan = [apiPath];
    if (existsSync(apiDir)) {
      for (const entry of readdirSync(apiDir)) {
        if (entry.endsWith(".ts")) {
          filesToScan.push(resolve(apiDir, entry));
        }
      }
    }
    const source = filesToScan.map((f) => readFileSync(f, "utf8")).join("\n");

    // Regular expression matching object property declarations in interfaces and types:
    // e.g. "  propertyName?:" or "  propertyName:"
    const propertyRegex = /^\s+['"]?([a-zA-Z0-9_]+)['"]?\s*\??\s*:/gm;
    const matches: string[] = [];
    let match: RegExpExecArray | null;

    while ((match = propertyRegex.exec(source)) !== null) {
      const propName = match[1];
      // Check if property is snake_case (e.g. contains underscore between words)
      if (/[a-z0-9]_[a-z0-9]/i.test(propName)) {
        matches.push(propName);
      }
    }

    expect(matches, `Found snake_case properties in api.ts: ${matches.join(", ")}`).toEqual([]);
  });
});
