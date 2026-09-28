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
│  │ Push-to-talk │  │ Menu bar app │  │  Chat interface    │    │
│  │ TTS playback │  │ TTS playback │  │  Approvals inbox   │    │
│  │ Notifications│  │ Voice toggle │  │  Memory / Schedules│    │
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
│  │  │   Engine    │  │  Gate        │  │              │  │    │
│  │  │             │  │              │  │  Cron-like   │  │    │
│  │  │ Short-term  │  │  Graduated   │  │  triggers &  │  │    │
│  │  │ Long-term   │  │  trust model │  │  event hooks │  │    │
│  │  │ Vector +    │  │  Sandboxing  │  │              │  │    │
│  │  │ Structured  │  │              │  │              │  │    │
│  │  └─────────────┘  └──────────────┘  └──────────────┘  │    │
│  │                                                          │    │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  Secrets    │  │  Voice       │  │  Document    │  │    │
│  │  │  Manager    │  │  Pipeline    │  │  Index       │  │    │
│  │  │             │  │              │  │              │  │    │
│  │  │ Keychain +  │  │  Whisper STT │  │  SQLite FTS5 │  │    │
│  │  │ Docker vault│  │  TTS output  │  │  + vectors   │  │    │
│  │  └─────────────┘  └──────────────┘  └──────────────┘  │    │
│  │                                                          │    │
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

The Document Index is not a separate process: it is an actor-backed local store inside the core engine, sitting beside the other Support Services and feeding `memories.recall`. See Component Details §10.

Shipped tool set: Email IMAP/SMTP (`email.search`, `email.read`, `email.attachment`, `email.send`, `email.listMailboxes`, `email.move`), web + browser (`web.search`, `web.fetch`, `browser.navigate`, `browser.act`, `api.request`), files (`files.read`, `files.grep`, `files.glob`), memory (`memories.store` canonical with `remember_fact` alias, `memories.recall` canonical with `recall_memories` alias), Apple Messages (`messages.search` read-only, `messages.read` read-only, `messages.send` approval-gated with dry-run preview), media automation (`media.arr` approval-gated plus `media.arr.read` read-only), desktop perception and control (`desktop.screenshot` read-only plus `desktop.action` approval-gated; always registered but fail-closed — ships disabled and runs only when the persisted tool-state toggle enables it).

### Engine-to-Service Shift

The core engine is shifting from a CLI-only tool to a local service that other UIs drive through one HTTP surface.

- **Vapor API layer**: A Vapor service fronts the core engine and exposes chat, health, tools, memory, approvals, runs, and scheduler operations as JSON routes. The CLI remains direct-core for v1. The service launches from the CLI binary via `rune-weaver serve`, which builds a `ServerContext` with `ServerContext.make(...)`.
- **CLI index wiring (shipped)**: The CLI chat loop inspects `config.index.enabled`. When enabled it resolves `config.index.databasePath(in: stateDir)` and passes `docIndexDBPath` into the memory engine, so terminal turns get the same indexed candidates as the service.
- **WebSocket event hub & real-time streaming**: The service maintains `/ws` managed by `WSHub`. In-flight turns support mid-turn cancellation via WebSocket or REST, aborting via `ActiveTurnTracker`.
- **Authoritative concurrent-turn cap**: `ActiveTurnTracker.maxConcurrentTurns = 3` bounds simultaneous chat turns. `GET /health` advertises the cap.
- **Durable SQLite persistence for scheduler & run history**: Jobs and run logs persist in `episodes.db`. `config.toml` jobs are bootstrap seed only when the database has zero jobs.
- **Static dashboard bundle**: Served by the engine itself with chat, memory, scheduler, run history, approvals inbox, and index status surfaces.
- **Same trust boundary**: Every service-triggered write still flows through the permission gate. The service adds transport; it does not bypass approvals.
- **Single-owner bearer auth & ephemeral browser sessions (shipped)**: Exactly one owner token guards the engine HTTP surface. Browser clients exchange it via `POST /auth/session` for an ephemeral `HttpOnly`, `SameSite=Strict` cookie. Rotation invalidates live sessions.
- **Fail-closed binding (shipped)**: Loopback always serves. Non-loopback requires a resolved token or boot is refused.
- **Service auto-fire plus per-process single-flight**: Service auto-fires scheduler triggers sharing one lock with manual runs; CLI foreground loop is a second runner — run one at a time.

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine owns orchestration, conversation state, and provider routing.

- **Orchestration**: Receives user input, routes through the LLM, executes tool calls, returns responses.
  - **Dynamic System Prompt Composition**: `SystemPromptComposer` snapshots `ToolBus.availableTools()` and generates a deterministic prompt with tool names, descriptions, schemas, permission levels, policies, and memory guidance. Canonical memory names are advertised; aliases never are.
  - **Narration Fallback for Local LLMs**: `OrchestratorToolLoop` extracts read-only calls from text narration; gated narrations file approvals and park until decided.
  - **In-Flight Turn Cancellation**: `ActiveTurnTracker` tracks running turns across WebSocket and REST.
