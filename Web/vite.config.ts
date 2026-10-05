// Rune Weaver Dashboard — Static bundle build and loopback-only dev configuration.
//
// Builds the React + TypeScript dashboard as a relative-base static bundle the
// engine serves with no runtime Node server. Splits the third-party trees into
// cache-stable vendor chunks, and pairs with the app's React.lazy route
// boundaries so no emitted chunk breaches Rollup's size warning ceiling. Pins
// dev/preview listeners to loopback only and pairs Vite with headless Vitest
// (jsdom) for unit tests.

import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

declare const process: { env: Record<string, string | undefined> };
process.env.VITEST_SKIP_INSTALL_CHECKS = "1";

// Bundle chunking. Third-party weight sits in two unrelated trees: the React
// runtime and the markdown pipeline. `react-markdown` + `remark-gfm` pull in the
// whole unified / micromark / mdast / hast stack, and together with `react-dom`
// those trees filled one ~898 kB (gzip ~243 kB) index chunk — past the 500 kB
// ceiling Rollup warns on. Splitting by tree keeps every emitted chunk under that
// default, and the win that actually matters is cache independence: a dashboard
// edit no longer invalidates the React runtime URL, and a markdown-dependency
// bump leaves both the app and React chunks untouched, so a returning client
// refetches one small file instead of the whole bundle.
//
// First-party modules deliberately get no manual chunks: route-level splitting
// lives in the app itself as React.lazy dynamic imports, and Rollup derives a
// chunk per boundary automatically. Naming those chunks here would couple build
// config to component layout for no benefit. Anything found in node_modules
// falls into a generic vendor chunk so a future dependency cannot silently
// re-merge into the entry chunk and re-breach the ceiling.

const REACT_RUNTIME_CHUNK = "vendor-react";
const MARKDOWN_CHUNK = "vendor-markdown";
const MISC_VENDOR_CHUNK = "vendor-misc";

// React's runtime pair: `react-dom` schedules through `scheduler`. `loose-envify`
// is listed under React in the lock but is a build-time shim for React's own
// sources, so it never reaches the graph and is deliberately not claimed here.
const REACT_RUNTIME_PACKAGES = new Set(["react", "react-dom", "scheduler"]);

// Markdown-pipeline families, matched by prefix because each family is a wide set
// of small packages — the GFM extensions alone span a dozen names. A prefix is
// either a real package name matched without its hyphen (`micromark`, `vfile`) or
// a namespace ending at the hyphen: the hyphen is what keeps `estree-walker`, a
// toolchain-side package, out of the `estree-util` group, and likewise for
// `remark-` versus a hypothetical bare `remark`. `is-` is intentionally broad —
// in the production graph the only `is-*` packages are the codepoint predicates
// and `is-plain-obj`, all of them pipeline members.
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

// Single-package members of the same closure that carry no shared prefix: the
// component itself, the processor core, its middleware chain, the inline-style
// path behind the JSX transform, and the entity/token helpers it reaches for.
// Anything in the tree not listed here still builds correctly — it just lands in
// the misc vendor chunk, and the packages that could do that are a few kB.
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

/**
 * Bare package name owning a module id, or `undefined` when the module is not
 * third-party. Reads the innermost `node_modules` segment so a nested duplicate
 * dependency is classified by its real owner rather than by its parent package,
 * and reassembles two segments for scoped names. Accepts either path separator
 * because ids are normalized per platform by the bundler.
 */
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

/**
 * Assigns each third-party module to its chunk; first-party code returns
 * `undefined` so Rollup keeps it in the entry chunk. Groups are chosen so
 * imports run one way only — app -> markdown -> React, with leaf utilities
 * parked in misc — because a manual-chunk cycle is the failure mode that makes
 * this kind of config noisy to maintain, and one-directional trees are also
 * what keeps each chunk independently cacheable.
 */
function manualChunkFor(id: string): string | undefined {
  const name = nodeModulesPackageName(id);
  if (name === undefined) return undefined;
  if (REACT_RUNTIME_PACKAGES.has(name)) return REACT_RUNTIME_CHUNK;
  if (isMarkdownPackage(name)) return MARKDOWN_CHUNK;
  return MISC_VENDOR_CHUNK;
}

// Static bundle for the engine to serve. Base "./" keeps asset URLs
// relative so the same dist works behind any loopback port with no CORS
// and no runtime Node server.
//
// Security: dev/preview listeners stay on loopback only (127.0.0.1).
// Do not pass --host 0.0.0.0 (or any non-loopback server.host /
// preview.host), and do not run `vitest --ui` / `--api` on untrusted
// networks or with untrusted code. See Web/README.md "Security".
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
  // GHSA-fx2h-pf6j-xcff (CVE-2026-53571): server.fs.deny bypass on
  // Windows alternate paths, fixed in vite 6.4.3 / 7.3.5 / 8.0.16.
  // Pin dev and preview to loopback and keep the default deny list
  // explicit so sensitive files (.env, certs) are never served.
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
    // Process stylesheets in tests so `?raw` CSS source imports resolve to
    // file text instead of the default empty mock; stylesheet regression
    // assertions then guard the real shared tokens rather than passing
    // vacuously on an empty string.
    css: true,
    setupFiles: ["./src/test-setup.ts"],
    globals: true,
    // Isolated workers per test file: no shared module state or globals
    // leak between suites, so one file's mocks and timers cannot flake
    // another. Threads share memory and need that justification; forks
    // keep the default isolation instead.
    pool: "forks",
    testTimeout: 5000,
    hookTimeout: 5000,
    teardownTimeout: 5000,
    // GHSA-5xrq-8626-4rwp (CVE-2026-47429): arbitrary file read/exec
    // when the Vitest UI/API server listens, fixed in vitest 3.2.6 / 4.1.0.
    // GHSA-82fw-gwwq-j7x9: path traversal / arbitrary file read via
    // @vitest/mocker redirect mock, fixed in vitest 5.0.0 / 4.1.11.
    // Keep `vitest run` headless with no standalone API listener
    // (middleware mode). Only enable --ui/--api for local debugging on
    // loopback, never on untrusted networks.
    ui: false,
    api: false,
  },
});
