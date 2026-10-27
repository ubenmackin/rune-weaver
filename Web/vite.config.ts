// Rune Weaver Dashboard — Static bundle build and loopback-only dev configuration.

import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

declare const process: { env: Record<string, string | undefined> };
process.env.VITEST_SKIP_INSTALL_CHECKS = "1";

// Bundle chunking. Third-party weight sits in two unrelated trees: the React runtime and the
// markdown pipeline.

const REACT_RUNTIME_CHUNK = "vendor-react";
const MARKDOWN_CHUNK = "vendor-markdown";
const MISC_VENDOR_CHUNK = "vendor-misc";

// React's runtime pair: `react-dom` schedules through `scheduler`. `loose-envify`
// is listed under React in the lock but is a build-time shim for React's own
// sources, so it never reaches the graph and is deliberately not claimed here.
const REACT_RUNTIME_PACKAGES = new Set(["react", "react-dom", "scheduler"]);

// Markdown-pipeline families, matched by prefix because each family is a wide set of small packages
// — the GFM extensions alone span a dozen names.
const MARKDOWN_PACKAGE_PREFIXES = [
  "micromark", // tokenizer core, factories, and per-syntax extensions
  "mdast-util", // markdown <-> mdast conversions
  "hast-util", // mdast -> hast and hast -> JSX
  "unist-util", // generic AST traversal the conversions share
  "remark-", // remark parse/rehype plugins
  "character-", // entity and codepoint tables
  "estree-util", // JS identifier checks for the hast -> JSX transform
  "is-", // single-codepoint predicates used while scanning
  "vfile", // virtual-file types threaded through the processor
];

// Single-package members of the same closure that carry no shared prefix: the component itself, the
// processor core, its middleware chain, the inline-style path behind the JSX transform, and the
// entity/token helpers it reaches for.
const MARKDOWN_PACKAGE_NAMES = new Set([
  "react-markdown",
  "unified",
  "bail",
  "trough",
  "zwitch",
  "devlop",
  "extend",
  "dequal",
  "parse-entities",
  "stringify-entities",
  "decode-named-character-reference",
  "escape-string-regexp",
  "ccount",
  "longest-streak",
  "markdown-table",
  "trim-lines",
  "style-to-js",
  "style-to-object",
  "inline-style-parser",
  "property-information",
  "html-url-attributes",
  "web-namespaces",
  "space-separated-tokens",
  "comma-separated-tokens",
]);

// Bare package name owning a module id, or undefined when not third-party.
// Reads innermost node_modules segment and handles scoped names.
function nodeModulesPackageName(id: string): string | undefined {
  const segments = id.split(/[\\/]/);
  const owner = segments.lastIndexOf("node_modules");
  if (owner < 0) return undefined;
  const name = segments[owner + 1];
  if (!name) return undefined; // id stops at the directory itself: no owner
  if (name.startsWith("@")) {
    const scopeMember = segments[owner + 2];
    return scopeMember ? `${name}/${scopeMember}` : name;
  }
  return name;
}

function isMarkdownPackage(name: string): boolean {
  if (MARKDOWN_PACKAGE_NAMES.has(name)) return true;
  return MARKDOWN_PACKAGE_PREFIXES.some((prefix) => name.startsWith(prefix));
}

// Assigns each third-party module to its cache-stable chunk; first-party code
// returns undefined so Rollup keeps it in the entry chunk.
function manualChunkFor(id: string): string | undefined {
  const name = nodeModulesPackageName(id);
  if (name === undefined) return undefined;
  if (REACT_RUNTIME_PACKAGES.has(name)) return REACT_RUNTIME_CHUNK;
  if (isMarkdownPackage(name)) return MARKDOWN_CHUNK;
  return MISC_VENDOR_CHUNK;
}

// Static bundle for the engine to serve. Base "./" keeps asset URLs relative so the same dist works
// behind any loopback port with no CORS and no runtime Node server.
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
    // No `chunkSizeWarningLimit` override: the split above is what holds the
    // bundle under Rollup's default 500 kB ceiling, so the warning stays live
    // as the guard that tells us when a new dependency needs its own group.
    rollupOptions: {
      output: {
        manualChunks: manualChunkFor,
      },
    },
  },
  css: {
    postcss: {},
  },
  // GHSA-fx2h-pf6j-xcff (CVE-2026-53571): server.fs.deny bypass on Windows alternate paths, fixed
  // in vite 6.4.3 / 7.3.5 / 8.0.16.
  server: {
    host: "127.0.0.1",
    fs: {
      deny: [".env", ".env.*", "*.{crt,pem}"],
    },
  },
  preview: {
    host: "127.0.0.1",
  },
  test: {
    environment: "jsdom",
    // Process stylesheets in tests so `?raw` CSS source imports resolve to file text instead of the
    // default empty mock; stylesheet regression assertions then guard the real shared tokens rather
    // than passing vacuously on an empty string.
    css: true,
    setupFiles: ["./src/test-setup.ts"],
    globals: true,
    // Isolated workers per test file: no shared module state or globals leak between suites, so one
    // file's mocks and timers cannot flake another.
    pool: "forks",
    // Generous timeouts keep the full 86-file suite green under parallel-forks load.
    testTimeout: 15000,
    hookTimeout: 15000,
    teardownTimeout: 15000,
    // GHSA-5xrq-8626-4rwp (CVE-2026-47429): arbitrary file read/exec when the Vitest UI/API server
    // listens, fixed in vitest 3.2.6 / 4.1.0.
    ui: false,
    api: false,
  },
});
