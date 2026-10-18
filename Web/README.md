# Rune Weaver Dashboard

Static web dashboard for the Rune Weaver engine:
- **Chat**: Fluid conversation streaming with live tool-action frames, thinking containers, inline approval banners, and model settings.
- **Approvals Inbox**: Centralized queue for pending write operations with graduated-trust durations (once, 5 minutes, 1 hour, 1 day, forever).
- **Staged Changes**: Collapsible review drawer and inline diff cards for interactive file review (`files.write`), supporting live accept (`POST /files/live-accept`) and decline.
- **Work Hub**:
  - **Goals**: `GoalsManager` and `GoalDrawer` for tracking autonomous long-horizon goals, step pacing, status progression, and event triggers.
  - **Schedules**: `SchedulerManager` and `ScheduleWizardModal` for managing persistent cron and email-arrival scheduled jobs.
  - **Runs**: `RunLogViewer` and `RunDetailModal` with hierarchical fan-out worker swarm tracking and granular worker cancellation.
- **Memory Browser**: Search and manage episodic conversation history and semantic profile facts.
- **Index Status**: `IndexingPanel` with cold-boot fast/slow split, content breakdown (files, mail, messages), and maintenance tools (prune, reset, reclaim).
- **Security Policy**: `AccessNetworkSection` and `AccessCredentialsSection` for managing declarative egress allowlists, homelab local exemptions, and SSRF loopback protections in `policy.toml`.
- **Settings**: `SettingsManager` with in-page search, tool toggles, media integrations (Sonarr/Radarr), goals, proactivity, secrets management, and access token rotation.
- **Owner Auth**: `LoginView` providing single-owner bearer token login and sliding 24h durable session cookies (`rw_session`) for remote or non-loopback binds.

## Build, test, and lint (Makefile, canonical)

Use the `Makefile` at the repo root as the canonical way to build, test, and lint — for the dashboard and the Swift engine alike. Run these from the repo root instead of invoking `npm` / `swift` directly:

```bash
make build-web   # build the dashboard bundle (requires Node.js 20+)
make test-web    # dashboard tests (vitest)
make lint-web    # typecheck + eslint (TS/CSS) + file-size budgets
```

Full target list (see root `Makefile`):

| Target | What it does |
|--------|--------------|
| `make all` | `build` + `test` + `lint` (default goal) |
| `make setup` | Clean setup dependencies for Web (`npm ci` / `npm install`) and Swift (`swift package resolve`) |
| `make version` | Stamp `Sources/RuneWeaverCore/GeneratedVersion.swift` from `VERSION` and sync `Web/package.json` |
| `make build` | `build-web` + `build-swift` (dashboard bundle plus Swift engine) |
| `make build-web` | `npm run build` in `Web/` (requires Node.js 20+; emits `Web/dist/`) |
| `make build-swift` | `swift build` (Swift engine) |
| `make test` | `test-web` + `test-swift` |
| `make test-web` | Dashboard tests (`npm test` in `Web/`, vitest) |
| `make test-swift` | `swift test` (full Swift suite) |
| `make lint` | `lint-web` + `lint-swift` |
| `make lint-web` | Dashboard typecheck + lint (`npm run typecheck` + `npm run lint` in `Web/`: eslint over `src` — TS/TSX + CSS via `@eslint/css` — plus the file-budget vitest suite) |
| `make lint-swift` | `swiftformat --lint .` plus `swiftlint lint` |
| `make audit` / `make audit-web` | Security vulnerability scan (`npm audit --audit-level=high` in `Web/`) |
| `make run ARGS="<args>"` | Launch the engine (`swift run rune-weaver <args>`), e.g. `make run ARGS="chat"` |
| `make app` | Build the macOS `.app` bundle (`scripts/build_app.sh`) |
| `make dmg` | Build the distributable `.dmg` installer (`scripts/build_dmg.sh`) |
| `make clean` | Remove build outputs (`.build`, `Web/dist`, `dist`) |

## Node build requirement

