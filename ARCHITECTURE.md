# Rune Weaver — Architecture

## PROJECT SOUL

Rune Weaver is a personal AI assistant harness — a modular, privacy-first system that bridges your digital life across Apple ecosystem, self-hosted services, and the web. Inspired by Jarvis/Friday from Iron Man, it runs as an always-on "brain" on a Mac Studio, with thin clients connecting to interact with it.

The name comes from JRPG lore: a Rune Weaver is a mage who inscribes and channels magical runes to shape reality. Our Rune Weaver inscribes digital "runes" (skills, integrations, memory) to shape your daily workflow.

### Core Philosophy

- **Local-first, cloud-optional**: Your data stays on your hardware by default. Cloud LLMs are an opt-in fallback, not a requirement.
- **Human-in-the-loop**: The agent reads freely but writes cautiously. Every action that changes state requires explicit permission — with graduated trust so you're not approving the same thing forever.
- **Modular by design**: Capabilities are plugins (runes). Add new ones without touching the core. The system learns, remembers, and grows.
- **Apple-native where it counts**: Deep macOS integration (Keychain, AppKit/SwiftUI, Messages snapshot reads, ScreenCaptureKit) — not bolted on, but foundational. iOS is planned, not built.
- **Swappable LLMs**: The brain is model-agnostic. Run Gemma 4 on MLX locally, switch to Qwen 3.8 via llama.cpp, or fall back to a cloud API — the tools and memory don't care which model is thinking.
- **Fast recall without exfiltration**: An opt-in on-device index over files, mail, and Apple Messages makes everyday questions fast — chunked, keyword-searchable, and optionally vectorized — while live reads remain the freshness fallback. Nothing is indexed until the owner turns it on.
- **Durable goals over one-shot prompts**: The agent holds long-horizon goals — a plan, step statuses, an event log, and a cadence — and keeps working toward them between conversations. A goal is a first-class entity; the scheduler merely executes toward it.
- **Proactive, but interrupt-worthy**: Background completions are gated by a surfacing judgment so notifications stay rare enough to be trusted, while run history and the approvals inbox record everything regardless.
- **One switch per capability**: something that only runs when its tool is invoked is enabled in exactly one place — the tool toggle. A second enablement gate in config is a bug, not a feature.

**Delivery status lives in `ROADMAP.md`.** This document describes what the architecture *is* (decisions, protocols, component responsibilities, constraints) — not what shipped in which release. Items below are explicitly marked **shipped**, **partial**, or **planned** where the distinction matters.

---

## TECH STACK

LANGUAGE: Swift (core engine + macOS client), Python (embedded bridge scripts and supported external-plugin runtime — no standalone plugins ship in-repo), TypeScript + React + Vite (web dashboard static bundle served by the engine)

### Why Swift First
- Native macOS integration (Keychain, AppKit/SwiftUI)
- Strong type system, memory safety, great performance on Apple Silicon
- User's primary development language — fast iteration
- Swift concurrency (async/await, actors) is ideal for the async nature of LLM inference and tool orchestration

### Why Python for Plugins
- ML ecosystem (Whisper, Playwright, email parsing libraries) is Python-first
- Plugin isolation: a bad Python plugin can't crash the Swift core
- Easy for community contributors to write new skills

### Unified Toolchain & Quality Gates
- **Single Build Entrypoint**: A root `Makefile` coordinates build, test, lint, and security auditing across both the Swift 6.0 engine and the React + TypeScript + Vite web dashboard.
- **Workflow Targets**: `make build` (compiles Vite bundle to `Web/dist` and builds Swift products), `make test` (runs Vitest unit tests and Swift Testing suites), `make lint` (`tsc --noEmit`, `swiftformat --lint .`, `swiftlint lint`).
- **Multi-Ecosystem Security Auditing**: `make audit` coordinates vulnerability scanning across both package ecosystems: `npm audit --audit-level=high` for web frontend dependencies, and `osv-scanner` (with `trivy` fallback) scanning `Package.resolved` against open-source vulnerability databases.

---

