# Rune Weaver Dashboard

Static web dashboard for the Rune Weaver engine: chat view, approvals
inbox (allow/deny plus graduated-trust durations), memory search and
facts browser, and run log viewer.

## Build, test, and lint (Makefile, canonical)

Use the `Makefile` at the repo root as the canonical way to build,
test, and lint — for the dashboard and the Swift engine alike. Run
these from the repo root instead of invoking `npm` / `swift` directly:

```bash
make build-web   # build the dashboard bundle (requires Node.js 20+)
make test-web    # dashboard tests (vitest)
make lint-web    # dashboard typecheck (tsc --noEmit)
```

Full target list (see root `Makefile`):

| Target | What it does |
|--------|--------------|
| `make all` | `build` + `test` + `lint` (default goal) |
| `make setup` | Clean setup dependencies for Web (`npm ci` / `npm install`) and Swift (`swift package resolve`) |
| `make build` | `build-web` + `build-swift` (dashboard bundle plus Swift engine) |
| `make build-web` | `npm run build` in `Web/` (requires Node.js 20+; emits `Web/dist/`) |
| `make build-swift` | `swift build` (Swift engine) |
| `make test` | `test-web` + `test-swift` |
| `make test-web` | Dashboard tests (`npm test` in `Web/`, vitest) |
| `make test-swift` | `swift test` (full Swift suite) |
| `make lint` | `lint-web` + `lint-swift` |
| `make lint-web` | Dashboard typecheck (`npm run typecheck` in `Web/`) |
| `make lint-swift` | `swiftformat --lint .` plus `swiftlint lint` |
| `make audit` / `make audit-web` | Security vulnerability scan (`npm audit --audit-level=high` in `Web/`) |
| `make run ARGS="<args>"` | Launch the engine (`swift run rune-weaver <args>`), e.g. `make run ARGS="chat"` |
| `make clean` | Remove build outputs (`.build`, `Web/dist`) |

## Node build requirement

Node.js 20 or later plus npm is required **only at build time**. There
is no runtime Node server and no CORS: the Vite bundle is compiled once
to static files and served by the engine process on the same loopback
origin as the JSON API.

`make build-web` runs the equivalent of:

```bash
cd Web
npm ci
npm run build
```

What this does:

- `make build-web` installs pinned dependencies (`react`, `typescript`,
  `vite`, `vitest`, Testing Library) and typechecks (`tsc --noEmit`)
  then emits `Web/dist/` (`index.html` plus hashed `assets/`).
- The engine serves `Web/dist/` at `GET /` on `127.0.0.1:8082` (same
  origin, relative `fetch` only). Client-side routes fall back to
  `index.html`; missing hashed assets answer 404 JSON.

To preview the production bundle without the engine (dashboard-only
development commands, run inside `Web/`):

```bash
cd Web
npm run preview
```

## Missing build behavior

If `Web/dist/index.html` is absent (Node/npm missing in the build
environment), the engine still starts:

- `GET /` and `GET /index.html` answer 200 with a stub page reporting
  the `make build-web` steps (`npm ci && npm run build` in `Web/`).
- Other dashboard paths answer 503 JSON
  (`{"error":"dashboard-not-built",...}`).
- Every dashboard response carries `X-RuneWeaver-Dashboard: stub` so
  the stub is explicit, never a silent 404.
- Set `RUNEWEAVER_DASHBOARD_DIR` to point the engine at a bundle outside
  `Web/dist` when needed.

## Security: loopback-only dev servers and patched advisories

Patched dependency floors (see `package.json`):

- `vite ^6.4.3` fixes GHSA-fx2h-pf6j-xcff / CVE-2026-53571
  (`server.fs.deny` bypass on Windows alternate paths, `vite <=6.4.2`;
  upstream fixes `6.4.3` / `7.3.5` / `8.0.16`). This repo stays on the
  `6.x` line with the minimal patched floor `^6.4.3`.
- `vitest ^3.2.6` fixes GHSA-5xrq-8626-4rwp / CVE-2026-47429
  (arbitrary file read/execution when the Vitest UI/API server listens,
  `vitest <3.2.6`; upstream fixes `3.2.6` / `4.1.0`, `>=4.1.11` on the
  `4.x` line). This repo stays on the `3.x` line with the minimal
  patched floor `^3.2.6`, which pairs with Vite 6.

Loopback-only hardening (defense in depth, even when patched):

- `vite.config.ts` pins `server.host` and `preview.host` to
  `127.0.0.1` and keeps `server.fs.deny` explicit
  (`[".env", ".env.*", "*.{crt,pem}"]`).
- `npm run dev` / `npm run preview` pass
  `--host 127.0.0.1 --strictPort`. Never override with
  `--host 0.0.0.0` (or any non-loopback `server.host` /
  `preview.host`); the engine serves the production `Web/dist/` bundle
  on `127.0.0.1:8082` instead — there is no separate frontend host
  process to expose.
- `npm test` (`vitest run`) and `npm run test:watch` (`vitest`) run
  headless with no `--ui` / `--api` flags, and `vite.config.ts` keeps
  `test.ui: false` plus `test.api: false` (Vitest middleware mode, no
  standalone listener). Do not run `vitest --ui` / `vitest --api` (or
  Browser Mode) on untrusted networks or with untrusted code; if the UI
  is needed for local debugging, bind loopback only and stop the server
  when done.

Lockfile and audit:

```bash
cd Web
npm install        # refresh package-lock.json after any vite/vitest bump
npm audit --audit-level=high   # or: make audit-web (from the repo root)
```

`package-lock.json` must stay in sync with `package.json`; a stale
lockfile that still resolves `vite <=6.4.2` or `vitest <3.2.6` fails the
audit above. This matches the engine's localhost-only, no-auth v1 trust
boundary (`127.0.0.1`, local-process access) and the
auth-before-exposure rule: no VPN, tunnel, or port-forward exposure
without auth first.

## Development

Canonical checks from the repo root:

```bash
make test-web   # vitest: API-client plus component tests
make lint-web   # typecheck
make build-web  # full dashboard build
```

Dashboard-only commands (run inside `Web/`, development only):

```bash
npm run dev      # Vite dev server (development only)
npm run typecheck
npm test         # vitest: API-client plus component tests
```

The API client (`src/api.ts`) uses relative URLs only. Do not introduce
absolute hosts or a separate frontend host process.