- **Conversation Manager**: Session state, history, and context windows across durable SQLite tables, hydrating from disk.
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

### 3. Tool Plugin System

Tools declare name, description, JSON Schema, permission level (`readOnly`, `requiresApproval`, `trusted`), and handler. `ToolBus` carries aliases; `MemoryTools.registerMemoryAliases` registers `remember_fact`/`recall_memories` once. Python tools run out-of-process via JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`).

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

Levels `readOnly`, `requiresApproval`, `trusted` with graduated trust (this time / 5m / 1h / 1d / forever). `memories.store`/`recall` are `trusted`; `messages.send`, `desktop.action`, `browser.act`, `api.request`, `media.arr`, `goal.create/progress` require approval.

### 6. Secrets Manager (shipped)

Keychain primary, Docker vault optional, `config.toml` for non-sensitive settings only. Secrets never enter logs, prompts, or index.

### 7. Scheduler & Run Execution Engine (shipped)

Cron plus polling, SQLite source of truth, per-run sessions (`source: scheduler`), parked `awaiting_approval` resume, single-flight per process.

### 8. Voice Pipeline (partial)

Local Whisper STT, system TTS; push-to-talk planned.

### 9. Client Layer

**macOS App — shipped**: Menu-bar chat, approvals, scheduler summary, dashboard/settings shortcuts, Desktop Control section when enabled. **Web Dashboard — shipped**: chat, memory, scheduler, runs, approvals, index status, tools config. **iOS — planned**.

### 10. Document Index (shipped, opt-in)

Local single-owner pre-built index: pay once, answer from index, fall back to live reads. Off by default with per-source files/mail/messages toggles. SQLite `indexed_documents` + `indexed_chunks` + FTS5 porter plus embedding BLOB, content-hash skip, per-mailbox UID and Messages ROWID watermarks, best-effort extraction with status, `BODY.PEEK` mail reads, bounded vectorization (`mail_vector_window`, size rule), nightly plus on-demand `IndexCoordinator` runs with `liveTotals`, `index_as_of` watermark, and prune/reset maintenance. Vector pool width and fusion weights are governed by recall budgets; injected hits always preserve file/mail citations so the model can answer with paths and dates without re-walking.

---

## INTEGRATIONS

### Shipped

**Email**: IMAP search/read via `BODY.PEEK`, attachment staging, approval-gated send. **Apple Messages**: snapshot-copy search/read plus gated send. **Browser/web**: `web.search`, `web.fetch`, `browser.navigate` + `act`, `api.request`. **Desktop**: `desktop.screenshot` plus gated `desktop.action`, off by default behind tool-state toggle. **Media**: `media.arr` gated plus `media.arr.read`. **Files & documents**: direct reads plus grep/glob via `FilesAccessGuard`. **Local document index**: opt-in FTS5 plus vectors feeding `memories.recall`.

### Planned

Apple Mail native, HomeKit/Home Assistant control, Discord, GitHub, Calendar (config stubs only).

---

## SECURITY MODEL

1. **Read by default, write with permission**.
2. **Least privilege**.
3. **Sandbox before trust**.
4. **No secrets in prompts**.
5. **Audit trail** locally with timestamps and inputs.

Sandbox paths under `~/.runeweaver/` for config, `index.db`, `memory/episodes.db`, `memory/vectors/`, logs, plugins, voice models.

---

## MVP SCOPE (with build status — detail in ROADMAP.md)

Phase 1 Foundation — shipped. Phase 2 Memory — shipped (now routed recall with budgets, starter pack, diagnostics). Phase 3 Email — shipped except Apple Mail native. Phase 4 Browser & Multi-step — tools shipped. Phase 5 Home & Communication — partial (Messages shipped). Phase 6 Voice & Polish — partial. Phase 7 Self-Improvement — partial. Phase 8 Service & Runtime — shipped except launchd/iOS.

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
```

Full sample retains `[engine]`, `[auth]`, `[llm]`, `[voice]`, `[sandbox]`, `[files]`, `[browser]`, `[desktop]`, `[email]`, `[home]`, `[media.*]`, `[scheduler]`, `[plugins]`, `[security]` as previously documented; only `[memory]` gains the `recall_*` budget keys above.

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
8. **SQLite as source of truth for scheduler and runs**.
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

### Constraints

- Apple Silicon required for MLX; Intel via llama.cpp/cloud only.
- Single-owner, fail-closed binding and host enforcement, auth-before-exposure, ATS local-networking only.
- Local-first; opt-in indexing; opt-in desktop with OS permissions; Messages send always gated.
- Default-ON hardening; no live secrets in context; fail-closed transport.
- Bounds: `memories.recall` limit 1–50 default 5; auto-recall bounded by `recall_auto_limit`, `recall_threshold`, `recall_max_chars`, `recall_per_hit_chars`; doc pool bounded by `recall_doc_pool_multiplier` (1–8); episodic weight 0–1; `messages.search` 1–50 default 10; `messages.read` 1–100 default 20; empty text rejected; AppleScript rejects null bytes.
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