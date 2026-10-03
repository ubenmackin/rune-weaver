// Rune Weaver Dashboard — Static bundle build and loopback-only dev configuration.
//
// Builds the React + TypeScript dashboard as a relative-base static bundle the
// engine serves with no runtime Node server. Pins dev/preview listeners to
// loopback only and pairs Vite with headless Vitest (jsdom) for unit tests.

import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

declare const process: { env: Record<string, string | undefined> };
process.env.VITEST_SKIP_INSTALL_CHECKS = "1";

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