Node.js 20 or later plus npm is required **only at build time**. There is no runtime Node server and no CORS: the Vite bundle is compiled once to static files and served by the engine process on the same loopback origin as the JSON API.

`make build-web` runs the equivalent of:

```bash
cd Web
npm ci
npm run build
```

What this does:

- `make build-web` installs pinned dependencies (`react`, `typescript`, `vite`, `vitest`, Testing Library) and typechecks (`tsc --noEmit`), then emits `Web/dist/` (`index.html` plus hashed `assets/`).
- The engine serves `Web/dist/` at `GET /` on `127.0.0.1:8082` (same origin, relative `fetch` only). Client-side routes fall back to `index.html`; missing hashed assets answer 404 JSON.

To preview the production bundle without the engine (dashboard-only development commands, run inside `Web/`):

```bash
cd Web
npm run preview
```

## Missing build behavior

If `Web/dist/index.html` is absent (Node/npm missing in the build environment), the engine still starts:

- `GET /` and `GET /index.html` answer 200 with a stub page reporting the `make build-web` steps (`npm ci && npm run build` in `Web/`).
- Other dashboard paths answer 503 JSON (`{"error":"dashboard-not-built",...}`).
- Every dashboard response carries `X-RuneWeaver-Dashboard: stub` so the stub is explicit, never a silent 404.
- Set `RUNEWEAVER_DASHBOARD_DIR` to point the engine at a bundle outside `Web/dist` when needed.

## Security: loopback-only dev servers and patched advisories

Patched dependency floors (see `package.json`):

- `vite ^6.4.3` fixes GHSA-fx2h-pf6j-xcff / CVE-2026-53571 (`server.fs.deny` bypass on Windows alternate paths, `vite <=6.4.2`).
- `vitest ^5.0.0` exceeds the GHSA-5xrq-8626-4rwp / CVE-2026-47429 patched floors (`vitest >=3.2.6`, `>=4.1.11`).

Loopback-only hardening (defense in depth):

- `vite.config.ts` pins `server.host` and `preview.host` to `127.0.0.1` and keeps `server.fs.deny` explicit (`[".env", ".env.*", "*.{crt,pem}"]`).
- `npm run dev` / `npm run preview` pass `--host 127.0.0.1 --strictPort`. Never override with `--host 0.0.0.0` (or any non-loopback `server.host` / `preview.host`); the engine serves the production `Web/dist/` bundle on `127.0.0.1:8082` instead — there is no separate frontend host process to expose.
- `npm test` (`vitest run`) and `npm run test:watch` (`vitest`) run headless with no `--ui` / `--api` flags, and `vite.config.ts` keeps `test.ui: false` plus `test.api: false` (Vitest middleware mode, no standalone listener). Do not run `vitest --ui` / `vitest --api` on untrusted networks.

Lockfile and audit:

```bash
cd Web
npm install                    # refresh package-lock.json after any dependency bump
npm audit --audit-level=high   # or: make audit-web (from the repo root)
```

`package-lock.json` must stay in sync with `package.json`. This matches the engine's localhost-only trust boundary (`127.0.0.1`, local-process access) and the auth-before-exposure rule: no VPN, tunnel, or port-forward exposure without authentication.

## Development

Canonical checks from the repo root:

```bash
make test-web   # vitest: API-client plus component tests
make lint-web   # typecheck + eslint (TS/CSS) + file-size budgets
make build-web  # full dashboard build
```

Dashboard-only commands (run inside `Web/`, development only):

```bash
npm run dev        # Vite dev server (development only)
npm run typecheck  # TypeScript check
npm run lint       # eslint over src (TS/TSX + CSS) + file-size budgets
npm test           # vitest: API-client plus component tests
```

- The API client (`src/api.ts`) uses relative URLs only. Do not introduce absolute hosts or a separate frontend host process.
- The dashboard connects to the engine WebSocket at `/ws` for live streaming of chat turns, tool execution progress, run events (`run_started`, `run_completed`), and proactive notifications.