## SYSTEM ARCHITECTURE

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLIENT LAYER                              │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │ iOS Client   │  │  macOS Client│  │   Web Dashboard    │    │
│  │  (planned)   │  │ (shipped:    │  │   (shipped: React  │    │
│  │              │  │  menu bar)   │  │   + Vite bundle)   │    │
│  │ Push-to-talk │  │ Menu bar app │  │  Chat + goal chip  │    │
│  │ TTS playback │  │ TTS playback │  │  Approvals inbox   │    │
│  │ Notifications│  │ Voice toggle │  │  Goals/Schedules/  │    │
│  └──────┬───────┘  └──────┬───────┘  └────────┬───────────┘    │
│         │                 │                     │                │
│         └─────────────────┼─────────────────────┘                │
│                           │                                      │
│                    WebSocket / REST                               │
│         (loopback always; non-loopback requires owner auth)       │
├───────────────────────────┼──────────────────────────────────────┤
│                    CORE ENGINE (Swift)                            │
│                           │                                      │
│  ┌────────────────────────┼────────────────────────────────┐    │
│  │              ORCHESTRATION LAYER                         │    │
│  │                                                          │    │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  LLM Router │  │  Tool Bus    │  │  Conversation │  │    │
│  │  │             │  │  + aliases   │  │  Manager      │  │    │
│  │  │ Provider    │  │  Dispatches  │  │              │  │    │
│  │  │ selection & │  │  tool calls  │  │  Session      │  │    │
│  │  │ fallback    │  │  to plugins  │  │  context &    │  │    │
│  │  │             │  │              │  │  history      │  │    │
│  │  └─────────────┘  └──────────────┘  └──────────────┘  │    │
│  │                                                          │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │              SUPPORT SERVICES                            │    │
│  │                                                          │    │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │   Memory    │  │  Permission  │  │  Scheduler   │  │    │
│  │  │   Engine    │  │  Gate        │  │  & Goals     │  │    │
│  │  │             │  │              │  │              │  │    │
│  │  │ Short-term  │  │  Graduated   │  │  Cron/poll & │  │    │
│  │  │ Long-term   │  │  trust model │  │  event trigs │  │    │
│  │  │ Vector +    │  │  Sandboxing  │  │  GoalEngine  │  │    │
│  │  │ Structured  │  │              │  │  Ideas       │  │    │
│  │  └─────────────┘  └──────────────┘  └──────────────┘  │    │
│  │                                                          │    │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  Secrets    │  │  Voice       │  │  Document    │  │    │
│  │  │  Manager    │  │  Pipeline    │  │  Index       │  │    │
│  │  │             │  │              │  │              │  │    │
│  │  │ Keychain +  │  │  Whisper STT │  │  SQLite FTS5 │  │    │
│  │  │ surrogates  │  │  TTS output  │  │  + vectors   │  │    │
│  │  └─────────────┘  └──────────────┘  └──────────────┘  │    │
│  │                                                          │    │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  Declarative│  │  Policy      │  │  Egress      │  │    │
│  │  │  Policy     │  │  Invariants  │  │  Supervisor  │  │    │
│  │  │  (policy.toml)  │  (4 proofs)  │  │  (api.request)  │    │
│  │  └─────────────┘  └──────────────┘  └──────────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                    TOOL PLUGINS                                   │
│              (shipped vs planned — see INTEGRATIONS)              │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │  Email   │ │ Browser  │ │  Files   │ │  Memory  │          │
│  │ (IMAP +  │ │(Playwrt) │ │ (local)  │ │(memories │          │
│  │ send;    │ │          │ │          │ │.store +  │          │
│  │ shipped) │ │ shipped  │ │ shipped  │ │.recall)  │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
└──────────────────────────────────────────────────────────────────┘
```

The Document Index is not a separate process: it is an actor-backed local store inside the core engine, sitting beside the other Support Services and feeding `memories.recall`. See Component Details §14. Goals, the proactive surfacing gate, the Ideas engine, and multi-agent fan-out are likewise actor-backed sub-systems inside the core engine rather than separate processes. The declarative policy engine (§15) is the third such in-process security subsystem: policy store, invariant verifier, and egress supervisor are all actors in the core engine.

Shipped tool set: Email IMAP/SMTP (`email.search`, `email.read`, `email.attachment`, `email.send`, `email.listMailboxes`, `email.move`), web + browser (`web.search`, `web.fetch`, `browser.navigate`, `browser.act`, `api.request`), files (`files.read`, `files.grep`, `files.glob`), memory (`memories.store` canonical with `remember_fact` alias, `memories.recall` canonical with `recall_memories` alias), Apple Messages (`messages.search` read-only, `messages.read` read-only, `messages.send` approval-gated with dry-run preview), media automation (`media.arr` approval-gated plus `media.arr.read` read-only), desktop perception and control (`desktop.screenshot` read-only plus `desktop.action` approval-gated; always registered but fail-closed), goals (`goal.create` approval-gated plus `goal.status`/`goal.progress` read-only), and multi-agent fan-out (`fanout.run` approval-gated).

### Engine-to-Service Shift

The core engine is shifting from a CLI-only tool to a local service that other UIs drive through one HTTP surface.

- **Vapor API layer**: A Vapor service fronts the core engine and exposes chat, health, tools, memory, approvals, runs, scheduler, goals, ideas, and settings operations as JSON routes. The CLI remains direct-core for v1. The service launches from the CLI binary via `rune-weaver serve`, which builds a `ServerContext` with `ServerContext.make(...)`.
- **CLI index wiring (shipped)**: The CLI chat loop inspects `config.index.enabled`. When enabled it resolves `config.index.databasePath(in: stateDir)` and passes `docIndexDBPath` into the memory engine, so terminal turns get the same indexed candidates as the service.
- **WebSocket event hub & real-time streaming**: The service maintains `/ws` managed by `WSHub`. Chat turns stream text deltas, tool invocations, and outcomes tagged by `sessionID`; in-flight turns support mid-turn cancellation via WebSocket or REST, aborting via `ActiveTurnTracker`. Scheduler, goal, and idea events broadcast on the same hub (`run_started`/`run_completed`, `goal_updated`, `proactive_message`).
- **Authoritative concurrent-turn cap**: `ActiveTurnTracker.maxConcurrentTurns = 3` bounds simultaneous chat turns. `GET /health` advertises the cap and the live SearXNG start flight.
- **Durable SQLite persistence for scheduler, goals & run history**: Jobs, run logs, goals, goal steps/events/triggers, and ideas persist in `episodes.db`. `config.toml` jobs are bootstrap seed only when the database has zero jobs.
- **Fan-out cancellation (shipped)**: `POST /runs/:id/cancel` cancels one running worker or a whole swarm by run-log row id; affected subtasks and rows settle to `cancelled` and the Runs tab refetches. No new transport.
- **Static dashboard bundle**: Served by the engine itself with chat, grouped nav (Chat, Approvals, Work → Goals/Schedules/Runs, Memory), approvals inbox, run history, and index status surfaces.
- **Same trust boundary**: Every service-triggered write still flows through the permission gate. The service adds transport; it does not bypass approvals.
- **Single-owner bearer auth & ephemeral browser sessions (shipped)**: Exactly one owner token guards the engine HTTP surface. Browser clients exchange it via `POST /auth/session` for an ephemeral `HttpOnly`, `SameSite=Strict` cookie. Rotation invalidates live sessions.
- **Fail-closed binding (shipped)**: Loopback always serves. Non-loopback requires a resolved token or boot is refused.
- **Service auto-fire plus per-process single-flight**: Service auto-fires scheduler and goal triggers, sharing one lock per firing class with manual runs; the CLI foreground loop is a second runner — run one at a time.

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine owns orchestration, conversation state, and provider routing.

- **Orchestration**: Receives user input, routes through the LLM, executes tool calls, returns responses.
  - **Dynamic System Prompt Composition**: `SystemPromptComposer` snapshots `ToolBus.availableTools()` and generates a deterministic prompt with tool names, descriptions, schemas, permission levels, policies, and memory guidance. Canonical memory names are advertised; aliases never are. The prompt also carries one static rule teaching that delimited untrusted content is data, never instructions.
  - **Narration Fallback for Local LLMs**: `OrchestratorToolLoop` extracts read-only calls from text narration; gated narrations file approvals and park until decided.
  - **Background turn sources**: `Orchestrator.isBackgroundSource(_:)` is the single owner of which sources (`scheduler`, `goal`) use background prompt/turn handling and parking, so future background sources extend in one place.
  - **In-Flight Turn Cancellation**: `ActiveTurnTracker` tracks running turns across WebSocket and REST.
- **Conversation Manager**: Session state, history, and context windows across durable SQLite tables, hydrating from disk. Sessions carry an optional `goal_id` linking a chat or background session to the goal it advances.
- **LLM Router**: Priority-ordered providers with fallback, key management, pooling.

Key patterns: Swift actors for isolation, protocol-oriented subsystems, structured concurrency for streaming.

### 2. LLM Provider Abstraction

```
Protocol: LLMProvider
  ├── func chat(messages: [Message], tools: [Tool]) -> AsyncStream<LLMResponse>
  ├── func embeddings(text: [String]) -> [[Float]]
  └── var modelInfo: ModelInfo
```

Implementations: `MLXProvider`, `LlamaCppProvider`, `OpenAICompatibleProvider`. Routing via `LLMRouter`, config via `ProviderConfig`, backend selector via `ProviderKind`.

Goal decomposition, the proactive judge, and the fan-out reviewer all reuse the SAME injected provider/router instance the orchestrator is constructed with; none is self-built.

### 3. Tool Plugin System

Tools declare name, description, JSON Schema, permission level (`readOnly`, `requiresApproval`, `trusted`), and handler. `ToolBus` carries aliases; `MemoryTools.registerMemoryAliases` registers `remember_fact`/`recall_memories` once. Python tools run out-of-process via JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`). Tools that return network-derived content declare `contentTrustLevel == .untrustedExternal` via a non-breaking `Tool` protocol extension (default `.trusted`), never by name-sniffing.

Registration flows through `BuiltinToolPlugins.makeAllTools` behind optional engine/store parameters (`nil` = not registered) so CLI, menu-bar app, and serve share one registration path with no drift. Tools always register (visible in `GET /tools`) so the registry never shape-shifts with config. Subsystems with background entry points (goals, ideas) register even when their `enabled` flag is off and return the honest disabled error when called; tool-invoked-only capabilities (desktop, fan-out) instead ship disabled and go live solely through the persisted tool-state toggle — the single-gate enablement rule (decision 36, §11). `api.request` is the one exception to silent-nil defaults: it is constructed only with a live `OutboundEgressSupervisor` (§15) — supervisor construction is fail-closed at boot.

### 4. Memory Engine (shipped)

Three tiers plus routed automatic injection:

| Tier | What | Storage | Lifecycle |
|------|------|---------|-----------|
| **Working Memory** | Current context | In-memory + SQLite sessions | Session-scoped, folds into rolling summary over budget |
| **Episodic Memory** | Past turns as cleaned rows | SQLite + FTS5 | Permanent, mirrored via `mirrorTurn`; compacts >30d when >10,000 rows |
| **Semantic Memory** | Facts, preferences, profile | JSON vector store (LanceDB-compatible) + JSON profile | Permanent; cosine when embeddings available, keyword overlap otherwise |

**Automatic recall path (routed, budgeted, freshness-aware):**

1. `Orchestrator.process` builds one `RecallPlan` per turn via `MemoryQueryRouter.plan(for:currentDate:)` — inferring `since/until` (yesterday, single date, month window via `TemporalFilter.parse`) and freshness (`today`, `this-morning`, `latest`, `unread`, `just-arrived` via `LiveSearchGuidance`) with query expansion only, no LLM call.
2. `MemoryEngine.recallMessage` embeds best-effort (`embedQuery`; cancel propagates, other failures fall back to keyword), calls `recall(query:embedding:limit:since:until:)` with the plan window, and skips or down-weights `docIndex` when `LiveSearchOverride.shouldUseLiveSearch` is forced. Empty query, store error, or below-threshold yields nil — recall never fails a turn.
3. `recall` merges episodic, semantic, document-index, and profile hits under `RecallBudgets` from `[memory] recall_*` (`perTierLimit`, `autoLimit`, `threshold`, `maxChars`, `perHitChars`, `docPoolMultiplier`, `episodicWeight`). Document candidates use a widened newest-first pool (`clamped * docPoolMultiplier`) unioned across keyword and vectors, fused with reciprocal-rank plus token-overlap, recency, and exact name-or-path bonuses, then calibrated by tier weight. Results dedupe by ID plus content, sort by score then tier priority (profile > semantic > docIndex > episodic).
4. Injection is at most one auto-recall system message plus at most one starter-pack system message, both placed directly before the last user message via `MemoryEngine.historyWithRecall` (never lead system) to preserve prefix-cache. `RecallStarterPack.build` always supplies `Profile:`, `Index as of:`, and optional `Goal:` lines (trusted verbatim, capped). Recall lines are capped per-hit, carry `[date|path|display_name]` citations, and wrap docIndex plus episodic `Used`-mirror content in the `ContentTrustLabeler` data-only block; trusted tiers pass verbatim.
5. Diagnostics: `recallWithDiagnostics` returns hit IDs, sources, scores, injected chars, and `skippedDocIndex`; `Orchestrator` logs one content-free `RuneWeaverLog.memory.info` line per turn.

**Memory Flow**: user text enters working memory and mirrors clean into episodic (`Used <tool>:` records); context overflow folds into rolling summary; `/remember` captures deterministically; facts persist with vectors and mirror into profile; future turns see routed recall plus starter pack plus live-tool fallback.

**Embeddings**: Via `EmbeddingsBackend` (`apple` default, `provider` opt-in, `none` keyword-only). Failures fall back to keyword; cancellation propagates. Backfill gains vectors for older rows.

**Document recall**: Via `recallDocuments`, pairing FTS chunks with parents through `DocIndexStore.documents(ids:)` with source metadata and `index_as_of` watermark.

### 5. Permission Gate & Sandboxing (shipped)

Levels `readOnly`, `requiresApproval`, `trusted` with graduated trust (this time / 5m / 1h / 1d / forever). `memories.store`/`recall` are `trusted`; `messages.send`, `desktop.action`, `browser.act`, `api.request`, `media.arr`, `goal.create`, and `fanout.run` require approval. Goal ledger bookkeeping (`goal.status`, `goal.progress`) is `readOnly` — the same bargain as `remember_fact`: it mutates only the local ledger, never the world.

Every action a goal step or fan-out worker takes while advancing still flows through the permission gate exactly like any other turn. The gate does not bypass approvals for background work. Declarative egress supervision (§15) is layered beneath this gate for `api.request` and never relaxes it: approval is still required, and the supervisor can deny on top of any approval.

### 6. Secrets Manager & Surrogation (shipped)

Keychain primary, Docker vault optional, `config.toml` for non-sensitive settings only. Secrets never enter logs, prompts, or index.

**Credential surrogation**: `api.request` header values may reference `rwsecret:<key>` surrogates. `SecretsManager` issues (`surrogate(for:)`), resolves (`resolve(_:)`), and sweeps (`redactResolved(_:)`) them. Resolution happens just-in-time at the transport boundary so the real value is never model-visible; the surrogate is a reference, not a copy, and dry-run previews never show the real value. A surrogate with inner whitespace is rejected so issuance and resolution agree. `ApiHeaderPolicy.redacted` also redacts any resolved secret values that echo into outputs. Surrogate resolution is now performed under the mandatory `OutboundEgressSupervisor` choke-point (§15), which also sweeps responses for echoed secrets.

### 7. Scheduler, Goals & Run Execution Engine (shipped)

Cron plus polling plus goal cadence and event triggers, with SQLite as source of truth. Per-run sessions (`source: scheduler` or `source: goal`) with fresh `UUID()` per execution, parked `awaiting_approval` resume through the inbox, and per-firing-class single-flight per process (a dedicated goal run lock so goal and job firings never collide). Downtime semantics: `next_due_at` drives firing; there is no catch-up stacking after a long sleep — a skipped-while-down firing simply re-dueues on the next interval. Each run persists a `run_logs` row (`kind` = `scheduler`, `goal`, `fanout`, or `fanout_worker`) linked to its session and, where applicable, its goal.

**Event triggers**: `goal_triggers` rows (goal id, event kind, optional substring pattern, cooldown, last-fired) arm a goal for event wake-up. `GoalTriggerBridge` runs in the worker tick, polls recent goal and episode events within a bounded lookback, and on a kind/pattern match whose cooldown has elapsed sets `next_due_at = now`. The existing due-firing path then picks it up unchanged. The bridge stays event-kind-agnostic so future event sources extend in one place; there is no catch-up stacking (one match per cooldown window).

### 8. Goals Subsystem (shipped)

Goals are durable first-class entities: each owns a plan (ordered steps with statuses), an event log, and a cadence. State lives in `episodes.db` (`goals`, `goal_steps`, `goal_events`, `goal_triggers`), opened via the shared Core store idiom with additive, best-effort migrations (`sessions.goal_id`, `run_logs.goal_id`).

- **Model**: `GoalStatus` (`active`, `paused`, `needs_input`, `achieved`, `abandoned`), `StepStatus` (`pending`, `inProgress`, `done`, `blocked`, `skipped`), `GoalEventKind` (`created`, `planReady`, `stepStarted`, `stepDone`, `stepBlocked`, `needsInput`, `completed`, `resumed`, `paused`, `note`). `GoalStore` is an actor behind a `GoalStoring` seam; `nextActionableStep` deterministically selects the lowest-ordinal pending/in-progress step.
- **Engine**: `GoalEngine` (actor) with an injected LLM. `create` enforces `[goals] enabled` plus the active-goal cap, persists one placeholder step, then decomposes via ONE LLM call bounded to `maxStepsPerGoal`. Defensive parse (strip fences, outermost array); on parse failure/timeout it falls back to a single "Work toward: …" step plus a note — a goal is never lost because planning was flaky. `postAdvance` re-reads steps after the turn and, when no actionable step remains, marks the goal achieved; the cadence advances `next_due_at`.
- **Advance composition**: dynamic goal state never enters the cached system-prompt prefix. `advancePrompt(goal:steps:events:)` composes the per-run prompt into the `UserInput` text (plan with statuses, last 5 events, instructions to advance exactly one step and record blockers honestly).
- **Firing**: an ordinary orchestrator turn with a fresh per-run session (`source: "goal"`, `goal_id` stamped), a `run_logs` row `kind="goal"`, WSHub broadcast, and parked `requiresApproval` turns resuming through the inbox. No bypass of the permission gate.
- **Tools**: `goal.create` (`requiresApproval` — commits recurring autonomous work) and `goal.status`/`goal.progress` (`readOnly` ledger bookkeeping). `goal.progress` resolves the current session's linked goal, falls back to the single active goal, and returns typed guidance on ambiguity rather than guessing.
- **REST**: `GET /goals` (status filter), `POST /goals`, `GET /goals/:id`, `PATCH /goals/:id` (edits + pause/resume), `DELETE /goals/:id` (abandoned tombstone; `?purge=true` hard-delete), `POST /goals/:id/advance` (single-flight contention → `409`), `PATCH /goals/:id/steps/:stepId`, `GET /goals/summary`. Emits `goal_updated` WS frames on create/plan-ready/progress/status-change/advance.
- **Surfaces**: a CLI `goals` command (list/add/show/pause/resume/advance/abandon/steps, direct-core, no session linking) and the dashboard (see §13).

### 9. Proactive Surfacing Gate (shipped)

`OutcomeGate` (Core) decides `(surface, headline)` for every scheduler/goal completion that would otherwise notify unconditionally. Modes come from `[proactive] mode`:

- **all** (default — preserves prior behavior): surface everything.
- **milestones**: goal milestones (step-done/achieved/needs-input/blocked) plus errors plus parked approvals only.
- **guarded**: milestones, plus one cheap LLM judgment (with timeout) for everything else; a judge error or unparseable result fails OPEN to surface — never silently swallow something the owner might need.
- **off**: never surface.

The gate filters interruptions ONLY — run history, WSHub run frames, and the approvals inbox record regardless of mode. Surfacing to the browser goes over the `proactive_message` WS frame on the existing hub (no new transport), so the dashboard can raise a Web Notification/badge even with no macOS notifier.

### 10. Ideas Engine (shipped, opt-in)

`IdeasStore` (actor, `episodes.db`, `ideas` table) and `IdeasEngine` (actor, injected LLM) proactively suggest next moves. One cheap LLM call reviews recent goal outcomes plus a memory-facts summary and produces `0..maxPerCycle` ideas (`planAdjustment`, `newGoal`, `tip`). Defensive parse; on failure/timeout it returns an EMPTY array (never hallucinate because planning was flaky). Dedup skips titles equal to an existing non-dismissed idea. Generation is triggered after a goal is achieved (the natural "what next?" moment) and on a nightly cadence hook, both behind `[ideas] enabled` (default false).

REST: `GET /ideas`, `GET /ideas/summary`, `POST /ideas/:id/dismiss`, `POST /ideas/:id/accept`. Accept routes through the engine with the same honest errors as `POST /goals`: a `planAdjustment` applies via `replacePlan` on the linked goal (only when it still exists and is active, else `409`), a `newGoal` creates via `engine.create`. Ideas surface on the dashboard and ride the `proactive_message` frame with kind `idea_proposed`.

### 11. Multi-Agent Fan-Out (shipped, opt-in)

`FanOutEngine` (actor) behind a narrow `OrchestratorFanOutSeam` spawns concurrent worker turns for a set of caller-composed subtasks. Each worker gets a fresh per-run session (`source: "fanout_worker"`), a read-only tool subset via `UserInput.allowedTools` (nil = full registry; `fanout.run` passes the read-only names unless `[fanout] full_tools`), and `run_logs` rows — a `kind="fanout"` parent plus `kind="fanout_worker"` children — so the swarm is fully auditable in the Runs tab. Workers fan out via a `TaskGroup`; if the orchestrator serializes concurrent turns, workers stay sequential-but-bounded rather than forcing a core rewrite.

**Enablement (single gate)**: fan-out has no background entry point — a swarm runs only when the `fanout.run` tool is invoked — so the persisted tool-state toggle is the sole enablement authority. The tool ships disabled and appears in `GET /tools`; `[fanout]` carries only behavior knobs (`max_workers` default 2, `worker_timeout_seconds` default 0 = unlimited, `full_tools` default false) and no enablement key. Settings → Tools configures the knobs with live reload. `fanout.run` stays `requiresApproval` (it spawns autonomous work): approval is the per-call permission, separate from enablement.

**Timeout**: `worker_timeout_seconds = 0` means no wall-clock budget, because a local model serving a worker turn can take minutes and a short default would kill workers mid-turn. Owners may set a positive budget (clamped 1–86400s); the bound on an unbounded worker is owner cancellation, not a timer.

**Cancellation (cooperative, engine-owned)**: the engine keeps an active-run registry keyed by the run-log row ids it mints. `POST /runs/:id/cancel` cancels one running worker (child row) or the whole swarm (parent row); a cancel arriving before a worker registers is remembered and applied at registration, so there is no start race. Cancellation propagates Task cancellation to the worker's orchestrator turn — the same cooperative contract as the chat window — and a worker that ignores cancellation still ends when its current await returns; nothing is force-killed. Chat's existing per-tool cancel aborts the whole `fanout.run` call and now also yields honest statuses.

**Statuses**: `FanOutSubtask.Status` and `FanOutRun.Status` include `cancelled`, and the child/parent run rows use the existing `cancelled` run status. Cancellation outranks failure for the owner's reading (a stopped swarm reads `cancelled`, not `error`), while sibling workers keep running when only one is cancelled.

**Merge**: deterministic overlap detection first (exact file-path/URL collisions between outputs are flagged conflict), then ONE background reviewer LLM pass over the collected outputs producing a merged summary plus per-subtask verdicts (keep/drop/conflict). The reviewer judges content quality, not permissions. Fail-open: a reviewer error yields the raw concatenation with an honest note, so worker output is never lost. An all-cancelled run skips the reviewer and carries a short honest summary.

### 12. Voice Pipeline (partial)

Local Whisper STT, system TTS; push-to-talk planned.

### 13. Client Layer

**macOS App — shipped**: Menu-bar chat, approvals, scheduler summary, dashboard/settings shortcuts, Desktop Control section when enabled.

**Web Dashboard — shipped**: chat with session sidebar and clock-badged background sessions, memory, run history (with fan-out worker grouping and cancel controls for running swarms), approvals, index status, tools config (including the fan-out run policy with live apply), declarative security policy (visual overview, invariant-status banner, and a raw-TOML editor with real-time candidate verification), goals management, and an ideas panel. Navigation is grouped — **Chat** and **Approvals** stand alone as direct views; **Work** groups Goals/Schedules/Runs; **Memory** groups Search and Memory plus Index Status — using click/keyboard-only dropdown mechanics (click-toggle, click-outside, Escape closes and returns focus, `aria-haspopup`/menu; no hover-open path). The active goal is surfaced inline in chat as a header chip that opens a right-side `GoalDrawer` (plan checklist, recent events, linked runs, pause/resume, advance-now, "Open in Goals"). A `goal_updated` WS frame refreshes the chip/summary list; `proactive_message` raises a Web Notification with the headline and bumps the goals-attention badge (which clears when the Goals tab opens), falling back to badge-only when notification permission is absent. All model-authored content renders through the sanitized `MarkdownText` (zero `dangerouslySetInnerHTML`, protocol-whitelisted URLs).

**iOS — planned**.

### 14. Document Index (shipped, opt-in)

Local single-owner pre-built index: pay once, answer from index, fall back to live reads. Off by default with per-source files/mail/messages toggles. SQLite `indexed_documents` + `indexed_chunks` + FTS5 porter plus embedding BLOB, content-hash skip, per-mailbox UID and Messages ROWID watermarks, best-effort extraction with status, `BODY.PEEK` mail reads, bounded vectorization (`mail_vector_window`, size rule), nightly plus on-demand `IndexCoordinator` runs with `liveTotals`, `index_as_of` watermark, and prune/reset maintenance. Vector pool width and fusion weights are governed by recall budgets; injected hits always preserve file/mail citations so the model can answer with paths and dates without re-walking. Indexed mail is stored in its credential-redacted form so search recall cannot resurrect a redacted link.

### 15. Declarative Security Policy & Outbound Egress Supervision (shipped)

A declarative, owner-editable `~/.runeweaver/policy.toml` governs outbound network egress and credential use for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action`. Three fail-closed actor components own it:

- **`PolicyStore`** (`PolicyStore.swift`, Core): the single owner of the policy file. Every load and every update runs `PolicyInvariantVerifier.verify` before the policy is accepted; an unreadable or failing file seeds factory-safe defaults (deny-by-default) rather than permissive ones. `snapshot()` returns the verified in-memory policy or throws — there is no permissive fallback state.
- **`PolicyInvariantVerifier`** (`PolicyInvariantVerifier.swift`, Core): four formal invariants checked at the storage boundary (on load and on every update) and on demand — (1) **path containment**: no allow root covers protected directories (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library/Keychains`, `~/.runeweaver/memory`, `~/.runeweaver/config.toml`, `~/.runeweaver/policy.toml`), and that protected set always applies even when `deny_paths` is narrowed or emptied; (2) **credential confinement**: credentials cannot target unbounded wildcards (a single leading `*.` edge authorizes its base domain plus subdomains, with the base checked like an exact host), cloud metadata (`169.254.169.254`, `metadata.google.internal`), loopback, or private RFC 1918 ranges; (3) **rule-shadow prevention**: broad allowlists never shadow or conflict with specific deny rules; (4) **critical tool lock**: `messages.send`, `desktop.action`, `desktop.screenshot` cannot be raised to `trusted` via policy.
- **`OutboundEgressSupervisor`** (actor, `OutboundEgressSupervisor.swift`, Tools): the multi-consumer choke-point for `api.request`, `web.fetch` (per-hop `validateHopSafety`), `browser.navigate`/`browser.act` (per-entry and per-hop `EgressPolicy.validateURLAsync`), `bash.exec` (explicit plus schemeless `screenExplicitURLs`), and `desktop.action` (typed-URL `screenBatchURLs`). `validate()` gate order: (1) network policy gate (canonicalized exact and wildcard domain match, honoring session and one-shot grants), (2) credential target-binding gate (verify credential host, method, path prefix), (3) SSRF guard (`ApiSSRFGuard`), (4) just-in-time wire injection (swap `rwsecret:<key>` for the live Keychain value), followed by `sweepResponse` redaction of echoed secrets. `validateReadOnly()` applies the same network gate (including grants) plus SSRF with no credential binding and no Keychain access. Network and binding checks run BEFORE Keychain access or DNS resolution, so a denied destination never causes a network side effect. The SSRF gate returns a **dial pin** — the numeric addresses it proved plus the original host identity — and the `api.request` transport (`PinnedDialTransport.swift`) dials only those pinned addresses, presenting the original `Host` header and TLS server name and validating the peer certificate against that host. The hostname is never resolved again after vetting, so a rebinding answer cannot steer a hop to a destination the gate refused; every redirect hop carries its own pin from its own supervised pass, and the transport fails closed when a dial arrives without a pin.

**Production wiring contract**: the supervisor is mandatory at every production entry point. `ApiRequestTool` takes a non-optional supervisor (no default-nil); `BuiltinToolPlugins.makeAllTools(config:policyStore:)` uses exactly ONE `PolicyStore` instance per process (the caller injects it, or the factory constructs it when nil), builds the supervisor via `OutboundEgressSupervisor.make(policyStore:)` (which reads the verified `snapshot()` and throws when no verified policy exists), and threads it through `ApiRequestTools.makeTools` plus the web, browser, bash, and desktop tool factories with per-tool session threading. CLI and menu-bar app exit nonzero at boot when the policy cannot be verified — no supervisor-less fallback path exists. The server's `ServerContext.make` always injects a verified supervisor or throws at boot; the context type holds the supervisor as optional only for fallback and test doubles, and `applyEgressDecision` (REST plus WebSocket triage sharing one handler) fails closed when the supervisor is nil. The server's `ServerSettingsRoutes` shares the SAME store instance between the tool-rebuild path and the `GET/PUT/POST /settings/policy` routes, so an HTTP policy write is visible to the supervisor immediately without a restart; there is no filesystem watcher — the actor state is authoritative within the process and the file is source of truth at first construction. `PolicyStore.appendAllowedDomain`/`appendBlockedDomain` verify, write the file first, then commit to memory, so a throwing disk write never diverges memory from file. Seatbelt profiles deny `~/.runeweaver/policy.toml` to sandboxed subprocesses so policy cannot be altered from inside a sandboxed shell.

**Surfaces**: CLI `rune-weaver policy show/verify/init` (verify runs all four invariants on demand); dashboard Security tab (visual egress-boundaries overview, target-bound credentials table, invariant-status banner, and a raw-TOML editor with real-time candidate verification); REST `GET /settings/policy` (parsed DTO + raw TOML + live invariant status), `PUT /settings/policy` (atomically validates invariants then persists), and `POST /settings/policy/verify` (candidate verification for editors).

Scope note: `web.fetch` (per-hop `validateHopSafety`), browser `navigate`/`act` (per-entry and per-hop `EgressPolicy.validateURLAsync`), `bash.exec` (explicit plus schemeless `screenExplicitURLs`), and `desktop.action` (typed-URL `screenBatchURLs`) are supervised in this cycle through `OutboundEgressSupervisor.validate` alongside `api.request`, each threading its calling session so interactive grants stay scoped; all keep their existing SSRF/redirect guard stacks (sensitive-range table single-sourced with `api.request`) layered beneath the policy gate. Triage badges the first host while enforcement screens every host, so multi-host batches re-park iteratively. Follow-up: extend declarative credential target-binding beyond `api.request` and unify multi-host badging.

---

## INTEGRATIONS

### Shipped

**Email**: IMAP search/read via `BODY.PEEK`, attachment staging, approval-gated send, with deterministic redaction of credential-bearing mail at the agent-visible boundary. **Apple Messages**: snapshot-copy search/read plus gated send. **Browser/web**: `web.search`, `web.fetch` (supervised per-hop egress), `browser.navigate` + `act` (supervised entry plus per-hop egress), `api.request` (surrogate-aware headers supervised by the mandatory `OutboundEgressSupervisor`, §15). **Desktop**: `desktop.screenshot` plus gated `desktop.action` (typed URLs supervised per batch, §15), off by default behind tool-state toggle. **Media**: `media.arr` gated plus `media.arr.read`. **Files & documents**: direct reads plus grep/glob via `FilesAccessGuard`. **Local document index**: opt-in FTS5 plus vectors feeding `memories.recall`. **Goals/ideas/fan-out**: durable goals with proactive surfacing, an opt-in ideas engine, and opt-in multi-agent fan-out with per-worker/whole-run cancellation. **Declarative policy**: `~/.runeweaver/policy.toml` with CLI/dashboard/REST management surfaces (§15).

### Planned

Apple Mail native, HomeKit/Home Assistant control, Discord, GitHub, Calendar (config stubs only).

---

## SECURITY MODEL

1. **Read by default, write with permission**.
2. **Least privilege**.
3. **Sandbox before trust**.
4. **No secrets in prompts**.
5. **Audit trail** locally with timestamps and inputs.
6. **Defense in depth for external content**: declaration-driven untrusted labeling, deterministic credential filtering, single-sourced SSRF egress, and surrogate credential references.
7. **Declarative deny-by-default egress**: `~/.runeweaver/policy.toml` verified by formal invariants at the storage boundary and enforced at a single mandatory choke-point (`OutboundEgressSupervisor`) for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action`; unverifiable policy fails closed at boot, and supervisor denial is evaluated before Keychain or DNS side effects.

Sandbox paths under `~/.runeweaver/` for config, `policy.toml`, `index.db`, `memory/episodes.db`, `memory/vectors/`, logs, plugins, voice models. The policy file itself is additionally denied to sandboxed subprocesses via the Seatbelt profile.

---

## MVP SCOPE (with build status — detail in ROADMAP.md)

Phase 1 Foundation — shipped. Phase 2 Memory — shipped (routed recall with budgets, starter pack, diagnostics). Phase 3 Email — shipped except Apple Mail native. Phase 4 Browser & Multi-step — tools shipped. Phase 5 Home & Communication — partial (Messages shipped). Phase 6 Voice & Polish — partial. Phase 7 Self-Improvement — partial. Phase 8 Service & Runtime — shipped except launchd/iOS, and now includes the Goals subsystem, proactive surfacing gate, Ideas engine, and multi-agent fan-out.

---

## CONFIGURATION

```toml
[memory]
vector_db_path = "~/.runeweaver/memory/vectors"
episodes_db_path = "~/.runeweaver/memory/episodes.db"
embedding_model = "all-MiniLM-L6-v2"
embedding_backend = "apple"
recall_per_tier_limit = 5
recall_auto_limit = 5
recall_threshold = 0.1
recall_max_chars = 2000
recall_per_hit_chars = 500
recall_doc_pool_multiplier = 4
recall_episodic_weight = 0.25

[index]
enabled = false
files = true
mail = false
messages = false
roots = ["~"]
exclude = [".git", "node_modules", ".build", "DerivedData", "Library", ".Trash", "*.app"]
max_file_mb = 20
mail_vector_window = "2y"
icloud_evicted = "skip"
describe_images_with_llm = false
nightly_budget = 0
db_path = "~/.runeweaver/index.db"

[security]
untrusted_labeling = true
email_credential_filter = true

[goals]
enabled = false
step_interval_minutes = 1440
max_active_goals = 10
max_steps_per_goal = 12
plan_timeout_seconds = 60
max_triggers_per_goal = 8

[proactive]
mode = "all"          # all | milestones | guarded | off
judge_timeout_seconds = 15

[ideas]
enabled = false
max_per_cycle = 3

# Enablement for fan-out is the `fanout.run` tool toggle (Settings → Tools);
# the section carries policy knobs only.
[fanout]
max_workers = 2
worker_timeout_seconds = 0   # 0 = unlimited
full_tools = false
```

Every section is additive with defaults on absent keys, so existing `config.toml` files load untouched. Full sample retains `[engine]`, `[auth]`, `[llm]`, `[voice]`, `[sandbox]`, `[files]`, `[browser]`, `[desktop]`, `[email]`, `[home]`, `[media.*]`, `[scheduler]`, and `[plugins]` as previously documented. All of these sections round-trip through `Config`/`ConfigTOML`/`Config+Serialization`/`Config+Validation`.

**Separate declarative policy file (`~/.runeweaver/policy.toml`, not part of `config.toml`)**: top-level `version`; `[network]` with `mode` (`allowlist_only` | `deny_by_default` | `unrestricted`), `allowed_domains`, `blocked_domains`; `[credentials."<key>"]` with `allowed_hosts` (exact hosts plus a single leading `*.` subdomain edge), `allowed_methods`, `allowed_path_prefixes`; `[filesystem]` with `allow_roots` and `deny_paths` (declared paths are always enforced together with the fixed protected set); `[tools."<name>"]` with `level` and `allow_graduated_trust`. TOML arrays are single-line per element-list convention (enforced by the parser). The file is owned by `PolicyStore`, editable via CLI `rune-weaver policy` commands or the dashboard raw-TOML editor, and is never written by tools at runtime.

---

## DECISIONS & CONSTRAINTS

### Key Decisions

1. **Swift over Python for core**.
2. **Actor model for concurrency**.
3. **WebSocket for client-server & ephemeral sessions**.
4. **JSON vector store with pluggable embeddings**.
5. **Playwright over Selenium**.
6. **Graduated trust over binary permissions**.
7. **Native WebSocket notifications; osascript only for CLI foreground**.
8. **SQLite as source of truth for scheduler, goals, and runs**.
9. **Per-run job sessions & badged history**.
10. **Dynamic system prompt plus narration fallback**.
11. **Spec-compliant markdown sanitization**.
12. **Unified toolchain & audit**.
13. **ATS local-networking only**.
14. **Disabled-by-default plugin holding pen**.
15. **Status lives in ROADMAP.md**.
16. **SSRF DNS timeout fail-closed (5.0s)**.
17. **Opt-in local document index with incremental refresh**.
18. **Native desktop perception with gated control**.
19. **Host validation & boundary protection**.
20. **Additive `[security]` default-ON policy**.
21. **Declaration-driven content trust**.
22. **Surrogate credential references**.
23. **Deterministic credential filtering for mail**.
24. **Manual redirects with re-validation**.
25. **Canonical memory tool identity with aliases**.
26. **Native Messages read plus gated send**.
27. **Dashboard tools category contract**.
28. **Routed, budgeted, freshness-aware recall with starter pack**: automatic recall is governed by `[memory] recall_*` budgets owned by `MemoryConfig`, planned by `MemoryQueryRouter` (temporal + freshness inference, no LLM), footed by `RecallStarterPack` (`Profile:`, `Index as of:`, `Goal:`), fused with widened-pool RRF plus citation-preserving truncation, and observed via content-free diagnostics. Placement stays before the last user message; retrieval stays fail-closed; labeling stays declaration-driven.
29. **Goals are durable first-class entities, not scheduler jobs**: a goal owns a plan, step statuses, an event log, and a cadence in `episodes.db`; the scheduler executes toward it. Dynamic goal state composes into the advance prompt (UserInput text), never the cached system-prompt prefix. Goal advances are ordinary orchestrator turns and never bypass the permission gate.
30. **Proactive surfacing is gated, default-all**: `OutcomeGate` decides interruptions with modes `all`/`milestones`/`guarded`/`off`, guarded failing open; the gate filters interruptions only and never suppresses run history, WS frames, or the approvals inbox.
31. **Ideas are opt-in, fail-empty**: one cheap LLM call over goal outcomes plus memory facts; a flaky parse yields no ideas rather than fabricated ones; dedup by title.
32. **Event triggers reuse the firing path**: a trigger match sets `next_due_at = now`; no parallel firing machinery, no catch-up stacking (one match per cooldown window).
33. **Multi-agent fan-out is opt-in with read-only workers**: concurrent worker turns get fresh sessions and a read-only tool subset; merge is deterministic overlap flagging first, then one background reviewer pass that fails open to the raw concatenation, and workers never exceed their permission gate. A swarm is cooperatively cancellable — one worker or the whole run — through row-keyed cancel from the Runs surface.
34. **Grouped navigation, click-only menus**: Chat and Approvals stand alone while Work groups Goals/Schedules/Runs and Memory groups Search and Memory plus Index Status; navigation groups tab-state (no router); dropdowns are click/keyboard-only — hover-open is deliberately excluded.
35. **Declarative deny-by-default egress with mandatory supervision**: `~/.runeweaver/policy.toml` is owned by a verifying `PolicyStore` actor (four formal invariants at the storage boundary; atomic file-first appends; factory-safe defaults on failure; `snapshot()` throws when unverified); `OutboundEgressSupervisor` is the multi-consumer choke-point for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action` egress (network gate with session plus one-shot grants → binding gate → SSRF → JIT secret injection → response sweep), mandatory at every production entry point with per-tool session threading, sharing one `PolicyStore` per process with the settings routes so HTTP policy writes apply immediately without restart. Each allowed verdict carries a **dial pin** (the numeric addresses the SSRF gate proved plus the original host identity), and the transport dials that pin with the original `Host` header and TLS server name instead of resolving the hostname again — so the pre-dial gate order also closes the connect-time DNS-rebinding race on the initial URL and every redirect hop, and a missing pin fails closed.
36. **Single-gate enablement for tool-invoked capabilities**: a capability that runs only when its tool is invoked (desktop, fan-out) has exactly one enablement switch — the persisted tool-state toggle — and its config section carries only behavior knobs. It ships disabled and stays visible in `GET /tools`; removing a redundant config `enabled` gate is a correctness fix, not a convenience. Subsystems with background entry points (scheduler, goals, ideas, index) keep a config `enabled` because work can start without a tool call.
37. **Fan-out timeout is opt-out, bounded by cancellation**: `worker_timeout_seconds` defaults to 0 (unlimited) because local inference can exceed any short budget, and a default timer kills workers mid-turn; owners may set a positive budget (clamped 1–86400s). The escape hatch for an unbounded worker is cooperative cancellation, never a forced kill.

### Constraints

- Apple Silicon required for MLX; Intel via llama.cpp/cloud only.
- Single-owner, fail-closed binding and host enforcement, auth-before-exposure, ATS local-networking only.
- Local-first; opt-in indexing; opt-in desktop with OS permissions; Messages send always gated.
- Default-ON hardening; no live secrets in context; fail-closed transport.
- Declarative egress policy: deny-by-default with explicit allowlist only; credentials bound to `allowed_hosts`/`allowed_methods`/`allowed_path_prefixes`; protected directories are never allowable roots; unverifiable `policy.toml` fails closed (CLI exits nonzero, serve refuses boot) — never permissive defaults.
- Bounds: `memories.recall` limit 1–50 default 5; auto-recall bounded by `recall_auto_limit`, `recall_threshold`, `recall_max_chars`, `recall_per_hit_chars`; doc pool bounded by `recall_doc_pool_multiplier` (1–8); episodic weight 0–1; `messages.search` 1–50 default 10; `messages.read` 1–100 default 20; empty text rejected; AppleScript rejects null bytes.
- Goals bounds: `step_interval_minutes` 5–20160; `max_active_goals` 1–50; `max_steps_per_goal` 1–24; `max_triggers_per_goal` 0–32; `plan_timeout_seconds` default 60.
- Fan-out bounds: `max_workers` 1–8 default 2; `worker_timeout_seconds` 0=unlimited, 1–86400 otherwise; `full_tools` default false. Cancellation is cooperative (no hard kill), and only `fanout`/`fanout_worker` rows are cancellable.
- Ideas bound: `max_per_cycle` 1–10 default 3.
- macOS Sequoia or later.

### Code Commenting Guidelines

- **New-File Headers**: Every new source and test file must begin with a descriptive top-of-file header comment documenting the component's purpose, scope, and architectural role.
- **Intent Over Mechanics**: Inline and doc comments must explain rationale, invariants, non-obvious logic, or edge cases rather than restating mechanics.
- **No Planning-Artifact References**: Code comments must never reference task IDs, session IDs, PR numbers, plan identifiers, or other transient planning artifacts.

---

## OPEN QUESTIONS

1. iOS distribution.
2. Plugin updates propagation.
3. Offline behavior when Mac Studio unreachable.
4. Index freshness: nightly plus on-demand now supplemented by freshness-aware live fallback and watermark surfacing; whether hot-path filesystem watchers are still needed remains open.
5. Proactive-gate tuning: whether `guarded` should also judge non-`schedulerOk` events (e.g. ideas) in addition to milestones.
6. Fan-out concurrency: whether the orchestrator should admit truly concurrent turns or remain sequential-but-bounded under load.